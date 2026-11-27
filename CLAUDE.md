# Project Coldfall: notes for coding agents

A macOS app for running persistent AI agents ("desks") side by side across
vendors. Swift and AppKit, built with SwiftPM, terminal from SwiftTerm.

## Layout

- `app/Sources/ColdfallCore`: pure logic. **Foundation only.** CI fails the
  build if it imports AppKit, SwiftUI, UIKit, PDFKit or SwiftTerm. Anything
  with a real way to go wrong (parsing, ranking, ordering, limits) lives here
  so it can be tested.
- `app/Sources/Coldfall`: the app. `main.swift` holds the Controller.
- `app/Sources/ColdfallCLI`: `coldfall-cli`.
- `app/Sources/ColdfallTests`: `coldfall-test`, a plain executable with
  `check` and `eq`. Not XCTest, so it runs on any toolchain.

## Build, test, look

```sh
cd app
swift build -c release
./.build/release/coldfall-test
./.build/release/Coldfall --snapshot /tmp/shot.png            # render the window, start nothing
./.build/release/Coldfall --snapshot /tmp/shot.png --palette hub   # plus quick open
./.build/release/Coldfall --snapshot /tmp/shot.png --palette ">stop" --waiting   # quick open as a command palette
./.build/release/Coldfall --snapshot /tmp/shot.png --desks demo.toml  # made-up desks, not the real ones
./.build/release/Coldfall --snapshot /tmp/shot.png --reader-hidden    # as if the reader were toggled off
./.build/release/Coldfall --snapshot /tmp/shot.png --settings Desks   # plus Settings on a tab, to shot-settings.png
./.build/release/Coldfall --snapshot /tmp/shot.png --inventory hub    # plus a desk's What This Desk Has, to shot-inventory.png
./.build/release/Coldfall --snapshot /tmp/shot.png --welcome none     # plus Welcome as a Mac with no agent CLI sees it
./.build/release/Coldfall --snapshot /tmp/shot.png --show-hidden      # the rail with hidden desks listed
./.build/release/Coldfall --snapshot /tmp/shot.png --live             # the rail with Keep Active Groups on Top
./.build/release/Coldfall --snapshot /tmp/shot.png --desks-on-top --meter-hidden   # for public pictures: no real usage numbers
./.build/release/Coldfall --snapshot /tmp/shot.png --offer copilot    # the rail offering a desk for a new agent
./.build/release/Coldfall --snapshot /tmp/shot.png --waiting          # the launch screen: a desk shown, not started
./.build/release/Coldfall --snapshot /tmp/shot.png --budget-demo      # the rail with desks near and over a made-up budget
./.build/release/Coldfall --snapshot /tmp/shot.png --prompt-helper    # plus the Write a prompt window, to shot-prompt.png
./.build/release/Coldfall --snapshot /tmp/shot.png --pin docs         # the rail with that desk pinned to the top
./.build/release/Coldfall --snapshot /tmp/shot.png --waiting --restore hub,work   # the launch screen offering desks back
./.build/release/Coldfall --snapshot /tmp/shot.png --quit-prompt hub,work  # the quit question, to shot-quit.png
./.build/release/Coldfall --snapshot /tmp/shot.png --blocked api      # the rail with that desk stopped on a question
./.build/release/Coldfall --snapshot /tmp/shot.png --terminal out.txt --peek   # that desk peeked at, to shot-peek.png
./.build/release/Coldfall --snapshot /tmp/shot.png --terminal out.txt --split  # that desk as two pane cards
./.build/release/Coldfall --snapshot /tmp/shot.png --terminal out.txt --beside api   # that desk with another next to it
./.build/release/Coldfall --snapshot /tmp/shot.png --terminal out.txt --beside api,docs,review   # several, as a grid
./.build/release/Coldfall --snapshot /tmp/shot.png --terminal out.txt --feed   # Needs You with that desk's question, to shot-feed.png
./.build/release/Coldfall --snapshot /tmp/shot.png --schedules        # the Schedules window with made-up ones, to shot-schedules.png
./.build/release/Coldfall --snapshot /tmp/shot.png --conversations    # the Conversations window with made-up ones, to shot-conversations.png
./.build/release/Coldfall --snapshot /tmp/shot.png --changes          # the Changes window with a made-up diff, to shot-changes.png
./.build/release/Coldfall --snapshot /tmp/shot.png --asleep docs       # that desk put to sleep (the moon on its row)
./.build/release/Coldfall --snapshot /tmp/shot.png --by-priority      # the Desks section by priority instead of by group
./.build/release/Coldfall --snapshot /tmp/shot.png --all-desks        # the Desks section as every desk by name
./.build/release/Coldfall --snapshot /tmp/shot.png --settings Agents --settings-at "ssh hosts" --tailnet status.json   # a tab scrolled to a heading, with made-up Tailscale machines
./.build/release/Coldfall --snapshot /tmp/shot.png --drip             # Drip in each mood in a stand-in notch, to shot-drip.png (a snapshot never shows the real one)
../scripts/build-app.sh                                        # ~/Applications/Project Coldfall.app
../scripts/release-zip.sh                                      # the zip a GitHub release ships
../scripts/release.sh X.Y.Z "summary"                          # the whole release (see below)
```

