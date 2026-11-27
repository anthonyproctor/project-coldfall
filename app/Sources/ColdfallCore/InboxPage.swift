import Foundation

extension Inbox {
    /// The whole page. Agent output only ever reaches it through textContent,
    /// never innerHTML, so nothing a desk prints can become markup.
    public static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#f7f6f3" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1b1a19" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="Coldfall">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<title>Coldfall</title>
<style>
:root{--bg:#f7f6f3;--side:#efede8;--card:#fff;--text:#1d1d1b;--dim:#76746e;--line:#e3e0d8;--accent:#2f6fdb;--green:#2e9d4f;--orange:#d9761c;--red:#c8432f;--term:#fbfaf7;--sel:#e4e9f5;--vh:100dvh}
@media (prefers-color-scheme:dark){:root{--bg:#1b1a19;--side:#201f1d;--card:#262523;--text:#ecebe8;--dim:#9b9892;--line:#353330;--accent:#6ea0ff;--green:#5cc27a;--orange:#f0a050;--red:#ef6a55;--term:#151413;--sel:#2b3242}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{height:100%;margin:0;overflow:hidden;overscroll-behavior:none}
body{background:var(--bg);color:var(--text);font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
button{font:inherit;color:inherit}
#app{position:fixed;left:0;right:0;top:0;height:var(--vh);display:flex}
.pane{display:flex;flex-direction:column;min-width:0;min-height:0;flex:1}
#side{background:var(--bg)}
.bar{display:flex;align-items:center;gap:10px;padding:calc(env(safe-area-inset-top) + 10px) calc(env(safe-area-inset-right) + 14px) 8px calc(env(safe-area-inset-left) + 14px);flex:none}
.bar h1{font-size:22px;margin:0;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar .t{flex:1;min-width:0}
.bar .t h1{font-size:18px}
.iconbtn{background:none;border:0;color:var(--accent);font-size:17px;padding:6px 4px;cursor:pointer;min-width:34px}
.muted{color:var(--dim);font-size:13px}
.tools{padding:0 calc(env(safe-area-inset-right) + 12px) 6px calc(env(safe-area-inset-left) + 12px);flex:none}
#q{width:100%;background:var(--card);color:var(--text);border:1px solid var(--line);border-radius:10px;padding:9px 12px;font:inherit;font-size:16px}
.chips{display:flex;gap:6px;margin-top:8px}
.chips button{background:var(--card);border:1px solid var(--line);border-radius:999px;padding:5px 12px;font-size:14px;cursor:pointer}
.chips button.on{background:var(--text);color:var(--bg);border-color:var(--text)}
.chips .n{opacity:.6;margin-left:4px}
.scroll{flex:1;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;padding:0 calc(env(safe-area-inset-right) + 12px) calc(env(safe-area-inset-bottom) + 24px) calc(env(safe-area-inset-left) + 12px)}
h2{font-size:12px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:var(--dim);margin:18px 4px 6px;display:flex;align-items:center;gap:6px}
.group{display:flex;align-items:center;gap:6px;width:100%;background:none;border:0;padding:10px 4px 4px;color:var(--dim);font-size:13px;font-weight:600;cursor:pointer;text-align:left}
.group .chev{display:inline-block;transition:transform .15s;width:12px}
.group.folded .chev{transform:rotate(-90deg)}
.group .n{font-weight:400}
.row{display:flex;align-items:center;gap:10px;width:100%;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 6px 10px 12px;margin:5px 0;cursor:pointer;text-align:left}
.row.cur{border-color:var(--accent);background:var(--sel)}
.row .mid{flex:1;min-width:0}
.row .name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:flex;align-items:center;gap:6px}
.row .sub{color:var(--dim);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .end{text-align:right;color:var(--dim);font-size:12px;flex:none;line-height:1.3}
.row .more{background:none;border:0;color:var(--dim);font-size:20px;padding:4px 8px;cursor:pointer;flex:none;line-height:1}
.pin{font-size:11px;filter:grayscale(1);opacity:.55}
.dot{width:10px;height:10px;border-radius:50%;flex:none;background:var(--dim);opacity:.45}
.blocked .dot{background:var(--orange);opacity:1}.ready .dot{background:var(--green);opacity:1}.working .dot{background:var(--accent);opacity:1;animation:pulse 1.6s ease-in-out infinite}
.asleep .dot{background:none;opacity:1;width:auto;height:auto;font-size:11px}
.asleep .dot::before{content:"☾";color:var(--dim)}
@keyframes pulse{50%{opacity:.35}}
.blocked .name{color:var(--orange)}
.badge{width:22px;height:22px;border-radius:6px;flex:none;display:grid;place-items:center;font:700 11px/1 -apple-system,system-ui,sans-serif;color:#fff;background:#6b6b6b}
.empty{color:var(--dim);padding:24px 6px;text-align:center}
.ask{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--orange);border-radius:12px;padding:12px 14px;margin:8px 0}
.ask .who{display:flex;gap:8px;align-items:baseline;margin-bottom:4px}
.ask .who b{color:var(--orange)}
.ask p{margin:0;font-size:15px;line-height:1.4;word-break:break-word}
.ask .act{display:flex;gap:8px;margin-top:10px}
.ask button{background:none;color:var(--accent);border:1px solid var(--line);border-radius:10px;padding:7px 12px;cursor:pointer}
#detail .bar{border-bottom:1px solid var(--line)}
.state{font-weight:600}
#notice{margin:8px 12px 0}
#screen{flex:1;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;background:var(--term);padding:10px calc(env(safe-area-inset-right) + 12px) 10px calc(env(safe-area-inset-left) + 12px);white-space:pre-wrap;word-break:break-word;font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
#top{font:12px/1.4 -apple-system,system-ui,sans-serif;color:var(--dim);text-align:center;padding:2px 0 10px}
.dock{flex:none;border-top:1px solid var(--line);background:var(--bg);padding:8px calc(env(safe-area-inset-right) + 12px) calc(env(safe-area-inset-bottom) + 8px) calc(env(safe-area-inset-left) + 12px)}
.keys{display:flex;flex-wrap:wrap;gap:8px;margin:2px 0 8px}
.keys button,.open{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:9px 13px;cursor:pointer}
.open{width:100%;background:var(--accent);color:#fff;border-color:transparent;font-weight:600;padding:12px}
.send{display:flex;gap:8px;align-items:flex-end}
textarea{flex:1;min-height:40px;max-height:34vh;resize:none;background:var(--card);color:var(--text);border:1px solid var(--line);border-radius:20px;padding:9px 14px;font:inherit;font-size:16px;line-height:1.35}
.send .go{background:var(--accent);color:#fff;border:0;border-radius:20px;height:40px;padding:0 16px;font-weight:600;cursor:pointer;flex:none}
.send .add{background:var(--card);border:1px solid var(--line);border-radius:50%;width:40px;height:40px;font-size:22px;line-height:1;color:var(--accent);cursor:pointer;flex:none}
.photos{display:flex;gap:10px;overflow-x:auto;margin:0 0 8px;padding:8px 8px 0 0}
.photo{position:relative;flex:none}
.photo img{width:64px;height:64px;object-fit:cover;border-radius:10px;border:1px solid var(--line);display:block}
.photo button{position:absolute;top:-6px;right:-6px;width:22px;height:22px;border-radius:50%;border:0;background:var(--text);color:var(--bg);font-size:13px;line-height:1;cursor:pointer}
.photo.busy img{opacity:.4}
#note{min-height:0;font-size:13px;color:var(--dim);margin-top:6px}
#note:empty{display:none}
#none{flex:1;display:none;place-items:center;color:var(--dim)}
#phone{margin-top:26px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;font-size:14px;color:var(--dim);margin-top:8px}
.card .keys{margin:10px 0 0}
.card .keys button.go{background:var(--accent);color:#fff;border-color:transparent;font-weight:600}
#sheet{position:fixed;inset:0;background:rgba(0,0,0,.35);display:flex;align-items:flex-end;justify-content:center;z-index:9}
#sheet .panel{background:var(--card);width:100%;max-width:520px;border-radius:16px 16px 0 0;padding:14px 14px calc(env(safe-area-inset-bottom) + 14px)}
#sheet .title{font-weight:600;text-align:center;margin:2px 0 4px}
#sheet .say{color:var(--dim);font-size:14px;text-align:center;margin:0 6px 10px}
#sheet .acts button{display:block;width:100%;background:var(--bg);border:0;border-radius:12px;padding:13px;margin:6px 0;font-size:16px;cursor:pointer}
#sheet .acts button.danger{color:var(--red);font-weight:600}
#sheet .acts button.cancel{font-weight:600}
@media (min-width:820px){
  #side{flex:0 0 340px;border-right:1px solid var(--line);background:var(--side)}
  #side .row{background:var(--bg)}
  #back{display:none}
  body.nodesk #none{display:grid}
  #sheet{align-items:center}
  #sheet .panel{border-radius:16px}
}
@media (max-width:819px){
  #screen{font-size:11.5px}
  body.indesk #side{display:none}
  body.nodesk #detail{display:none}
}
.hidden{display:none!important}
</style>
</head>
<body class="nodesk">
<div id="app">
<div class="pane" id="side">
  <div class="bar"><h1>Desks</h1><span class="muted" id="when"></span></div>
  <div class="tools">
    <input id="q" type="search" placeholder="Find a desk" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search">
    <div class="chips" id="chips"><button data-f="all" class="on">All</button><button data-f="active">Active<span class="n" id="nactive"></span></button><button data-f="waiting">Waiting<span class="n" id="nwaiting"></span></button></div>
  </div>
  <div class="scroll" id="sidescroll">
    <section id="asks"></section>
    <section id="list"></section>
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
      <div class="card" id="face">
        <div id="facesay"></div>
        <div class="keys hidden" id="facekeys"><button class="go" id="faceset">Set up Face ID</button></div>
      </div>
    </section>
  </div>
</div>
<div class="pane" id="detail">
  <div class="bar">
    <button class="iconbtn" id="back" aria-label="Desks">‹ Desks</button>
    <div class="t"><h1 id="title"></h1><div class="muted"><span class="state" id="state"></span> <span id="runtime"></span></div></div>
    <button class="iconbtn" id="more" aria-label="Desk actions">•••</button>
  </div>
  <div class="ask hidden" id="notice"><p id="noticetext"></p><div class="act"><button id="noticeclear">Dismiss</button></div></div>
  <div id="screen"><div id="top" class="hidden"></div><div id="screentext"></div></div>
  <div class="dock">
    <div class="keys hidden" id="opts"></div>
    <div class="keys hidden" id="keys"></div>
    <div class="muted hidden" id="unread" style="margin-bottom:8px"></div>
    <button class="open hidden" id="open">Start this desk</button>
    <div class="photos hidden" id="photos"></div>
    <div class="send" id="sendrow">
      <button class="add" id="attach" aria-label="Attach a photo">+</button>
      <input type="file" id="file" accept="image/*" multiple class="hidden">
      <textarea id="msg" placeholder="Message" rows="1" enterkeyhint="enter"></textarea>
      <button class="go" id="send">Send</button>
    </div>
    <div id="note"></div>
  </div>
</div>
<div id="none">Pick a desk</div>
</div>
<div id="sheet" class="hidden"><div class="panel"><div class="title" id="sheettitle"></div><div class="say" id="sheetsay"></div><div class="acts" id="sheetacts"></div></div></div>
<script>
"use strict";
const $ = id => document.getElementById(id);
const labels = {blocked:"Needs you", ready:"Done", working:"Working", quiet:"Idle", off:"Not running", asleep:"Asleep"};
let current = null, listTimer = null, deskTimer = null, desks = [], notices = [], filter = "all";
// Each desk's half-written message and photos, kept when you go to another desk.
const drafts = {}, photoDrafts = {};
let photos = [];
const store = {get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
               set(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }};
const wide = () => window.matchMedia("(min-width: 820px)").matches;

// The app fills what the screen shows, so the message box sits on the
// keyboard, not behind it or halfway up the page.
function fit() {
  const v = window.visualViewport;
  const h = v ? v.height : window.innerHeight;
  document.documentElement.style.setProperty("--vh", h + "px");
  $("app").style.transform = v && v.offsetTop ? "translateY(" + v.offsetTop + "px)" : "";
}
if (window.visualViewport) { visualViewport.addEventListener("resize", fit); visualViewport.addEventListener("scroll", fit); }
window.addEventListener("resize", fit);
fit();

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
function kind(d) { return d.running ? d.activity : (d.asleep ? "asleep" : "off"); }
const rank = {blocked:0, ready:1, working:2, quiet:3};
// The same letters and colours as the desk list in the app (VendorBadge).
const badges = {claude:["C","#c96442"], codex:["X","#10a37f"], antigravity:["A","#4285f4"], copilot:["G","#8957e5"], grok:["K","#3a3a3a"], ollama:["O","#5a5a5a"], shell:["›",""]};
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }
function go(name) { location.hash = "desk=" + encodeURIComponent(name); }

function row(d, showGroup) {
  const k = kind(d);
  const b = el("div", "row " + k + (d.name === current ? " cur" : ""));
  b.setAttribute("role", "button");
  const bd = el("span", "badge");
  const [letter, colour] = badges[d.runtime] || [(d.runtime || "?").slice(0,1).toUpperCase(), "#6b6b6b"];
  bd.textContent = letter; if (colour) bd.style.background = colour; else { bd.style.background = "none"; bd.style.color = "var(--dim)"; }
  const mid = el("div", "mid");
  const n = el("div", "name");
  n.append(el("span", "dot"), document.createTextNode(d.name));
  if (d.pinned) n.append(el("span", "pin", "📌"));
  const note = notices.find(x => x.desk === d.name);
  const sub = note ? "Asked for you: " + note.text : (d.detail || labels[k] || k);
  mid.append(n, el("div", "sub", showGroup && d.group ? d.group + " · " + sub : sub));
  const end = el("div", "end");
  end.append(el("div", "", ago(d.lastOutput)));
  if (d.memory) end.append(el("div", "", d.memory));
  const more = el("button", "more", "⋯");
  more.setAttribute("aria-label", "Actions for " + d.name);
  more.onclick = e => { e.stopPropagation(); deskSheet(d); };
  b.append(bd, mid, end, more);
  b.onclick = () => go(d.name);
  return b;
}

function matches(d) {
  const q = $("q").value.trim().toLowerCase();
  if (q && !(d.name.toLowerCase().includes(q) || (d.group || "").toLowerCase().includes(q))) return false;
  if (filter === "active") return d.running;
  if (filter === "waiting") return waiting(d);
  return true;
}
function waiting(d) { return (d.running && (d.activity === "blocked" || d.activity === "ready")) || notices.some(n => n.desk === d.name); }
const pinnedFirst = (a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0);

// Like the app's rail: what's running on top (pinned first, then what needs
// you), then everything else by group, each group folded or open as you left it.
function renderList() {
  const list = $("list");
  list.textContent = "";
  $("nactive").textContent = desks.filter(d => d.running).length || "";
  $("nwaiting").textContent = desks.filter(waiting).length || "";
  const shown = desks.filter(matches);
  const active = shown.filter(d => d.running).sort((a, b) => pinnedFirst(a, b) || 0);
  const rest = shown.filter(d => !d.running);
  if (active.length) {
    list.append(el("h2", "", "Active"));
    for (const d of active) list.append(row(d, true));
  }
  if (rest.length) {
    list.append(el("h2", "", "Not running"));
    for (const d of rest.filter(d => d.pinned)) list.append(row(d, true));
    const groups = [];
    for (const d of rest.filter(d => !d.pinned)) {
      const g = d.group || "";
      let e = groups.find(x => x.name === g);
      if (!e) { e = {name: g, desks: []}; groups.push(e); }
      e.desks.push(d);
    }
    const searching = !!$("q").value.trim();
    for (const g of groups) {
      if (!g.name && groups.length === 1) { for (const d of g.desks) list.append(row(d, false)); continue; }
      const key = "cf.fold." + (g.name || "-");
      const folded = !searching && store.get(key) === "1";
      const h = el("button", "group" + (folded ? " folded" : ""));
      h.append(el("span", "chev", "▾"), document.createTextNode(g.name || "No group"), el("span", "n", " " + g.desks.length));
      h.onclick = () => { store.set(key, folded ? null : "1"); renderList(); };
      list.append(h);
      if (!folded) for (const d of g.desks) list.append(row(d, false));
    }
  }
  if (!shown.length) list.append(el("div", "empty", desks.length ? "No desk matches." : "No desks."));
}

// What desks asked for in their own words (coldfall-cli notify), above the list.
function renderAsks() {
  const box = $("asks");
  box.textContent = "";
  if (filter === "active") return;
  for (const n of notices) {
    const c = el("div", "ask");
    const who = el("div", "who");
    who.append(el("b", "", n.desk), el("span", "muted", "needs you · " + ago(n.time)));
    const act = el("div", "act");
    const o = el("button", "", "Open desk"); o.onclick = () => go(n.desk);
    const x = el("button", "", "Dismiss");
    x.onclick = () => { api("/api/notice/clear", {desk: n.desk}).then(refreshList).catch(e => { $("when").textContent = e.message; }); };
    act.append(o, x);
    c.append(who, el("p", "", n.text), act);
    box.append(c);
  }
}

function refreshList() {
  return api("/api/desks").then(r => {
    desks = r.desks || []; notices = r.notices || [];
    renderAsks(); renderList(); $("when").textContent = "";
    if (current) deskHead();
  }).catch(e => { $("when").textContent = e.message; });
}
for (const b of $("chips").querySelectorAll("button")) b.onclick = () => {
  filter = b.dataset.f;
  for (const x of $("chips").querySelectorAll("button")) x.classList.toggle("on", x === b);
  renderAsks(); renderList();
};
$("q").addEventListener("input", renderList);

// One desk's actions, as a sheet from the bottom: open, start or stop, pin.
function sheet(title, say, acts) {
  $("sheettitle").textContent = title;
  $("sheetsay").textContent = say || "";
  const box = $("sheetacts"); box.textContent = "";
  for (const a of acts.concat([{label: "Cancel", cls: "cancel"}])) {
    const b = el("button", a.cls || "", a.label);
    b.onclick = () => { closeSheet(); if (a.run) a.run(); };
    box.append(b);
  }
  $("sheet").classList.remove("hidden");
}
function closeSheet() { $("sheet").classList.add("hidden"); }
$("sheet").onclick = e => { if (e.target === $("sheet")) closeSheet(); };
function say(text) { if (current) $("note").textContent = text || ""; else $("when").textContent = text || ""; }
function deskSheet(d) {
  const acts = [];
  if (d.name !== current) acts.push({label: "Open", run: () => go(d.name)});
  if (d.running) acts.push({label: "Stop…", cls: "danger", run: () => stopSheet(d)});
  else acts.push({label: d.asleep ? "Wake and Start" : "Start", run: () => start(d.name)});
  acts.push({label: d.pinned ? "Unpin" : "Pin to Top", run: () => api("/api/pin", {desk: d.name, on: d.pinned ? "false" : "true"}).then(r => { say(r.message); refreshList(); }).catch(e => say(e.message))});
  sheet(d.name, [labels[kind(d)], d.group, d.memory].filter(Boolean).join(" · "), acts);
}
function stopSheet(d) {
  const busy = d.activity === "working";
  sheet("Stop " + d.name + "?",
    (busy ? "It's working right now, and stopping ends that turn. " : "") + "Its agent ends" + (d.memory ? ", freeing about " + d.memory : "") + ". Its conversation picks up when you start it again.",
    [{label: "Stop " + d.name, cls: "danger", run: () => act("/api/stop", {desk: d.name}).then(r => { say(r.message); refreshList(); if (current === d.name) setTimeout(refreshDesk, 800); })}]);
}
function start(name) {
  act("/api/open", {desk: name}).then(r => { say(r.message); setTimeout(refreshList, 1200); if (current === name) setTimeout(refreshDesk, 1500); });
}
$("more").onclick = () => { const d = desks.find(x => x.name === current); if (d) deskSheet(d); };

// The desk on screen. Its screen comes back only when it changed; scrolling
// to the top asks for more of what Coldfall keeps, up to 5000 lines.
let want = 400, have = "", lines = 0, fetching = false, growing = false;
function deskHead() {
  const d = desks.find(x => x.name === current);
  if (!d) return;
  const k = kind(d);
  $("state").textContent = labels[k] || k;
  $("state").style.color = k === "blocked" ? "var(--orange)" : k === "ready" ? "var(--green)" : "";
}
function refreshDesk() {
  if (!current || fetching) return;
  const asked = current;
  fetching = true;
  api("/api/read?desk=" + encodeURIComponent(asked) + "&lines=" + want + "&have=" + encodeURIComponent(have)).then(r => {
    fetching = false;
    // An answer for the desk you've since left belongs to nobody.
    if (asked !== current) return;
    const sc = $("screen");
    if (typeof r.text === "string") {
      const fromBottom = sc.scrollHeight - sc.scrollTop, top = sc.scrollTop;
      const atBottom = fromBottom - sc.clientHeight < 40;
      $("screentext").textContent = r.text;
      have = r.hash || ""; lines = r.lines || 0;
      // Following along at the bottom stays there. Earlier lines arriving
      // above keep what you're reading where it was; so does new output below.
      sc.scrollTop = atBottom ? sc.scrollHeight : growing ? sc.scrollHeight - fromBottom : top;
      growing = false;
    }
    const more = lines >= want && want < 5000;
    $("top").textContent = !r.running ? current + " isn't running. Start it and it picks up its conversation where it left off."
      : more ? "Scroll up for earlier lines" : "Start of what Coldfall keeps for this desk";
    $("top").classList.toggle("hidden", r.running && lines < 30);
    if (!r.running && $("screentext").textContent) { $("screentext").textContent = ""; have = ""; }
    const k = r.running ? r.activity : "off";
    $("state").textContent = labels[k] || k;
    $("state").style.color = k === "blocked" ? "var(--orange)" : k === "ready" ? "var(--green)" : "";
    $("runtime").textContent = r.runtime ? "· " + r.runtime : "";
    $("keys").classList.toggle("hidden", k !== "blocked");
    // Its own choices, by name, when they could be read off the screen.
    const opts = (k === "blocked" && r.options) || [];
    const sig = JSON.stringify(opts);
    if ($("opts").dataset.sig !== sig) {
      $("opts").dataset.sig = sig;
      $("opts").textContent = "";
      for (const o of opts) {
        const b = el("button", "", o.key + "  " + o.label);
        b.onclick = () => { const desk = current; act("/api/keys", {desk, key: o.key}).then(a => { if (current === desk) { $("note").textContent = a.message || ""; setTimeout(refreshDesk, 400); } }); };
        $("opts").append(b);
      }
    }
    $("opts").classList.toggle("hidden", !opts.length);
    // No choices read, and a version Coldfall has no record of reading.
    const unread = (k === "blocked" && !opts.length && r.unread) || "";
    $("unread").textContent = unread ? "Its choices couldn't be read, so these are the plain keys. " + unread : "";
    $("unread").classList.toggle("hidden", !unread);
    $("noticetext").textContent = r.notice || "";
    $("notice").classList.toggle("hidden", !r.notice);
    $("open").classList.toggle("hidden", r.running);
    const canSend = r.running && k !== "blocked" && r.agent;
    $("sendrow").classList.toggle("hidden", !canSend);
    $("photos").classList.toggle("hidden", !canSend || !photos.length);
  }).catch(e => { fetching = false; $("note").textContent = e.message; });
}
$("screen").addEventListener("scroll", () => {
  const sc = $("screen");
  if (sc.scrollTop < 80 && lines >= want && want < 5000 && !growing) {
    growing = true; want = Math.min(5000, want * 2); have = ""; refreshDesk();
  }
});

function show() {
  const m = location.hash.match(/^#desk=(.+)$/);
  if (current) { drafts[current] = $("msg").value; photoDrafts[current] = photos; }
  current = m ? decodeURIComponent(m[1]) : null;
  $("msg").value = (current && drafts[current]) || "";
  photos = (current && photoDrafts[current]) || [];
  renderPhotos(); grow();
  document.body.classList.toggle("indesk", !!current);
  document.body.classList.toggle("nodesk", !current);
  $("title").textContent = current || "";
  $("note").textContent = "";
  $("screentext").textContent = ""; $("top").classList.add("hidden");
  want = 400; have = ""; lines = 0; growing = false;
  for (const id of ["keys", "opts", "unread", "notice", "open"]) $(id).classList.add("hidden");
  $("opts").dataset.sig = "";
  phoneShow();
  clearInterval(listTimer); clearInterval(deskTimer);
  refreshList();
  if (current) { refreshDesk(); deskTimer = setInterval(refreshDesk, 2000); }
  if (!current || wide()) listTimer = setInterval(refreshList, 3000);
  renderList();
}

for (const [label, key] of [["1","1"],["2","2"],["3","3"],["↑","up"],["↓","down"],["Return","enter"],["Esc","esc"]]) {
  const b = el("button", "", label);
  b.onclick = () => { const desk = current; act("/api/keys", {desk, key}).then(r => { if (current === desk) { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 400); } }); };
  $("keys").append(b);
}
// The box grows with what you write, up to a third of the screen.
function grow() { const t = $("msg"); t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight + 2, window.innerHeight * .34) + "px"; }
$("msg").addEventListener("input", grow);
$("send").onclick = () => {
  const desk = current;
  if (!desk) return;
  if (photos.some(p => !p.path)) { $("note").textContent = "Wait for the photos to finish uploading."; return; }
  let text = $("msg").value.trim();
  if (photos.length) text = (text || "Have a look at " + (photos.length === 1 ? "this photo" : "these photos") + ".") + "\n\n" + photos.map(p => p.path).join("\n");
  if (!text) return;
  $("note").textContent = "Sending to " + desk + "…";
  act("/api/send", {desk, text}).then(r => {
    if (r.outcome === "sent") { drafts[desk] = ""; photoDrafts[desk] = []; if (current === desk) { $("msg").value = ""; photos = []; renderPhotos(); grow(); } }
    if (current === desk) { $("note").textContent = r.message || ""; setTimeout(refreshDesk, 600); }
  }).catch(e => { $("note").textContent = e.message; });
};

// Photos: made smaller on the phone (a desk doesn't need 12 megapixels),
// saved on the Mac beside the desk, and sent as their paths with the message.
function renderPhotos() {
  const box = $("photos"); box.textContent = "";
  for (const p of photos) {
    const c = el("div", "photo" + (p.path ? "" : " busy"));
    const img = el("img"); img.src = p.url; img.alt = "";
    const x = el("button", "", "✕"); x.setAttribute("aria-label", "Remove photo");
    x.onclick = () => { photos = photos.filter(q => q !== p); URL.revokeObjectURL(p.url); renderPhotos(); };
    c.append(img, x); box.append(c);
  }
  box.classList.toggle("hidden", !photos.length);
}
function shrink(file) {
  return new Promise(resolve => {
    const url = URL.createObjectURL(file), img = new Image();
    img.onload = () => {
      const scale = Math.min(1, 2048 / Math.max(img.naturalWidth, img.naturalHeight));
      const c = document.createElement("canvas");
      c.width = Math.round(img.naturalWidth * scale); c.height = Math.round(img.naturalHeight * scale);
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
      c.toBlob(b => resolve({blob: b || file, url}), "image/jpeg", .85);
    };
    img.onerror = () => resolve({blob: file, url});
    img.src = url;
  });
}
function base64(blob) {
  return new Promise((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result).split(",")[1] || ""); r.onerror = no; r.readAsDataURL(blob); });
}
$("attach").onclick = () => $("file").click();
$("file").onchange = async () => {
  const desk = current, files = Array.from($("file").files || []);
  $("file").value = "";
  for (const f of files) {
    const s = await shrink(f);
    const p = {url: s.url, path: ""};
    photos.push(p); renderPhotos();
    const r = await act("/api/upload", {desk, data: await base64(s.blob)});
    if (r.ok && r.path) { p.path = r.path; }
    else { photos = photos.filter(q => q !== p); if (current === desk) $("note").textContent = r.message || "Couldn't attach that photo."; }
    if (current === desk) renderPhotos(); else photoDrafts[desk] = (photoDrafts[desk] || []).filter(q => q.path);
  }
};
$("noticeclear").onclick = () => {
  const desk = current;
  api("/api/notice/clear", {desk}).then(r => { if (current === desk) { $("note").textContent = r.message || ""; refreshDesk(); refreshList(); } })
    .catch(e => { $("note").textContent = e.message; });
};
$("open").onclick = () => start(current);
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
  phoneShow();
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
function phoneShow() {
  $("phone").classList.toggle("hidden", !$("pushsay").textContent && !$("facesay").textContent);
}

// Face ID: once a phone has a passkey here, acting on a desk asks for it.
// One Face ID covers the next five minutes on this page.
let unlock = "", unlockUntil = 0, face = {required: false, pairing: false, here: false, ids: []};
function b64u(buf) { return btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
const cancelled = e => e && e.name === "NotAllowedError";
async function faceUnlock() {
  if (!window.PublicKeyCredential || !window.isSecureContext) throw new Error("Answering needs Face ID, which needs Coldfall's https link. It's in Settings on the Mac, under General.");
  const b = await api("/api/faceid/begin", {});
  if (!b.challenge) throw new Error(b.message || "Face ID isn't available here.");
  const c = await navigator.credentials.get({publicKey: {challenge: keyBytes(b.challenge), rpId: b.rpId, userVerification: "required", timeout: 60000,
    allowCredentials: b.ids.map(id => ({type: "public-key", id: keyBytes(id)}))}});
  const r = await api("/api/faceid/verify", {id: b64u(c.rawId), clientDataJSON: b64u(c.response.clientDataJSON),
    authenticatorData: b64u(c.response.authenticatorData), signature: b64u(c.response.signature)});
  if (!r.ok) throw new Error(r.message);
  unlock = r.unlock; unlockUntil = Date.now() + (r.seconds - 10) * 1000;
}
// Acting on a desk (an answer, a message, a start): Face ID first when asked.
async function act(path, body) {
  try {
    if (face.required && Date.now() >= unlockUntil) await faceUnlock();
    let r = await api(path, Object.assign({}, body, {unlock}));
    if (r.needsFaceID) { unlockUntil = 0; await faceUnlock(); r = await api(path, Object.assign({}, body, {unlock})); }
    return r;
  } catch (e) {
    return {message: cancelled(e) ? "Face ID was cancelled, so nothing was sent." : e.message};
  }
}
async function faceState() {
  try {
    face = await api("/api/faceid/state", {});
    const can = !!window.PublicKeyCredential && window.isSecureContext && face.here;
    let say = "", setUp = false;
    if (face.pairing && can) { say = "Set up Face ID: after this, answering a desk from a phone asks for it."; setUp = true; }
    else if (face.pairing) say = "To set up Face ID, open Coldfall's https link on your phone. It's in Settings on the Mac, under General.";
    else if (face.required && face.ids.length) say = "Answering from here asks for Face ID.";
    else if (face.required) say = "Answering asks for Face ID, which this address can't do. Open Coldfall's https link on the phone you set up.";
    else say = "Want Face ID before answering from your phone? Start it on the Mac: Settings, General, Set Up a Phone.";
    $("facesay").textContent = say;
    $("facekeys").classList.toggle("hidden", !setUp);
    phoneShow();
  } catch (e) {}
}
$("faceset").onclick = async () => {
  try {
    const b = await api("/api/faceid/begin", {});
    if (!b.challenge) throw new Error(b.message);
    const c = await navigator.credentials.create({publicKey: {challenge: keyBytes(b.challenge), rp: {id: b.rpId, name: "Coldfall"},
      user: {id: crypto.getRandomValues(new Uint8Array(16)), name: "Coldfall inbox", displayName: "Coldfall inbox"},
      pubKeyCredParams: [{type: "public-key", alg: -7}], timeout: 60000, attestation: "none",
      authenticatorSelection: {authenticatorAttachment: "platform", userVerification: "required", residentKey: "discouraged"},
      excludeCredentials: b.ids.map(id => ({type: "public-key", id: keyBytes(id)}))}});
    const r = await api("/api/faceid/register", {clientDataJSON: b64u(c.response.clientDataJSON), attestationObject: b64u(c.response.attestationObject)});
    $("facesay").textContent = r.message || "";
    if (r.ok) { $("facekeys").classList.add("hidden"); face.required = true; setTimeout(faceState, 3000); }
  } catch (e) { $("facesay").textContent = cancelled(e) ? "Face ID setup was cancelled." : "Couldn't set up Face ID: " + e.message; }
};

function seen() { if (navigator.clearAppBadge) navigator.clearAppBadge().catch(() => {}); }

window.addEventListener("hashchange", show);
document.addEventListener("visibilitychange", () => { if (!document.hidden) { show(); seen(); faceState(); } });
show();
seen();
pushState();
faceState();
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
