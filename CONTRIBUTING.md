# Contributing

## Where things go

| | |
|---|---|
| **Bug** | [Issues](../../issues/new/choose) — something behaves differently from how it reads |
| **Feature** | [Issues](../../issues/new/choose), after reading [ROADMAP.md](ROADMAP.md) |
| **Another runtime** | [Issues](../../issues/new/choose) — there is a template that asks the four questions that matter |
| **Half-formed idea, question, poll** | [Discussions](../../discussions) |
| **Security** | [Private advisory](../../security/advisories/new), not an issue |

**Voting is 👍 on the issue.** Priorities get ranked by reactions rather than by
who argues longest. Every priority in the roadmap is currently one person's
guess, so a reaction genuinely moves things.

## Security is not a formality here

Project Coldfall launches shells, reads local files, and hands a working directory to
agents from other companies. A bug in the meter shows a wrong number; a bug in
that surface does not. Report anything touching process execution, file access
the phone inbox or the cross-vendor bridge privately. [SECURITY.md](SECURITY.md)
says how, and what counts.

## Building

```sh
cd app && swift build -c release && ./.build/release/coldfall-test
```

macOS 13+, Command Line Tools is enough. **Xcode is not required and should not
become required** — that is a promise the README makes and CI enforces by
printing its toolchain. It is also why the test suite is a plain executable
rather than XCTest, which ships only with Xcode.

## Two rules the code is built around

**Never reimplement an agent.** Project Coldfall launches the vendor's own CLI in a real
pty. That is why your agent definitions, hooks, memory and model pins all work —
nothing is intercepting them. Anything that starts parsing or re-serving a
vendor's protocol is going the wrong way.

**`ColdfallCore` imports Foundation and nothing else.** That boundary is what
keeps a future Linux or Windows front end a UI project rather than a rewrite.
CI fails the build if a UI framework appears there.

## Things worth knowing before you change something

These are all bugs that already happened. Each cost an hour.

- `NSView` inherits `init()` from `NSResponder`, so `MyView()` can skip
  `init(frame:)` entirely and render an empty pane. Compiles, runs, shows
  nothing.
- An `NSStackView` used as a scroll view's `documentView` has no size of its
  own, and an unflipped one stacks content upward from the bottom.
- `String(format: "%-8s", swiftString)` needs a C string pointer and emits
  whatever is in memory otherwise.
- FSEvents returns a raw `char **` unless you set
  `kFSEventStreamCreateFlagUseCFTypes`.
- Config parsing must not cut at the first `#`: a command containing one is
  silently truncated, and a truncated command still runs.

The last one was found by a second AI agent reviewing the first one's tests,
using the bridge in this repo. If you are changing the parsers, add a test —
that is what caught the two bugs that followed it.

## Style

Comments explain **why**, especially where the obvious approach was rejected
and what went wrong. The code says what it does.

## The CLA

First pull request asks you to sign a [Contributor License Agreement](CLA.md). A bot posts a comment; you reply with one line and are never asked again.

It does not take your copyright — you keep it and can reuse your own work anywhere. It grants a licence broad enough that the project can relicense later without tracking down every past contributor, which is the thing that quietly strands projects that skip it.

The document says plainly that this includes the power to release under a different licence in future, and why you might reasonably decline on those grounds. Every version already published stays MIT permanently; nothing can close source that is already open.
