#!/usr/bin/env python3
"""Run Coldfall for a while under load and fail if it grows, stalls or burns CPU.

Coldfall once grew to about 100GB over half a day: its usage meter re-read a
busy desk's whole conversation every two minutes, the passes outlasted the gap
and piled up. Nothing short-lived would have shown it. This does what a day of
use does, faster:

  - a throwaway home (never the real one), with N stand-in desks that print a
    line every half second, opened through `coldfall-cli open`;
  - a fake Claude conversation of about 150MB in that home, growing every
    second the way a busy desk's does (replies with usage, big tool results);
  - the built app, with its update check pointed nowhere.

Every second it reads how fresh the app's status file is (what `coldfall-cli`
goes by); every ten it reads the app's memory footprint and CPU. At the end:

  memory   footprint at the end minus at the warm-up mark  < --grow MB
  status   longest the status file went without a write    < 5 s
  cpu      average CPU after warm-up                       < --cpu %

Usage (from the repo, after `swift build -c release` in app/):

  scripts/soak.py                      # 10 minutes, 12 desks
  scripts/soak.py --minutes 30 --desks 24
  scripts/soak.py --app "$HOME/Applications/Project Coldfall.app/Contents/MacOS"

Exits 0 when all three hold, 1 when one doesn't. It never touches a running
Coldfall: it starts and ends only the one it launched.
"""
import argparse, json, os, re, shutil, signal, subprocess, sys, tempfile, threading, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--minutes", type=float, default=10)
ap.add_argument("--desks", type=int, default=12)
ap.add_argument("--warmup", type=float, default=2, help="minutes before the memory baseline")
ap.add_argument("--grow", type=float, default=150, help="allowed footprint growth after warm-up, MB")
ap.add_argument("--cpu", type=float, default=25, help="allowed average CPU %% after warm-up")
ap.add_argument("--transcript-mb", type=int, default=150)
ap.add_argument("--app", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", ".build", "release"),
                help="folder holding Coldfall and coldfall-cli")
ap.add_argument("--keep", action="store_true", help="leave the throwaway home for a look afterwards")
a = ap.parse_args()

app_bin = os.path.join(a.app, "Coldfall")
cli_bin = os.path.join(a.app, "coldfall-cli")
for b in (app_bin, cli_bin):
    if not os.access(b, os.X_OK):
        sys.exit(f"not found: {b} (build first: cd app && swift build -c release)")

# Short: holder sockets must fit in 104 bytes.
home = tempfile.mkdtemp(prefix="cfsoak.", dir="/tmp")
env = {k: v for k, v in os.environ.items() if not k.startswith("COLDFALL_")}
env.update(HOME=home, CFFIXED_USER_HOME=home, COLDFALL_UPDATE_URL="http://127.0.0.1:9")
cfg = os.path.join(home, ".config", "coldfall")
os.makedirs(cfg)

agent = os.path.join(home, "agent.py")
with open(agent, "w") as f:
    f.write(r'''import sys, time, random, threading
def read():
    for line in sys.stdin: print("got:", line.strip(), flush=True)
threading.Thread(target=read, daemon=True).start()
n = 0
while True:
    n += 1
    print(f"\x1b[32mstep {n}\x1b[0m " + "x" * random.randint(20, 120), flush=True)
    if n % 40 == 0: print("\x1b]7501;state=working\x1b\\", end="", flush=True)
    time.sleep(0.5)
''')

names = [f"d{i:02d}" for i in range(a.desks)]
with open(os.path.join(cfg, "desks.toml"), "w") as f:
    for n in names:
        f.write(f'[desk.{n}]\nruntime = "claude"\ncommand = "python3 {agent}"\ncwd = "{home}"\nkeep_running = false\n\n')

# A conversation that grows like a busy desk's.
proj = os.path.join(home, ".claude", "projects", "-srv-demo")
os.makedirs(proj)
convo = os.path.join(proj, f"{uuid.uuid4()}.jsonl")
def stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
def reply(i):
    return json.dumps({"type": "assistant", "timestamp": stamp(), "message": {
        "id": f"msg_{i}", "model": "claude-sonnet-4-5",
        "content": [{"type": "tool_use", "id": f"tu_{i}", "name": "Bash", "input": {"command": "ls"}}],
        "usage": {"input_tokens": 10, "cache_creation_input_tokens": 100,
                  "cache_read_input_tokens": 50000, "output_tokens": 200}}}) + "\n"
def result(i, size):
    return json.dumps({"type": "user", "timestamp": stamp(), "message": {"content": [
        {"type": "tool_result", "tool_use_id": f"tu_{i}", "content": "r" * size}]}}) + "\n"
