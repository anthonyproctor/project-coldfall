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
<meta name="theme-color" content="#f7f6f3" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1b1a19" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Coldfall">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<title>Coldfall</title>
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
.badge{width:20px;height:20px;border-radius:5px;flex:none;display:grid;place-items:center;font:700 11px/1 -apple-system,system-ui,sans-serif;color:#fff;background:#6b6b6b}
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
#phone{margin-top:26px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;font-size:14px;color:var(--dim)}
.card .keys{margin:10px 0 0}
.card .keys button.go{background:var(--accent);color:#fff;border-color:transparent;font-weight:600}
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
    <div class="keys hidden" id="opts"></div>
    <div class="keys hidden" id="keys"></div>
    <div class="muted hidden" id="unread"></div>
    <button class="open hidden" id="open">Start this desk</button>
    <div class="send" id="sendrow">
      <textarea id="msg" placeholder="Message" rows="2"></textarea>
      <button id="send">Send</button>
    </div>
    <div id="note"></div>
  </section>
  <section id="phone" class="hidden">
    <h2>This device</h2>
    <div class="card">
      <div id="pushsay"></div>
      <div class="keys hidden" id="pushkeys">
        <button class="go hidden" id="pushon">Turn on notifications</button>
        <button class="hidden" id="pushtest">Send a test</button>
        <button class="hidden" id="pushoff">Turn off</button>
      </div>
    </div>
  </section>
</main>
<script>
"use strict";
const $ = id => document.getElementById(id);
const labels = {blocked:"Needs you", ready:"Done", working:"Working", quiet:"Idle", off:"Not started"};
let current = null, timer = null, stuckToBottom = true;
// Each desk's half-written message, kept when you go to another desk.
const drafts = {};

function api(path, body) {
  const o = body === undefined ? {} : {method:"POST", headers:{"Content-Type":"application/json","X-Coldfall":"1"}, body:JSON.stringify(body)};
  return fetch(path, o).catch(() => { throw new Error("Can't reach your Mac. Is it awake, and is Tailscale on here?"); })
    .then(r => { if (r.status === 401) { if (!asking) { asking = true; location.reload(); } throw new Error("Coldfall needs its link again."); } return r.json(); });
}
// A 401 means the secret changed or was never here: load the page that asks for it.
let asking = false;
function ago(t) {
  if (!t) return "";
  const s = Math.max(0, Date.now()/1000 - t);
  return s < 60 ? "now" : s < 3600 ? Math.floor(s/60) + "m" : s < 86400 ? Math.floor(s/3600) + "h" : Math.floor(s/86400) + "d";
}
function kind(d) { return d.running ? d.activity : "off"; }
// The same letters and colours as the desk list in the app (VendorBadge).
const badges = {claude:["C","#c96442"], codex:["X","#10a37f"], antigravity:["A","#4285f4"], copilot:["G","#8957e5"], grok:["K","#3a3a3a"], ollama:["O","#5a5a5a"], shell:["›",""]};

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
    const bd = document.createElement("span"); bd.className = "badge";
    const [letter, colour] = badges[d.runtime] || [(d.runtime || "?").slice(0,1).toUpperCase(), "#6b6b6b"];
    bd.textContent = letter; if (colour) bd.style.background = colour; else { bd.style.background = "none"; bd.style.color = "var(--dim)"; }
    const n = document.createElement("span"); n.className = "name"; n.textContent = d.name;
    const s = document.createElement("span"); s.className = "sub"; s.textContent = [d.detail, d.group, ago(d.lastOutput)].filter(Boolean).join(" · ");
    b.append(dot, bd, n, s);
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
  const asked = current;
  api("/api/read?desk=" + encodeURIComponent(asked) + "&lines=300").then(r => {
    // An answer for the desk you've since left belongs to nobody.
    if (asked !== current) return;
    const sc = $("screen");
    stuckToBottom = sc.scrollHeight - sc.scrollTop - sc.clientHeight < 40;
    if (sc.textContent !== (r.text || "")) sc.textContent = r.text || "";
    if (stuckToBottom) sc.scrollTop = sc.scrollHeight;
    const k = r.running ? r.activity : "off";
    $("state").textContent = labels[k] || k;
    $("state").style.color = k === "blocked" ? "var(--orange)" : k === "ready" ? "var(--green)" : "";
    $("runtime").textContent = r.runtime || "";
    $("keys").classList.toggle("hidden", k !== "blocked");
    // Its own choices, by name, when they could be read off the screen.
    const opts = (k === "blocked" && r.options) || [];
    const sig = JSON.stringify(opts);
    if ($("opts").dataset.sig !== sig) {
      $("opts").dataset.sig = sig;
      $("opts").textContent = "";
      for (const o of opts) {
        const b = document.createElement("button"); b.textContent = o.key + "  " + o.label;
        b.onclick = () => { const desk = current; api("/api/keys", {desk, key: o.key}).then(a => { if (current === desk) { $("note").textContent = a.message || ""; setTimeout(refreshDesk, 400); } }); };
        $("opts").appendChild(b);
      }
    }
    $("opts").classList.toggle("hidden", !opts.length);
    // No choices read, and a version Coldfall has no record of reading.
    const unread = (k === "blocked" && !opts.length && r.unread) || "";
    $("unread").textContent = unread ? "Its choices couldn't be read, so these are the plain keys. " + unread : "";
    $("unread").classList.toggle("hidden", !unread);
    $("open").classList.toggle("hidden", r.running);
    $("sendrow").classList.toggle("hidden", !r.running || k === "blocked" || !r.agent);
  }).catch(e => { $("note").textContent = e.message; });
}

function show() {
  const m = location.hash.match(/^#desk=(.+)$/);
  if (current) drafts[current] = $("msg").value;
  current = m ? decodeURIComponent(m[1]) : null;
  $("msg").value = (current && drafts[current]) || "";
  $("list").classList.toggle("hidden", !!current);
  $("phone").classList.toggle("hidden", !!current || !$("pushsay").textContent);
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
  b.onclick = () => { const desk = current; api("/api/keys", {desk, key}).then(r => { if (current === desk) { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 400); } }); };
  $("keys").appendChild(b);
}
$("send").onclick = () => {
  const desk = current, text = $("msg").value;
  if (!desk || !text.trim()) return;
  $("note").textContent = "Sending to " + desk + "…";
  api("/api/send", {desk, text}).then(r => {
    if (r.outcome === "sent") { drafts[desk] = ""; if (current === desk) $("msg").value = ""; }
    if (current === desk) { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 600); }
  }).catch(e => { $("note").textContent = e.message; });
};
$("open").onclick = () => { const desk = current; api("/api/open", {desk}).then(r => { if (current === desk) { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 1500); } }); };
$("back").onclick = () => { location.hash = ""; };

