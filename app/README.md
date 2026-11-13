# Project Coldfall — M1, the desk switcher

A window with your desks down the left and one long-lived terminal each. Switching
desks swaps which terminal is visible; the others keep running.

Project Coldfall does not reimplement any agent. Each desk launches the vendor's own CLI in
a real pty, so that CLI's config, hooks, memory and model pins apply untouched.

## Build and run

```sh
swift build -c release
.build/release/Project Coldfall
```

Requires macOS 13+ and the Swift toolchain (Command Line Tools is enough; Xcode is
not needed).

## Configure

`~/.config/coldfall/desks.toml`:

```toml
[desk.shell]
# A plain shell first means opening the app costs nothing.
command = "exec zsh -l"
cwd = "~"

[desk.notes]
agent   = "research-copilot"
runtime = "claude"          # claude | codex | gemini | copilot
cwd     = "~/notes"

[desk.api]
# `command` is the escape hatch: run anything verbatim, including your own
# wrapper script that already handles resume-vs-new.
command = "~/bin/desk api"
cwd     = "~/src/api"
```

Nothing starts until you click a desk.

## Keys

`cmd-1` … `cmd-9` jump between the first nine desks.

## Panes

Three, all resizable:

- **Left rail** — desks on top, the visible desk's folder tree beneath.
- **Centre** — that desk's terminal, running the vendor's real CLI.
- **Right** — the reader. Click a file in the tree to open it.

The reader handles **PDFs** (PDFKit), images, and anything decodable as text. It
refuses binaries rather than spraying them at you. It is deliberately read-only:
agents write, you read, and that is what keeps this a few hundred lines instead
of an editor.

`cmd-r` refreshes the tree after an agent writes something.

## What it does not do yet

- No diff view in the reader
- Desks kept running outlive the app, but not a restart of the Mac (Coldfall
  then offers to start them again)

See [../DESIGN.md](../DESIGN.md) for where this is going.