with open(convo, "w") as f:
    f.write(json.dumps({"type": "custom-title", "customTitle": "d00"}) + "\n")
    i, written = 0, 0
    while written < a.transcript_mb << 20:
        chunk = reply(i) + result(i, 60_000)
        f.write(chunk); written += len(chunk); i += 1
stop = threading.Event()
def grow():
    j = i
    while not stop.is_set():
        with open(convo, "a") as f:
            f.write(reply(j) + result(j, 40_000))
        j += 1
        stop.wait(1)

print(f"home {home}\nconversation {os.path.getsize(convo) >> 20}MB, {a.desks} desks, {a.minutes} minutes")
log = open(os.path.join(home, "app.log"), "w")
app = subprocess.Popen([app_bin], env=env, stdout=log, stderr=log, start_new_session=True)
status = os.path.join(home, ".local", "share", "coldfall", "remote", "status.json")

def cli(*args):
    return subprocess.run([cli_bin, *args], env=env, capture_output=True, text=True, timeout=30)

def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB)", out)
    if not m: return None
    v = float(m.group(1)); return v / 1024 if m.group(2) == "KB" else v * 1024 if m.group(2) == "GB" else v

def cpu(pid):
    out = subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return float(out) if out else None

failed = []
try:
    # Up and answering.
    t0 = time.time()
    while time.time() - t0 < 30 and json.loads(cli("running").stdout or "{}").get("coldfallRunning") is not True:
        time.sleep(0.5)
    if app.poll() is not None: sys.exit("Coldfall exited at launch; see app.log in " + home)
    for n in names:
        r = cli("open", n)
        if r.returncode != 0: print(f"open {n}: {r.stdout.strip()} {r.stderr.strip()}")
    threading.Thread(target=grow, daemon=True).start()

    start = time.time(); end = start + a.minutes * 60; warm = start + a.warmup * 60
    last_write, max_gap, rows, base = None, 0.0, [], None
    next_sample = start
    while time.time() < end:
        if app.poll() is not None:
            failed.append(f"Coldfall exited during the run (code {app.returncode})"); break
        try:
            t = json.load(open(status))["time"]
            # After warm-up only: starting a dozen desks at once may stall it briefly.
            if time.time() > warm:
                if last_write is not None and t != last_write: max_gap = max(max_gap, t - last_write)
                max_gap = max(max_gap, time.time() - t)
            last_write = t
        except Exception:
            pass
        now = time.time()
        if now >= next_sample:
            fp, c = footprint_mb(app.pid), cpu(app.pid)
            rows.append((now - start, fp, c))
            if base is None and now >= warm: base = fp
            print(f"  {int(now - start):5d}s  {fp or 0:8.0f} MB  {c or 0:5.1f}% cpu  status gap max {max_gap:4.1f}s", flush=True)
            next_sample = now + 10
        time.sleep(1)

    after = [r for r in rows if r[0] >= a.warmup * 60 and r[2] is not None]
    avg_cpu = sum(r[2] for r in after) / len(after) if after else 0
    final = rows[-1][1] if rows else None
    grew = (final - base) if (final is not None and base is not None) else None
    print()
    print(f"memory  {base or 0:.0f} MB after warm-up, {final or 0:.0f} MB at the end: "
          + (f"grew {grew:.0f} MB (limit {a.grow:.0f})" if grew is not None else "not measured"))
    print(f"status  longest without a write: {max_gap:.1f}s (limit 5)")
    print(f"cpu     average after warm-up: {avg_cpu:.1f}% (limit {a.cpu:.0f})")
    if grew is None: failed.append("memory wasn't measured (run longer than the warm-up)")
    elif grew > a.grow: failed.append(f"memory grew {grew:.0f} MB")
    if max_gap >= 5: failed.append(f"status went {max_gap:.1f}s without a write")
    if avg_cpu > a.cpu: failed.append(f"average CPU {avg_cpu:.1f}%")
    with open(os.path.join(home, "soak.csv"), "w") as f:
        f.write("seconds,footprint_mb,cpu\n" + "".join(f"{s:.0f},{m or ''},{c or ''}\n" for s, m, c in rows))
finally:
    stop.set()
    if app.poll() is None:
        os.killpg(app.pid, signal.SIGTERM)
        try: app.wait(10)
        except subprocess.TimeoutExpired: os.killpg(app.pid, signal.SIGKILL)
    # Stand-in agents left behind (they run from this home and nowhere else).
    subprocess.run(["pkill", "-f", agent])
    if not a.keep: shutil.rmtree(home, ignore_errors=True)

print("PASS" if not failed else "FAIL: " + "; ".join(failed))
sys.exit(1 if failed else 0)