`scripts/release.sh X.Y.Z "summary"` is the whole release: the CI checks, the soak test, the release
commit and tag, push and wait for CI, the zip, the GitHub release, checking the download, and deploying
the site. `--dry-run` changes nothing; `--skip-soak` skips the ten-minute soak. It never restarts
Coldfall. Only with the person's go-ahead for that release.

A release zip always comes from `scripts/release-zip.sh`, never a hand-made
zip of the local bundle. The local bundle carries the builder's home path (in
Info.plist and in debug symbols) and a personal signing certificate; the
script strips all of it and refuses to finish if any home path is left.

`--usage [tab]` snapshots the usage window on a tab (Plans, This week,
Where it went), to shot-usage.png.

`coldfall-cli tokenomics` prints where the week's tokens went, the same
reading the usage window shows; `--usage` snapshots that window.

`coldfall-cli reopen [desk]` prints each Claude desk's conversation size, when
it was last used, and whether opening it would ask about starting fresh.

`coldfall-cli versions` prints each agent's version as the update notice reads it;
`--agent-news` snapshots the rail with a made-up update. `versions --read` adds the version a
desk's choices were last read on (see `PromptCheck` in the core), and `--terminal out.txt --feed
--feed-unread` snapshots Needs You with a card saying a version hasn't been read from yet.

`coldfall-cli notify --from <desk> "message"` puts up that desk's notice (see `Notice` in the core): Needs You,
the phone page and a Mac banner, and a phone notification in fixed words. `--terminal out.txt --feed --feed-notice`
snapshots Needs You with a made-up one. Try it only in a throwaway home.

`coldfall-cli attach <desk>` shows a held desk in the terminal it runs in, beside Coldfall's own (see `Holder.Driver`
in the core: the agent draws for whichever terminal typed last; `Ctrl-\` leaves). It needs a real terminal: try it with a short
throwaway `COLDFALL_HOLDER_DIR`, `coldfall-holder attach` and the CLI each in a pty from a script, never against a real desk.

Pull request cards (see `PRWatch` in the core) come from your own `gh` every five minutes while Settings has them on;
`--terminal out.txt --feed --feed-pr` snapshots Needs You with a made-up one.

Shortcuts actions live in `Coldfall/Intents.swift`. Shortcuts finds them through `Metadata.appintents`, which
`scripts/build-app.sh` makes with Xcode's `appintentsmetadataprocessor` from the constants the compiler writes
(`-emit-const-values` in Package.swift); without Xcode the bundle just has none. Logic for them goes in the core.

`coldfall-cli wake <desk> --from <desk> "message"` starts a desk that is off, asks it and puts it back (see
`Wake` in the core). Try it only in a throwaway home with stand-in agents (a desk whose `command` is a small
script that reads a line and prints a reply), never against real desks.

`coldfall-cli menu [desk]` prints a desk's right-click menu as data. A
context menu cannot be captured in an offscreen snapshot, so its order,
wording and tone are checked there and in the core's tests.

`COLDFALL_SNAPSHOT_DEBUG=1` prints measured frames with a snapshot.

`scripts/soak.py` runs the built app for a while in a throwaway home (stand-in desks opened through
`coldfall-cli open`, a fake Claude conversation of about 150MB growing every second) and fails if memory
grows after warm-up, the status file goes 5 seconds without a write, or CPU stays high. Run it (10 minutes
is the default) before a release that touches anything periodic: timers, scans, watchers, the activity tick.
It never touches a running Coldfall.

The Family Connector (a separate app) is read over its socket as agent
`coldfall`; see `Connector` in the core. Never point Coldfall at the real one
to test: run the Connector repo's `connector-fixture` (made-up people) and set
`CONNECTOR_SOCKET` to its socket and `CONNECTOR_TOKEN=fixture-token-coldfall`.
Then `--terminal out.txt --feed --connector` snapshots Needs You with its cards,
`coldfall-test` with `COLDFALL_TEST_CONNECTOR=<socket>` (and
`COLDFALL_TEST_CONNECTOR_PID`) also runs against it, and
`COLDFALL_CONNECTOR_DEBUG=1` makes a live run print each change (counts only).

A snapshot never asks Tailscale which machines exist (their names are private);
`--tailnet file.json` gives it a made-up `tailscale status --json` instead.

For a live picture of several desks, run the built binary in a throwaway home
with stand-in agents and `--beside docs,review` (it presses Start on the launch
screen, then opens those beside the first); `COLDFALL_WINDOW=1480x860` sets the
window's size.

Ghostty's terminal is a second engine beside SwiftTerm, chosen in Settings
(General, Terminal; SwiftTerm is the default). `scripts/ghostty-kit.sh` builds
the library into `app/Vendor/` (needs Zig and Apple's Metal toolchain).
`scripts/build-app.sh` links it whenever the library is there, so release
builds carry it; a plain `swift build` does not unless you say
`COLDFALL_GHOSTTY=1 swift build -c release`, and CI never does. Code for it is
under `#if COLDFALL_GHOSTTY`, not `canImport`. `COLDFALL_TERMINAL=ghostty`
overrides the setting for one run. With the library linked, `./.build/release/Coldfall --ghostty-demo` opens one Ghostty
terminal in a window, with no desks. `--ghostty-held <program>` runs that program
as a held desk drawn by Ghostty and prints its state as it changes (set
`COLDFALL_HOLDER_DIR` to a short throwaway folder first); with
`COLDFALL_GHOSTTY_SELFTEST=1` it answers the program's question and quits.

