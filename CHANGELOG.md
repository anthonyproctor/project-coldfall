# Changelog

What changed in each release, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Anything under **Unreleased** is on
`main` and arrives in the next release. In the app, **Project Coldfall ▸ What's New**
opens this file.

## [Unreleased]

### Added
- **The pull request and its checks, in Changes.** When the desk's branch has a pull request,
  the top of Changes says "PR #12 · 2 checks failing" (click to open it), and **Send Failing
  Checks to** the desk asks the agent to find the cause and fix it, without pushing. It asks
  your own `gh`, and only when you open or refresh Changes: no background calls to GitHub.
- **Conversations** (**Desks ▸ Conversations…**, ⇧⌘H): every conversation Claude Code and
  Codex have had in the desk's folder, with when, how big, and the first thing you asked.
  Type to search everything said in them. **Open in a Split** resumes one in a shell beside
  the desk; **Copy Command** gives you the vendor's resume command.
- **Fork Conversation in a Split** runs the vendor's own fork (Claude Code, Codex) beside
  the desk, so you can try something without disturbing the original.
- **Hand Off to Another Desk…** sends the end of a desk's screen to another running desk as
  history, for one that is out of context or out of quota. It says how much goes and that
  nothing is redacted, and asks first; the other agent is told to read it as history,
  check the folder, and change nothing yet.
- **Sleep idle desks.** **Settings ▸ Agents ▸ Idle desks** (off until you pick a time): a
  desk that has finished, been read, and sat untouched that long is put to sleep. Its
  processes end and its memory comes back, its row shows a moon, and opening it picks the
  conversation up. Only desks Coldfall knows how to resume; never one that is working,
  asking, on screen, half typed into, or has a shell split open. A timer or job the agent
  left running ends with it.
- **Changes shows the last turn.** Beside *Uncommitted*, **Last turn** lists only what the
  agent changed since your last prompt, new files included. For a desk that has run for
  weeks, "what did it just do" is the question. Coldfall remembers the folder when you send
  a prompt, using a throwaway copy of git's index: your index, branch and files are not
  touched.
- **Not This One Yet** (⌃⌘U): the desk on screen goes to the back of the waiting queue,
  still marked, and you go to the next. Work through the finished desks without losing
  the ones you can't answer yet.
- **Back and Forward** (⌃⌘← / ⌃⌘→) through the desks you've been on, like a browser.
- **Reopen Stopped Desk** (⇧⌘T) starts again the desk you stopped last.
- **Any agent's terminal notification counts.** A program that sends a plain terminal
  notification (OSC 9, 99 or 777) now marks its desk: Needs you when it reads like a
  question or a request, done otherwise. For agents with neither Coldfall's hook nor
  OSC 7501; where one of those speaks for the desk, it wins.

## [0.3.39] - 2026-11-13

Two desks side by side.

### Added
- **Two desks side by side.** Right-click a desk, **Open Beside**, and it appears next to
  the desk on screen: two agents, each in its own card with its own colour and state. The
  outline shows which one your keys go to; click the other to move them. Choosing the desk
  that is beside swaps the two; choosing any other desk replaces the first and keeps the
  second. Drag the gap to resize (double-click for even halves). The close button on the
  second desk's pane, or **Desks ▸ Close Beside Desk** (⌥⌘W), takes it off the screen; it
  keeps running.

### Changed
- A desk stopped on a question shows **Needs you** even while it is on screen. It used to
  read as idle there, which with two desks in view hid which one was asking.

## [0.3.38] - 2026-11-13

A colour for each desk, so you can see which agent you are in.

### Added
- **A colour for each desk.** Right-click a desk, **Colour**, and pick one of eight (or set
  `color = "teal"` or `color = "#3aa0ff"` in desks.toml). The desk's pane takes it as its
  outline, its header and a faint wash on the terminal; its tab gets a line under it and
  its row a bar. So you can see which agent you are about to type into without reading
  its name.
