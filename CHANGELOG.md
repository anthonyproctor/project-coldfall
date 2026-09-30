# Changelog

What changed in each release, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Anything under **Unreleased** is on
`main` and arrives in the next release. In the app, **Project Coldfall ▸ What's New**
opens this file.

## [Unreleased]

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

[Unreleased]: https://github.com/anthonyproctor/project-coldfall/compare/v0.3.18...HEAD
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