`--live --tab-groups` snapshots the tab row with two made-up tab groups, one folded (see `TabLayout`
in the core). `./.build/release/Coldfall --tabs-selftest api,docs` (same rules as the grid self-test
below) starts those beside the desk on screen, then moves tabs by drags through the tab bar's own drag
code (to the front, into a group, out of it), printing the row after each step, and quits.

`./.build/release/Coldfall --grid-selftest api,docs` (never with `--snapshot`, and
only in a throwaway home with stand-in agents) starts the desk on screen, opens
those beside it, then goes to one, replaces one, drags one onto another and takes
two off, printing what is on screen after each step, and quits.

Each start and exit of the app is one line in `~/.local/share/coldfall/exit.log`
(a quit and its answer, the last window closing, or a signal and who sent it);
a held desk's end is in `holders/holders.log`. Read these first when someone
says Coldfall "crashed" and there is no crash report.

Held desks (see `Holder` in the core) run through `coldfall-holder`, which
ships beside the app. To try one end to end without touching a running
Coldfall, run the built `Coldfall` binary directly with `HOME` and
`CFFIXED_USER_HOME` pointing at a throwaway folder (short: socket paths must fit
in 104 bytes), set `COLDFALL_UPDATE_URL` to a dead local address so it never
counts as an install, open a desk with `coldfall-cli open`, kill that Coldfall,
and check `coldfall-cli holders` with the same environment. If you are
running inside a held desk yourself, also `unset COLDFALL_HOLDER_DIR`: a held
desk's environment carries the real holders folder, and a throwaway Coldfall
that inherits it shares that folder with the real one.

The inbox (see `Inbox` in the core) can be tried the same way with `"inboxOn":true`
in the throwaway ui.json: curl `http://127.0.0.1:47101/?t=<inbox-token>` (127.0.0.1 has its own port, 47101,
which `tailscale serve` points at; the Tailscale address is on 47100) for the
cookie, then the `/api/*` routes with `X-Coldfall: 1` on POSTs. A Mac can't reach
its own Tailscale address, so the tailnet side is only checkable from another device.
The page is also an app for a phone's Home Screen (`/manifest.webmanifest`, `/sw.js`, `/icon-512.png`)
and takes notification subscriptions (`/api/push/*`; see `WebPush` in the core). A headless Chrome
with a throwaway `--user-data-dir` pointed at `http://localhost:47101/?t=<inbox-token>` runs the
page's script for real (`--dump-dom`, `--screenshot`). Never subscribe a real device or send a
notification from a test: that calls Apple's or Google's service. `COLDFALL_PUSH_DEBUG=1` prints how
each send went (kind, whose service, its answer). `--settings General --settings-at "inbox for your
phone" --inbox-https demo.example.ts.net` snapshots Settings as if Tailscale served the inbox over
HTTPS (add `--inbox-funnel` for the warning); a snapshot never asks Tailscale.

Snapshots take their theme from the real desks.toml, not from `--desks`. To see
another mode, point `CFFIXED_USER_HOME` and `HOME` at a throwaway folder holding
`.config/coldfall/desks.toml` with `[theme] mode = "light"`.

## Rules

- **Never quit or relaunch a running Project Coldfall.** The person you are
  working for is probably running you inside it, so quitting it ends the
  conversation. Use `--snapshot` to see UI changes, build the bundle, and ask
  them to relaunch.
- **Render and look before calling UI work done.** Take a snapshot and read
  the image. A clean build proves nothing about layout.
- **Check CI after every push** (`gh run list --limit 1`). Run the CI steps
  locally first: build, test, the core import guard, and the privacy guard.
- **Assert on scripted edits.** A search-and-replace that matches nothing
  fails silently. Check the match count is exactly one.
- **Tests go in the core.** If logic you need to test sits in the app target,
  move it to ColdfallCore.
- **Nothing private in the repo.** CI rejects committed paths under a real
  home directory. Test fixtures use neutral paths such as `/srv/demo`.
- Tests must not write to the real `~/.local/share/coldfall` or
  `~/.config/coldfall`. Point the overridable roots at a temp directory.
- **Nothing periodic reads a whole file or overlaps itself.** Coldfall runs for days next to
  conversations that reach hundreds of megabytes. Work on a timer reads only what a file gained
  (`LineTail` in the core), and background work started by a timer doesn't start again while the
  last run is going. A pass that outlasted its interval once piled up until Coldfall reached about
  100GB and macOS ended it.
- Record user-visible changes under **Unreleased** in `CHANGELOG.md`.