- More groundwork for Ghostty's terminal, still off in every release: a pane view that hosts
  it (keys, input methods, mouse, paste, copy, resize, Coldfall's theme), tried with
  `--ghostty-demo` in a build made with `COLDFALL_GHOSTTY=1`.

## [0.3.37] - 2026-11-13

Answer waiting desks from one window, and review what a desk changed.

### Added
- **Changes: read what a desk changed, and send comments back.** The Changes button over
  the terminal (or **Desks ▸ Changes…**, ⇧⌘G) lists the files changed in the desk's folder
  since the last commit, with each one's diff. Select lines, write a comment, add as many
  as you like across files, and Send gives the agent all of them in one message, each with
  its file, line and the code it is about. A send is refused, and your comments kept, while
  the desk is asking something. Coldfall only reads the repository: nothing is staged,
  committed or reverted.
- **Needs You: answer waiting desks from one window.** Click "needs you" on the status bar
  (or **Desks ▸ Needs You…**, ⌥⌘0) for every desk stopped on a question, each with its
  question, what it is about, and its choices as buttons. The choices are read off the
  desk's own screen, and a button presses its key only if that choice is still there. A
  desk whose question can't be read offers Go to Desk instead of a guess. ⌘0 still goes
  straight to the desk that has waited longest.
- **The phone inbox names the choices** ("1 Yes", "3 No…") above its plain keys, and shows
  why each desk is waiting in the list.

## [0.3.36] - 2026-11-13

Who needs you next, and why.

### Added
- **Desks by priority.** The button beside "Desks" switches the list between the selected
  group and every running desk from every group under Needs you, Done, Working and Idle,
  longest wait first. It re-sorts only while the pointer is away from the list. Also
  **Desks ▸ Desks by Priority**.
- **Next Desk and Previous Desk** (⌥⌘↓ and ⌥⌘↑) walk the list in the order shown, so by
  priority they take you to whoever needs you first.
- **Why a desk is waiting, beside its name.** "wants to use Bash", or the question it asked,
  in the desk's row and in its notification. From the agent's own words (the done hook, or a
  status report); an installed done hook is updated on launch to pass them on.
- **What a desk is doing, beside its name:** the agent's own terminal title, when it sets one.
- **Mark Unread** on a desk's right-click menu puts its green mark back until you next open it.
- **Context gauge.** A pane's header shows "ctx 62%" in orange from 60%, red from 80%.
- **Zoom Pane** (⇧⌘↩, or the button in a pane's header): one pane fills the desk; again to
  bring the others back.
- A pane's header shows the folder's **git branch** when it isn't main or master.

### Changed
- A pane's split, zoom and close buttons show while the pointer is over the pane.
- With Coldfall behind another app, the desk on screen no longer counts as being looked at:
  an answer that lands then is marked, and notified, like any other desk's.

## [0.3.35] - 2026-11-13

Fixes to the new layout, and a shorter desk list.

### Changed
- **The Desks section lists the selected group only** (plus pinned desks). Click a group and
  the list and the tabs both switch to it, so a long list of desks no longer scrolls. To
  move a desk to another group, drag it onto that group's row. Groups are renamed, sorted
  and reordered from their rows in the Groups section (right-click, or drag).

### Fixed
- **Group marks keep up.** A group's running count and mark in the desk list now change the
  moment one of its desks starts, stops or goes to work. In 0.3.34 they only caught up when
  a desk began or stopped waiting on you.
- **Many running desks no longer crowd the tab row.** Tabs that don't fit go behind a "+N"
  button (amber when one of them needs you); the desk on screen always keeps its tab.
- The Groups section follows **Keep Active Groups on Top**, as the list under it does.

### Added
- Groundwork for a faster terminal (Ghostty's), not yet switched on: `coldfall-holder` can
  be watched without being driven, and `scripts/ghostty-kit.sh` builds the library.

## [0.3.34] - 2026-11-13

A new window layout, after Herdr's: groups, tabs, and panes as cards.

### Added
- **Groups at the top of the desk list.** Each group has a coloured letter, how many of its
  desks are running, and one mark for the whole group ("1 needs you", done, working). Click a
  group to go to the desk you last used in it.
- **Tabs over the terminal.** One tab for each running desk in the current group, with its
  logo, name and state. Click to switch; the × on hover stops the desk (it asks first, as
  Stop Desk does). "+" starts another desk from the group, or a new shell desk.
- **Panes are cards.** Each pane has its own header: the desk, the agent and folder, its
  state, and split right, split down and close. With two or more panes the focused card is
  outlined.
- **Counts on the status bar.** "1 needs you · 2 working · 3 done" before the usage line.
  Click "needs you" to go to the desk that has waited longest.
- **Real logos.** Put `claude.png`, `codex.png` and so on in `~/.config/coldfall/icons/` and
  the desk list, tabs and pane headers show them. Without them, the letter badges stay.

### Changed
- **One state mark everywhere:** an amber "Needs you" pill, a blue ring while working, a green
  dot for an answer you haven't seen, a hollow circle for idle. Desk rows are one line.
- The Active / Not running split, and the needs-you banner above the list, are gone. The
  status bar and the group marks carry the same news.
- The header over the terminal is replaced by the tabs and the pane headers.

## [0.3.33] - 2026-11-13

Safer around your agents, and a desk list that shows what needs you.

### Added
- **Active and Not running.** The desk list now has an Active section at the top: every
  running desk, sorted by what it needs from you (needs you, done, working, idle). Everything
  else sits below under Not running, in its groups, and a group says how many of its desks
  are up in Active. Pinned desks keep the very top. Active re-sorts only while the pointer is
  away from the list, and at most every few seconds, so nothing moves under a click. **Desks ▸
  Show Running Desks on Top** turns it off. It replaces Move Ready Desks to Top.
- **Which agent runs each desk, at a glance:** a small badge beside its name, a letter on the
  vendor's colour (C Claude, X Codex, A Antigravity, G Copilot). A desk can have its own:
  `icon = "⛳️"` in desks.toml. The inbox shows the same badges.

### Changed
- **A compact desk list.** One line per desk (its state, name and how long ago), so a long
  list fits without scrolling; the rest (vendor, state, memory, budget, what's new) is in the
  row's tooltip, and a budget warning or news tints the time. **Desks ▸ Compact Desk List**
  goes back to two lines.
- **One set of words for a desk's state:** needs you (orange: a question for you), done
  (green: finished), working, idle. A finished desk said "answered" in the list and "done"
  everywhere else; now it's "done" throughout. The line at the top of the list tells the two
  apart: "api needs you · 3 done".
- A folded group shows orange when a desk inside needs you, green when one is done.
- The desk list takes as much of the left column as it needs, up to 70%, ahead of the file
  tree (it stopped at 45%).

### Fixed
From an audit of 0.3.32: two independent reviews of the code (Claude and Codex), then a
second Codex pass over the fixes.
- **A desk counts as having an agent only while the agent has the terminal.** A job left
  running in the background, or an agent suspended with ^Z, no longer passes for one.
- **"Needs you" clears only on an answer:** Return, Esc or a choice's number, the turn
  ending, or the agent saying it's working again. Moving through choices with the arrow keys,
  or the screen repainting, no longer clears it.
- **The inbox keeps each desk's draft to itself,** sends to the desk it was written for, and
  ignores a late screen from the desk you just left.
- **Only one holder can ever start for a desk** (a lock held for its whole life), a holder
  ending never waits on a terminal that stopped reading, a big paste waits for room instead
  of being dropped, and a desk renamed while held keeps reporting after Coldfall reopens.
- **The inbox listens only on Tailscale's own tunnel,** not any network that happens to use
  the same address range.
- **A send that times out says what it knows:** never touched (safe to retry), or taken but
  unconfirmed (check before retrying). `ask` waits for a busy desk to finish first, and
  compares against the screen as it was when its message went in.
- **`build-app.sh` stops if the build fails** and swaps the new app in only once it's whole,
  so a failed build or update leaves the installed app as it was.
- Agent mail and fan out, when they give up, stop everything the agent started, not just
  the agent.
- **A send could reach a bare shell.** After a desk's agent exited or crashed, `coldfall-cli
  send`, `ask`, the inbox, Wrap Up and commands run in a desk could type into the shell left
  behind, where text runs as a command. Each now checks the agent is really running under the
  desk first; closing the agent's own pane counts as it being gone.
- **"Needs you" could go stale.** A question asked while Coldfall was closed now shows when a
  held desk comes back; a renamed desk keeps reporting; switching to a desk (which makes it
  redraw) no longer counts as answering; and the terminal's own replies to the agent no
  longer count as you typing. Wrap Up follows the send rules too.
- **A command meant for one desk could land in another** if you switched desks in the second
  before it was typed.
- **The holder could stall** on a big paste while the agent printed a lot; both sides now
  queue instead of waiting. Two holders can no longer start for one desk, a holder only ever
  removes its own socket, a desk renamed while held stays reachable, and ending a held desk
  takes under a second and reports how it ended.
- Timers now keep running while a dialog is open, so `coldfall-cli wait`/`ask` and the inbox
  don't see Coldfall as gone. `ask` times from when its message went in. Two pastes in the
  same second no longer overwrite each other's file. Answers to `coldfall-cli read` are
  readable by your account only. Settings says so when the inbox's port is taken. Stopping
  a desk no longer reads the process table on the main thread.

## [0.3.32] - 2026-11-12

Every desk from your phone, and agents that wait for each other.

### Added
- **An inbox for your phone and other computers.** Settings, General, "Reach every desk from
  your phone or another computer" serves a small page over Tailscale: your desks grouped as
  needs you, done, working and idle; tap one for its live screen and a box to send it a
  message, or keys (1, 2, 3, arrows, Return, Esc) to answer a question it's waiting on. Every
  desk, Codex ones too, from any browser on your tailnet. Scan the QR code in Settings, or
  copy the link.

  It listens only on this Mac's Tailscale address and loopback, never the home network; it
  answers nothing without the secret in the link (kept in `~/.config/coldfall/inbox-token`,
  replaceable with New Link); it checks the Host it was reached by and refuses changes that
  don't come from the page itself; and agent output is only ever shown as text. Off by
  default.
- **Hand a desk work and wait for the answer.** `coldfall-cli wait <desk>` returns when the
  desk's turn ends or it needs you (exit 0 done, 2 needs you, 3 still working after
  `--timeout`, default ten minutes). `coldfall-cli ask <desk> "message"` sends it, waits, and
  prints just what the desk added: its reply, without the agent's input box. An agent that
  doesn't report for itself counts as done once its output has been quiet for ten seconds,
  and `wait` says that was a guess.

## [0.3.31] - 2026-11-12

Everything from the keyboard, and a look without switching.

### Added
- **Your own shortcuts.** Settings, General, Edit Shortcuts opens `keys.json`: a command's name
  (as ⌘⇧P shows it) to a shortcut like "cmd+shift+k", or "none" to take one away. Coldfall
  applies it the next time it comes to the front; a key you give a command is taken from the
  one that had it, and anything it can't use is listed in Settings in orange.
- **The meter says when you'd run out.** If, at the rate so far, a vendor's weekly quota runs
  out before it resets, the usage strip says when: "claude: at this pace you run out Fri 6 pm,
  47h before the week resets." Quiet when you're on pace, and early in the week, when one busy
  morning would skew it.
- **Peek at a desk without leaving the one you're on.** Option-click a running desk in the
  rail, or right-click it and choose Peek: its screen opens over the current desk and keeps
  up as it works. Return goes to it, Escape closes the look. Read only, so nothing you type
  lands in the wrong desk. Peeking at an answer counts as reading it; a question it's
  waiting on stays orange until you answer.
- **Run any command from the keyboard.** ⌘⇧P, or `>` in quick open, lists every menu command
  with its shortcut, and the desk on screen's own actions (stop, rename, pin, hide…) first.
  Type a few letters and press Return. Commands come from the menus themselves, so the list is
  always complete and never offers what the menus wouldn't.
- **Agents that speak OSC 7501 report to Coldfall without a hook.** The Program Status
  Protocol (also read by Herdr) lets a program say it's blocked, errored or done in one escape
  sequence. Coldfall treats blocked and error as "needs you" and done as finished, exactly as
  the done hook does, so any agent that adopts it turns orange or green on its own word.

## [0.3.30] - 2026-11-12

Know which desk needs you, and reach it from anywhere.

### Added
- **Read a desk and send it work from outside the app.** `coldfall-cli read <desk>` prints a
  desk's screen as text, scrollback included (`--lines N`). `coldfall-cli send <desk> "message"`
  types it into the desk's agent and presses Enter, as if typed there. A send waits while
  someone is partway through typing into that desk (up to a minute after their last key), and
  is refused on a desk stopped on a question, so it can never answer a permission prompt, or
  on a plain shell, where it would run as a command. With these, an agent driven from a phone
  can check on any desk and hand it work, Codex desks included.
- **"Needs you" is its own state.** A desk whose agent stopped on a question (a permission, a
  choice) shows orange with ◉ and "needs you", sits first in the needs-you line, and stays that
  way until you answer it, not just look. A finished desk is still green. Needs the done hook.
- **Notifications.** When a desk you aren't looking at needs you or finishes, a notification
  if Coldfall is in the background (click it to go there), a sound if it's in front. Only on
  the agent's own word, never on a guess from output, and nothing from the conversation is
  shown. Settings, Agents, "Tell me when a desk needs me or finishes".

### Changed
- A working desk shows a still blue dot instead of a spinner. A rail of spinners pulled the
  eye away from the one desk that needed you, and redrew the rail several times a second.

## [0.3.29] - 2026-11-12

Desks that outlive a quit.

### Added
- **Desks can keep running when Coldfall quits.** Turn on "Keep desks running when Coldfall
  quits" in Settings, Desks, or set `keep_running = true` on one desk in desks.toml. A held
  desk's agent carries on while Coldfall is closed, updating or crashed, and Coldfall picks it
  back up when it opens, with its screen as it was. A small `coldfall-holder` process keeps
  each one; what it keeps for the screen stays in memory and is never written to disk. Off
  by default. `coldfall-cli holders` lists them, and `coldfall-cli holders end <desk>` ends one.
- **Quitting asks about held desks.** Keep them running (the default) or end them, with what
  they cost in memory, about 400 to 600 MB per agent. An update relaunch keeps them without asking.
- **After a restart of the Mac, Coldfall offers the desks back.** The launch screen names the
  desks that were running when Coldfall last closed and starts them all with one button, each
  picking up its conversation.

### Changed
- Settings headings keep "Coldfall" and "Project Coldfall" capitalized.

## [0.3.28] - 2026-11-09

The done hook stays put.

### Fixed
- Running the test suite deleted the real done hook (`~/.config/coldfall/done-hook.sh`), so agents
  stopped reporting when they finished and every Claude turn ended with "Stop hook error … exit 127".
  Uninstalling now deletes only the hook in the folder it was given, and the tests never touch the real
  config or data folders. If you ran the tests since 0.3.24, turn the done hook on again in Settings, Agents.

## [0.3.27] - 2026-11-08

Start a desk from your phone.

### Added
- Open a desk from your phone. An agent you are driving remotely (Claude's
  Remote Control, or SSH) can run `coldfall-cli open <desk>`, and the desk
  starts in Coldfall the way a click starts it: in the list, with its own
  settings, picking up its last conversation. It starts in the background
  unless you add `--show`, and it answers with one line saying whether it
  worked. `coldfall-cli running` lists which desks are going and which have an
  answer waiting. Only desks already in your list can be opened, and hidden
  ones stay closed.

## [0.3.26] - 2026-10-30

A first launch that fits the Mac and speaks plainly.

### Changed
- New setups follow the Mac's light or dark setting. Existing setups keep what
  they have; Settings, Appearance changes it.
- The Welcome window is written for people who don't live in a terminal.

## [0.3.25] - 2026-10-30

A calmer look, and timers that stop crying wolf.

### Changed
- A calmer desk list: labels as you typed them rather than in capitals, larger
  desk names, more room between rows, softer corners, and warmer neutral colors
  for the default theme's chrome. The terminal's colors are unchanged.
- The same calm everywhere else: Settings, Welcome and Usage headings in larger
  sentence case instead of tiny capitals, soft dividers between panes in place
  of a hard line, and easier type in the terminal header and the reader's title.

### Fixed
- A desk with a timer in its conversation turned green every time the timer
  ran, all day, with nothing to say to you. With agents reporting when they're
  done, a finished turn now turns a desk green only if you sent that desk
  something since you last read it. An agent asking for you always does.

## [0.3.24] - 2026-10-16

Green on the agent's word, not a guess.

### Added
- **Agents can say when they're done.** Settings, **Let agents say when
  they're done**, adds a small hook to Claude Code (and Codex, if it's set
  up) that notes when a desk's agent finishes or asks you something. A desk
  that reports turns green on the agent's word instead of a guess from its
  output, so repaints, notices and status lines can't fake it. Claude Code's
  one-minute "waiting for your input" reminder doesn't count. The hook writes
  one line to a file on this Mac and sends nothing. Click again to remove it,
  and Remove Files takes it out too. Codex asks you to trust a new hook once:
  run /hooks in a Codex desk. `coldfall-cli hooks install` does the same.

## [0.3.23] - 2026-10-16

Green only for lines that are actually new.

### Fixed
- Desks you had read could still turn green after sitting idle for a while.
  A notice appearing under the input box (Claude Code's "update installed",
  for one) pushed every row up by one, and a row-by-row comparison read that
  as a whole new screen. A desk now turns green only when a line appears that
  wasn't on its screen before, anywhere, with numbers ignored, so moved text
  and ticking timers don't count.

## [0.3.22] - 2026-10-09

Green means something new, and "new" says where to look.

### Fixed
- A desk you had read could turn green again later with nothing new on it.
  Reading a long answer means scrolling up, and the screen Coldfall noted when
  you left was that page of history, so the next quiet repaint at the bottom
  looked like news. It now compares the live screen, wherever you scrolled.
- The "2 new" on a desk was orange, the colour of Stop Desk in the menu, and
  nothing said what to click. It's blue now, hovering it says what it means,
  and the right-click menu opens with **See What's New on This Desk**, which
  shows what was added and clears it.

## [0.3.21] - 2026-10-01

The desk in front of you says what it is doing.

### Fixed
- The desk you were looking at always said "idle", even while its agent was
  answering in front of you. It now says "working" while output arrives and
  "idle" once it stops. Typing doesn't count: the echo of your own keystrokes
  isn't the agent working. It still never turns green, since you can see it.

## [0.3.20] - 2026-10-01

Finished desks come to you, and the ones you live in stay on top.

### Added
- **Ready desks move to the top.** A desk that is waiting on you already
  turned green and was named in the "needs you" line; now its row rises to
  the top of the rail too, right under that line, and goes back to its place
  once you've looked at it. Rows only move while the pointer is away from the
  rail, so nothing shifts under a click. Right-click the rail, or use the
  View menu, to turn **Move Ready Desks to Top** off.
- **Pin a desk to the top.** Right-click a desk, **Pin to Top**. Pinned desks
  sit above everything else in the rail, in your order, whatever group they
  belong to, and cmd-1..9 count from them. Saved in desks.toml as
  `pinned = true`.

## [0.3.19] - 2026-09-30

A helper for writing a clearer prompt, built by the codex desk.

### Added
- Write a prompt: a local helper in the terminal header and Edit menu. Describe
  the outcome, context, boundaries, and what a good result looks like; build an
  editable draft and copy it into any agent. No model calls, automatic sending,
  or reading desk content. Drafts stay in memory while the app is open.

## [0.3.18] - 2026-09-25

A review of the whole app by Fable 5.1, and what it found. Subagents are
counted in the week's usage, the reopen question quotes dollars, several
crash shapes are gone, the update server turns away floods, and the app
builds from source on the macOS 27 Command Line Tools.

### Changed (building from source)
- The terminal library, SwiftTerm, now comes from a fork pinned to one
  commit: version 1.20.0 plus one line that stops its Metal shader being
  compiled as a package resource. Swift 6.4's package manager (the macOS 27
  Command Line Tools) hands that shader to the Metal compiler, which the
  Command Line Tools don't include, so a source build failed with "unable
  to spawn process metal". Nothing in the app changes: the Metal renderer
  is never turned on, and the library loads the shader at run time anyway.

### Changed (update server)
- The update-check server turns away more than 20 requests a minute from
  one address (a real install checks once a day), keeps its daily estimates
  for 45 days instead of forever, accepts only version strings shaped like a
  release tag, and caps the stats page's per-version breakdown so a flood
  of made-up versions can't run up the bill or lock the page. The stats key
  may be sent in a header instead of the address.
- The CI guard that keeps the app from spending tokens on its own now
  catches any call of a runtime's argv or a `-p` literal, not one spelling.

### Fixed (stability)
- The file watcher that opens what an agent just wrote touched one set of
  paths from two threads at once, the same shape as the earlier usage-scan
  crash. It now does all of that on one queue.
- Remove, Rename, Hide and MCP Servers acted on a desk's position in the
  list as it was before their dialog opened; if desks.toml was reloaded
  while the dialog was up, they could act on the wrong desk or crash. They
  find the desk again by name afterwards.
- Editing desks.toml in an editor that autosaves could kill a running agent
  the moment a half-typed `[desk.]` header was saved. A desk missing from
  the file now gets five seconds to come back before its session is ended.
- The Start screen tracked its desk by position, so after a reorder Return
  could start a different desk than the one named. It tracks by name.
- Stop Desk read the whole conversation history on the main thread before
  its dialog appeared, a visible freeze on a long-lived folder. Off-main now.
- A desk removed while its "pick up or start clean" question was being
  prepared could start an orphan process nobody tracked. It no longer starts.
- If the agent pane exited and a shell pane remained, Wrap Up and "run this
  in the desk" would type into the shell. Both now say the agent has exited.
- Switching desks re-read every transcript to redraw one line of the meter
  strip; it redraws from the last reading instead.
- Hiding the desk on screen leaves you on a desk that is still in the list.

### Fixed (usage numbers and advice)
- **Subagents were not counted.** Claude Code keeps a subagent's transcript
  under its session's folder, and the scans stopped at the top level, so
  every token a subagent spent was missing from the week (241 such files on
  one Mac). They are counted now, under the desk that ran them.
- **"Coming back after a break" over-counted.** It flagged any big cache
  write, so a new conversation's first turn, a compaction and a big file
  read mid-flow all counted as rebuilds after a break. A rebuild is now a
  big write an hour or more after the previous turn of the same
  conversation, which is when Claude Code's cache has actually lapsed.
- **"Twice the usual price" was wrong by a factor of ten or more.** A
  rebuild is twice the *fresh* price, but a warm turn is a cache read at a
  twentieth of it, so picking up a big conversation after a break costs 20
  to 40 times a warm turn. The reopen question now says the dollars for
  that conversation ("about $4.80; once warm, about $0.12"), and the usage
  window's heading says the same.
- The cache note counted context written to cache as cached, and could
  call a write-heavy week "the cheap way to work". Writes count as
  uncached now, which they are.
- "LAST 14 DAYS" only ever held this week; it says "EACH DAY THIS WEEK".
- The usage window rescans when the week has rolled over or its numbers
  are older than two minutes, instead of showing last week under a new
  date. Budgets shown there are re-read each time.
- MCP server counts in the advice are matched by the title a desk's
  conversation carries, so a desk whose conversation is named differently
  is no longer missed.
- The Sonnet comparison is labelled an estimate wherever it appears.
- Copilot's premium-request month starts at midnight UTC, as GitHub's does.
- A budget's spent figure rounds down, so "$50 of $50" only appears when
  it really is over. Percentages round the same way everywhere, and the
  CLI omits a dollar figure for vendors Coldfall doesn't price rather than
  printing 0.

### Security
- The Claude limits recorder wrote a per-desk file named after whatever
  Claude reported as the session name, unsanitised, so a name containing
  `../` could overwrite a file outside its folder. Names are now reduced to
  plain characters and can never be a path.
- The recorder embedded your own statusline command in double quotes with
  no escaping, so a command containing `"$@"`, `$` or backticks broke the
  whole script. It is now single-quoted, and read back the same way.
- A saved release link is checked again before it is opened, so an edited
  update.json can't send the browser anywhere but this project's GitHub.
- A Codex profile name and an SSH host alias offered as desks were put into
  the desk's command unquoted; both are quoted now, as everything else is.
- `Shell.quote` now quotes a word starting with `=`, which zsh expands.

### Fixed
- A budget that was an absurd or non-finite number (`1e300`, `inf`) crashed
  the app on every save. Budgets are now checked on the way in and written
  safely, and Settings refuses the same values.
- Turning on live limits a second time silently dropped your own statusline;
  now it keeps wrapping the one the first install wrapped.
- Resume matched a desk's title anywhere in a transcript's text, so a
  session that merely quoted such a record could be resumed as that desk.
  It now matches the record itself.
- The reopen question could silently never appear for a big transcript
  whose tail happened to be cut inside a multi-byte character, and for one
  whose last turn sat behind a huge tool result. Both are read correctly.
- A desk renamed by editing desks.toml now keeps its conversation, as a
  rename made in the app already did, and a desk whose conversation goes by
  another title (`conversation`) resumes, starts and is measured by it.
- desks.toml: an array split across lines was read as empty and then
  written away; `\u00e9` escapes read as letters; a CRLF file mangled every
  name; a desk's `agent` was dropped on save when it also had a command; a
  `[desk."a.b"]` table this version can't read was deleted on save. All
  fixed, all round-tripped in tests.
- A model id the price table hasn't met is priced by its family (a new
  Haiku as Haiku), not as Opus.
- The login-shell PATH lookup is locked; a background read during the one
  write at launch was a data race.

### Fixed
- **Programs run in a desk can use the microphone and camera.** The app
  didn't declare either, so macOS killed any program in a desk the moment
  it opened the mic (exit 134), before asking permission: a meeting
  recorder worked in Terminal and died in a desk. The first time now,
  macOS asks, once, for Project Coldfall.

## [0.3.17] - 2026-09-24

A weekly budget per desk.

### Added
- **A weekly budget per desk.** `budget = 50` in desks.toml, or the budget
  field in Settings, gives a Claude desk a dollar budget for the week. Its
  row turns orange at 80% and red when it's over ("$62/$50"), the usage
  window's This week tab shows each desk against its budget, and the Start
  screen says so before an over-budget desk starts. Nothing is stopped or
  paused: it's there so you notice. Claude only, since Coldfall prices only
  Claude.

## [0.3.16] - 2026-09-23

A Start button for any desk that isn't running.

### Changed
- **Picking a desk that isn't running shows its Start button first**, the
  same screen as at launch, so a stray click starts nothing. Return starts
  it. Running desks still switch at once, and a desk you stop goes straight
  back to its Start screen. Settings ▸ Desks turns it off for one-click
  starts.

## [0.3.15] - 2026-09-23

Deleting takes a deliberate click, and Remove Files moves away from Quit.

### Changed
- **Remove Project Coldfall's Files moved to Settings ▸ General.** It sat
  just above Quit in the app menu, one slip away. Its dialog, and Remove
  Desk's when there's no name to type, now take Return as Cancel: deleting
  needs a deliberate click. The Updates tab is now General.

## [0.3.14] - 2026-09-23

Opening the app starts nothing, and shells get desks of their own.

### Changed
- **Opening the app starts nothing.** It opens on the desk you were last
  on, shown but not started, with a Start button (or Return). Before, it
  started the default desk every launch, using its memory and, for a big
  conversation, asking about it before you'd done anything.

### Added
- **Desks ▸ New Shell Desk** (⌘N): a plain shell as its own desk, named
  shell-2, shell-3 and so on, in the folder of the desk you're on.

### Fixed
- The agent update notice never appeared: reading a CLI's version could
  wait forever when that CLI left something running in the background, so
  the check never finished. Output now goes to a file, which a lingering
  process can't hold open.

## [0.3.13] - 2026-09-23

Where your tokens go, and what to change; picking up where you left off, or starting clean.

### Fixed
- **Claude prices were out of date.** Opus 5.5 (released 2026-09-22) wasn't
  priced at all, cache reads were assumed to cost a tenth of input on every
  model (Opus 5.5 is a twentieth, Fable 5.1 a fortieth), and cache writes
  were priced as the five-minute cache when Claude Code writes the one-hour
  one at twice the input price. Dollar figures now come from one dated table
  and from the cache split Claude Code records, and the text that said the
  cache lasts "a few minutes" says an hour.

### Added
- **What's filling the conversations**, in Where it went: how much tool
  output each desk took in this week (command output, file reads, browser
  automation, images), how many jobs it handed to a subagent, and advice
  when one stands out. A subagent does the messy reading in its own
  conversation and hands back only the answer, which is the habit that
  keeps a big desk small. Screenshots get their own note: each is sent
  again on every later turn.
- **When an agent updates, the rail says so**: "Claude Code updated to
  2.1.280", with What's New opening the vendor's own release notes. Checked
  once a launch by asking each CLI its version, locally, with no tokens.
- **Pick up where you left off, or start clean.** A desk still picks up its
  conversation when you open it; that's the default and nothing about it
  changed. When a big one (150K tokens or more) has sat for an hour, opening
  the desk offers a clean start too, because the first message would
  re-send all of it at a little over the usual price. A clean start keeps
  the desk's name, folder, instructions and memory files, and nothing is
  deleted: `/resume` in the desk reopens the old conversation.
- **Wrap Up & Stop.** Stopping a desk with a big conversation says first
  that it will pick up where you left off, then offers Wrap Up for when
  you're done with a topic: the desk saves what's worth keeping to its own
  notes, you check it, and next time a clean start is the suggestion.
- The question can be switched off for every desk (Settings, Desks) or one
  desk (right-click it, Ask Before Reopening a Big Conversation, or "Don't
  ask" in the dialog itself).
- Where it went counts **cache rebuilds**: each time a big conversation
  was picked up after its cache lapsed, and what that cost.
- Two desk settings for desks that run their own script: `fresh`, the
  command that starts it with a new conversation (`desk money new`), and
  `conversation`, the title its conversation carries when it isn't the
  desk's name.
- The usage window has three tabs: **Plans** (what's left of each), **This
  week** (where it went, by vendor, desk and day) and **Where it went** (why:
  cache reuse, model mix, the smallest turn each desk sent, and what to
  change). It was one long column, and the answer you wanted was three
  scrolls away. The scan runs once; switching tabs re-reads nothing.
- **Where it went**, a tab in the usage window (⇧⌘U). How much of your
  input was read from cache rather than sent fresh, the model mix with what
  the same tokens would have cost on a smaller model, the smallest turn each
  desk sent all week, and a short list of what to change, written from your
  own numbers. Anything projected rather than measured says so.
- `coldfall-cli tokenomics [--days N]` prints the same reading as JSON, and
  `--usage` snapshots the usage window.

## [0.3.12] - 2026-09-22

Stop Desk and Remove Desk no longer look alike.

### Changed
- A desk's right-click menu tells Stop and Remove apart. Stop Desk has an
  orange stop icon, Remove Desk a red trash icon and red text, each with a
  line saying what it does, and Remove sits alone at the bottom behind its
  own separator. Two plain lines of text, one above the other, made the
  destructive one the easy one to hit.

## [0.3.11] - 2026-09-22

One look at what's new answers for every desk.

### Fixed
- Seeing what's new on one desk now answers for every desk of that runtime.
  Your own skills, hooks and plugins apply to all of them, so one plugin
  update lit up "1 new" on every Claude desk and had to be dismissed desk
  by desk. Anything from a desk's own folder is still that desk's own.

## [0.3.10] - 2026-09-22

A new app icon.

### Changed
- A new app icon: the two pipes from the `coldfa||` wordmark, in the same
  green as the app, offset so they read as pipes rather than as a pause
  button. The old one was a dark grey square that disappeared into a dark
  Dock and said nothing about the app.

## [0.3.9] - 2026-09-22

A crash fix, and a way out.

### Added
- **Project Coldfall ▸ Remove Project Coldfall's Files…** It lists the two
  folders Coldfall owns and what's in them, with sizes, puts `statusLine`
  in each Claude account's settings.json back the way it was, and deletes
  the folders. It says up front that your agents aren't touched, because
  they aren't: Coldfall launches the vendors' CLIs and nothing it does is
  load-bearing for them.

### Fixed
- The app could crash while the usage meter refreshed. The strip at the
  bottom and the usage panel each scan on their own thread, and two scans
  running at once wrote to the same list. Each scan now keeps its own, and
  the usage cache is locked.

## [0.3.8] - 2026-09-22

More than one Claude plan, a guide, and green checks that mean something.

### Added
- **More than one Claude plan.** `account = "~/.claude-second"` on a desk,
  or the account field in Settings, runs that desk's Claude on a second
  login (Claude Code's `CLAUDE_CONFIG_DIR`). The rail and the meter name it
  `claude-second`, with its own usage and, once its recorder is on, its own
  weekly limit, so you can see which plan has room. It resumes from that
  account's conversations, What This Desk Has reads that account's
  settings, and agent mail and fan out can send a question to it.
- A guide at https://project-coldfall.vercel.app/guide: what the app is
  for, your first ten minutes, setting up desks, a normal day, agent mail,
  usage, and every shortcut.

### Fixed
- A desk you had just read no longer turns green again on its own. Agents
  repaint their screen when you leave them, and when their status line
  ticks, and that output counted as news. Now a desk only shows as needing
  you if what it shows, above its input box and status line, has changed
  since you left it.

## [0.3.7] - 2026-09-21

Antigravity replaces Gemini CLI, and the needs-you line can be cleared.

### Added
- **Antigravity** as a runtime (`runtime = "antigravity"`, the `agy`
  command). Google moved Google AI Pro and Ultra subscribers from Gemini CLI
  to the Antigravity CLI in June 2026, so on those plans this is the Google
  desk to use. Welcome and Settings show how to install it, the rail offers
  a desk once it's installed, and What This Desk Has lists its MCP servers
  and skills.
- The "needs you" line at the top of the rail has an ×, and Clear on its
  right-click menu, to mark every waiting desk as seen without opening them.

### Removed
- Gemini CLI. Google no longer lets personal accounts sign in to it, so
  Coldfall stops offering, installing or making desks for it. Antigravity
  takes its place.

### Fixed
- A desk removed from desks.toml kept its terminal running out of sight,
  and could keep a "needs you" line up for a desk that no longer existed.
  Its processes now end with it.
- Removing an agent's last desk no longer brings back the offer to add one.

## [0.3.6] - 2026-09-21

New agents get offered a desk, and Copilot shows up in the meter.

### Added
- Copilot usage in the meter: tokens this week, read from the records Copilot
  CLI keeps on your Mac, and premium requests this month, which is what a
  Copilot plan counts. Click the meter for the breakdown. Your plan's
  allowance lives on github.com, so there's no percentage for Copilot yet.
- An agent installed after the first run gets offered a desk. When Coldfall
  finds Copilot, Gemini or another supported CLI with no desk (at launch,
  when you switch back to the app, and every minute), the top of the rail
  says "Copilot is installed. Give it a desk?" with Add desk and Not now.
- Coldfall finds CLIs wherever your login shell would, including ones
  installed with npm under nvm, not just in a few fixed folders.

## [0.3.5] - 2026-09-21

Security fixes, live desks.toml, and a rail that can keep busy groups on top.

### Added
- **Keep Active Groups on Top**, from the rail's right-click menu or the
  Desks menu, off by default. Groups with a desk that needs you rise first,
  then the most recently used; idle ones sink. It only reorders when the
  pointer isn't over the rail, at most every 30 seconds, so nothing moves
  under a click. Your own order is kept underneath: cmd-1 to cmd-9 stay on
  it, and turning this off puts the rail back.
- Coldfall picks up changes to desks.toml while it runs, from an agent, a
  script or an editor. A desk renamed on disk keeps its running terminal
  under the new name.
- A landing page, at https://project-coldfall.vercel.app. Its source is
  `server/public/`; the pictures are of made-up desks.

### Security
- Values read from desks.toml (a desk's name, agent, model, runtime and
  folder) are quoted before they reach the shell. A desk or folder name
  containing `;`, `$( )` or a quote could otherwise have run as a command.
- Saving from the app no longer overwrites an edit someone else made to
  desks.toml. If the file changed first, the app loads that version and asks
  you to redo your change; Settings won't save over a file edited while it
  was open.
- Stop Desk's final kill checks each process is still the one it saw, by its
  start time, so a process that reused an ended one's number is never hit.
- The update check only opens release links on this project's GitHub page.

### Fixed
- Tree on Top (cmd-T) moves the desks and the file tree on screen again. It
  changed the setting but left both where they were until a relaunch.
- Starting a desk no longer reads session files on the main thread, so the
  app can't stall on a Mac with a long history. Config files too big to be
  real are skipped instead of read.
- A desk's memory figure no longer lingers after it stops or restarts.
- Agent mail's read-only and scope notes always name the vendor you picked.

## [0.3.4] - 2026-09-21

Hide a desk without losing it.

### Added
- **Hide Desk** on a desk's right-click menu takes it out of the rail and
  cmd-1 to cmd-9 but keeps it, with its settings and conversation, as
  `hidden = true` in desks.toml. A running desk is offered a stop too. The
  bottom of the rail says how many are hidden; click to list them, and
  right-click one to unhide it. Quick open (cmd-P) still finds them.

## [0.3.3] - 2026-09-21

A bug fix: desks stop asking for you after you've already looked.

### Fixed
- A desk no longer turns green again right after you've looked at it and
  moved on. Leaving a desk takes its keyboard focus, the terminal tells the
  agent, and the agent redraws; that redraw counted as new output. Output in
  the moment after leaving is now ignored, and a real answer still shows.

## [0.3.2] - 2026-09-21

See what each desk has, and know when it changes.

### Added
- A first run with no agent CLI installed is no longer a dead end. The
  welcome screen shows how to install Claude Code, Codex, Gemini CLI, Copilot
  CLI and Ollama, with what each needs, a copy button and its docs, and
  **Check again** finds a new install without a relaunch. Settings ▸ Agents
  shows the same line next to any vendor that isn't installed.
- **What This Desk Has…** on a desk's right-click menu lists its MCP servers
  (and which run on this Mac), hooks (commands that run by themselves),
  skills and plugins, read from Claude, Codex or Gemini's own files.
- **MCP Servers…** works for Codex desks too, switching off servers from
  `~/.codex/config.toml` for that desk alone.
- **What changed.** What This Desk Has now marks what's new, updated or gone
  since you last looked, and names each change at the top. When a desk starts
  with something new (a plugin that added a hook, say), its row in the rail
  says "2 new" until you look. The first look is a baseline, not a list of
  everything. `coldfall-cli inventory <desk>` prints the same as JSON.

### Fixed
- The README's install commands work when pasted: the app's path has a
  space and wasn't quoted. It also says how to get past the macOS warning on
  macOS 15 and later, where right-click ▸ Open no longer does.
- Renaming a desk Coldfall starts itself no longer loses its conversation. It
  remembers the conversation's id (as `session` in desks.toml) and reopens it
  under the new name.

## [0.3.1] - 2026-09-21

Trim what each desk runs, and a cleaner Settings.

### Added
- A daily update check. The title strip shows a link when a newer release is
  out. The check sends a random ID made on your Mac, the app version and the
  macOS version, which is also how installs are counted; nothing else, and
  the server keeps no list of IDs. On by default; a new install sees it on
  the Welcome screen, and it can be turned off in Settings. See "What
  Coldfall sends" in the README.

- **MCP Servers…** on a desk's right-click menu switches off MCP servers from
  its folder's `.mcp.json` for that desk alone, so a desk that never reads
  mail doesn't start a mail server. claude.ai connectors and plugins are left
  alone. Saved as `mcp_off` in desks.toml. Claude desks for now.

### Changed
- Settings is split into Desks, Appearance, Agents and Updates tabs, sized to
  fit the screen. It used to be one column taller than a laptop display.

### Fixed
- Editing a desk in Settings no longer drops what the form doesn't show: its
  agent, model and whether it's the default.
- Double-clicking the title strip a second time now puts the window back.
- Release downloads no longer contain the path of the folder they were built
  in. The zips for 0.1.0, 0.2.0 and 0.3.0 have been replaced with cleaned
  copies of the same builds. New releases are made with
  `scripts/release-zip.sh`, which checks for this before it finishes.

## [0.3.0] - 2026-09-21

Desks pick up where they left off, and the rail shows which ones are waiting
on you.

### Added
- Rename a desk: right-click it, **Rename Desk…**. A running desk keeps running
  under the new name.
- Drag desks in the rail to reorder them. Dropping a desk among another group's
  desks, or on a group's header, moves it into that group. cmd-1 to cmd-9
  follow the new order.
- **Needs you**: when desks are waiting on you, a line at the top of the rail
  names them, oldest wait first. Click it, or press cmd-0, to go to the one
  that has waited longest. A folded group shows how many of its desks are
  waiting, so folding one no longer hides them.
- Desks Coldfall starts itself now pick up where they left off. A Claude desk
  reopens its own conversation (the newest one carrying the desk's name), and
  a Codex desk reopens its latest conversation in the desk's folder. Desks
  with their own command still run exactly that command.
- Drag a group's header to move the whole group, desks and all.
- **Sort Desks A to Z**: right-click a group header or empty space in the rail,
  or use the Desks menu. Groups sort by name, and so do the desks in each
  group. Ungrouped desks stay on top. It sorts once, so you can still drag
  afterwards.
- **Stop Desk…** on right-click ends a desk's processes and frees their memory.
  Click the desk to start it again.
- Each running desk shows its memory in the rail, measured across its whole
  process tree (the agent and every MCP server it started).
- Quick open (cmd-P): one box that finds a desk or a file.
- Layout toggles in the title strip for the rail, the reader and the usage
  meter (cmd-B, opt-cmd-B, cmd-J).
- A header over the terminal with split and close buttons.
- The reader sits in the window as a pane by default, and can be popped out.
- Markdown renders in the reader instead of showing its source.
- A real title strip: nothing sits under the window buttons, and
  double-clicking it fills the screen without hiding the dock.
- VS Code style explorer (EXPLORER title, the folder's name, file icons) and
  Cursor style desk rows (status, name, time since last output).

### Fixed
- Hiding the reader no longer leaves a dark line down the terminal where its
  edge used to be.
- A stopped desk no longer leaves a `<defunct>` process behind until the app
  quits.
- **Stop Desk…** now ends the agent too. It used to end only the shell, which
  ignores that signal, so the agent kept running unseen, still holding its
  memory, and starting the desk again opened the same conversation a second
  time. Closing a split pane had the same problem.
- The stop and update dialogs said every desk starts fresh. They now say what
  actually comes back.
- cmd-1 to cmd-9 now match the rail even when a group's desks are scattered
  through `desks.toml`.
- Saving `desks.toml` no longer stacks another copy of the header comment at
  the top each time.
- The rail no longer repaints every row three times a second while nothing
  changes.
- Saving desks.toml dropped a desk's `model`, so any edit from the rail would
  have reset an ollama or grok desk to its default model.
- macOS stops asking for Documents access after every rebuild, when the local
  signing certificate is installed (`scripts/make-signing-cert.sh`).
- Every window follows the theme, not just the main two.

## [0.2.0] - 2026-09-20

Renamed from Deskwork to **Project Coldfall**. Existing config and history move
over on first launch, with a link left at the old paths.

### Added
- Fan-out: one question across many directories, priced before it runs, with a
  progress view and a cancel that stops the work.
- VS Code Dark Modern and Light Modern themes, dark by default.
- The rail shows when a desk has answered while you were looking elsewhere,
  and the dock badge counts them.
- Drag a file onto a desk, or paste a screenshot into one.
- An Edit menu, so copy and paste work everywhere.
- A contributor licence agreement (CLA.md).

### Fixed
- A fan-out slice could deadlock on a full pipe and sit forever.
- Codex vanished from the usage meter when its newest log had no limits in it.
- Scanning usage took 12 seconds; it is now cached.
- Theme settings in desks.toml were ignored, and saving desks wiped them.
- CI had been red for four commits unnoticed; the privacy guard now passes.

## [0.1.0] - 2026-09-20

First build.

### Added
- Desks: persistent agents in named terminals, started on first click, grouped
  and collapsible, configured in `~/.config/coldfall/desks.toml`.
- Runtimes for Claude, Codex, Gemini, Copilot, Grok, Ollama and plain shells.
- SSH hosts from `~/.ssh/config` offered as desks.
- A folder tree and a reader with tabs and syntax highlighting; files an agent
  writes open themselves.
- A cross-vendor usage meter with live plan limits.
- A mailbox bridge for handing work between vendors.
- Splits: up to four terminals per desk.
- Update from inside the app.
- Tests, CI, and guards that keep the core free of UI code and keep private
  paths out of the repo.

[Unreleased]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.39...HEAD
[0.3.39]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.38...v0.3.39
[0.3.38]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.37...v0.3.38
[0.3.37]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.36...v0.3.37
[0.3.36]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.35...v0.3.36
[0.3.35]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.34...v0.3.35
[0.3.34]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.33...v0.3.34
[0.3.33]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.32...v0.3.33
[0.3.32]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.31...v0.3.32
[0.3.31]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.30...v0.3.31
[0.3.30]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.29...v0.3.30
[0.3.29]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.28...v0.3.29
[0.3.28]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.27...v0.3.28
[0.3.27]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.26...v0.3.27
[0.3.26]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.25...v0.3.26
[0.3.25]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.24...v0.3.25
[0.3.24]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.23...v0.3.24
[0.3.23]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.22...v0.3.23
[0.3.22]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.21...v0.3.22
[0.3.21]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.20...v0.3.21
[0.3.20]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.19...v0.3.20
[0.3.19]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.18...v0.3.19
[0.3.18]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.17...v0.3.18
[0.3.17]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.16...v0.3.17
[0.3.16]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.15...v0.3.16
[0.3.15]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.14...v0.3.15
[0.3.14]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.13...v0.3.14
[0.3.13]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.12...v0.3.13
[0.3.12]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.11...v0.3.12
[0.3.11]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.10...v0.3.11
[0.3.10]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/anthonyproctor/project-coldfall/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/anthonyproctor/project-coldfall/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/anthonyproctor/project-coldfall/releases/tag/v0.1.0