// This device as an app: its notifications. Everything here is optional; the
// list above works without it.
let reg = null, sub = null, senderKey = "";
function keyBytes(s) {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(b, c => c.charCodeAt(0));
}
function pushSay(text, on, test, off) {
  $("pushsay").textContent = text;
  $("pushon").classList.toggle("hidden", !on);
  $("pushtest").classList.toggle("hidden", !test);
  $("pushoff").classList.toggle("hidden", !off);
  $("pushkeys").classList.toggle("hidden", !(on || test || off));
  $("phone").classList.toggle("hidden", !!current || !text);
}
// An iPhone or iPad in Safari, not yet on the Home Screen.
const inSafariOnly = navigator.standalone === false;
const addFirst = "To get notifications here: tap Share, then Add to Home Screen, and open Coldfall from there.";
async function pushState() {
  try {
    if (!window.isSecureContext) return pushSay("To keep Coldfall on your Home Screen and get notifications, open its https link. It's in Coldfall's Settings on the Mac, under General.");
    if (!("serviceWorker" in navigator)) return pushSay(inSafariOnly ? addFirst : "");
    reg = reg || await navigator.serviceWorker.register("/sw.js");
    if (!("PushManager" in window) || !("Notification" in window)) return pushSay(inSafariOnly ? addFirst : "");
    sub = await reg.pushManager.getSubscription();
    const st = await api("/api/push/state", {endpoint: sub ? sub.endpoint : ""});
    senderKey = st.key || "";
    if (!st.on) return pushSay("Notifications to phones are off. Turn them on in Coldfall's Settings on the Mac, under General.");
    if (sub && st.subscribed) return pushSay("Notifications are on for this device. " + (st.last || ""), false, true, true);
    if (Notification.permission === "denied") return pushSay("Notifications are blocked for Coldfall in this device's settings.");
    if (inSafariOnly) return pushSay(addFirst);
    pushSay("Get a notification here when a desk needs you or finishes while you're away from the Mac. It never shows which desk or why.", true);
  } catch (e) { pushSay("Notifications aren't set up: " + e.message); }
}
$("pushon").onclick = async () => {
  try {
    // Asked for first, straight from the tap: phones insist on that.
    if (await Notification.requestPermission() !== "granted") return pushState();
    // One made against an older key (or forgotten on the Mac) is replaced.
    if (sub) await sub.unsubscribe();
    sub = await reg.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: keyBytes(senderKey)});
    const j = sub.toJSON();
    const r = await api("/api/push/subscribe", {endpoint: j.endpoint, p256dh: j.keys.p256dh, auth: j.keys.auth, origin: location.origin});
    if (!r.ok) { await sub.unsubscribe(); sub = null; return pushSay(r.message, true); }
    pushState();
  } catch (e) { pushSay("Couldn't turn on notifications: " + e.message, true); }
};
$("pushtest").onclick = () => {
  if (!sub) return;
  api("/api/push/test", {endpoint: sub.endpoint}).then(r => { pushSay(r.message || "", false, true, true); setTimeout(pushState, 6000); })
    .catch(e => pushSay(e.message, false, true, true));
};
$("pushoff").onclick = async () => {
  try {
    if (sub) { await api("/api/push/unsubscribe", {endpoint: sub.endpoint}); await sub.unsubscribe(); sub = null; }
  } catch (e) {}
  pushState();
};
function seen() { if (navigator.clearAppBadge) navigator.clearAppBadge().catch(() => {}); }

