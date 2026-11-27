import Foundation

extension Inbox {
    /// The whole page. Agent output only ever reaches it through textContent,
    /// never innerHTML, so nothing a desk prints can become markup.
    /// The page as served: the template with its own version written in,
    /// so a page left open on a phone can tell that the Mac now serves a
    /// newer one (see `pageVersion`).
    public static let page = pageTemplate.replacingOccurrences(of: "__PAGE_VERSION__", with: pageVersion)
    /// Which page this Coldfall serves: a hash of it, sent with every answer.
    public static let pageVersion = textHash(pageTemplate)

    static let pageTemplate = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#faf9f5" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#1f1e1d" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="Coldfall">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon-180.png">
<title>Coldfall</title>
<style>
:root{--onaccent:#fff;--bg:#faf9f5;--side:#f3f1ea;--surface:#fff;--raised:#f0eee6;--bubble:#efece3;--text:#1f1e1d;--dim:#73726c;--faint:#a3a199;--line:#e6e3da;--accent:#c96442;--green:#3f8f55;--amber:#c27c12;--red:#c0392b;--term:#fdfcf9;--glass:rgba(250,249,245,.86);--vh:100dvh}
@media (prefers-color-scheme:dark){:root{--bg:#1f1e1d;--side:#1a1918;--surface:#2a2927;--raised:#30302e;--bubble:#3a3936;--text:#f3f2ee;--dim:#a6a39b;--faint:#75736d;--line:#3b3a37;--accent:#d97757;--green:#71c287;--amber:#e3ab4f;--red:#ef6a55;--term:#191817;--glass:rgba(31,30,29,.86)}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{height:100%;margin:0;overflow:hidden;overscroll-behavior:none}
body{background:var(--bg);color:var(--text);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
button{font:inherit;color:inherit;cursor:pointer}
.hidden{display:none!important}
#app{position:fixed;left:0;right:0;top:0;height:var(--vh);display:flex}
.pane{display:flex;flex-direction:column;min-width:0;min-height:0;flex:1;position:relative}
.circle{width:42px;height:42px;border-radius:50%;border:1px solid var(--line);background:var(--glass);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);display:grid;place-items:center;flex:none;padding:0}
.circle svg{width:20px;height:20px;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round}
.pill{border:1px solid var(--line);background:var(--glass);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);border-radius:999px}
.muted{color:var(--dim);font-size:13px}

/* the list (home on a phone, a drawer over a desk, a sidebar when wide) */
#side{background:var(--bg)}
.top{display:flex;align-items:center;gap:10px;padding:calc(env(safe-area-inset-top) + 12px) calc(env(safe-area-inset-right) + 16px) 6px calc(env(safe-area-inset-left) + 16px);flex:none}
.top h1{font-size:26px;letter-spacing:-.01em;margin:0;flex:1}
.tools{padding:4px calc(env(safe-area-inset-right) + 16px) 8px calc(env(safe-area-inset-left) + 16px);flex:none}
#q{width:100%;background:var(--raised);color:var(--text);border:0;border-radius:12px;padding:10px 14px;font:inherit;font-size:16px;outline:none}
.chips{display:flex;gap:6px;margin-top:10px;overflow-x:auto}
.chips button{background:none;border:1px solid var(--line);border-radius:999px;padding:5px 13px;font-size:14px;white-space:nowrap;color:var(--dim)}
.chips button.on{background:var(--text);color:var(--bg);border-color:var(--text)}
.chips .n{opacity:.65;margin-left:5px}
.scroll{flex:1;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;padding:0 calc(env(safe-area-inset-right) + 10px) calc(env(safe-area-inset-bottom) + 28px) calc(env(safe-area-inset-left) + 10px)}
h2{font-size:12px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--faint);margin:20px 8px 4px}
.group{display:flex;align-items:center;gap:6px;width:100%;background:none;border:0;padding:12px 8px 4px;color:var(--dim);font-size:13px;font-weight:600;text-align:left}
.group .chev{display:inline-block;transition:transform .15s;width:12px;font-size:10px}
.group.folded .chev{transform:rotate(-90deg)}
.group .n{font-weight:400;color:var(--faint)}
.row{display:flex;align-items:center;gap:12px;width:100%;border-radius:14px;padding:10px 4px 10px 10px;cursor:pointer}
.row:active,.row.cur{background:var(--raised)}
.row .mid{flex:1;min-width:0}
.row .name{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:flex;align-items:center;gap:7px}
.row .sub{color:var(--dim);font-size:14px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .end{text-align:right;color:var(--faint);font-size:12px;flex:none;line-height:1.35}
.row .more{background:none;border:0;color:var(--faint);font-size:18px;padding:6px 8px;flex:none;line-height:1}
.pin{font-size:10px;filter:grayscale(1);opacity:.55}
.av{width:34px;height:34px;border-radius:10px;flex:none;display:grid;place-items:center;font:700 13px/1 -apple-system,system-ui,sans-serif;color:#fff;background:#6b6b6b;position:relative}
.av .st{position:absolute;right:-3px;bottom:-3px;width:12px;height:12px;border-radius:50%;border:2px solid var(--bg);background:var(--faint)}
.row.cur .av .st,.row:active .av .st{border-color:var(--raised)}
.off .av{opacity:.55}.off .av .st,.asleep .av .st{display:none}
.blocked .st{background:var(--amber)}.ready .st{background:var(--green)}.working .st{background:var(--accent);animation:pulse 1.4s ease-in-out infinite}.quiet .st{background:var(--faint)}
.blocked .name{color:var(--amber)}
.moon{color:var(--faint);font-size:12px}
@keyframes pulse{50%{opacity:.3}}
.empty{color:var(--dim);padding:28px 8px;text-align:center}
.ask{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:12px 14px;margin:8px 4px}
.ask .who{display:flex;gap:8px;align-items:baseline;margin-bottom:4px}
.ask .who b{color:var(--amber)}
.ask p{margin:0;font-size:15px;word-break:break-word}
.ask .act{display:flex;gap:8px;margin-top:10px}
.ask .act button{background:var(--raised);border:0;border-radius:999px;padding:7px 14px;font-size:14px}
#phone{margin:28px 4px 0}
#help{margin:16px 4px 28px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:12px 14px;font-size:14px;color:var(--dim);margin-top:8px}
.card .keys{margin:10px 0 0}
.card .keys button{background:var(--raised);border:0;border-radius:999px;padding:8px 14px}
.card .keys button.go{background:var(--accent);color:var(--onaccent);font-weight:600}
#backdrop{position:fixed;inset:0;background:rgba(0,0,0,.4);z-index:7;opacity:0;pointer-events:none;transition:opacity .2s}

/* a desk */
#detail{background:var(--bg)}
.head{position:absolute;left:0;right:0;top:0;z-index:3;padding:calc(env(safe-area-inset-top) + 8px) calc(env(safe-area-inset-right) + 12px) 16px calc(env(safe-area-inset-left) + 12px);background:linear-gradient(var(--bg) 72%,transparent)}
.hrow{display:flex;align-items:center;gap:8px}
.title{flex:1;display:flex;justify-content:center;min-width:0}
.title .pill{padding:5px 18px;text-align:center;max-width:100%;min-width:0;background:var(--glass)}
.title b{display:block;font-size:16px;line-height:1.25;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.title span{display:block;font-size:12.5px;color:var(--dim);line-height:1.25;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.right{display:flex;align-items:center;gap:2px;padding:3px 4px 3px 6px;flex:none}
.right button{background:none;border:0;padding:6px 8px;display:grid;place-items:center}
.ring{width:32px;height:32px;position:relative}
.ring svg{width:32px;height:32px;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:3}
.ring .bgc{stroke:var(--line)}.ring .fg{stroke:var(--accent);stroke-linecap:round;transition:stroke-dashoffset .4s}
.ring i{position:absolute;inset:0;display:grid;place-items:center;font:600 10.5px/1 -apple-system,system-ui,sans-serif;font-style:normal}
.dots3{font-size:20px;letter-spacing:1px;line-height:1}
.tabs{display:flex;justify-content:center;gap:4px;margin:0 auto}
.tabs button{background:none;border:0;border-radius:999px;padding:3px 12px;font-size:13px;color:var(--dim)}
.tabs button.on{background:var(--raised);color:var(--text)}
#tabsrow{display:flex;justify-content:center;margin-top:8px}
.body{flex:1;min-height:0;overflow:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain}
#chat{padding:0 calc(env(safe-area-inset-right) + 18px) 14px calc(env(safe-area-inset-left) + 18px)}
#chatlist{max-width:760px;margin:0 auto}
.m{margin:14px 0;word-break:break-word}
.m.user{display:flex;justify-content:flex-end}
.m.user .b{background:var(--bubble);border-radius:20px;padding:10px 15px;max-width:86%;white-space:pre-wrap}
.m.user.pending{flex-direction:column;align-items:flex-end}.m.user.pending .b{opacity:.7}
.m.user .lbl{font-size:12px;color:var(--faint);margin:4px 8px 0}
.m.assistant{font-size:16px;line-height:1.55}
.m.assistant p{margin:0 0 .7em}.m.assistant p:last-child{margin-bottom:0}
.m.assistant h3,.m.assistant h4{font-size:16.5px;margin:1em 0 .4em}
.m.assistant ul,.m.assistant ol{margin:.2em 0 .8em;padding-left:1.4em}.m.assistant li{margin:.25em 0}
.m.assistant blockquote{margin:.5em 0;padding-left:12px;border-left:3px solid var(--line);color:var(--dim)}
.m code{font:13.5px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--raised);border-radius:5px;padding:1px 5px}
.m pre{background:var(--term);border:1px solid var(--line);border-radius:12px;padding:10px 12px;overflow-x:auto;margin:.4em 0 .9em}
.m pre code{background:none;padding:0;font-size:12.5px;white-space:pre}
.m table{border-collapse:collapse;font-size:14px;margin:.4em 0 .9em;display:block;overflow-x:auto}
.m th,.m td{border:1px solid var(--line);padding:5px 9px;text-align:left;vertical-align:top}
.m th{background:var(--raised)}
.m a,#screen a{color:var(--accent);overflow-wrap:anywhere}
.toolrow{margin:10px 0;color:var(--dim);font-size:14px}
.toolrow summary{list-style:none;display:inline-flex;align-items:center;gap:7px;cursor:pointer;padding:4px 10px 4px 8px;border:1px solid var(--line);border-radius:999px}
.toolrow summary::-webkit-details-marker{display:none}
.toolrow div{font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:6px 0 0 10px;padding-left:10px;border-left:2px solid var(--line);white-space:pre-wrap;word-break:break-all}
.when{color:var(--faint);font-size:12px;text-align:center;margin:20px 0 6px}
#earlier{text-align:center;color:var(--faint);font-size:13px;padding:6px 0 0}
#working{display:flex;align-items:center;gap:10px;color:var(--dim);font-size:15px;margin:16px 0 4px}
.spark{display:inline-flex;gap:4px}.spark i{width:6px;height:6px;border-radius:50%;background:var(--accent);animation:blink 1.2s infinite}
.spark i:nth-child(2){animation-delay:.2s}.spark i:nth-child(3){animation-delay:.4s}
@keyframes blink{0%,80%,100%{opacity:.25}40%{opacity:1}}
#screen{padding:0 calc(env(safe-area-inset-right) + 12px) 12px calc(env(safe-area-inset-left) + 12px);white-space:pre-wrap;word-break:break-word;font:11.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--term)}
#top{font:12.5px/1.4 -apple-system,system-ui,sans-serif;color:var(--faint);text-align:center;padding:4px 10px 12px}
#jump{position:absolute;left:50%;transform:translateX(-50%);z-index:2;bottom:0;margin-bottom:8px}
.dock{flex:none;padding:6px calc(env(safe-area-inset-right) + 12px) calc(env(safe-area-inset-bottom) + 8px) calc(env(safe-area-inset-left) + 12px);position:relative}
.dockin{max-width:760px;margin:0 auto}
#notice{margin:0 0 8px;border-color:var(--amber)}
.q{background:var(--surface);border:1px solid var(--amber);border-radius:20px;padding:12px;margin:0 0 8px}
.q .qt{font-weight:600;margin:0 4px 8px}
.q .qs{display:flex;flex-direction:column;gap:6px}
.q .qs button{background:var(--raised);border:0;border-radius:12px;padding:10px 12px;text-align:left;font-size:15px}
.q .qs button b{color:var(--dim);margin-right:8px;font-weight:600}
.q .row2{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.q .row2 button{background:none;border:1px solid var(--line);border-radius:999px;padding:6px 12px;font-size:14px}
.q .muted{margin:8px 4px 0}
.composer{background:var(--surface);border:1px solid var(--line);border-radius:26px;padding:10px 10px 8px 16px;box-shadow:0 2px 12px rgba(0,0,0,.06)}
.composer textarea{width:100%;min-height:26px;max-height:34vh;resize:none;background:none;color:var(--text);border:0;outline:none;padding:4px 4px 6px 0;font:inherit;font-size:16.5px;line-height:1.4;display:block}
.composer .bar{display:flex;align-items:center;gap:8px;margin-left:-6px}
.composer .bar .sp{flex:1}
.model{border:1px solid var(--line);background:none;border-radius:999px;padding:6px 13px;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:56%}
.model .ef{color:var(--dim)}
.send{width:38px;height:38px;border-radius:50%;border:0;background:var(--accent);color:var(--onaccent);display:grid;place-items:center;flex:none;padding:0}
.send svg{width:18px;height:18px;stroke:var(--onaccent);fill:none;stroke-width:2.4;stroke-linecap:round;stroke-linejoin:round}
.send:disabled{opacity:.35}
.send.stop{background:var(--text)}.send.stop i{width:12px;height:12px;border-radius:2px;background:var(--bg)}
.add{width:36px;height:36px;border:1px solid var(--line);background:none}
.photos{display:flex;gap:10px;overflow-x:auto;padding:8px 8px 6px 0}
.photo{position:relative;flex:none}
.photo img{width:60px;height:60px;object-fit:cover;border-radius:12px;display:block}
.photo button{position:absolute;top:-6px;right:-6px;width:22px;height:22px;border-radius:50%;border:0;background:var(--text);color:var(--bg);font-size:12px;line-height:1;padding:0}
.photo.busy img{opacity:.4}
.start{width:100%;background:var(--accent);color:var(--onaccent);border:0;border-radius:999px;padding:13px;font-weight:600;font-size:16px}
#note{font-size:13px;color:var(--dim);margin:6px 8px 0;text-align:center}
#note:empty{display:none}
#conn{position:fixed;left:50%;transform:translateX(-50%);top:calc(env(safe-area-inset-top) + 60px);z-index:8;background:var(--text);color:var(--bg);border-radius:999px;padding:7px 14px;font-size:13px;box-shadow:0 4px 16px rgba(0,0,0,.2)}
#none{flex:1;display:none;place-items:center;color:var(--faint)}
#sheet{position:fixed;inset:0;background:rgba(0,0,0,.4);display:flex;align-items:flex-end;justify-content:center;z-index:9}
#sheet .panel{background:var(--surface);width:100%;max-width:520px;border-radius:22px 22px 0 0;padding:16px 14px calc(env(safe-area-inset-bottom) + 14px)}
#sheet .stitle{font-weight:600;text-align:center;margin:2px 0 4px}
#sheet .say{color:var(--dim);font-size:14px;text-align:center;margin:0 8px 10px}
#sheet .acts button{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;background:var(--raised);border:0;border-radius:14px;padding:14px;margin:6px 0;font-size:16px}
#sheet .acts button.danger{color:var(--red);font-weight:600}
#sheet .acts button.on{font-weight:600}
#sheet .acts button.on::after{content:"✓";color:var(--accent)}
#sheet .acts button.cancel{font-weight:600;background:none}
#sheet .acts button.primary{background:var(--accent);color:var(--onaccent);font-weight:600}
#sheet .acts button:disabled{opacity:.6}
#sheet textarea.report{display:block;width:100%;min-height:96px;resize:none;background:var(--raised);color:var(--text);border:1px solid var(--line);border-radius:14px;padding:10px 12px;font:inherit;font-size:16px;outline:none}
#sheet .diag{max-height:24vh;overflow:auto;margin:6px 0;padding:8px 10px;border-radius:12px;background:var(--raised);color:var(--dim);font:11px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-word}
#sheet .panel{max-height:calc(var(--vh, 100vh) - 24px);overflow:auto}
@media (min-width:820px){
  #side{flex:0 0 340px;border-right:1px solid var(--line);background:var(--side)}
  #menu{display:none}
  body.nodesk #none{display:grid}
  #sheet{align-items:center}
  #sheet .panel{border-radius:22px}
}
@media (max-width:819px){
  body.indesk #side{position:fixed;left:0;top:0;bottom:0;width:86%;max-width:380px;z-index:8;transform:translateX(-102%);transition:transform .22s ease;box-shadow:0 0 30px rgba(0,0,0,.3);height:var(--vh)}
  body.drawer #side{transform:none}
  body.drawer #backdrop{opacity:1;pointer-events:auto}
  body.nodesk #detail{display:none}
}
</style>
</head>
<body class="nodesk">
<div id="app">
<div class="pane" id="side">
  <div class="top">
    <h1>Desks</h1>
    <button class="circle" id="sortbtn" aria-label="Sort desks"><svg viewBox="0 0 24 24"><path d="M7 4v16M3.5 16.5 7 20l3.5-3.5M17 20V4M13.5 7.5 17 4l3.5 3.5"/></svg></button>
  </div>
  <div class="tools">
    <input id="q" type="search" placeholder="Search desks" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search">
    <div class="chips" id="chips"><button data-f="all" class="on">All</button><button data-f="active">Running<span class="n" id="nactive"></span></button><button data-f="waiting">Needs me<span class="n" id="nwaiting"></span></button></div>
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
    <section id="help">
      <div class="card">Something not working right? Your Mac keeps what this page notices going wrong.
        <div class="keys"><button id="reportbtn">Report a problem</button></div>
      </div>
    </section>
  </div>
</div>
<div class="pane" id="detail">
  <div class="head" id="head">
    <div class="hrow">
      <button class="circle" id="menu" aria-label="Desks"><svg viewBox="0 0 24 24"><path d="M5 9h14M5 15h9"/></svg></button>
      <div class="title"><div class="pill" id="titlepill"><b id="title"></b><span id="place"></span></div></div>
      <div class="right pill">
        <div class="ring" id="ring" title="How full its context is"><svg viewBox="0 0 36 36"><circle class="bgc" cx="18" cy="18" r="15"/><circle class="fg" id="ringfg" cx="18" cy="18" r="15" stroke-dasharray="94.25" stroke-dashoffset="94.25"/></svg><i id="ringtext"></i></div>
        <button id="more" aria-label="Desk actions"><span class="dots3">···</span></button>
      </div>
    </div>
    <div id="tabsrow"><div class="tabs pill" id="tabs"><button data-t="chat" class="on">Chat</button><button data-t="screen">Screen</button></div></div>
  </div>
  <div class="body" id="chatbody">
    <div id="chat">
      <div id="chatlist"><div id="earlier"></div><div id="msgs"></div>
        <div id="working" class="hidden"><span class="spark"><i></i><i></i><i></i></span><span id="worktext">Working</span></div>
      </div>
    </div>
  </div>
  <div class="body hidden" id="screenbody"><div id="screen"><div id="top" class="hidden"></div><div id="screentext"></div></div></div>
  <div class="dock">
    <button class="circle hidden" id="jump" aria-label="Go to the latest"><svg viewBox="0 0 24 24"><path d="M12 5v14M6 13l6 6 6-6"/></svg></button>
    <div class="dockin">
      <div class="ask hidden" id="notice"><p id="noticetext"></p><div class="act"><button id="noticeclear">Dismiss</button></div></div>
      <div class="q hidden" id="question"><div class="qt" id="qtext"></div><div class="qs" id="opts"></div><div class="row2" id="keys"></div><div class="muted hidden" id="unread"></div></div>
      <button class="start hidden" id="open">Start</button>
      <div class="composer" id="composer">
        <div class="photos hidden" id="photos"></div>
        <textarea id="msg" rows="1" placeholder="Message" enterkeyhint="enter"></textarea>
        <input type="file" id="file" accept="image/*" multiple class="hidden">
        <div class="bar">
          <button class="circle add" id="attach" aria-label="Attach photos"><svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg></button>
          <button class="model hidden" id="model"></button>
          <span class="sp"></span>
          <button class="send" id="send" aria-label="Send"><svg viewBox="0 0 24 24"><path d="M12 19V5M6 11l6-6 6 6"/></svg></button>
        </div>
      </div>
      <div id="note"></div>
    </div>
  </div>
</div>
<div id="none">Pick a desk</div>
<div id="backdrop"></div>
</div>
<div id="conn" class="hidden"></div>
<div id="sheet" class="hidden"><div class="panel"><div class="stitle" id="sheettitle"></div><div class="say" id="sheetsay"></div><div class="acts" id="sheetacts"></div></div></div>
<script>
"use strict";
const $ = id => document.getElementById(id);
const labels = {blocked:"Needs you", ready:"Done", working:"Working", quiet:"Idle", off:"Not running", asleep:"Asleep"};
let current = null, listTimer = null, deskTimer = null, chatTimer = null, desks = [], notices = [], filter = "all";
const drafts = {}, photoDrafts = {};
let photos = [];
const store = {get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
               set(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }};
const wide = () => window.matchMedia("(min-width: 820px)").matches;
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; }

// --- trouble: what this page sees go wrong, kept on the phone (so it lasts
// through a reload) and sent to the Mac, where `coldfall-cli phone-log` reads
// it. Only the page's own words go: an error, a route, a status, never what a
// desk said.
const PAGE = "__PAGE_VERSION__";
const loud = new Set(["error", "rejection", "net", "timeout", "http", "stall", "reload"]);
const diag = (() => { try { const a = JSON.parse(localStorage.getItem("cf.diag") || "[]"); return Array.isArray(a) ? a.slice(-80) : []; } catch (e) { return []; } })();
let diagSent = +(store.get("cf.diagSent") || 0), diagTimer = 0, diagLast = 0;
function where() { try { return {desk: current || "", tab: typeof tab === "string" ? tab : ""}; } catch (e) { return {desk: "", tab: ""}; } }
function trouble(kind, msg) {
  const w = where(), now = Date.now();
  const m = String(msg || "").replace(/([?&#]t=)[^&#\s]*/g, "$1…").slice(0, 400);
  const last = diag[diag.length - 1];
  if (last && last.kind === kind && last.msg === m && last.t > diagSent && now - last.t < 120000) { last.n = (last.n || 1) + 1; }
  else { diag.push({t: now, kind, msg: m, desk: w.desk, tab: w.tab, page: PAGE}); if (diag.length > 80) diag.splice(0, diag.length - 80); }
  store.set("cf.diag", JSON.stringify(diag));
  if (loud.has(kind)) sendTroubleSoon();
}
function device() {
  let app = false; try { app = !!navigator.standalone || matchMedia("(display-mode: standalone)").matches; } catch (e) {}
  return {device: String(navigator.userAgent || "").slice(0, 200), size: innerWidth + "x" + innerHeight + (app ? " Home Screen app" : " browser")};
}
// At most every 20 seconds, so a page that keeps failing doesn't flood the Mac.
function sendTroubleSoon() {
  if (diagTimer) return;
  diagTimer = setTimeout(() => { diagTimer = 0; sendTrouble(); }, Math.max(3000, 20000 - (Date.now() - diagLast)));
}
function sendTrouble(extra) {
  const fresh = diag.filter(e => e.t > diagSent);
  if (!extra && !fresh.some(e => loud.has(e.kind))) return Promise.resolve({ok: true});
  diagLast = Date.now();
  const upTo = fresh.length ? fresh[fresh.length - 1].t : diagSent;
  const events = fresh.map(e => Object.assign({}, e, {msg: e.n > 1 ? e.msg + " (" + e.n + " times)" : e.msg}));
  const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 30000);
  return fetch("/api/report", {method: "POST", signal: ctl.signal, headers: {"Content-Type": "application/json", "X-Coldfall": "1"},
      body: JSON.stringify(Object.assign({events}, device(), extra || {}))})
    .then(r => r.json())
    .then(r => { clearTimeout(t); diagSent = Math.max(diagSent, upTo); store.set("cf.diagSent", String(diagSent)); return r; })
    .catch(() => { clearTimeout(t); return {ok: false, message: "Couldn't reach your Mac. Try again when it's awake and Tailscale is on."}; });
}
window.addEventListener("error", e => trouble("error", (e.message || "Script error") + (e.lineno ? " (line " + e.lineno + ":" + (e.colno || 0) + ")" : "")));
window.addEventListener("unhandledrejection", e => { const r = e.reason; trouble("rejection", (r && (r.stack || r.message)) || String(r)); });
window.addEventListener("online", () => trouble("online", ""));
window.addEventListener("offline", () => trouble("offline", ""));
// A page that stops running (a long render, a stuck loop) shows up as a gap
// in a once-a-second beat while it's on screen.
let beat = 0;
setInterval(() => { const now = Date.now(); if (beat && !document.hidden && now - beat > 4000) trouble("stall", "The page didn't run for " + ((now - beat) / 1000).toFixed(1) + "s"); beat = document.hidden ? 0 : now; }, 1000);
document.addEventListener("visibilitychange", () => { beat = 0; if (!document.hidden) trouble("visible", ""); });
trouble("load", PAGE + " " + device().size);
if (diag.some(e => e.t > diagSent && loud.has(e.kind))) sendTroubleSoon();

function reportSheet() {
  let shot = null;
  sheet("Report a problem", "Your Mac gets what you write, a screenshot if you add one, and what the page noticed itself (below). Nothing a desk said is sent.",
    [{label: "Send to my Mac", cls: "primary", keep: true, run: async () => {
      const b = $("sheetacts").querySelector("button.primary"), note = ta.value.trim();
      if (!note && !shot) { $("sheetsay").textContent = "Write a line about what went wrong first."; ta.focus(); return; }
      b.disabled = true; b.textContent = "Sending…";
      const w = where();
      const r = await sendTrouble({note: note || "(a screenshot only)", desk: w.desk, tab: w.tab, page: PAGE, shot: shot ? await base64(shot) : undefined});
      if (r && r.ok) { closeSheet(); say("Sent to your Mac."); }
      else { b.disabled = false; b.textContent = "Send to my Mac"; $("sheetsay").textContent = (r && r.message) || "Couldn't send it. Try again in a moment."; }
    }}]);
  const ta = el("textarea", "report"); ta.placeholder = "What were you doing, and what went wrong?";
  const file = document.createElement("input"); file.type = "file"; file.accept = "image/*"; file.hidden = true;
  const pick = el("button", "", "Add a screenshot");
  pick.onclick = () => file.click();
  file.onchange = async () => {
    const f = file.files && file.files[0]; if (!f) return;
    const s = await shrink(f); URL.revokeObjectURL(s.url);
    shot = s.blob; pick.textContent = "Screenshot added ✓";
  };
  const seen = diag.filter(e => !["visible", "online"].includes(e.kind)).slice(-14);
  const log = el("div", "diag", seen.length ? seen.map(e => new Date(e.t).toTimeString().slice(0, 8) + "  " + e.kind + "  " + e.msg + (e.n > 1 ? " (" + e.n + " times)" : "")).join("\n") : "Nothing has gone wrong that the page could see.");
  $("sheetacts").prepend(ta, pick, file, log);
}

// The app is exactly what the screen shows, so the message box rides on the
// keyboard rather than hiding behind it or floating halfway up.
function fit() {
  const v = window.visualViewport;
  document.documentElement.style.setProperty("--vh", (v ? v.height : window.innerHeight) + "px");
  $("app").style.transform = v && v.offsetTop ? "translateY(" + v.offsetTop + "px)" : "";
  pad();
}
if (window.visualViewport) { visualViewport.addEventListener("resize", fit); visualViewport.addEventListener("scroll", fit); }
window.addEventListener("resize", fit);

// The Mac's theme, when it isn't the default: its colours, light and dark,
// following this device's own setting.
let look = null;
const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
function paintLook() {
  const root = document.documentElement.style;
  const vars = look && (darkQuery.matches ? look.dark : look.light);
  for (const k of ["bg","side","surface","raised","bubble","text","dim","faint","line","accent","onaccent","term","green","amber","red","sel","glass"]) root.removeProperty("--" + k);
  if (!vars) return;
  for (const [k, v] of Object.entries(vars)) if (/^[0-9a-f]{6}$/i.test(v)) root.setProperty("--" + k, "#" + v);
  const b = vars.bg || "000000", n = parseInt(b, 16);
  root.setProperty("--glass", "rgba(" + (n >> 16 & 255) + "," + (n >> 8 & 255) + "," + (n & 255) + ",.88)");
  for (const m of document.querySelectorAll('meta[name="theme-color"]')) m.content = "#" + vars.bg;
}
function loadLook() { api("/api/look").then(r => { look = r && !r.default ? r : null; paintLook(); }).catch(() => {}); }
if (darkQuery.addEventListener) darkQuery.addEventListener("change", paintLook);

// Every request gives up after 12 seconds, so a Mac that stopped answering
// never freezes the page; a note says so, and it tries again on its own.
// The page this is, and what to do when the Mac serves a newer one (an
// update while you were away): reload by itself, unless you're writing.
let newer = false;
function checkPage(v) {
  if (!v || v === PAGE || newer) return;
  newer = true;
  tryUpdate();
}
function tryUpdate() {
  if (!newer || document.hidden) return;
  const writing = ($("msg").value.trim() !== "") || photos.length > 0;
  // Once a minute at most, so a page that somehow can't get the new one never loops.
  let last = 0; try { last = +sessionStorage.getItem("cf.reloaded") || 0; } catch (e) {}
  if (writing || Date.now() - last < 60000) {
    $("conn").textContent = "Coldfall was updated. ";
    const b = el("button", "", "Reload");
    b.style.cssText = "background:none;border:0;color:inherit;font:inherit;font-weight:600;text-decoration:underline;padding:0";
    b.onclick = () => { if (current) { drafts[current] = $("msg").value; } location.reload(); };
    $("conn").append(b);
    $("conn").classList.remove("hidden");
    return;
  }
  try { sessionStorage.setItem("cf.reloaded", String(Date.now())); } catch (e) {}
  trouble("reload", "Coldfall was updated: loading the new page");
  location.reload();
}

let failures = 0;
function conn(ok, why) {
  failures = ok ? 0 : failures + 1;
  $("conn").textContent = why || "Can't reach your Mac. Trying again…";
  $("conn").classList.toggle("hidden", failures < 2);
}
function api(path, body) {
  const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 12000);
  const o = body === undefined ? {signal: ctl.signal} : {method:"POST", signal: ctl.signal, headers:{"Content-Type":"application/json","X-Coldfall":"1"}, body:JSON.stringify(body)};
  const route = path.split("?")[0], started = Date.now();
  return fetch(path, o).catch(() => {
      clearTimeout(t);
      trouble(ctl.signal.aborted ? "timeout" : "net", route + (ctl.signal.aborted ? ": no answer in 12s" : ": couldn't connect") + (navigator.onLine === false ? " (offline)" : ""));
      conn(false); throw new Error("Can't reach your Mac. Is it awake, and is Tailscale on here?");
    })
    .then(r => {
      clearTimeout(t);
      const ms = Date.now() - started;
      if (ms > 5000) trouble("slow", route + " took " + (ms / 1000).toFixed(1) + "s");
      if (r.status === 401) { trouble("reload", route + " was refused: asking for the link again"); if (!asking) { asking = true; location.reload(); } throw new Error("Coldfall needs its link again."); }
      if (r.status >= 500) trouble("http", route + " answered " + r.status);
      checkPage(r.headers.get("X-Coldfall-Page"));
      if (!newer) conn(true);
      return r.json().catch(() => { trouble("http", route + " answered " + r.status + " with something that isn't JSON"); throw new Error("Coldfall's answer didn't make sense. Try again."); });
    });
}
// A 401 means the secret changed or was never here: load the page that asks for it.
let asking = false;
function ago(t) {
  if (!t) return "";
  const s = Math.max(0, Date.now()/1000 - t);
  return s < 60 ? "now" : s < 3600 ? Math.floor(s/60) + "m" : s < 86400 ? Math.floor(s/3600) + "h" : Math.floor(s/86400) + "d";
}
function kind(d) { return d.running ? d.activity : (d.asleep ? "asleep" : "off"); }
const rank = {blocked:0, ready:1, working:2, quiet:3, asleep:4, off:5};
// The same letters and colours as the desk list in the app (VendorBadge).
const badges = {claude:["C","#c96442"], codex:["X","#10a37f"], antigravity:["A","#4285f4"], copilot:["G","#8957e5"], grok:["K","#3a3a3a"], ollama:["O","#5a5a5a"], shell:["›","#55534e"]};
function avatar(d) {
  const a = el("span", "av");
  const [letter, colour] = badges[d.runtime] || [(d.runtime || "?").slice(0,1).toUpperCase(), "#6b6b6b"];
  a.textContent = letter; a.style.background = colour;
  a.append(el("span", "st"));
  return a;
}
function go(name) { closeDrawer(); location.hash = "desk=" + encodeURIComponent(name); }

// --- the desk list --------------------------------------------------------
function row(d, showGroup) {
  const k = kind(d);
  const b = el("div", "row " + k + (d.name === current ? " cur" : ""));
  b.setAttribute("role", "button");
  const mid = el("div", "mid");
  const n = el("div", "name");
  n.append(document.createTextNode(d.name));
  if (d.pinned) n.append(el("span", "pin", "📌"));
  if (k === "asleep") n.append(el("span", "moon", "☾"));
  const note = notices.find(x => x.desk === d.name);
  const what = note ? "Asked for you: " + note.text : (d.detail || labels[k] || k);
  mid.append(n, el("div", "sub", showGroup && d.group ? d.group + " · " + what : what));
  const end = el("div", "end");
  end.append(el("div", "", ago(d.lastOutput)));
  if (d.memory) end.append(el("div", "", d.memory));
  const more = el("button", "more", "···");
  more.setAttribute("aria-label", "Actions for " + d.name);
  more.onclick = e => { e.stopPropagation(); deskSheet(d); };
  b.append(avatar(d), mid, end, more);
  b.onclick = () => go(d.name);
  return b;
}
function waiting(d) { return (d.running && (d.activity === "blocked" || d.activity === "ready")) || notices.some(n => n.desk === d.name); }
function matches(d) {
  const q = $("q").value.trim().toLowerCase();
  if (q && !(d.name.toLowerCase().includes(q) || (d.group || "").toLowerCase().includes(q) || (d.detail || "").toLowerCase().includes(q))) return false;
  if (filter === "active") return d.running;
  if (filter === "waiting") return waiting(d);
  return true;
}
// How the list is ordered, as on the Mac: by group (running on top), what
// needs you first, most recent, or by name. Pinned desks always lead.
const sorts = {groups: "By group", needs: "Needs me first", recent: "Most recent", name: "By name"};
let sortBy = store.get("cf.sort") || "groups";
let runningTop = store.get("cf.runningTop") !== "0";
const byName = (a, b) => a.name.localeCompare(b.name);
const byRecent = (a, b) => (b.lastOutput || 0) - (a.lastOutput || 0) || byName(a, b);
const byNeed = (a, b) => rank[kind(a)] - rank[kind(b)] || byRecent(a, b);
const pinFirst = f => (a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) || f(a, b);
function renderList() {
  const list = $("list");
  list.textContent = "";
  $("nactive").textContent = desks.filter(d => d.running).length || "";
  $("nwaiting").textContent = desks.filter(waiting).length || "";
  const shown = desks.filter(matches);
  const section = (title, items, showGroup) => {
    if (!items.length) return;
    if (title) list.append(el("h2", "", title));
    for (const d of items) list.append(row(d, showGroup));
  };
  if (sortBy === "groups") {
    const top = runningTop ? shown.filter(d => d.running).sort(pinFirst(byNeed)) : [];
    const rest = runningTop ? shown.filter(d => !d.running) : shown.slice();
    section(top.length ? "Running" : "", top, true);
    const pinned = rest.filter(d => d.pinned).sort(byName);
    if (rest.length && top.length) list.append(el("h2", "", "Not running"));
    for (const d of pinned) list.append(row(d, true));
    const groups = [];
    for (const d of rest.filter(d => !d.pinned)) {
      const g = d.group || "";
      let e = groups.find(x => x.name === g);
      if (!e) { e = {name: g, desks: []}; groups.push(e); }
      e.desks.push(d);
    }
    groups.sort((a, b) => (a.name ? 0 : 1) - (b.name ? 0 : 1) || a.name.localeCompare(b.name));
    const searching = !!$("q").value.trim();
    for (const g of groups) {
      g.desks.sort(runningTop ? byName : pinFirst(byNeed));
      if (groups.length === 1 && !g.name) { for (const d of g.desks) list.append(row(d, false)); continue; }
      const key = "cf.fold." + (g.name || "-");
      const folded = !searching && store.get(key) === "1";
      const h = el("button", "group" + (folded ? " folded" : ""));
      h.append(el("span", "chev", "▼"), document.createTextNode(g.name || "No group"), el("span", "n", " " + g.desks.length));
      h.onclick = () => { store.set(key, folded ? null : "1"); renderList(); };
      list.append(h);
      if (!folded) for (const d of g.desks) list.append(row(d, false));
    }
  } else {
    const f = sortBy === "needs" ? byNeed : sortBy === "recent" ? byRecent : byName;
    if (runningTop && sortBy !== "needs") {
      section("Running", shown.filter(d => d.running).sort(pinFirst(f)), true);
      section("Not running", shown.filter(d => !d.running).sort(pinFirst(f)), true);
    } else section("", shown.sort(pinFirst(f)), true);
  }
  if (!shown.length) list.append(el("div", "empty", desks.length ? "No desk matches." : "No desks."));
}
$("sortbtn").onclick = () => {
  const acts = Object.entries(sorts).map(([k, label]) => ({label, cls: k === sortBy ? "on" : "", keep: true,
    run: () => { sortBy = k; store.set("cf.sort", k); renderList(); $("sortbtn").onclick(); }}));
  acts.push({label: "Running desks on top", cls: runningTop ? "on" : "", keep: true,
    run: () => { runningTop = !runningTop; store.set("cf.runningTop", runningTop ? "1" : "0"); renderList(); $("sortbtn").onclick(); }});
  sheet("Sort desks", "Pinned desks always come first.", acts, "Done");
};

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
    x.onclick = () => { api("/api/notice/clear", {desk: n.desk}).then(refreshList).catch(e => say(e.message)); };
    act.append(o, x);
    c.append(who, el("p", "", n.text), act);
    box.append(c);
  }
}
function refreshList() {
  return api("/api/desks").then(r => {
    desks = r.desks || []; notices = r.notices || [];
    renderAsks(); renderList();
    if (current) deskHead();
  }).catch(() => {});
}
for (const b of $("chips").querySelectorAll("button")) b.onclick = () => {
  filter = b.dataset.f;
  for (const x of $("chips").querySelectorAll("button")) x.classList.toggle("on", x === b);
  renderAsks(); renderList();
};
$("q").addEventListener("input", renderList);
function openDrawer() { refreshList(); document.body.classList.add("drawer"); }
function closeDrawer() { document.body.classList.remove("drawer"); }
$("menu").onclick = openDrawer;
$("reportbtn").onclick = reportSheet;
$("backdrop").onclick = closeDrawer;

// --- sheets ----------------------------------------------------------------
function sheet(title, said, acts, cancel) {
  $("sheettitle").textContent = title;
  $("sheetsay").textContent = said || "";
  const box = $("sheetacts"); box.textContent = "";
  for (const a of acts.concat([{label: cancel || "Cancel", cls: "cancel"}])) {
    const b = el("button", a.cls || "", a.label);
    b.onclick = () => { if (!a.keep) closeSheet(); if (a.run) a.run(); };
    box.append(b);
  }
  $("sheet").classList.remove("hidden");
}
function closeSheet() { $("sheet").classList.add("hidden"); }
$("sheet").onclick = e => { if (e.target === $("sheet")) closeSheet(); };
function say(text) { $("note").textContent = text || ""; if (text) setTimeout(() => { if ($("note").textContent === text) $("note").textContent = ""; }, 6000); }
function deskSheet(d) {
  const acts = [];
  if (d.name !== current) acts.push({label: "Open", run: () => go(d.name)});
  if (d.running) acts.push({label: "Stop…", cls: "danger", run: () => stopSheet(d)});
  else acts.push({label: d.asleep ? "Wake and start" : "Start", run: () => start(d.name)});
  acts.push({label: d.pinned ? "Unpin" : "Pin to top", run: () => api("/api/pin", {desk: d.name, on: d.pinned ? "false" : "true"}).then(r => { say(r.message); refreshList(); }).catch(e => say(e.message))});
  if (d.name === current) acts.push({label: tab === "chat" ? "Show its screen" : "Show the chat", run: () => setTab(tab === "chat" ? "screen" : "chat")});
  if (d.name === current) acts.push({label: "Report a problem…", run: reportSheet});
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

// --- a desk: header ----------------------------------------------------------
function deskHead() {
  const d = desks.find(x => x.name === current);
  if (d) { $("place").textContent = [labels[kind(d)], d.group].filter(Boolean).join(" · "); }
}
function ring(pct) {
  const has = typeof pct === "number";
  $("ring").classList.toggle("hidden", !has);
  if (!has) return;
  const p = Math.max(0, Math.min(100, pct));
  $("ringfg").style.strokeDashoffset = String(94.25 * (1 - p / 100));
  $("ringtext").textContent = Math.round(p);
  $("ring").title = Math.round(p) + "% of its context used";
}

// --- a desk: chat --------------------------------------------------------------
// Markdown from the agent, built as elements: nothing it wrote is ever markup.
// Only http and https become links; a bare address loses the punctuation after it.
function link(url, label) {
  let u; try { u = new URL(url); } catch (_) { return null; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  const a = el("a"); a.href = u.href; a.target = "_blank"; a.rel = "noopener noreferrer";
  if (typeof label === "string") a.textContent = label; else a.append(label);
  return a;
}
function bare(t) {
  for (;;) {
    const c = t[t.length - 1];
    if (".,;:!?'\"*_".includes(c)) t = t.slice(0, -1);
    else if (c === ")" && (t.match(/\(/g) || []).length < (t.match(/\)/g) || []).length) t = t.slice(0, -1);
    else if (c === "]" && (t.match(/\[/g) || []).length < (t.match(/\]/g) || []).length) t = t.slice(0, -1);
    else if (c === ">") t = t.slice(0, -1);
    else return t;
  }
}
const urlRe = /https?:\/\/[^\s<>"'`]+/g;
function linkify(parent, text) {
  let at = 0, m; urlRe.lastIndex = 0;
  while ((m = urlRe.exec(text))) {
    const u = bare(m[0]);
    const a = u.length > 8 ? link(u, u) : null;
    if (!a) continue;
    if (m.index > at) parent.append(document.createTextNode(text.slice(at, m.index)));
    parent.append(a);
    at = m.index + u.length; urlRe.lastIndex = at;
  }
  if (at < text.length) parent.append(document.createTextNode(text.slice(at)));
}
function inline(parent, text) {
  const re = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\(https?:\/\/[^)\s]+\))/g;
  let at = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > at) linkify(parent, text.slice(at, m.index));
    const t = m[0];
    if (t[0] === "`") {
      const c = el("code", "", t.slice(1, -1));
      parent.append(/^https?:\/\/\S+$/.test(c.textContent) ? (link(c.textContent, c) || c) : c);
    }
    else if (t[0] === "*") { const b = el("strong"); inline(b, t.slice(2, -2)); parent.append(b); }
    else { const i = t.indexOf("]("); const label = t.slice(1, i); parent.append(link(t.slice(i + 2, -1), label) || document.createTextNode(label)); }
    at = m.index + t.length;
  }
  if (at < text.length) linkify(parent, text.slice(at));
}
function markdown(text) {
  const out = document.createDocumentFragment();
  const lines = text.replace(/\r/g, "").split("\n");
  let i = 0, para = [];
  const flush = () => { if (para.length) { const p = el("p"); para.forEach((l, k) => { if (k) p.append(el("br")); inline(p, l); }); out.append(p); para = []; } };
  while (i < lines.length) {
    const l = lines[i];
    if (/^\s*```/.test(l)) {
      flush();
      const body = []; i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) body.push(lines[i++]);
      i++;
      const pre = el("pre"); pre.append(el("code", "", body.join("\n"))); out.append(pre); continue;
    }
    if (/^\s*\|.*\|\s*$/.test(l) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
      flush();
      const cells = s => s.trim().replace(/^\||\|$/g, "").split("|").map(c => c.trim());
      const t = el("table"), hr = el("tr");
      for (const c of cells(l)) { const th = el("th"); inline(th, c); hr.append(th); }
      t.append(hr); i += 2;
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        const tr = el("tr"); for (const c of cells(lines[i])) { const td = el("td"); inline(td, c); tr.append(td); } t.append(tr); i++;
      }
      out.append(t); continue;
    }
    let m;
    if ((m = l.match(/^(#{1,6})\s+(.*)$/))) { flush(); const h = el(m[1].length <= 2 ? "h3" : "h4"); inline(h, m[2]); out.append(h); i++; continue; }
    if (/^\s*([-*•]|\d+[.)])\s+/.test(l)) {
      flush();
      const ordered = /^\s*\d+[.)]/.test(l);
      const list = el(ordered ? "ol" : "ul");
      while (i < lines.length && /^\s*([-*•]|\d+[.)])\s+/.test(lines[i])) {
        const li = el("li"); inline(li, lines[i].replace(/^\s*([-*•]|\d+[.)])\s+/, "")); list.append(li); i++;
        while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*•]|\d+[.)])\s+/.test(lines[i])) { li.append(el("br")); inline(li, lines[i].trim()); i++; }
      }
      out.append(list); continue;
    }
    if (/^>\s?/.test(l)) { flush(); const q = el("blockquote"); inline(q, l.replace(/^>\s?/, "")); out.append(q); i++; continue; }
    if (!l.trim()) { flush(); i++; continue; }
    para.push(l); i++;
  }
  flush();
  return out;
}
let chat = [], chatRev = "", chatMore = false, chatBefore = 0, chatLoading = false, chatNone = false, lastUserAt = 0;
function bubbles(list) {
  // Neighbouring tool lines fold into one row; a long quiet gap shows the time.
  const frag = document.createDocumentFragment();
  let tools = null, prevT = 0;
  for (const m of list) {
    if (m.time && prevT && m.time - prevT > 3600) frag.append(el("div", "when", new Date(m.time * 1000).toLocaleString([], {weekday: "short", hour: "numeric", minute: "2-digit"})));
    if (m.time) prevT = m.time;
    if (m.role === "tool") {
      if (!tools) { tools = {box: el("details", "toolrow"), lines: el("div"), n: 0}; tools.sum = el("summary"); tools.box.append(tools.sum, tools.lines); frag.append(tools.box); }
      tools.n++; tools.lines.append(document.createTextNode((tools.n > 1 ? "\n" : "") + m.text));
      tools.sum.textContent = "⚙ " + (tools.n === 1 ? m.text.split(" · ")[0] : "Used " + tools.n + " tools") + "  ›";
      continue;
    }
    tools = null;
    const d = el("div", "m " + m.role);
    if (m.role === "user") { d.append(el("div", "b", m.text === "[image]" ? "📷 Photo" : m.text)); if (m.label) { d.classList.add("pending"); d.append(el("div", "lbl", m.label)); } }
    else d.append(markdown(m.text));
    frag.append(d);
  }
  return frag;
}
function nearBottom(b) { return b.scrollHeight - b.scrollTop - b.clientHeight < 80; }
// What you sent from here, shown until the agent's transcript has it (Claude
// queues a message sent mid-turn, and writes it down only once it takes it).
let pending = null;
function renderChat(keepPlace) {
  const b = $("chatbody"), stick = nearBottom(b), from = b.scrollHeight - b.scrollTop;
  $("msgs").textContent = "";
  let list = chat.filter(m => m.id >= 0);
  if (pending && pending.desk === current) {
    const head = pending.text.slice(0, 60);
    const landed = list.some(m => m.role === "user" && (!m.time || m.time >= pending.at - 30) && m.text.slice(0, 60) === head);
    if (landed || Date.now() / 1000 - pending.at > 600) pending = null;
    else list = list.concat([{id: -1, role: "user", text: pending.text, time: pending.at, label: pending.label}]);
  }
  $("msgs").append(bubbles(list));
  $("earlier").textContent = chatNone ? "" : chatMore ? "Scroll up for earlier messages" : chat.length ? "Start of this conversation" : "";
  const u = [...chat].reverse().find(m => m.role === "user");
  lastUserAt = Math.max(u && u.time || 0, pending && pending.desk === current ? pending.at : 0);
  if (keepPlace) b.scrollTop = b.scrollHeight - from;
  else if (stick) b.scrollTop = b.scrollHeight;
  else $("jump").classList.remove("hidden");
}
function refreshChat() {
  if (!current || tab !== "chat") return;
  const asked = current;
  const last = chat.filter(m => m.id >= 0).slice(-1)[0];
  api("/api/chat?desk=" + encodeURIComponent(asked) + "&have=" + encodeURIComponent(chatRev) + (last ? "&after=" + last.id : "")).then(r => {
    if (asked !== current) return;
    if (r.loading) { $("earlier").textContent = "Finding the conversation…"; setTimeout(refreshChat, 800); return; }
    if (r.none) { chatNone = true; if (!chat.length) { setTab("screen", true); } return; }
    chatNone = false;
    if (r.same) return;
    const first = !chat.length;
    const got = r.messages || [];
    chat = r.append ? chat.filter(m => m.id >= 0).concat(got) : got;
    chatRev = r.rev || ""; chatMore = !!r.more; chatBefore = r.before || 0;
    renderChat(false);
    if (first) $("chatbody").scrollTop = $("chatbody").scrollHeight;
  }).catch(() => {});
}
$("chatbody").addEventListener("scroll", () => {
  const b = $("chatbody");
  if (nearBottom(b)) $("jump").classList.add("hidden");
  if (b.scrollTop < 120 && chatMore && !chatLoading && current) {
    chatLoading = true;
    const asked = current;
    $("earlier").textContent = "Loading earlier messages…";
    api("/api/chat?desk=" + encodeURIComponent(asked) + "&before=" + chatBefore).then(r => {
      chatLoading = false;
      // Read in the background on the Mac: ask again in a moment.
      if (r.loading && asked === current) { setTimeout(() => $("chatbody").dispatchEvent(new Event("scroll")), 700); return; }
      if (asked !== current || !r.messages) return;
      chat = r.messages.concat(chat); chatMore = !!r.more; chatBefore = r.before || 0;
      renderChat(true);
    }).catch(() => { chatLoading = false; });
  }
});
$("jump").onclick = () => { const b = tab === "chat" ? $("chatbody") : $("screenbody"); b.scrollTop = b.scrollHeight; $("jump").classList.add("hidden"); };

// --- a desk: state, screen, question ----------------------------------------
// The screen comes back only when it changed; scrolling up asks for more of
// what Coldfall keeps, up to 5000 lines.
let tab = "chat", want = 400, have = "", lines = 0, fetching = false, growing = false, deskState = null;
function setTab(t, quiet) {
  tab = t;
  for (const b of $("tabs").querySelectorAll("button")) b.classList.toggle("on", b.dataset.t === t);
  $("chatbody").classList.toggle("hidden", t !== "chat");
  $("screenbody").classList.toggle("hidden", t !== "screen");
  $("jump").classList.add("hidden");
  if (!quiet && current) store.set("cf.tab." + current, t);
  have = "";
  refreshDesk(); refreshChat();
  setTimeout(() => { const b = t === "chat" ? $("chatbody") : $("screenbody"); b.scrollTop = b.scrollHeight; }, 50);
}
for (const b of $("tabs").querySelectorAll("button")) b.onclick = () => setTab(b.dataset.t);
function pad() {
  // Room above the first message for the floating header and tabs.
  const top = $("head").offsetHeight - 6;
  $("chat").style.paddingTop = top + "px";
  $("screen").style.paddingTop = top + "px";
}
function refreshDesk() {
  if (!current || fetching) return;
  const asked = current;
  fetching = true;
  const n = tab === "screen" ? want : 1;
  api("/api/read?desk=" + encodeURIComponent(asked) + "&lines=" + n + "&have=" + encodeURIComponent(tab === "screen" ? have : "")).then(r => {
    fetching = false;
    if (asked !== current) return;
    deskState = r;
    const k = r.running ? r.activity : "off";
    if (tab === "screen" && typeof r.text === "string") {
      const sc = $("screenbody");
      const fromBottom = sc.scrollHeight - sc.scrollTop, top = sc.scrollTop, atBottom = fromBottom - sc.clientHeight < 40;
      const st = $("screentext"); st.textContent = ""; if (r.running) linkify(st, r.text);
      have = r.hash || ""; lines = r.lines || 0;
      sc.scrollTop = atBottom ? sc.scrollHeight : growing ? sc.scrollHeight - fromBottom : top;
      growing = false;
      const more = lines >= want && want < 5000;
      $("top").textContent = !r.running ? current + " isn't running. Start it and it picks up its conversation where it left off."
        : more ? "Scroll up for earlier lines" : "Start of what Coldfall keeps for this desk";
      $("top").classList.toggle("hidden", r.running && lines < 30);
    }
    $("place").textContent = [labels[k] || k, r.place].filter(Boolean).join(" · ");
    ring(r.context);
    const model = r.model ? r.model.replace(/^claude-/i, "") : "";
    $("model").textContent = "";
    if (model) { $("model").append(document.createTextNode(model + " ")); if (r.effort) $("model").append(el("span", "ef", r.effort)); }
    $("model").classList.toggle("hidden", !model);
    // Working: the agent's own spark, and how long since you last asked.
    const working = k === "working";
    $("working").classList.toggle("hidden", !working || tab !== "chat");
    if (working) {
      const s = lastUserAt ? Math.max(0, Math.round(Date.now() / 1000 - lastUserAt)) : 0;
      $("worktext").textContent = s ? "Working · " + (s >= 60 ? Math.floor(s / 60) + "m " + (s % 60) + "s" : s + "s") : "Working";
    }
    // A question: its own choices as buttons, or the plain keys when they couldn't be read.
    const opts = (k === "blocked" && r.options) || [];
    $("question").classList.toggle("hidden", k !== "blocked");
    $("qtext").textContent = r.question || current + " is asking you something";
    const sig = JSON.stringify(opts);
    if ($("opts").dataset.sig !== sig) {
      $("opts").dataset.sig = sig;
      $("opts").textContent = "";
      for (const o of opts) {
        const b = el("button"); b.append(el("b", "", o.key), document.createTextNode(o.label));
        b.onclick = () => { const desk = current; act("/api/keys", {desk, key: o.key}).then(a => { if (current === desk) { say(a.message); setTimeout(refreshDesk, 400); } }); };
        $("opts").append(b);
      }
    }
    $("opts").classList.toggle("hidden", !opts.length);
    $("keys").classList.toggle("hidden", !!opts.length);
    const unread = (k === "blocked" && !opts.length && r.unread) || "";
    $("unread").textContent = unread ? "Its choices couldn't be read, so these are the plain keys. " + unread : "";
    $("unread").classList.toggle("hidden", !unread);
    $("noticetext").textContent = r.notice || "";
    $("notice").classList.toggle("hidden", !r.notice);
    $("open").classList.toggle("hidden", r.running);
    $("open").textContent = "Start " + current;
    const canSend = r.running && k !== "blocked" && r.agent;
    $("composer").classList.toggle("hidden", !canSend);
    $("msg").placeholder = "Reply to " + current + "…";
    sendState();
  }).catch(() => { fetching = false; });
}
$("screenbody").addEventListener("scroll", () => {
  const sc = $("screenbody");
  if (sc.scrollTop < 80 && lines >= want && want < 5000 && !growing) { growing = true; want = Math.min(5000, want * 2); have = ""; refreshDesk(); }
});
for (const [label, key] of [["1","1"],["2","2"],["3","3"],["↑","up"],["↓","down"],["Return","enter"],["Esc","esc"]]) {
  const b = el("button", "", label);
  b.onclick = () => { const desk = current; act("/api/keys", {desk, key}).then(r => { if (current === desk) { say(r.message); setTimeout(refreshDesk, 400); } }); };
  $("keys").append(b);
}

// --- sending ------------------------------------------------------------------
function grow() { const t = $("msg"); t.style.height = "auto"; t.style.height = Math.min(t.scrollHeight, window.innerHeight * .34) + "px"; sendState(); }
// Send when there's something to send; stop (Esc) when the agent is working
// and the box is empty, as in Claude.
const arrow = $("send").querySelector("svg").cloneNode(true);
function sendState() {
  const empty = !$("msg").value.trim() && !photos.length;
  const working = deskState && deskState.running && deskState.activity === "working";
  const stop = empty && working;
  const b = $("send");
  b.classList.toggle("stop", stop);
  b.textContent = "";
  if (stop) { b.append(el("i")); b.setAttribute("aria-label", "Stop this turn"); }
  else { b.append(arrow.cloneNode(true)); b.setAttribute("aria-label", "Send"); }
  b.disabled = empty && !stop;
}
$("msg").addEventListener("input", grow);
$("send").onclick = () => {
  const desk = current;
  if (!desk) return;
  if ($("send").classList.contains("stop")) {
    act("/api/interrupt", {desk}).then(r => { say(r.message); setTimeout(refreshDesk, 600); });
    return;
  }
  if (photos.some(p => !p.path)) { say("Wait for the photos to finish uploading."); return; }
  let text = $("msg").value.trim();
  if (photos.length) text = (text || "Have a look at " + (photos.length === 1 ? "this photo" : "these photos") + ".") + "\n\n" + photos.map(p => p.path).join("\n");
  if (!text) return;
  pending = {desk, text, at: Date.now() / 1000, label: "Sending…"};
  renderChat(false); $("chatbody").scrollTop = $("chatbody").scrollHeight;
  $("msg").value = ""; const sentPhotos = photos; photos = []; renderPhotos(); grow();
  act("/api/send", {desk, text}).then(r => {
    if (r.outcome === "sent") {
      drafts[desk] = ""; photoDrafts[desk] = [];
      if (pending && pending.desk === desk) { pending.label = deskState && deskState.activity === "working" ? "Queued until it finishes this turn" : "Sent"; renderChat(false); }
    } else if (current === desk) { pending = null; renderChat(false); $("msg").value = text.split("\n\n/")[0]; photos = sentPhotos; renderPhotos(); grow(); }
    if (current === desk) { if (r.outcome !== "sent") say(r.message); chatRev = ""; setTimeout(refreshChat, 900); setTimeout(refreshDesk, 600); }
  }).catch(e => say(e.message));
};

// Photos: made smaller on the phone (a desk doesn't need 12 megapixels),
// saved on the Mac beside the desk, and sent as their paths with the message.
function renderPhotos() {
  const box = $("photos"); box.textContent = "";
  for (const p of photos) {
    const c = el("div", "photo" + (p.path ? "" : " busy"));
    const img = el("img"); img.src = p.url; img.alt = "";
    const x = el("button", "", "✕"); x.setAttribute("aria-label", "Remove photo");
    x.onclick = () => { photos = photos.filter(q => q !== p); URL.revokeObjectURL(p.url); renderPhotos(); sendState(); };
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
    photos.push(p); renderPhotos(); sendState();
    const r = await act("/api/upload", {desk, data: await base64(s.blob)});
    if (r.ok && r.path) p.path = r.path;
    else { photos = photos.filter(q => q !== p); if (current === desk) say(r.message || "Couldn't attach that photo."); }
    if (current === desk) { renderPhotos(); sendState(); } else photoDrafts[desk] = (photoDrafts[desk] || []).filter(q => q.path);
  }
};
$("noticeclear").onclick = () => {
  const desk = current;
  api("/api/notice/clear", {desk}).then(r => { if (current === desk) { say(r.message); refreshDesk(); refreshList(); } }).catch(e => say(e.message));
};
$("open").onclick = () => start(current);

// --- moving between desks -----------------------------------------------------
function show() {
  const m = location.hash.match(/^#desk=(.+)$/);
  if (current) { drafts[current] = $("msg").value; photoDrafts[current] = photos; }
  current = m ? decodeURIComponent(m[1]) : null;
  closeDrawer();
  $("msg").value = (current && drafts[current]) || "";
  photos = (current && photoDrafts[current]) || [];
  renderPhotos();
  document.body.classList.toggle("indesk", !!current);
  document.body.classList.toggle("nodesk", !current);
  $("title").textContent = current || "";
  $("place").textContent = "";
  $("note").textContent = "";
  $("screentext").textContent = ""; $("top").classList.add("hidden");
  $("msgs").textContent = ""; $("earlier").textContent = ""; $("working").classList.add("hidden");
  chat = []; chatRev = ""; chatMore = false; chatNone = false; lastUserAt = 0; deskState = null;
  want = 400; have = ""; lines = 0; growing = false; fetching = false;
  for (const id of ["question", "notice", "open"]) $(id).classList.add("hidden");
  $("opts").dataset.sig = ""; ring(null); $("model").classList.add("hidden");
  phoneShow();
  clearInterval(listTimer); clearInterval(deskTimer); clearInterval(chatTimer);
  refreshList();
  if (current) {
    setTab(store.get("cf.tab." + current) || "chat", true);
    deskTimer = setInterval(refreshDesk, 2000);
    chatTimer = setInterval(refreshChat, 2500);
  }
  listTimer = setInterval(() => { if (!current || wide() || document.body.classList.contains("drawer")) refreshList(); }, 3000);
  renderList(); grow(); fit();
}
// Back from the background or the network: look again at once.
function wake() { if (document.hidden) return; if (newer) { tryUpdate(); return; } failures = 0; conn(true); refreshList(); loadLook(); if (current) { fetching = false; refreshDesk(); refreshChat(); } seen(); }
window.addEventListener("pageshow", wake);
window.addEventListener("online", wake);
window.addEventListener("focus", wake);

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
loadLook();
document.addEventListener("visibilitychange", () => { if (!document.hidden) { wake(); faceState(); } });
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
