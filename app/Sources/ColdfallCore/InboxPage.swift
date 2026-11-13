import Foundation

extension Inbox {
    /// The whole page. Agent output only ever reaches it through textContent,
    /// never innerHTML, so nothing a desk prints can become markup.
    public static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>Coldfall inbox</title>
<style>
:root{--bg:#f7f6f3;--card:#fff;--text:#1d1d1b;--dim:#76746e;--line:#e6e3dc;--accent:#2f6fdb;--green:#2e9d4f;--orange:#d9761c;--term:#fbfaf7}
@media (prefers-color-scheme:dark){:root{--bg:#1b1a19;--card:#242322;--text:#ecebe8;--dim:#9b9892;--line:#34322f;--accent:#6ea0ff;--green:#5cc27a;--orange:#f0a050;--term:#161514}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom)}
header{position:sticky;top:0;background:var(--bg);padding:14px 16px 8px;display:flex;align-items:center;gap:10px;z-index:2}
header h1{font-size:20px;margin:0;flex:1}
header .back{font-size:16px;color:var(--accent);background:none;border:0;padding:4px 0;cursor:pointer;display:none}
.muted{color:var(--dim);font-size:13px}
main{padding:0 12px 24px;max-width:760px;margin:0 auto}
h2{font-size:13px;font-weight:600;color:var(--dim);margin:18px 6px 6px}
.desk{display:flex;align-items:center;gap:12px;width:100%;text-align:left;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:6px 0;color:var(--text);font:inherit;cursor:pointer}
.dot{width:10px;height:10px;border-radius:50%;flex:none;background:var(--dim);opacity:.5}
.blocked .dot{background:var(--orange);opacity:1}.ready .dot{background:var(--green);opacity:1}.working .dot{background:var(--accent);opacity:1}
.blocked .name{color:var(--orange)}.ready .name{color:var(--green)}
.name{font-weight:600;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sub{color:var(--dim);font-size:13px;white-space:nowrap}
#screen{background:var(--term);border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin:8px 0;height:56vh;overflow:auto;white-space:pre-wrap;word-break:break-word;font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.state{font-weight:600}
.keys{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0}
.keys button,.send button,.open{background:var(--card);color:var(--text);border:1px solid var(--line);border-radius:10px;padding:10px 14px;font:inherit;cursor:pointer}
.send{display:flex;gap:8px;align-items:flex-end}
textarea{flex:1;min-height:46px;max-height:30vh;resize:vertical;background:var(--card);color:var(--text);border:1px solid var(--line);border-radius:10px;padding:10px 12px;font:inherit}
.send button{background:var(--accent);color:#fff;border-color:transparent;font-weight:600}
#note{min-height:20px;margin:6px 2px;font-size:14px;color:var(--dim)}
.hidden{display:none!important}
</style>
</head>
<body>
<header><button class="back" id="back">‹ Desks</button><h1 id="title">Desks</h1><span class="muted" id="when"></span></header>
<main>
  <section id="list"></section>
  <section id="detail" class="hidden">
    <div><span class="state" id="state"></span> <span class="muted" id="runtime"></span></div>
    <div id="screen"></div>
    <div class="keys hidden" id="keys"></div>
    <button class="open hidden" id="open">Start this desk</button>
    <div class="send" id="sendrow">
      <textarea id="msg" placeholder="Message" rows="2"></textarea>
      <button id="send">Send</button>
    </div>
    <div id="note"></div>
  </section>
</main>
<script>
"use strict";
const $ = id => document.getElementById(id);
const labels = {blocked:"Needs you", ready:"Done", working:"Working", quiet:"Idle", off:"Not started"};
let current = null, timer = null, stuckToBottom = true;

function api(path, body) {
  const o = body === undefined ? {} : {method:"POST", headers:{"Content-Type":"application/json","X-Coldfall":"1"}, body:JSON.stringify(body)};
  return fetch(path, o).then(r => { if (r.status === 401) throw new Error("This inbox needs its link again."); return r.json(); });
}
function ago(t) {
  if (!t) return "";
  const s = Math.max(0, Date.now()/1000 - t);
  return s < 60 ? "now" : s < 3600 ? Math.floor(s/60) + "m" : s < 86400 ? Math.floor(s/3600) + "h" : Math.floor(s/86400) + "d";
}
function kind(d) { return d.running ? d.activity : "off"; }

function renderList(desks) {
  const list = $("list");
  list.textContent = "";
  let last = null;
  for (const d of desks) {
    const k = kind(d);
    if (k !== last) { const h = document.createElement("h2"); h.textContent = labels[k] || k; list.appendChild(h); last = k; }
    const b = document.createElement("button");
    b.className = "desk " + k;
    const dot = document.createElement("span"); dot.className = "dot";
    const n = document.createElement("span"); n.className = "name"; n.textContent = d.name;
    const s = document.createElement("span"); s.className = "sub"; s.textContent = [d.group, ago(d.lastOutput)].filter(Boolean).join(" · ");
    b.append(dot, n, s);
    b.onclick = () => { location.hash = "desk=" + encodeURIComponent(d.name); };
    list.appendChild(b);
  }
  if (!desks.length) list.textContent = "No desks.";
}

function refreshList() {
  api("/api/desks").then(r => { renderList(r.desks); $("when").textContent = ""; })
    .catch(e => { $("when").textContent = e.message; });
}

function refreshDesk() {
  if (!current) return;
  api("/api/read?desk=" + encodeURIComponent(current) + "&lines=300").then(r => {
    const sc = $("screen");
    stuckToBottom = sc.scrollHeight - sc.scrollTop - sc.clientHeight < 40;
    if (sc.textContent !== (r.text || "")) sc.textContent = r.text || "";
    if (stuckToBottom) sc.scrollTop = sc.scrollHeight;
    const k = r.running ? r.activity : "off";
    $("state").textContent = labels[k] || k;
    $("state").style.color = k === "blocked" ? "var(--orange)" : k === "ready" ? "var(--green)" : "";
    $("runtime").textContent = r.runtime || "";
    $("keys").classList.toggle("hidden", k !== "blocked");
    $("open").classList.toggle("hidden", r.running);
    $("sendrow").classList.toggle("hidden", !r.running || k === "blocked" || !r.agent);
  }).catch(e => { $("note").textContent = e.message; });
}

function show() {
  const m = location.hash.match(/^#desk=(.+)$/);
  current = m ? decodeURIComponent(m[1]) : null;
  $("list").classList.toggle("hidden", !!current);
  $("detail").classList.toggle("hidden", !current);
  $("back").style.display = current ? "inline" : "none";
  $("title").textContent = current || "Desks";
  $("note").textContent = "";
  clearInterval(timer);
  if (current) { $("screen").textContent = ""; refreshDesk(); timer = setInterval(refreshDesk, 2000); }
  else { refreshList(); timer = setInterval(refreshList, 3000); }
}

for (const [label, key] of [["1","1"],["2","2"],["3","3"],["↑","up"],["↓","down"],["Return","enter"],["Esc","esc"]]) {
  const b = document.createElement("button"); b.textContent = label;
  b.onclick = () => api("/api/keys", {desk: current, key}).then(r => { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 400); });
  $("keys").appendChild(b);
}
$("send").onclick = () => {
  const text = $("msg").value;
  if (!text.trim()) return;
  $("note").textContent = "Sending…";
  api("/api/send", {desk: current, text}).then(r => {
    $("note").textContent = r.message || "";
    if (r.outcome === "sent") { $("msg").value = ""; setTimeout(refreshDesk, 600); }
  }).catch(e => { $("note").textContent = e.message; });
};
$("open").onclick = () => api("/api/open", {desk: current}).then(r => { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 1500); });
$("back").onclick = () => { location.hash = ""; };
window.addEventListener("hashchange", show);
document.addEventListener("visibilitychange", () => { if (!document.hidden) show(); });
show();
</script>
</body>
</html>
"""#
}
