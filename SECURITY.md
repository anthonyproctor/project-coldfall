# Security

Project Coldfall starts shells, reads local files, types into terminals on your
behalf and can hand a folder to another company's agent. A hole in any of that
matters more than a wrong number in the usage meter, so please report it
privately.

## Reporting a problem

[Open a private advisory](https://github.com/anthonyproctor/project-coldfall/security/advisories/new).
Only the maintainer sees it. Please don't open a public issue or discussion for
something that could be used against other people's Macs.

It helps to say:

- the version (select the app in Finder and choose **Get Info**), and whether
  you downloaded it or built it from source,
- what you did and what happened, as steps someone else can follow,
- what an attacker would need first: a web page you visit, a device on your
  Tailscale network, a file in a folder a desk works in, or code already
  running as you.

This is one person's project. There is no bounty and no promised reply time.
Reports are read, a fix ships as an ordinary release, the changelog's
**Security** heading says what it was, and you are credited if you want to be.
Fixes go into the newest release only.

## What is worth reporting

- **Running things.** Anything that makes Coldfall, `coldfall-cli` or
  `coldfall-holder` run a command, or type into a desk, that the person at the
  Mac did not ask for. A folder name, a desk name, a file's contents or a
  terminal's output should never become a command.
- **The phone inbox.** It is a small web server on the Mac, off by default. It
  listens only on the Mac's Tailscale addresses and on loopback, and wants a
  secret from the link in Settings before it answers anything but its icon.
  Reading or answering a desk without that secret, from a web page in a browser
  on the same Mac, or over Tailscale Funnel, is a hole. So is a photo sent from
  the phone landing anywhere but its desk's `.coldfall-photos` folder, under a
  name the phone chose, or as anything but a picture.
- **One desk reaching another.** `coldfall-cli send`, `ask` and `wake` let an
  agent in one desk reach another. Getting past the limits on them (a desk's
  `wake_from` list, the refusal to type into a desk that is asking a question)
  is a hole.
- **Second opinions.** A second opinion from Claude or Codex runs with the
  vendor's own read-only flag. Anything that lets that responder write is a
  hole. Other agents have no such flag, and Coldfall says so before you send;
  that is a limit, not a hole. So is the responder reading the folder you gave
  it (see "Read-only is not private" in the README).
- **Held desks.** A desk kept running while Coldfall is closed is reached
  through a socket in a folder only your account can open, by Coldfall and by
  `coldfall-cli attach`. Another account on the Mac reaching it is a hole.
- **Shortcuts.** Coldfall's actions follow the CLI's rules for sending. One
  that types into a desk stopped on a question, or offers a hidden desk, is a
  hole.
- **What leaves the Mac.** The README's "What Coldfall sends" is the whole
  list. Anything else going out is a hole, and so is a notification that
  carries more than that section says, or that its push service can read.
- **The download.** A release zip that differs from what the tagged source
  builds, or that carries anything from the Mac it was built on.

## What is not

- What an agent does inside its own desk. Coldfall runs each vendor's own CLI
  in a real terminal and does not sit between you and it; that CLI's
  permissions and sandbox are the vendor's.
- Anything that needs code already running as you on the Mac. It can read the
  same files Coldfall can.
- The download not being signed or notarized. That is known and said in the
  README; building from source is the careful path until it is.
- Answering from the phone without Face ID before a phone has been set up
  for it (Settings, General, Set Up a Phone). Until then the inbox link alone
  can answer, as the Settings text says. Getting past Face ID once a phone is
  set up is a hole.