window.addEventListener("hashchange", show);
document.addEventListener("visibilitychange", () => { if (!document.hidden) { show(); seen(); } });
show();
seen();
pushState();
</script>
</body>
</html>
"""#

    /// What lets a phone keep the inbox on its Home Screen as an app. No
    /// secret in it: a phone fetches this without the cookie.
    public static let manifest = #"""
{"name":"Coldfall","short_name":"Coldfall","id":"/","start_url":"/","scope":"/","display":"standalone",
"background_color":"#1b1a19","theme_color":"#1b1a19",
"icons":[{"src":"/icon-192.png","sizes":"192x192","type":"image/png","purpose":"any"},
{"src":"/icon-512.png","sizes":"512x512","type":"image/png","purpose":"any"},
{"src":"/icon-512.png","sizes":"512x512","type":"image/png","purpose":"maskable"}]}
"""#

    /// The part of the app that runs on the phone without the page open.
    /// Three jobs: show a notification that arrives, open the inbox when it's
    /// tapped, and keep the page's empty frame so the app opens to "can't
    /// reach your Mac" instead of a browser error. It keeps nothing a desk
    /// said: only "/" is ever stored, and the page holds no desk data itself.
    public static let worker = #"""
"use strict";
const SHELL = "coldfall-shell-1";
self.addEventListener("install", () => { self.skipWaiting(); });
self.addEventListener("activate", e => { e.waitUntil(self.clients.claim()); });
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  if (e.request.mode !== "navigate" || u.origin !== location.origin || u.pathname !== "/" || u.search) return;
  e.respondWith(fetch(e.request).then(r => {
    if (r.status === 200) { const copy = r.clone(); caches.open(SHELL).then(c => c.put("/", copy)); }
    return r;
  }).catch(() => caches.match("/").then(r => r ||
    new Response("Can't reach your Mac. Is it awake, and is Tailscale on here?", {status: 503, headers: {"Content-Type": "text/plain; charset=utf-8"}}))));
});
self.addEventListener("push", e => {
  let m = null;
  try { m = e.data ? e.data.json() : null; } catch (_) {}
  const n = (m && m.web_push === 8030 && m.notification) || {title: "Coldfall", body: "A desk has news.", navigate: "/"};
  const jobs = [self.registration.showNotification(n.title, {body: n.body || "", tag: n.tag, data: {url: n.navigate || "/"}})];
  if (n.app_badge !== undefined && navigator.setAppBadge) jobs.push(navigator.setAppBadge(parseInt(n.app_badge, 10) || 0).catch(() => {}));
  e.waitUntil(Promise.all(jobs));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  let url = "/";
  try { const u = new URL((e.notification.data && e.notification.data.url) || "/", location.origin); if (u.origin === location.origin) url = u.href; } catch (_) {}
  e.waitUntil(self.clients.matchAll({type: "window", includeUncontrolled: true}).then(list => {
    for (const c of list) {
      if ("navigate" in c) return c.navigate(url).then(x => (x || c).focus());
      if ("focus" in c) return c.focus();
    }
    return self.clients.openWindow(url);
  }));
});
"""#

    /// Shown instead of the inbox when the secret isn't there: a page opened
    /// from a Home Screen has no address bar to put the link in.
    public static let askPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Coldfall">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<title>Coldfall</title>
<style>
:root{--bg:#f7f6f3;--card:#fff;--text:#1d1d1b;--dim:#76746e;--line:#e6e3dc;--accent:#2f6fdb}
@media (prefers-color-scheme:dark){:root{--bg:#1b1a19;--card:#242322;--text:#ecebe8;--dim:#9b9892;--line:#34322f;--accent:#6ea0ff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;padding:calc(env(safe-area-inset-top) + 28px) 20px 24px}
main{max-width:520px;margin:0 auto}
h1{font-size:22px;margin:0 0 8px}
p{color:var(--dim);margin:0 0 16px}
input{width:100%;background:var(--card);color:var(--text);border:1px solid var(--line);border-radius:10px;padding:12px;font:inherit}
button{margin-top:10px;width:100%;background:var(--accent);color:#fff;border:0;border-radius:10px;padding:12px;font:inherit;font-weight:600}
#say{min-height:20px;margin-top:10px;font-size:14px;color:var(--dim)}
</style>
</head>
<body>
<main>
<h1>Coldfall needs its link</h1>
<p>On the Mac, open Coldfall's Settings, General, and press Copy Link. Then paste it here.</p>
<input id="link" type="text" inputmode="url" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Paste the link" aria-label="The link from Coldfall's Settings">
<button id="go">Open Coldfall</button>
<div id="say"></div>
</main>
<script>
"use strict";
document.getElementById("go").onclick = () => {
  const v = document.getElementById("link").value.trim();
  const m = v.match(/[?&]t=([A-Za-z0-9_-]+)/);
  const t = m ? m[1] : v;
  if (/^[A-Za-z0-9_-]{32,}$/.test(t)) location.replace("/?t=" + t);
  else document.getElementById("say").textContent = "That doesn't look like the link from Settings.";
};
</script>
</body>
</html>
"""#
}
