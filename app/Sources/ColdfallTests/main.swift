import Foundation
import ColdfallCore

// Regression tests for faults that actually shipped today, not invented cases.
// Each one names the bug it stops coming back.
//
// Deliberately not XCTest: that ships with Xcode, and this project builds on
// Command Line Tools alone. A test suite that reintroduces a 15GB dependency
// defeats the point.

var failures: [String] = []
/// Whether a real usage cache existed before any test ran. Lets the final
/// check tell test pollution apart from the user's own data.
let preexistingCache = FileManager.default.fileExists(
    atPath: NSString(string: "~/.local/share/coldfall/cache/usage.json").expandingTildeInPath)
var passed = 0

func check(_ name: String, _ cond: @autoclosure () -> Bool, _ note: String = "") {
    if cond() { passed += 1; print("  ok    \(name)") }
    else { failures.append(name + (note.isEmpty ? "" : " — " + note)); print("  FAIL  \(name)") }
}

func eq<T: Equatable>(_ name: String, _ a: T?, _ b: T?) {
    if a == b { passed += 1; print("  ok    \(name)") }
    else {
        failures.append("\(name) — got \(String(describing: a)), wanted \(String(describing: b))")
        print("  FAIL  \(name): got \(String(describing: a)), wanted \(String(describing: b))")
    }
}

func parse(_ toml: String) -> [Desk] {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml")
    try? toml.write(to: f, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: dir) }
    return DeskConfig.load(path: f.path)
}

print("\nprompt helper")
eq("blank goal produces no draft", PromptDraft.build(goal: " \n ", context: "context"), "")
eq("simple asks stay simple", PromptDraft.build(goal: " Explain this. "), "Explain this.")
eq("empty optional fields are omitted", PromptDraft.build(goal: "Review", constraints: " \n "), "Review")
eq("all supplied sections appear verbatim",
   PromptDraft.build(goal: "Review", context: "line one\nline two", constraints: "Do not edit", success: "Three findings"),
   "Review\n\nContext:\nline one\nline two\n\nConstraints:\nDo not edit\n\nWhat a good result looks like:\nThree findings")
eq("unicode and shell text are preserved as text",
   PromptDraft.build(goal: "Explain `echo $PATH` 🐾"), "Explain `echo $PATH` 🐾")
eq("optional fields remain independent", PromptDraft.build(goal: "Write", success: "One paragraph"),
   "Write\n\nWhat a good result looks like:\nOne paragraph")

print("\nconfig parsing")

// A desk running a bare shell was labelled claude, so it could be chosen as
// the claude home — meaning "Manage" would type /agents at a zsh prompt.
eq("bare command is shell, not claude",
   parse("[desk.shell]\ncommand = \"exec zsh -l\"\n").first?.runtime, "shell")

eq("declared runtime survives a command",
   parse("[desk.m]\nruntime = \"claude\"\ncommand = \"~/bin/desk m\"\n").first?.runtime, "claude")

// A shell is nobody's home; routing into one produces nonsense.
check("a shell is never a home",
      DeskConfig.general(for: "shell",
                         in: parse("[desk.s]\ncommand = \"exec zsh -l\"\n")) == nil)

let two = parse("""
[desk.a]
runtime = "claude"

[desk.b]
runtime = "claude"
default = true
""")
eq("explicit home beats first match",
   DeskConfig.general(for: "claude", in: two).map { two[$0].name }, "b")

let both = parse("""
[desk.c]
runtime = "claude"
default = true

[desk.x]
runtime = "codex"
default = true
""")
eq("claude home", DeskConfig.general(for: "claude", in: both).map { both[$0].name }, "c")
eq("codex home, independently", DeskConfig.general(for: "codex", in: both).map { both[$0].name }, "x")

print("\ndefault runtime (was hardcoded to claude)")

eq("follows the majority",
   DeskConfig.preferredRuntime(given: [Desk(name: "a", runtime: "codex"),
                                       Desk(name: "b", runtime: "codex"),
                                       Desk(name: "c", runtime: "claude")]), "codex")

eq("shells do not get a vote",
   DeskConfig.preferredRuntime(given: [Desk(name: "s", runtime: "shell"),
                                       Desk(name: "t", runtime: "shell"),
                                       Desk(name: "g", runtime: "grok")]), "grok")

print("\nlaunch commands")

let api = parse("[desk.api]\ngroup = \"work\"\nruntime = \"claude\"\nagent = \"backend\"\n")
eq("group stays presentation only", api.first?.group, "work")
eq("claude agent launch", api.first?.launchCommand(), "claude --agent backend -n api")

// -p and --agent are different flags; confusing them yields a command that
// does not run.
let prof = Discovery.desk(
    from: DiscoveredAgent(name: "review", runtime: "codex", description: "codex profile",
                          model: nil, path: "/tmp/c.toml", isProjectLevel: false),
    cwd: "/tmp")
eq("codex profile uses -p", prof.command, "codex -p review")
check("codex profile sets no agent field", prof.agent == nil)

print("\nfront matter")

let fm = Discovery.frontMatter("""
---
name: golf-caddie
description: "Uses data: launch monitors, and more"
model: sonnet
---
body
""")
eq("name", fm["name"], "golf-caddie")
eq("model", fm["model"], "sonnet")
// Splitting on every colon mangles real descriptions.
eq("splits on the first colon only", fm["description"], "Uses data: launch monitors, and more")
check("no front matter is empty, not a crash", Discovery.frontMatter("plain text").isEmpty)

print("\nquota windows")

// A window whose reset has passed is from a dead cycle: dropping it is right.
// An old-but-live reading is not, and hiding those made idle vendors vanish —
// which is backwards, since an idle vendor is the one with headroom.
let past = VendorLimits(vendor: "x", weekPct: 50, weekResetsAt: Date().timeIntervalSince1970 - 60,
                        fiveHourPct: nil, fiveHourResetsAt: nil, planType: nil,
                        at: Date().timeIntervalSince1970)
check("rolled-over window is dropped", past.liveWeekPct == nil)

let live = VendorLimits(vendor: "x", weekPct: 50, weekResetsAt: Date().timeIntervalSince1970 + 3600,
                        fiveHourPct: nil, fiveHourResetsAt: nil, planType: nil,
                        at: Date().timeIntervalSince1970 - 7200)
eq("two-hour-old live reading still counts", live.liveWeekPct, 50)
check("and is usable", live.isUsable)
check("and is labelled stale", live.ageLabel != nil)

let ancient = VendorLimits(vendor: "x", weekPct: 50, weekResetsAt: Date().timeIntervalSince1970 + 3600,
                           fiveHourPct: nil, fiveHourResetsAt: nil, planType: nil,
                           at: Date().timeIntervalSince1970 - 90_000)
check("a day-old reading is not usable", !ancient.isUsable)

print("\nconfig text handling  (found by codex reviewing these tests)")

// The parser cut at the first # regardless of quoting, so a command with a #
// in it was silently truncated — it still ran, just doing something else.
eq("a # inside a quoted value survives",
   parse("[desk.t]\ncommand = \"git log --grep=#123 --oneline\"\n").first?.command,
   "git log --grep=#123 --oneline")

eq("a real trailing comment is still stripped",
   parse("[desk.t]\nruntime = \"codex\"   # the home\n").first?.runtime, "codex")

check("stripComment leaves a bare line alone",
      TomlText.stripComment("runtime = \"claude\"") == "runtime = \"claude\"")
check("stripComment removes an unquoted comment",
      TomlText.stripComment("a = 1 # note").trimmingCharacters(in: .whitespaces) == "a = 1")

// Writing an unescaped quote produced a file that no longer parsed, quietly
// corrupting the source of truth on the next save.
eq("quotes survive an escape round trip",
   TomlText.unescape(TomlText.escape("say \"hi\" now")), "say \"hi\" now")
eq("backslashes survive too",
   TomlText.unescape(TomlText.escape("C:\\path\\to")), "C:\\path\\to")

// The write -> load round trip was never tested at all.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    let awkward = [
        Desk(name: "hash", runtime: "claude", cwd: "~", command: "echo \"#prod\" && ls"),
        Desk(name: "plain", agent: "backend", runtime: "claude", cwd: "~/src", group: "work"),
    ]
    DeskConfig.write(awkward, to: f)
    let back = DeskConfig.load(path: f)
    eq("round trip keeps the count", back.count, 2)
    eq("round trip keeps a # inside quotes", back.first?.command, "echo \"#prod\" && ls")
    eq("round trip keeps the agent", back.last?.agent, "backend")
    eq("round trip keeps the group", back.last?.group, "work")
    try? FileManager.default.removeItem(at: dir)
}

// Weak assertion called out in review: check the label, not just that one exists.
do {
    let twoHours = VendorLimits(vendor: "x", weekPct: 10,
                                weekResetsAt: Date().timeIntervalSince1970 + 3600,
                                at: Date().timeIntervalSince1970 - 7200)
    eq("stale label reads in hours", twoHours.ageLabel, "2h ago")
    let fortyMin = VendorLimits(vendor: "x", weekPct: 10,
                                weekResetsAt: Date().timeIntervalSince1970 + 3600,
                                at: Date().timeIntervalSince1970 - 2400)
    eq("stale label reads in minutes", fortyMin.ageLabel, "40m ago")
}

// MARK: - fan-out budget
//
// The point of pricing a fan-out is that it REFUSES. A budget check that only
// ever says yes is decoration, so these pin the boundaries in both directions.

do {
    let now = Date().timeIntervalSince1970
    func lim(_ v: String, _ week: Double) -> VendorLimits {
        VendorLimits(vendor: v, weekPct: week, weekResetsAt: now + 86_400, at: now)
    }

    // Plenty of room: quiet. The router says nothing when there is nothing to do.
    let easy = Fanout.budget(vendor: "claude", slices: 4, limits: [lim("claude", 5)])
    check("fan-out is allowed with room to spare", easy.allowsRun)
    eq("and says nothing about it", easy.advice, nil)

    // Nearly spent: refuse, and say why rather than failing silently.
    let broke = Fanout.budget(vendor: "claude", slices: 12, limits: [lim("claude", 97)])
    check("fan-out refuses when the week cannot pay for it", !broke.allowsRun)
    check("and the refusal explains itself", (broke.advice ?? "").contains("left"))

    // A vendor with real room: advise, never act. Moving work to another
    // company is a decision, so the verdict still allows the run.
    let split = Fanout.budget(vendor: "claude", slices: 3,
                              limits: [lim("claude", 60), lim("codex", 8)])
    check("a much emptier vendor is suggested", (split.advice ?? "").contains("codex"))
    check("but the run is still allowed", split.allowsRun)

    // A vendor only slightly emptier is NOT worth interrupting over.
    let close = Fanout.budget(vendor: "claude", slices: 3,
                              limits: [lim("claude", 40), lim("codex", 30)])
    eq("a marginally emptier vendor stays quiet", close.advice, nil)

    // No local quota (Antigravity, Copilot) must not become a block. Punishing the
    // user for their vendor exposing nothing would be the wrong default.
    let blind = Fanout.budget(vendor: "antigravity", slices: 8, limits: [])
    check("unknown quota allows the run", blind.allowsRun)

    // Stale data is not usable data: a reading from last week says nothing
    // about this week, and must not be treated as quota in hand.
    let old = VendorLimits(vendor: "claude", weekPct: 99, weekResetsAt: now + 86_400,
                           at: now - 200_000)
    check("a day-old reading is ignored rather than trusted",
       Fanout.budget(vendor: "claude", slices: 9, limits: [old]).allowsRun)

    // Cost scales with slices: the same vendor state must refuse more slices
    // than it allows, or the count is not actually in the arithmetic.
    let mid = lim("claude", 90)
    check("more slices cost more",
       Fanout.budget(vendor: "claude", slices: 2, limits: [mid]).allowsRun
       && !Fanout.budget(vendor: "claude", slices: 40, limits: [mid]).allowsRun)
}

// MARK: - desk activity badges
//
// "Finished" is inferred from output STOPPING, which has two failure modes
// pulling opposite ways: a short quiet window flickers "ready" mid-answer, a
// long one lags. These pin the boundaries and the clearing rule.

do {
    let t0 = Date()
    let quiet = ActivityState.quietFor

    // Output still arriving: working, not ready. A badge that says "done"
    // while the agent is mid-sentence is worse than no badge.
    var s = ActivityState()
    s.setVisible(false)
    s.noteOutput(at: t0)
    eq("output just now reads as working", s.activity(now: t0.addingTimeInterval(0.5)), .working)

    // Gone quiet while you were elsewhere: ready.
    eq("quiet after output reads as ready", s.activity(now: t0.addingTimeInterval(quiet + 0.1)), .ready)

    // The window is exclusive: at EXACTLY the boundary it has already flipped
    // to ready. Named for what it asserts — an earlier version of this test
    // said "still working" while asserting .ready, which is a suite that lies.
    eq("the boundary itself already reads as ready",
       s.activity(now: t0.addingTimeInterval(quiet)), .ready)
    eq("a hair before the boundary is still working",
       s.activity(now: t0.addingTimeInterval(quiet - 0.01)), .working)

    // Looking at a desk clears it, and it stays clear.
    var seen = ActivityState()
    seen.setVisible(false)
    seen.noteOutput(at: t0)
    seen.setVisible(true)
    eq("a desk you are looking at never badges", seen.activity(now: t0.addingTimeInterval(quiet + 5)), .quiet)
    seen.setVisible(false)
    eq("and stays clear after you leave it", seen.activity(now: t0.addingTimeInterval(quiet + 6)), .quiet)

    // Output while VISIBLE must not queue up a badge for later. You saw it.
    var watched = ActivityState()
    watched.setVisible(true)
    watched.noteOutput(at: t0)
    watched.setVisible(false)
    eq("output you watched arrive does not badge later",
       watched.activity(now: t0.addingTimeInterval(quiet + 1)), .quiet)

    // A desk that has never written anything has nothing to say.
    var fresh = ActivityState()
    fresh.setVisible(false)
    eq("a silent desk is quiet", fresh.activity(now: t0), .quiet)

    // New output after you have left re-arms it.
    var again = ActivityState()
    again.setVisible(true)
    again.noteOutput(at: t0)
    again.setVisible(false)
    again.noteOutput(at: t0.addingTimeInterval(10))
    eq("new output after leaving re-arms the badge",
       again.activity(now: t0.addingTimeInterval(10 + quiet + 0.1)), .ready)

    // Leaving a desk takes its focus, and the program redraws. That is not
    // the desk saying anything, and it used to turn it green again.
    var left = ActivityState()
    left.setVisible(true, at: t0)
    left.setVisible(false, at: t0.addingTimeInterval(1))
    left.noteOutput(at: t0.addingTimeInterval(1.2))
    eq("the redraw from being left does not badge",
       left.activity(now: t0.addingTimeInterval(1.2 + quiet + 1)), .quiet)
    eq("nor count as the desk's last output", left.lastOutput, nil)
    left.noteOutput(at: t0.addingTimeInterval(1 + ActivityState.leaveGrace + 0.5))
    eq("but a real answer a moment later still does",
       left.activity(now: t0.addingTimeInterval(1 + ActivityState.leaveGrace + 0.5 + quiet + 0.1)), .ready)
    var never = ActivityState()
    never.setVisible(false, at: t0)
    never.noteOutput(at: t0.addingTimeInterval(0.2))
    eq("a desk never looked at has no leaving to ignore",
       never.activity(now: t0.addingTimeInterval(0.2 + quiet + 0.1)), .ready)
}

// MARK: - saving desks must not eat the rest of the file
//
// write() rebuilds desks.toml from the desk list. Anything it does not know
// about was silently deleted, so changing one desk in Settings wiped [theme]
// — and would have wiped whatever section came next, too.

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    defer { try? FileManager.default.removeItem(at: dir) }

    try? """
    [theme]
    palette = "gruvbox"
    mode = "light"
    size = 16

    [future]
    # a section this writer has never heard of
    setting = "keep me"

    [desk.one]
    runtime = "claude"
    cwd = "~/src"
    """.write(toFile: f, atomically: true, encoding: .utf8)

    // Save with no theme given: everything non-desk survives untouched.
    DeskConfig.write(DeskConfig.load(path: f), to: f)
    let after = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    check("saving desks keeps the theme table", after.contains("palette = \"gruvbox\""))
    check("saving desks keeps a section the writer never heard of",
          after.contains("setting = \"keep me\""))
    check("and still writes the desks", after.contains("[desk.one]"))

    // Headers from older builds, stacked by earlier saves, collapse to one;
    // a comment the user wrote stays.
    let hf = f + ".headers"
    try? """
    # Project Coldfall desks. Written by Project Coldfall; safe to edit by hand.

    # Project Coldfall desks. Written by Project Coldfall; safe to edit by hand.

    # Deskwork desks. Written by Deskwork; safe to edit by hand.
    # my own note

    [desk.one]
    runtime = "claude"
    """.write(toFile: hf, atomically: true, encoding: .utf8)
    DeskConfig.write(DeskConfig.load(path: hf), to: hf)
    DeskConfig.write(DeskConfig.load(path: hf), to: hf)
    let hdr = (try? String(contentsOfFile: hf, encoding: .utf8)) ?? ""
    eq("stacked headers collapse to one", hdr.components(separatedBy: "Written by").count - 1, 1)
    check("and a hand-written comment survives", hdr.contains("# my own note"))
    check("and the desks are still there", DeskConfig.load(path: hf).map(\.name) == ["one"])

    let t = DeskConfig.themeSettings(path: f)
    eq("the theme still parses after a save", t.palette, "gruvbox")
    eq("including the mode", t.mode, "light")
    eq("and the size", t.size, 16)

    // Now save WITH a new theme: it replaces the old one and keeps the rest.
    var t2 = DeskConfig.themeSettings(path: f)
    t2.palette = "vscode"; t2.mode = "dark"
    DeskConfig.write(DeskConfig.load(path: f), theme: t2, to: f)
    let t3 = DeskConfig.themeSettings(path: f)
    eq("a new theme replaces the old palette", t3.palette, "vscode")
    eq("and the old mode", t3.mode, "dark")
    let after2 = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    check("replacing the theme still keeps other sections",
          after2.contains("setting = \"keep me\""))
    check("and does not leave a second theme table",
          after2.components(separatedBy: "[theme]").count == 2)

    // Repeated saves must be stable rather than accreting blank lines or dupes.
    DeskConfig.write(DeskConfig.load(path: f), theme: t3, to: f)
    DeskConfig.write(DeskConfig.load(path: f), theme: t3, to: f)
    let after3 = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    check("saving repeatedly does not duplicate the theme",
          after3.components(separatedBy: "[theme]").count == 2)
    check("saving repeatedly does not duplicate a desk",
          after3.components(separatedBy: "[desk.one]").count == 2)
}

// Dark is the default, not the system setting. A terminal-first tool that
// opens white on a light-mode Mac has wasted its only first impression.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    defer { try? FileManager.default.removeItem(at: dir) }
    try? "[desk.one]\nruntime = \"claude\"\n".write(toFile: f, atomically: true, encoding: .utf8)
    eq("no theme table means no mode set, so the app default applies",
       DeskConfig.themeSettings(path: f).mode, nil)
}

// MARK: - the usage cache
//
// A cache that is fast and WRONG is worse than the 12-second scan it replaced,
// so these pin invalidation rather than hits. Every one of them is a way the
// meter could quietly report yesterday's numbers.

do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("t.jsonl").path
    // Point the cache at this test's own directory. It used to write to the
    // real ~/.local/share/coldfall, and the empty directory it left behind was
    // enough to make the rename's migration refuse to run.
    let realRoot = UsageCache.root
    UsageCache.root = dir.appendingPathComponent("cache").path
    defer {
        UsageCache.clear()
        UsageCache.root = realRoot
        try? FileManager.default.removeItem(at: dir)
    }
    UsageCache.clear()

    try? "one".write(toFile: f, atomically: true, encoding: .utf8)
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    guard let fp1 = UsageCache.fingerprint(f) else { fatalError("no fingerprint") }

    let slice = UsageSlice(vendor: "claude", desk: "hub", day: "2026-09-20",
                           tokens: 100, calls: 2, usd: 1.5)
    UsageCache.store([slice], for: f, key: fp1.key, since: since)

    eq("an unchanged file serves its cached slices",
       UsageCache.slices(for: f, key: fp1.key, since: since)?.first?.tokens, 100)

    // A file whose CONTENTS changed must not serve the old numbers. Size is
    // part of the key precisely so a same-second rewrite is still caught.
    try? "one plus more text".write(toFile: f, atomically: true, encoding: .utf8)
    guard let fp2 = UsageCache.fingerprint(f) else { fatalError("no fingerprint") }
    check("a changed file invalidates its cache entry",
          UsageCache.slices(for: f, key: fp2.key, since: since) == nil)

    // A report over a different window is a different answer and must not be
    // served from an entry computed for another one.
    check("a different window invalidates the cache",
          UsageCache.slices(for: f, key: fp1.key,
                            since: since.addingTimeInterval(86_400)) == nil)

    // A file that no longer exists must not linger forever.
    UsageCache.store([slice], for: f, key: fp2.key, since: since)
    UsageCache.flush(keeping: [])
    check("flushing drops files that were not seen this pass",
          UsageCache.slices(for: f, key: fp2.key, since: since) == nil)

    // A file that IS still present survives the same flush.
    UsageCache.store([slice], for: f, key: fp2.key, since: since)
    UsageCache.flush(keeping: [f])
    eq("and keeps the ones that were",
       UsageCache.slices(for: f, key: fp2.key, since: since)?.first?.calls, 2)

    // An unknown path is a miss, not a crash.
    check("an unknown file is simply a miss",
          UsageCache.slices(for: "/nope/missing.jsonl", key: "x", since: since) == nil)

    // Fingerprinting something that is not there fails cleanly rather than
    // returning a key that would match every other missing file.
    check("fingerprinting a missing file returns nil",
          UsageCache.fingerprint("/nope/missing.jsonl") == nil)
}

// MARK: - dropping a file onto a desk
//
// The path goes onto a command line, so anything that escapes wrong either
// breaks the command or, worse, runs part of the filename. Real filenames are
// the test cases here, not invented ones.

do {
    eq("an ordinary path needs no escaping",
       ShellPath.escape("/srv/demo/notes.md"), "/srv/demo/notes.md")
    eq("a space is escaped",
       ShellPath.escape("/srv/demo/My File.png"), "/srv/demo/My\\ File.png")

    // Parentheses are ordinary in a filename and are NOT ordinary to zsh.
    eq("parentheses are escaped",
       ShellPath.escape("/x/report (final).pdf"), "/x/report\\ \\(final\\).pdf")

    // The ones that would actually execute something rather than just fail.
    check("a dollar sign is escaped", ShellPath.escape("/x/$HOME.txt").contains("\\$"))
    check("a backtick is escaped", ShellPath.escape("/x/`whoami`.txt").contains("\\`"))
    check("a semicolon is escaped", ShellPath.escape("/x/a;rm -rf b").contains("\\;"))
    check("an ampersand is escaped", ShellPath.escape("/x/a&b").contains("\\&"))
    check("a quote is escaped", ShellPath.escape("/x/it's here.txt").contains("\\'"))
    check("a backslash is escaped", ShellPath.escape("/x/a\\b").contains("\\\\"))

    // Globs must reach the program as literals, not be expanded by the shell.
    check("an asterisk is escaped", ShellPath.escape("/x/a*.log").contains("\\*"))

    // Non-ASCII names are common and must not be mangled; escaping them is
    // harmless, dropping or re-encoding them would not be.
    check("a unicode name survives", ShellPath.escape("/x/café.png").contains("caf"))
    check("an emoji name survives", !ShellPath.escape("/x/🎉.png").isEmpty)

    // The trailing space is what stops a second drop gluing onto the first.
    check("a dropped path ends with a space",
          ShellPath.line(["/x/a.png"]).hasSuffix(" "))
    eq("several paths are separated",
       ShellPath.line(["/x/a.png", "/x/b.png"]), "/x/a.png /x/b.png ")
    eq("dropping nothing types nothing", ShellPath.line([]), "")
}

// MARK: - migration from Deskwork paths
//
// The one piece of the rename that can lose a user's data. A plain directory
// rename would have broken the author's Claude Code statusline in every
// session on the machine, so the contract is: move, leave a link, never delete,
// and refuse to guess when both sides exist.

do {
    let fm = FileManager.default
    func sandbox() -> String {
        let d = fm.temporaryDirectory.appendingPathComponent("mig-" + UUID().uuidString).path
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    // Nothing there: a fresh install does nothing.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        eq("no old directory means nothing to migrate",
           Migration.migrate(from: d + "/old", to: d + "/new"), .nothing)
    }

    // The ordinary upgrade: data moves, a link is left, and the file is still
    // readable through the OLD path — which is what keeps external references
    // like a statusline command working.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? fm.createDirectory(atPath: d + "/old", withIntermediateDirectories: true)
        try? "[desk.hub]\n".write(toFile: d + "/old/desks.toml", atomically: true, encoding: .utf8)

        eq("an old directory is migrated", Migration.migrate(from: d + "/old", to: d + "/new"), .migrated)
        check("the data is at the new path", fm.fileExists(atPath: d + "/new/desks.toml"))
        check("the old path is now a link",
              (try? fm.destinationOfSymbolicLink(atPath: d + "/old")) != nil)
        eq("and the old path still reads the same file",
           try? String(contentsOfFile: d + "/old/desks.toml", encoding: .utf8), "[desk.hub]\n")

        // Running it again on the next launch must be a no-op.
        eq("a second launch sees it is already done",
           Migration.migrate(from: d + "/old", to: d + "/new"), .alreadyDone)
        check("and the data is still there", fm.fileExists(atPath: d + "/new/desks.toml"))
    }

    // Both exist as real directories: refuse, and touch neither. This is the
    // state a too-early save would have produced, and guessing here means
    // destroying one side.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? fm.createDirectory(atPath: d + "/old", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: d + "/new", withIntermediateDirectories: true)
        try? "old".write(toFile: d + "/old/a", atomically: true, encoding: .utf8)
        try? "new".write(toFile: d + "/new/a", atomically: true, encoding: .utf8)

        eq("two real directories is a conflict", Migration.migrate(from: d + "/old", to: d + "/new"), .conflict)
        eq("the old side is untouched", try? String(contentsOfFile: d + "/old/a", encoding: .utf8), "old")
        eq("the new side is untouched", try? String(contentsOfFile: d + "/new/a", encoding: .utf8), "new")
        check("and no link was made over real data",
              (try? fm.destinationOfSymbolicLink(atPath: d + "/old")) == nil)
    }

    // A plain FILE where the old directory should be is not a directory to
    // move. Leave it alone.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? "x".write(toFile: d + "/old", atomically: true, encoding: .utf8)
        eq("a file at the old path is not migrated",
           Migration.migrate(from: d + "/old", to: d + "/new"), .nothing)
        check("and it is left where it was", fm.fileExists(atPath: d + "/old"))
    }

    // The new parent directory does not exist yet (a first run on a machine
    // that has never had ~/.local/share). The move must create it.
    do {
        let d = sandbox(); defer { try? fm.removeItem(atPath: d) }
        try? fm.createDirectory(atPath: d + "/old", withIntermediateDirectories: true)
        eq("migrating into a parent that does not exist yet still works",
           Migration.migrate(from: d + "/old", to: d + "/deep/nested/new"), .migrated)
    }
}

// MARK: - markdown rendering
//
// Markdown used to be shown as raw source. These pin that it renders, and —
// because the reader shows files the user may not have written — that nothing
// in a file can inject markup or script.

do {
    let h = MarkdownHTML.body

    // The original complaint, line by line.
    check("a heading renders without its pound sign", h("# Desks").contains("<h1>Desks</h1>"))
    check("bold renders without its asterisks", h("a **b** c").contains("<strong>b</strong>"))
    check("italic renders", h("a *b* c").contains("<em>b</em>"))

    // Tables were the worst of it: rows of pipes wrapping across the window.
    let t = h("| Desk | Model |\n|---|---|\n| hub | Opus |\n| money | Fable |")
    check("a GFM table becomes a real table", t.contains("<table>") && t.contains("<th>Desk</th>"))
    check("and its rows are cells, not pipes", t.contains("<td>hub</td>") && t.contains("<td>Fable</td>"))
    check("the separator row is not rendered as data", !t.contains("---"))
    check("a right-aligned column keeps its alignment",
          h("| a |\n|--:|\n| 1 |").contains("text-align:right"))
    check("an escaped pipe stays inside its cell",
          h("| a |\n|---|\n| x \\| y |").contains("<td>x | y</td>"))

    // Code must stay literal: underscores in code are not emphasis.
    check("underscores inside code are not italicised",
          h("run `a_b_c` now").contains("<code>a_b_c</code>"))
    check("snake_case in prose is not italicised", !h("the desk_name field").contains("<em>"))
    check("a fenced block keeps its contents verbatim",
          h("```\nlet x = **y**\n```").contains("let x = **y**"))

    // Lists, quotes, rules.
    check("a bullet list renders", h("- one\n- two").contains("<ul>") && h("- one").contains("<li>one</li>"))
    check("a numbered list renders", h("1. one\n2. two").contains("<ol>"))
    check("a task box renders checked", h("- [x] done").contains("checked"))
    check("a blockquote renders", h("> quoted").contains("<blockquote>"))
    check("a rule renders", h("---").contains("<hr>"))

    // SECURITY. Every line of this is escaping a file's contents, and files
    // come from cloned repos and agents, not only from the user.
    check("a script tag in a file is escaped, not run",
          !h("<script>alert(1)</script>").contains("<script>"))
    check("and shows as visible text", h("<script>x</script>").contains("&lt;script&gt;"))
    check("markup inside a table cell is escaped",
          !h("| a |\n|---|\n| <img src=x onerror=alert(1)> |").contains("<img"))
    check("a javascript: link is not made clickable",
          !h("[click](javascript:alert(1))").contains("href"))
    check("a normal https link is clickable",
          h("[site](https://example.com)").contains("href=\"https://example.com\""))
    check("a relative link to another file is clickable",
          h("[notes](other.md)").contains("href=\"other.md\""))
    check("a quote in text cannot break out of an attribute",
          !h("[x](https://a.com\"onmouseover=\"alert(1))").contains("onmouseover=\"alert"))
}


// MARK: - quick open (fuzzy matching)
//
// The ranking is the whole point: a palette that finds the right thing but
// puts it fifth is one you stop using.

do {
    // Matching itself.
    check("an in-order subsequence matches", Fuzzy.score("cpa", "cpa-strategy-copilot") != nil)
    check("out-of-order letters do not match", Fuzzy.score("apc", "cpa") == nil)
    check("matching ignores case", Fuzzy.score("README", "docs/readme.md") != nil)
    check("a query longer than the candidate does not match", Fuzzy.score("hubhub", "hub") == nil)
    eq("an empty query matches with score 0", Fuzzy.score("", "anything"), 0)

    // Ranking — what you meant comes first.
    let desks = ["market", "money", "mba", "hub"]
    eq("an exact prefix wins", Fuzzy.rank("mo", desks, key: { $0 }).first, "money")
    eq("word starts beat scattered letters",
       Fuzzy.rank("sst", ["self-study-tutor", "sasstrings"], key: { $0 }).first, "self-study-tutor")

    // A match in the file NAME beats one buried in the directory above it.
    let files = ["docs/desks/notes.md", "notes/DESKS.md"]
    eq("the file name outranks the path", Fuzzy.rank("desks", files, key: { $0 }).first, "notes/DESKS.md")

    // Consecutive letters beat the same letters spread out.
    eq("consecutive characters rank higher",
       Fuzzy.rank("desk", ["d_e_s_k.txt", "desk.txt"], key: { $0 }).first, "desk.txt")

    check("non-matches are dropped from the ranking",
          !Fuzzy.rank("zzz", desks, key: { $0 }).contains("hub"))
    eq("an empty query returns the list as-is",
       Fuzzy.rank("", desks, key: { $0 }), desks)

    // The file index skips what nobody opens by name.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fz-" + UUID().uuidString)
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dir) }
    for p in ["README.md", "src/app.swift", "node_modules/pkg/index.js", ".git/HEAD", ".build/x.o"] {
        let u = dir.appendingPathComponent(p)
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "x".write(to: u, atomically: true, encoding: .utf8)
    }
    let found = Set(FileIndex.files(under: dir.path))
    check("the index finds ordinary files", found.contains("README.md") && found.contains("src/app.swift"))
    check("the index skips node_modules", !found.contains(where: { $0.hasPrefix("node_modules") }))
    check("the index skips .git", !found.contains(where: { $0.hasPrefix(".git") }))
    check("the index skips build output", !found.contains(where: { $0.hasPrefix(".build") }))
    eq("the index respects its limit", FileIndex.files(under: dir.path, limit: 1).count, 1)
}


// MARK: - saved UI state survives new fields
//
// Adding a field to UIState used to wipe everyone's saved state: the default
// decoder throws on a missing key and load() falls back to defaults. This is
// the author's real ui.json from before the layout toggles existed.

do {
    let old = #"{"collapsed":["WORK"],"treeOnTop":true,"seenWelcome":true}"#
    let s = try? JSONDecoder().decode(UIState.self, from: Data(old.utf8))
    check("a ui.json from before the new fields still decodes", s != nil)
    eq("and keeps the tree position", s?.treeOnTop, true)
    eq("and keeps having seen the welcome screen", s?.seenWelcome, true)
    eq("and keeps collapsed groups", s?.collapsed, ["WORK"])
    eq("new fields take their defaults", s?.railHidden, false)

    // A completely empty object is the extreme case and must not throw.
    check("an empty object decodes to defaults",
          (try? JSONDecoder().decode(UIState.self, from: Data("{}".utf8))) != nil)

    // Round trip keeps the new fields.
    var u = UIState(); u.railHidden = true; u.readerPoppedOut = true
    let back = (try? JSONEncoder().encode(u)).flatMap { try? JSONDecoder().decode(UIState.self, from: $0) }
    eq("a saved layout toggle comes back", back?.railHidden, true)
    eq("and the reader's pop-out state", back?.readerPoppedOut, true)
}


// MARK: - renaming, reordering, memory

do {
    let names = ["hub", "money", "work"]
    check("a plain name is fine", DeskName.problem("career", existing: names) == nil)
    check("an empty name is refused", DeskName.problem("", existing: names) != nil)
    check("a dot would nest the TOML table", DeskName.problem("a.b", existing: names) != nil)
    check("so would a space", DeskName.problem("my desk", existing: names) != nil)
    check("a taken name is refused, case-insensitively", DeskName.problem("Money", existing: names) != nil)
    check("keeping its own name is not a clash",
          DeskName.problem("hub", existing: names, current: "hub") == nil)
    check("over the length limit is refused",
          DeskName.problem(String(repeating: "a", count: 41), existing: names) != nil)

    let list = [Desk(name: "a"), Desk(name: "b", group: "g"), Desk(name: "c", group: "g"),
                Desk(name: "d", group: "h")]
    let n = { (ds: [Desk]) in ds.map(\.name).joined() }
    eq("move down within a group", n(DeskOrder.move(list, from: 1, to: .after(2))), "acbd")
    eq("move up to the top", n(DeskOrder.move(list, from: 3, to: .before(0))), "dabc")
    let joined = DeskOrder.move(list, from: 0, to: .after(2))
    eq("landing beside a grouped desk joins its group", joined.first { $0.name == "a" }?.group, "g")
    eq("end of a group lands after its last member",
       n(DeskOrder.move(list, from: 0, to: .endOfGroup("g"))), "bcad")
    eq("end of the ungrouped section is ungrouped",
       DeskOrder.move(list, from: 3, to: .endOfGroup(nil)).first { $0.name == "d" }?.group ?? "none", "none")
    eq("a drop onto itself changes nothing", n(DeskOrder.move(list, from: 2, to: .before(2))), "abcd")

    // A group scattered through the file, as a hand edit leaves it.
    let messy = [Desk(name: "hub"), Desk(name: "cpa", group: "money"), Desk(name: "work", group: "work"),
                 Desk(name: "zed"), Desk(name: "market", group: "money"), Desk(name: "golf", group: "Personal"),
                 Desk(name: "desk10", group: "work"), Desk(name: "desk2", group: "work")]
    let ns = { (ds: [Desk]) in ds.map(\.name).joined(separator: " ") }
    eq("groups follow first appearance, ungrouped first",
       DeskOrder.groups(messy).map { $0 ?? "-" }, ["-", "money", "work", "Personal"])
    eq("grouped gathers each group's desks together",
       ns(DeskOrder.grouped(messy)), "hub zed cpa market work desk10 desk2 golf")
    eq("A to Z: ungrouped on top, groups by name ignoring case, desks by name, numbers natural",
       ns(DeskOrder.sortedAZ(messy)), "hub zed cpa market golf desk2 desk10 work")
    check("sorting keeps every desk", DeskOrder.sortedAZ(messy).count == messy.count)
    check("and every desk keeps its group",
          DeskOrder.sortedAZ(messy).allSatisfy { d in messy.first { $0.name == d.name }?.group == d.group })
    eq("a group moves as a block", ns(DeskOrder.moveGroup(messy, "Personal", before: "money")),
       "hub zed golf cpa market work desk10 desk2")
    eq("moving a group last", ns(DeskOrder.moveGroup(messy, "money", before: nil)),
       "hub zed work desk10 desk2 golf cpa market")
    eq("moving before itself only tidies", ns(DeskOrder.moveGroup(messy, "work", before: "work")),
       ns(DeskOrder.grouped(messy)))
    eq("an unknown group changes nothing but the tidy",
       ns(DeskOrder.moveGroup(messy, "nope", before: nil)), ns(DeskOrder.grouped(messy)))
    eq("an unknown target puts the group last", ns(DeskOrder.moveGroup(messy, "money", before: "nope")),
       "hub zed work desk10 desk2 golf cpa market")

    let ps = ProcessTree.parse("""
      100     1   2000
      101   100 900000
      102   101  50000
      103   101  40000
      200     1   1000
    garbage line
    """)
    eq("ps rows parse, garbage skipped", ps.count, 5)
    eq("a desk's memory is its whole tree", ProcessTree.totalKB(root: 100, in: ps), 992000)
    eq("an unrelated tree is not counted", ProcessTree.totalKB(root: 200, in: ps), 1000)
    eq("a pid that is gone counts nothing", ProcessTree.totalKB(root: 999, in: ps), 0)
    let tree = ProcessTree.descendants(of: 100, in: ps)
    eq("ending a desk reaches every process under its shell", Set(tree), [100, 101, 102, 103])
    eq("the shell is ended last", tree.last, 100)
    check("and children before their parent",
          tree.firstIndex(of: 102)! < tree.firstIndex(of: 101)! && tree.firstIndex(of: 103)! < tree.firstIndex(of: 101)!)
    check("an unrelated tree is left alone", !tree.contains(200))
    eq("a pid that is gone ends nothing", ProcessTree.descendants(of: 999, in: ps), [])
    eq("labels megabytes", ProcessTree.label(kb: 2048), "2 MB")
    eq("and gigabytes", ProcessTree.label(kb: 992000), "969 MB")
    eq("over a thousand MB reads as GB", ProcessTree.label(kb: 1_300_000), "1.2 GB")
}

// The writer used to drop `model`, so reordering or renaming an ollama desk
// would have silently switched it back to the default model.
do {
    let tmp = NSTemporaryDirectory() + "coldfall-model-\(UUID().uuidString).toml"
    DeskConfig.write([Desk(name: "local", runtime: "ollama", model: "qwen3")], to: tmp)
    eq("model survives a write", DeskConfig.load(path: tmp).first?.model, "qwen3")
    try? FileManager.default.removeItem(atPath: tmp)
}



// MARK: - resuming a desk's conversation

do {
    let root = NSTemporaryDirectory() + "coldfall-resume-\(UUID().uuidString)"
    let fm = FileManager.default
    eq("claude's folder for a directory", Resume.claudeProjectDir(for: "/srv/demo.app/my dir", root: "/r"),
       "/r/-srv-demo-app-my-dir")
    eq("dashes survive", Resume.claudeProjectDir(for: "/srv/a-b", root: "/r"), "/r/-srv-a-b")

    let cdir = Resume.claudeProjectDir(for: "/srv/demo", root: root + "/claude")
    try? fm.createDirectory(atPath: cdir, withIntermediateDirectories: true)
    func transcript(_ id: String, _ title: String?, age: TimeInterval) {
        let path = cdir + "/\(id).jsonl"
        var text = "{\"type\":\"user\",\"message\":\"hi\"}\n"
        if let title { text += "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"\(id)\"}\n" }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    eq("no transcripts, nothing to resume",
       Resume.claudeSession(named: "demo", cwd: "/srv/demo", root: root + "/claude"), nil)
    transcript("old-demo", "demo", age: 3000)
    transcript("new-demo", "demo", age: 100)
    transcript("other", "demo2", age: 10)
    transcript("untitled", nil, age: 5)
    eq("the newest transcript with the desk's title",
       Resume.claudeSession(named: "demo", cwd: "/srv/demo", root: root + "/claude"), "new-demo")
    eq("a longer title is not a match", Resume.claudeSession(named: "dem", cwd: "/srv/demo", root: root + "/claude"), nil)
    eq("another directory's desk finds nothing",
       Resume.claudeSession(named: "demo", cwd: "/srv/elsewhere", root: root + "/claude"), nil)

    let croot = root + "/codex/2026/09/20"
    try? fm.createDirectory(atPath: croot, withIntermediateDirectories: true)
    func rollout(_ name: String, cwd: String, subagent: Bool = false) {
        let src = subagent ? ",\"source\":{\"subagent\":{}}" : ""
        try? "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"\(cwd)\",\"originator\":\"codex-tui\"\(src)}}\n{}\n"
            .write(toFile: croot + "/\(name).jsonl", atomically: true, encoding: .utf8)
    }
    rollout("a", cwd: "/srv/demo", subagent: true)
    check("a subagent's session is not one to resume", !Resume.codexHasSession(cwd: "/srv/demo", root: root + "/codex"))
    rollout("b", cwd: "/srv/demo")
    check("an interactive session in the folder is", Resume.codexHasSession(cwd: "/srv/demo", root: root + "/codex"))
    check("but not for another folder", !Resume.codexHasSession(cwd: "/srv/other", root: root + "/codex"))

    let claudeDesk = Desk(name: "demo", runtime: "claude", cwd: "/srv/demo")
    eq("a claude desk with history resumes it by id",
       claudeDesk.resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"),
       "claude --resume new-demo")
    eq("without history it starts a named session",
       Desk(name: "fresh", runtime: "claude", cwd: "/srv/demo")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "claude -n fresh")
    eq("an agent desk keeps its agent when resuming",
       Desk(name: "demo", agent: "helper", runtime: "claude", cwd: "/srv/demo")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"),
       "claude --agent helper --resume new-demo")
    eq("a codex desk with history resumes the latest",
       Desk(name: "cx", runtime: "codex", cwd: "/srv/demo")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "codex resume --last")
    eq("without it, plain codex",
       Desk(name: "cx", runtime: "codex", cwd: "/srv/other")
           .resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "codex")
    let scripted = Desk(name: "demo", runtime: "claude", cwd: "/srv/demo", command: "/srv/demo/bin/desk demo")
    eq("a desk with its own command runs exactly that",
       scripted.resumingLaunchCommand(claudeRoot: root + "/claude", codexRoot: root + "/codex"), "/srv/demo/bin/desk demo")

    check("the stop dialog promises the conversation for a built-in desk",
          Resume.afterRestart(claudeDesk)?.contains("same conversation") == true)
    check("and makes no promise for a scripted one",
          Resume.afterRestart(scripted)?.contains("its own command") == true)
    eq("and says nothing for a shell", Resume.afterRestart(Desk(name: "sh", runtime: "shell")), nil)
    try? fm.removeItem(atPath: root)
}


// MARK: - needs you

do {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let e = [NeedsYou.Entry(name: "hub", activity: .ready, lastOutput: t0.addingTimeInterval(60)),
             NeedsYou.Entry(name: "money", activity: .working, lastOutput: t0),
             NeedsYou.Entry(name: "career", activity: .ready, lastOutput: t0),
             NeedsYou.Entry(name: "golf", activity: .quiet, lastOutput: nil),
             NeedsYou.Entry(name: "study", activity: .ready, lastOutput: t0.addingTimeInterval(60))]
    let q = NeedsYou.queue(e)
    eq("only waiting desks, oldest wait first, ties by name", q, ["career", "hub", "study"])
    eq("cmd-0 goes to the oldest", NeedsYou.next(in: q, current: "golf"), "career")
    eq("and never to the desk already on screen", NeedsYou.next(in: q, current: "career"), "hub")
    eq("nothing waiting, nowhere to go", NeedsYou.next(in: [], current: nil), nil)
    eq("one desk reads as a sentence", NeedsYou.summary(["career"]), "career needs you")
    eq("several are counted and named", NeedsYou.summary(q), "3 need you: career, hub, study")
    eq("a long queue is cut short", NeedsYou.summary(q + ["work"]), "4 need you: career, hub, study, …")
    eq("an empty queue says nothing", NeedsYou.summary([]), nil)
}

// MARK: - the daily update check

do {
    let dir = NSTemporaryDirectory() + "coldfall-update-\(UUID().uuidString)"
    let realRoot = UpdateState.root
    UpdateState.root = dir
    defer { UpdateState.root = realRoot; try? FileManager.default.removeItem(atPath: dir) }

    let first = UpdateState.load()
    check("a fresh install gets a random id", UUID(uuidString: first.id) != nil)
    eq("and keeps it", UpdateState.load().id, first.id)
    check("on by default", first.enabled)

    var s = first
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    check("nothing is sent before the notice is shown", !UpdateCheck.due(s, now: now))
    s.noticeShown = true
    check("after the notice, a first check is due", UpdateCheck.due(s, now: now))
    s.lastCheck = now.addingTimeInterval(-3600)
    check("not again within the day", !UpdateCheck.due(s, now: now))
    s.lastCheck = now.addingTimeInterval(-UpdateCheck.interval)
    check("but once a day has passed", UpdateCheck.due(s, now: now))
    s.enabled = false
    check("and never when turned off", !UpdateCheck.due(s, now: now))
    s.save()
    eq("turning it off is remembered", UpdateState.load().enabled, false)

    eq("a release reports as itself", UpdateCheck.reportedVersion("v0.3.0"), "v0.3.0")
    eq("a build from source hides its commit", UpdateCheck.reportedVersion("v0.3.0-5-gabc1234"), "v0.3.0-dev")
    eq("a build with no tag is unknown", UpdateCheck.reportedVersion("abc1234"), "unknown")

    let body = UpdateCheck.body(first, appVersion: "v0.3.0-2-gdeadbee", os: "15.6.1")
    let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
    eq("the request carries exactly three fields", sent.map { Set($0.keys) }, ["id", "v", "os"])
    eq("the id", sent?["id"], first.id)
    eq("the reported version", sent?["v"], "v0.3.0-dev")
    eq("the macOS version", sent?["os"], "15.6.1")

    eq("a reply names the latest release",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"https://github.com/anthonyproctor/project-coldfall/releases/tag/v0.4.0"}"#.utf8)),
       UpdateCheck.Reply(latest: "v0.4.0", url: "https://github.com/anthonyproctor/project-coldfall/releases/tag/v0.4.0"))
    eq("a link to another site is dropped",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"https://evil.example/releases"}"#.utf8))?.url, nil)
    eq("so is one that only looks like GitHub",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"https://github.com.evil.example/anthonyproctor/project-coldfall/x"}"#.utf8))?.url, nil)
    eq("and another repository",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"https://github.com/someone/else/releases"}"#.utf8))?.url, nil)
    eq("a link that is not https is dropped",
       UpdateCheck.parse(Data(#"{"latest":"v0.4.0","url":"javascript:alert(1)"}"#.utf8))?.url, nil)
    eq("anything else is not a reply", UpdateCheck.parse(Data("<html>".utf8)), nil)
    eq("nor is a version that is not one", UpdateCheck.parse(Data(#"{"latest":"soon"}"#.utf8)), nil)

    check("a higher release is newer", UpdateCheck.isNewer("v0.4.0", than: "v0.3.0"))
    check("numbers compare as numbers", UpdateCheck.isNewer("v0.10.0", than: "v0.9.2"))
    check("the same release is not", !UpdateCheck.isNewer("v0.3.0", than: "v0.3.0"))
    check("an older one is not", !UpdateCheck.isNewer("v0.2.0", than: "v0.3.0"))
    check("a build past a release does not nag about it",
          !UpdateCheck.isNewer("v0.3.0", than: "v0.3.0-5-gabc1234"))
    check("but does hear about the next", UpdateCheck.isNewer("v0.3.1", than: "v0.3.0-5-gabc1234"))
    check("an unreadable version never claims an update", !UpdateCheck.isNewer("v0.4.0", than: "abc1234"))
}

// MARK: - double-click to fill the screen and back

do {
    let screen = Frame(x: 0, y: 80, w: 1512, h: 862)
    let small = Frame(x: 200, y: 200, w: 900, h: 600)
    let (filled, saved) = WindowFill.toggle(frame: small, visible: screen, saved: nil)
    eq("a double-click fills the screen", filled, screen)
    eq("and remembers where it was", saved, small)
    let nudged = Frame(x: filled.x + 2, y: filled.y - 3, w: filled.w, h: filled.h)
    let (back, cleared) = WindowFill.toggle(frame: nudged, visible: screen, saved: saved)
    eq("a second double-click goes back, even after the drag's nudge", back, small)
    eq("and forgets the saved frame", cleared, nil)
    let (fallback, _) = WindowFill.toggle(frame: screen, visible: screen, saved: nil)
    check("filled with nothing saved still shrinks",
          fallback.w < screen.w && fallback.x >= screen.x && fallback.x + fallback.w <= screen.x + screen.w)
    check("a saved frame that also filled is not a way back",
          WindowFill.toggle(frame: screen, visible: screen, saved: screen).next != screen)
}

// MARK: - trimming a desk's MCP servers

do {
    eq("a TOML string list", TomlText.stringArray(#"["gmail", "chrome-devtools"]"#), ["gmail", "chrome-devtools"])
    eq("an empty one", TomlText.stringArray("[]"), [])
    eq("escapes inside", TomlText.stringArray(#"["a\"b"]"#), [#"a"b"#])
    eq("not a list", TomlText.stringArray(#""gmail""#), nil)
    eq("a bare word is not a string", TomlText.stringArray("[gmail]"), nil)
    eq("an unfinished string", TomlText.stringArray(#"["gmail]"#), nil)

    check("ordinary server names pass", McpTrim.validName("chrome-devtools") && McpTrim.validName("mcp_1.x"))
    check("a quote cannot reach the shell", !McpTrim.validName("x'; rm -rf ~; '"))
    check("nor a space", !McpTrim.validName("a b"))
    eq("settings switch off exactly the named servers, sorted, once",
       McpTrim.settingsJSON(off: ["gmail", "chrome-devtools", "gmail"]),
       #"{"disabledMcpjsonServers":["chrome-devtools","gmail"]}"#)
    eq("an unsafe name is dropped, not quoted", McpTrim.settingsJSON(off: ["bad'name", "gmail"]),
       #"{"disabledMcpjsonServers":["gmail"]}"#)
    eq("nothing off, no setting", McpTrim.settingsJSON(off: []), nil)

    let dir = NSTemporaryDirectory() + "coldfall-mcp-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? #"{"mcpServers":{"gmail":{"command":"x"},"mission-control":{"command":"node"},"bad name":{}}}"#
        .write(toFile: dir + "/.mcp.json", atomically: true, encoding: .utf8)
    eq("a desk can trim the servers in its folder's .mcp.json", McpTrim.servers(cwd: dir), ["gmail", "mission-control"])
    eq("a folder without one has none", McpTrim.servers(cwd: dir + "/nowhere"), [])

    var d = Desk(name: "golf", runtime: "claude", cwd: "/srv/demo")
    d.mcpOff = ["gmail", "chrome-devtools"]
    eq("a built-in desk starts Claude with them off", d.launchCommand(),
       #"claude -n golf --settings '{"disabledMcpjsonServers":["chrome-devtools","gmail"]}'"#)
    eq("and keeps them off when it resumes", d.launchCommand(claudeSession: "abc"),
       #"claude --resume abc --settings '{"disabledMcpjsonServers":["chrome-devtools","gmail"]}'"#)
    eq("an untrimmed desk is unchanged", Desk(name: "golf", runtime: "claude").launchCommand(), "claude -n golf")

    let f = dir + "/desks.toml"
    DeskConfig.write([d], to: f)
    eq("the choice survives a save", DeskConfig.load(path: f).first?.mcpOff, ["gmail", "chrome-devtools"])
    DeskConfig.write([Desk(name: "golf")], to: f)
    check("and an untrimmed desk writes no line for it",
          !((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").contains("mcp_off"))

    try? "#!/bin/sh\nexec claude \"$@\"\n".write(toFile: dir + "/plain", atomically: true, encoding: .utf8)
    try? "#!/bin/sh\nexec claude ${COLDFALL_CLAUDE_SETTINGS:+--settings \"$COLDFALL_CLAUDE_SETTINGS\"} \"$@\"\n"
        .write(toFile: dir + "/aware", atomically: true, encoding: .utf8)
    check("a script that ignores the setting is noticed", !McpTrim.commandHonors(dir + "/plain hub"))
    check("one that passes it on is too", McpTrim.commandHonors(dir + "/aware hub"))
    check("a command that is not a file cannot be vouched for", !McpTrim.commandHonors("claude --agent x"))
}

// MARK: - renaming a desk keeps its conversation

do {
    let root = NSTemporaryDirectory() + "coldfall-rename-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = Resume.claudeProjectDir(for: "/srv/demo", root: root)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let id = "3f2b8c1e-7a4d-4e5f-9b6c-1d2e3f4a5b6c"
    try? #"{"type":"custom-title","customTitle":"notes"}"#.write(toFile: dir + "/\(id).jsonl", atomically: true, encoding: .utf8)

    let before = Desk(name: "notes", runtime: "claude", cwd: "/srv/demo")
    eq("before, the desk finds its conversation by name",
       before.resumingLaunchCommand(claudeRoot: root), "claude --resume \(id)")
    let after = before.renamed(from: "notes", to: "journal", claudeRoot: root)
    eq("renaming remembers that conversation", after.session, id)
    eq("so the renamed desk still reopens it",
       after.resumingLaunchCommand(claudeRoot: root), "claude --resume \(id)")
    eq("a second rename keeps the same one",
       after.renamed(from: "journal", to: "diary", claudeRoot: root).session, id)
    eq("a desk with nothing to resume remembers nothing",
       Desk(name: "fresh", runtime: "claude", cwd: "/srv/demo").renamed(from: "fresh", to: "new", claudeRoot: root).session, nil)
    let scripted = Desk(name: "hub", runtime: "claude", cwd: "/srv/demo", command: "/srv/demo/desk hub")
    eq("a desk with its own command is left to it",
       scripted.renamed(from: "hub", to: "home", claudeRoot: root).session, nil)

    var gone = after
    gone.session = "00000000-0000-4000-8000-000000000000"
    eq("a remembered conversation that no longer exists falls back to the conversation's title",
       gone.resumingLaunchCommand(claudeRoot: root), "claude --resume \(id)")
    eq("renaming records the title the transcript carries", after.conversation, "notes")
    try? FileManager.default.removeItem(atPath: dir + "/\(id).jsonl")
    eq("with no such transcript either, a new conversation carries that title",
       gone.resumingLaunchCommand(claudeRoot: root), "claude -n notes")

    let f = root + "/desks.toml"
    DeskConfig.write([after], to: f)
    eq("the id survives a save", DeskConfig.load(path: f).first?.session, id)
    try? "[desk.x]\nruntime = \"claude\"\nsession = \"x'; rm -rf ~\"\n".write(toFile: f, atomically: true, encoding: .utf8)
    eq("anything but an id is ignored, never run", DeskConfig.load(path: f).first?.session, nil)
}

// MARK: - what a desk has

do {
    let root = NSTemporaryDirectory() + "coldfall-inv-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let home = root + "/home", cwd = root + "/srv/demo"
    let fm = FileManager.default
    func put(_ path: String, _ text: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    put(cwd + "/.mcp.json", #"{"mcpServers":{"mail":{"command":"/srv/demo/bin/mail-server"},"docs":{"type":"http","url":"https://docs.example.com/mcp"}}}"#)
    put(home + "/.claude.json", #"{"mcpServers":{"notes":{"command":"npx"}},"projects":{"\#(cwd)":{"mcpServers":{"trading":{"command":"node"}}}}}"#)
    put(cwd + "/.claude/skills/tax-notice/SKILL.md", "---\nname: tax-notice\ndescription: File a tax notice and log it.\n---\nbody")
    put(home + "/.claude/skills/synced/writing/SKILL.md", "---\nname: writing\ndescription: \"Plain writing.\"\n---\n")
    put(home + "/.claude/skills/not-a-skill/readme.txt", "x")
    put(cwd + "/.claude/settings.json", #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"python3 /srv/demo/hooks/brief.py --quiet"}]}]}}"#)
    let pdir = home + "/.claude/plugins/cache/market/helper/1.2.0"
    put(home + "/.claude/settings.json", #"{"enabledPlugins":{"helper@market":true,"off@market":false}}"#)
    put(home + "/.claude/plugins/installed_plugins.json",
        #"{"version":2,"plugins":{"helper@market":[{"installPath":"\#(pdir)","version":"1.2.0"}]}}"#)
    put(pdir + "/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship it.\n---\n")
    put(pdir + "/hooks/hooks.json", #"{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"node \"${CLAUDE_PLUGIN_ROOT}/hooks/telemetry.mjs\""}]}]}}"#)
    put(pdir + "/.mcp.json", #"{"mcpServers":{"helper":{"type":"http","url":"https://mcp.helper.dev"}}}"#)

    var desk = Desk(name: "demo", runtime: "claude", cwd: cwd)
    desk.mcpOff = ["mail"]
    let inv = Inventory.of(desk, home: home)
    let mcp = Dictionary(uniqueKeysWithValues: inv.mcp.map { ($0.name, $0) })
    eq("servers from the folder, you and plugins", Set(mcp.keys), ["mail", "docs", "notes", "trading", "helper"])
    eq("a local server says it runs on this Mac", mcp["mail"]?.detail, "runs mail-server on this Mac")
    eq("a remote one says where", mcp["docs"]?.detail, "remote, docs.example.com")
    eq("a trimmed server is marked off", mcp["mail"]?.off, true)
    eq("a server from a plugin says so", mcp["helper"]?.source, "plugin helper")
    eq("skills from the folder, you (synced too) and plugins",
       Set(inv.skills.map(\.name)), ["tax-notice", "writing", "deploy"])
    eq("a skill's description is its detail", inv.skills.first { $0.name == "tax-notice" }?.detail, "File a tax notice and log it.")
    eq("quotes around a description are dropped", inv.skills.first { $0.name == "writing" }?.detail, "Plain writing.")
    eq("only enabled plugins, with what they carry", inv.plugins.map(\.detail), ["v1.2.0: 1 skill, 1 hook, 1 MCP server"])
    let hooks = inv.hooks.map { "\($0.name) \($0.detail) \($0.source)" }.sorted()
    eq("hooks name their event and script, not the whole command", hooks,
       ["PostToolUse telemetry.mjs plugin helper", "SessionStart brief.py this folder"])
    check("claude.ai connectors are mentioned, not invented", inv.notes.contains { $0.contains("claude.ai connectors") })

    put(home + "/.codex/config.toml", "model = \"x\"\n[mcp_servers.search]\ncommand = \"s\"\n[mcp_servers.search.env]\nK = \"v\"\n")
    put(cwd + "/AGENTS.md", "rules")
    let cx = Inventory.of(Desk(name: "cx", runtime: "codex", cwd: cwd), home: home)
    eq("Codex servers from config.toml, once each", cx.mcp.map(\.name), ["search"])
    check("and it says Codex reads AGENTS.md", cx.notes.contains { $0.contains("AGENTS.md") })
    check("a shell desk has nothing, and says why",
          Inventory.of(Desk(name: "sh", runtime: "shell"), home: home).isEmpty)
    check("an empty home finds nothing and doesn't fail",
          Inventory.of(Desk(name: "x", runtime: "claude", cwd: root + "/none"), home: root + "/none").isEmpty)
}

// MARK: - install help for a first run with no vendor CLI

do {
    let names = VendorInstall.all.map(\.runtime)
    eq("each runtime appears once", names.count, Set(names).count)
    check("every install line is for a runtime Coldfall knows",
          names.allSatisfy { n in Bridge.known.contains { $0.name == n } })
    check("every command is a single pasteable line", VendorInstall.all.allSatisfy { !$0.command.contains("\n") })
    check("docs are https", VendorInstall.all.allSatisfy { $0.docs.hasPrefix("https://") })
    check("each says what it needs from you", VendorInstall.all.allSatisfy { !$0.needs.isEmpty })
    eq("lookup by runtime", VendorInstall.of("codex")?.command, "npm install -g @openai/codex")
    eq("no line for a vendor with no official CLI", VendorInstall.of("grok"), nil)
}

// MARK: - what changed since you last looked

do {
    let dir = NSTemporaryDirectory() + "coldfall-seen-\(UUID().uuidString)"
    let realRoot = InventorySeen.root
    InventorySeen.root = dir
    defer { InventorySeen.root = realRoot; try? FileManager.default.removeItem(atPath: dir) }

    var before = Inventory()
    before.mcp = [.init(name: "mail", detail: "runs mail on this Mac", source: "this folder")]
    before.plugins = [.init(name: "helper", detail: "v1.0.0: 1 skill", source: "helper@market")]
    before.hooks = [.init(name: "SessionStart", detail: "brief.py", source: "this folder")]
    before.skills = [.init(name: "old-skill", detail: "", source: "you, every folder")]

    eq("the first look is a baseline, not a list of everything", before.changes(since: nil).isEmpty, true)
    eq("nothing changed, nothing to say", before.changes(since: before.seen).isEmpty, true)

    var now = before
    now.plugins = [.init(name: "helper", detail: "v1.1.0: 1 skill, 2 hooks", source: "helper@market")]
    now.hooks.append(.init(name: "PostToolUse", detail: "telemetry.mjs", source: "plugin helper"))
    now.skills = []
    let c = now.changes(since: before.seen)
    eq("a new hook is new", c.added, [Inventory.key(kind: "hook", now.hooks[1])])
    eq("a plugin whose version moved is updated, with what it was",
       c.updated[Inventory.key(kind: "plugin", now.plugins[0])], "v1.0.0: 1 skill")
    eq("a skill that went away is listed as removed", c.removed, ["skill old-skill"])
    eq("the nudge counts new and updated, not removed", c.count, 2)
    eq("a hook's label names its script", Inventory.label(Inventory.key(kind: "hook", now.hooks[1])),
       "hook PostToolUse (telemetry.mjs)")

    eq("nothing saved for a desk yet", InventorySeen.load("golf"), nil)
    InventorySeen.save("golf", now.seen)
    eq("what was seen comes back", InventorySeen.load("golf"), now.seen)
}

// MARK: - trimming a Codex desk's MCP servers

do {
    let root = NSTemporaryDirectory() + "coldfall-cxmcp-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    try? FileManager.default.createDirectory(atPath: root + "/.codex", withIntermediateDirectories: true)
    try? "[mcp_servers.search]\ncommand = \"s\"\n[mcp_servers.browser]\ncommand = \"b\"\n"
        .write(toFile: root + "/.codex/config.toml", atomically: true, encoding: .utf8)
    var d = Desk(name: "cx", runtime: "codex", cwd: "/srv/demo")
    eq("a Codex desk can trim the servers in config.toml", McpTrim.servers(for: d, home: root), ["browser", "search"])
    d.mcpOff = ["search"]
    eq("a trimmed Codex desk starts with that one off",
       d.launchCommand(), "codex -c 'mcp_servers.search.enabled=false'")
    eq("and keeps it off when it resumes",
       d.launchCommand(resumeLast: true), "codex resume --last -c 'mcp_servers.search.enabled=false'")
    d.mcpOff = ["x'; rm -rf ~"]
    eq("an unsafe name never reaches the shell", d.launchCommand(), "codex")
    eq("vendors without a checked way have nothing to trim",
       McpTrim.servers(for: Desk(name: "g", runtime: "antigravity"), home: root), [])
}

// MARK: - hiding a desk

do {
    var list = (1...11).map { Desk(name: "d\($0)") }
    list[1].hidden = true
    list[4].hidden = true
    eq("cmd-1..9 skip hidden desks", DeskOrder.shortcuts(list), [0, 2, 3, 5, 6, 7, 8, 9, 10])
    eq("and never go past nine", DeskOrder.shortcuts((1...12).map { Desk(name: "x\($0)") }).count, 9)

    let f = NSTemporaryDirectory() + "coldfall-hidden-\(UUID().uuidString).toml"
    defer { try? FileManager.default.removeItem(atPath: f) }
    var h = Desk(name: "golf", runtime: "claude", cwd: "/srv/demo")
    h.hidden = true
    DeskConfig.write([h, Desk(name: "hub", runtime: "claude")], to: f)
    let back = DeskConfig.load(path: f)
    eq("a hidden desk stays hidden across a save", back.first { $0.name == "golf" }?.hidden, true)
    eq("and keeps everything else", back.first { $0.name == "golf" }?.cwd, "/srv/demo")
    check("a shown desk writes no hidden line",
          !((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").contains("[desk.hub]\nruntime = \"claude\"\nhidden"))
    eq("a shown desk loads as shown", back.first { $0.name == "hub" }?.hidden, false)
}

// MARK: - keeping active groups on top

do {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    var list = [Desk(name: "hub"),
                Desk(name: "cpa", group: "money"), Desk(name: "market", group: "money"),
                Desk(name: "work", group: "work"),
                Desk(name: "golf", group: "personal"), Desk(name: "garage", group: "personal"),
                Desk(name: "mba", group: "school")]
    let g = { (o: [String?]) in o.map { $0 ?? "-" } }
    eq("nothing going on keeps your order", g(DeskOrder.liveGroups(list, waiting: [:], used: [:])),
       ["-", "money", "work", "personal", "school"])
    eq("the most recently used group rises",
       g(DeskOrder.liveGroups(list, waiting: [:], used: ["golf": t0, "cpa": t0.addingTimeInterval(-600)])),
       ["-", "personal", "money", "work", "school"])
    eq("a group that needs you beats one merely used",
       g(DeskOrder.liveGroups(list, waiting: ["mba": t0.addingTimeInterval(-60)], used: ["golf": t0])),
       ["-", "school", "personal", "money", "work"])
    eq("among waiting groups, the oldest wait first",
       g(DeskOrder.liveGroups(list, waiting: ["mba": t0, "work": t0.addingTimeInterval(-300)], used: [:])),
       ["-", "work", "school", "money", "personal"])
    eq("any desk in a group counts for the group",
       g(DeskOrder.liveGroups(list, waiting: [:], used: ["market": t0])).dropFirst().first, "money")
    list[6].hidden = true
    eq("a hidden desk counts for nothing",
       g(DeskOrder.liveGroups(list, waiting: ["mba": t0], used: [:])),
       ["-", "money", "work", "personal", "school"])
    check("ungrouped desks always stay on top",
          DeskOrder.liveGroups(list, waiting: ["cpa": t0], used: ["golf": t0]).first! == nil)
}

// MARK: - nothing from desks.toml runs as a command

do {
    eq("a plain word passes through", Shell.quote("golf"), "golf")
    eq("a path passes through", Shell.quote("/srv/demo/app-1.2"), "/srv/demo/app-1.2")
    eq("a space is quoted", Shell.quote("/srv/my app"), "'/srv/my app'")
    eq("a command separator is quoted", Shell.quote("x; rm -rf ~"), "'x; rm -rf ~'")
    eq("command substitution is quoted", Shell.quote("$(touch /tmp/owned)"), "'$(touch /tmp/owned)'")
    eq("a quote inside is closed, escaped and reopened", Shell.quote("it's"), #"'it'\''s'"#)
    eq("a newline stays inside the quotes", Shell.quote("a\nb"), "'a\nb'")
    eq("empty is still one word", Shell.quote(""), "''")
    let evil = Desk(name: "x; touch /tmp/owned", agent: "a$(id)", runtime: "claude")
    eq("a hostile name and agent are quoted in the launch line", evil.launchCommand(),
       "claude --agent 'a$(id)' -n 'x; touch /tmp/owned'")
    eq("a hostile model too", Desk(name: "m", runtime: "ollama", model: "llama3; id").launchCommand(),
       "ollama run 'llama3; id'")
    eq("and an unknown runtime", Desk(name: "u", runtime: "tool;id").launchCommand(), "'tool;id'")
    eq("a desk's own command is still run as written",
       Desk(name: "s", runtime: "shell", command: "exec zsh -l").launchCommand(), "exec zsh -l")

    let me = ProcessTree.startTime(getpid())
    check("this process has a start time", me != nil)
    eq("and it holds still", ProcessTree.startTime(getpid()), me)
    eq("a pid that doesn't exist has none", ProcessTree.startTime(999_999), nil)
}

// MARK: - config files too big to be real are skipped

do {
    let dir = NSTemporaryDirectory() + "coldfall-big-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let pad = String(repeating: " ", count: 2_100_000)
    try? ("{\"mcpServers\":{\"x\":{}}}" + pad).write(toFile: dir + "/.mcp.json", atomically: true, encoding: .utf8)
    eq("an oversized .mcp.json is not read", McpTrim.servers(cwd: dir), [])
    try? "{\"mcpServers\":{\"x\":{}}}".write(toFile: dir + "/.mcp.json", atomically: true, encoding: .utf8)
    eq("a normal one is", McpTrim.servers(cwd: dir), ["x"])
}

// MARK: - desks.toml edited by someone else

do {
    let ws = "/srv/demo/ws"
    let before = [Desk(name: "hub", runtime: "claude", cwd: ws, command: "/srv/demo/ws/scripts/desk hub"),
                  Desk(name: "garage", runtime: "claude", cwd: ws, command: "/srv/demo/ws/scripts/desk garage", group: "personal"),
                  Desk(name: "golf", runtime: "claude", cwd: ws, command: "/srv/demo/ws/scripts/desk golf", group: "personal")]
    var after = before
    after[1] = Desk(name: "cars", runtime: "claude", cwd: ws, command: "/srv/demo/ws/scripts/desk cars", group: "personal")
    eq("a rename on disk is recognised, command and all", DeskSync.renames(from: before, to: after), ["garage": "cars"])
    eq("nothing renamed, nothing to say", DeskSync.renames(from: before, to: before), [:])
    var removedAdded = before
    removedAdded[1] = Desk(name: "cars", runtime: "codex", cwd: ws)
    eq("a different desk in its place is not a rename", DeskSync.renames(from: before, to: removedAdded), [:])
    let plainBefore = [Desk(name: "notes", runtime: "claude", cwd: "/srv/demo")]
    let plainAfter = [Desk(name: "journal", runtime: "claude", cwd: "/srv/demo")]
    eq("a built-in desk renamed on disk", DeskSync.renames(from: plainBefore, to: plainAfter), ["notes": "journal"])
    let twoGone = [Desk(name: "a", runtime: "claude", cwd: "/srv/demo"), Desk(name: "b", runtime: "claude", cwd: "/srv/demo")]
    let oneNew = [Desk(name: "c", runtime: "claude", cwd: "/srv/demo")]
    eq("an ambiguous change is read as removal and addition", DeskSync.renames(from: twoGone, to: oneNew), [:])
    eq("a whole word is swapped", DeskSync.swapWord("scripts/desk garage --x", "garage", "cars"), "scripts/desk cars --x")
    eq("part of a word is not", DeskSync.swapWord("scripts/garages/desk", "garage", "cars"), "scripts/garages/desk")

    let f = NSTemporaryDirectory() + "coldfall-sync-\(UUID().uuidString).toml"
    defer { try? FileManager.default.removeItem(atPath: f) }
    eq("no file, no snapshot", DeskSync.snapshot(f), nil)
    DeskConfig.write(before, to: f)
    let snap = DeskSync.snapshot(f)
    check("a snapshot is what's on disk", snap?.contains("[desk.garage]") == true)
    DeskConfig.write(after, to: f)
    check("and tells an edit apart", DeskSync.snapshot(f) != snap)
}

// MARK: - noticing desks.toml change on disk

do {
    let dir = NSTemporaryDirectory() + "coldfall-watch-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let f = dir + "/desks.toml"
    try? "[desk.garage]\n".write(toFile: f, atomically: false, encoding: .utf8)
    var hits = 0
    let w = DeskConfigWatcher(path: f)
    w.onChange = { hits += 1 }
    w.start()
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.8)) }
    settle(); let quiet = hits
    // An editor's save: a new file renamed over the old one.
    try? "[desk.cars]\n".write(toFile: f, atomically: true, encoding: .utf8)
    settle()
    check("a replaced file is noticed", hits > quiet)
    let afterReplace = hits
    // And then an edit in place, to the file that replaced it.
    if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(Data("[desk.golf]\n".utf8)); try? h.close() }
    settle()
    check("an edit in place after a replace is noticed too", hits > afterReplace)
}

// MARK: - Antigravity

do {
    let root = NSTemporaryDirectory() + "coldfall-agy-\(UUID().uuidString)"
    let home = root + "/home", cwd = root + "/work"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: home + "/.gemini/config", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: cwd + "/.agents", withIntermediateDirectories: true)
    try? #"{"mcpServers":{"docs":{"serverUrl":"https://mcp.example.com/sse"}}}"#
        .write(toFile: home + "/.gemini/config/mcp_config.json", atomically: true, encoding: .utf8)
    try? #"{"mcpServers":{"local":{"command":"node"}}}"#
        .write(toFile: cwd + "/.agents/mcp_config.json", atomically: true, encoding: .utf8)
    let inv = Inventory.of(Desk(name: "g", runtime: "antigravity", cwd: cwd), home: home)
    eq("antigravity: reads the folder's and the global MCP config", inv.mcp.map(\.name), ["local", "docs"])
    eq("antigravity: a serverUrl server is remote", inv.mcp.last?.detail, "remote, mcp.example.com")
    eq("antigravity: launches agy", Desk(name: "g", runtime: "antigravity").launchCommand(), "agy")
    check("antigravity: Coldfall knows its binary", Bridge.runtime(named: "antigravity")?.bin == "agy")
    check("antigravity: has install help", VendorInstall.of("antigravity") != nil)
    try? #"{"projects":{"\#(cwd)":"work"}}"#.write(toFile: root + "/projects.json", atomically: true, encoding: .utf8)
    check("antigravity: a folder it has worked in resumes", Resume.antigravityHasProject(cwd: cwd, file: root + "/projects.json"))
    check("antigravity: another folder doesn't", !Resume.antigravityHasProject(cwd: root, file: root + "/projects.json"))
    eq("antigravity: resume is --continue",
       Desk(name: "g", runtime: "antigravity", cwd: cwd).resumingLaunchCommand(agyProjects: root + "/projects.json"), "agy --continue")
    eq("antigravity: a first start is plain agy",
       Desk(name: "g", runtime: "antigravity", cwd: root).resumingLaunchCommand(agyProjects: root + "/projects.json"), "agy")
    eq("antigravity: short name", AgentOffer.shortName("antigravity"), "Antigravity")
    try? fm.removeItem(atPath: root)
}

// MARK: - review fixes: desks.toml round trips

do {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() + "coldfall-rt-\(UUID().uuidString).toml"
    defer { try? fm.removeItem(atPath: tmp) }

    // a budget that would have trapped Int() on save
    for bad in ["1e300", "inf", "$1e999", "-5", "0", "nan", "abc"] {
        eq("budget: \(bad) is not a budget", DeskBudget.parse(bad), nil)
    }
    eq("budget: with a comma", DeskBudget.parse("1,250.50"), 1250.5)
    eq("budget: written as a whole number", DeskBudget.text(50), "50")
    eq("budget: or with its decimals", DeskBudget.text(12.5), "12.5")
    try? "[desk.x]\nruntime = \"claude\"\nbudget = 1e300\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    let absurd = DeskConfig.load(path: tmp)
    eq("budget: an absurd value in the file is dropped, not crashed on", absurd.first?.budget, nil)
    DeskConfig.write(absurd, to: tmp)          // used to trap here
    check("budget: and the save goes through", fm.fileExists(atPath: tmp))

    // CRLF, a multi-line array, \u escapes, agent kept beside a command
    let crlf = "[desk.win]\r\nruntime = \"claude\"\r\ngroup = \"caf\\u00e9\"\r\nmcp_off = [\r\n  \"gmail\",\r\n  \"drive\"\r\n]\r\nagent = \"backend\"\r\ncommand = \"/srv/demo/wrap\"\r\n"
    try? crlf.write(toFile: tmp, atomically: true, encoding: .utf8)
    let win = DeskConfig.load(path: tmp).first
    eq("toml: CRLF leaves the name clean", win?.name, "win")
    eq("toml: and the runtime", win?.runtime, "claude")
    eq("toml: \\u escapes read as the character", win?.group, "café")
    eq("toml: an array across lines is read whole", win?.mcpOff ?? [], ["gmail", "drive"])
    DeskConfig.write(DeskConfig.load(path: tmp), to: tmp)
    let again = DeskConfig.load(path: tmp).first
    eq("toml: the array survives a save", again?.mcpOff ?? [], ["gmail", "drive"])
    eq("toml: the group survives a save", again?.group, "café")
    eq("toml: agent is kept beside a command", again?.agent, "backend")

    // a desk table the loader can't read is kept, not deleted
    try? "[desk.ok]\nruntime = \"claude\"\n\n[desk.\"my.desk\"]\nruntime = \"codex\"\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    eq("toml: a quoted key isn't a desk this version reads", DeskConfig.load(path: tmp).count, 1)
    DeskConfig.write(DeskConfig.load(path: tmp), to: tmp)
    check("toml: but it is still in the file after a save",
          (try? String(contentsOfFile: tmp, encoding: .utf8))?.contains("[desk.\"my.desk\"]") == true)
    eq("toml: a header this loader reads", DeskConfig.deskName(header: "[desk.api]"), "api")
    eq("toml: one it doesn't", DeskConfig.deskName(header: "[desk.a.b]"), nil)
}

// MARK: - review fixes: resume matches the record, not the text

do {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "coldfall-needle-\(UUID().uuidString)"
    let dir = Resume.claudeProjectDir(for: "/srv/demo", root: root)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let real = "11111111-1111-4111-8111-111111111111", fake = "22222222-2222-4222-8222-222222222222"
    try? #"{"type":"custom-title","customTitle":"money","sessionId":"x"}"#.write(toFile: dir + "/\(real).jsonl", atomically: true, encoding: .utf8)
    // a NEWER session that merely contains the text of such a record
    try? #"{"type":"user","message":{"content":"paste: {\"type\":\"custom-title\",\"customTitle\":\"money\"} end"}}"#
        .write(toFile: dir + "/\(fake).jsonl", atomically: true, encoding: .utf8)
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: dir + "/\(fake).jsonl")
    eq("resume: a transcript that only mentions the title is not it", Resume.claudeSession(named: "money", cwd: "/srv/demo", root: root), real)
    try? fm.removeItem(atPath: root)
}

// MARK: - review fixes: the tail of a big transcript

do {
    let fm = FileManager.default
    let path = NSTemporaryDirectory() + "coldfall-tail-\(UUID().uuidString).jsonl"
    // 600K of lines full of multi-byte characters, then the usage record
    var lines: [String] = []
    while lines.reduce(0, { $0 + $1.utf8.count }) < 700_000 {
        lines.append(#"{"type":"user","message":{"content":"— ’ café — ’ café — ’ café — ’ café — ’ café —"}}"#)
    }
    lines.append(#"{"timestamp":"2026-09-22T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":2000,"cache_read_input_tokens":600000,"output_tokens":400}}}"#)
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    var ok = 0
    // whatever byte the 512K window lands on, the last turn is found
    for tail in [512 * 1024, 512 * 1024 + 1, 512 * 1024 + 2, 512 * 1024 + 3, 100_000] {
        if Reopen.lastContext(path, tail: tail) == 602_003 { ok += 1 }
    }
    eq("tail: found from any cut point", ok, 5)
    // the record is further back than the tail: read further, once
    lines.append(contentsOf: Array(repeating: #"{"type":"user","message":{"content":"\#(String(repeating: "z", count: 2000))"}}"#, count: 400))
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    eq("tail: a huge trailing tool result doesn't hide the last turn", Reopen.lastContext(path, tail: 64 * 1024), 602_003)
    try? fm.removeItem(atPath: path)
}

// MARK: - review fixes: subagents count too

do {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "coldfall-sub-\(UUID().uuidString)"
    let proj = root + "/-srv-demo"
    let sid = "33333333-3333-4333-8333-333333333333"
    try? fm.createDirectory(atPath: proj + "/\(sid)/subagents", withIntermediateDirectories: true)
    let when = "2026-09-22T10:00:00.000Z"
    func turn(_ id: String, _ read: Int) -> String {
        #"{"timestamp":"\#(when)","message":{"id":"\#(id)","model":"claude-opus-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(read),"output_tokens":100}}}"#
    }
    try? ([#"{"type":"custom-title","customTitle":"cf","sessionId":"x"}"#, turn("p1", 1000)].joined(separator: "\n"))
        .write(toFile: proj + "/\(sid).jsonl", atomically: true, encoding: .utf8)
    try? ([turn("s1", 5000), turn("s2", 5000)].joined(separator: "\n"))
        .write(toFile: proj + "/\(sid)/subagents/agent-a1.jsonl", atomically: true, encoding: .utf8)
    let list = Usage.transcripts(in: proj)
    eq("subagents: the session and its subagent are both found", list.count, 2)
    eq("subagents: the subagent knows its parent", list.first { $0.parent != nil }?.parent, proj + "/\(sid).jsonl")
    var cache: [String: String?] = [:]
    eq("subagents: the parent's title is read without parsing it", Usage.title(ofTranscript: proj + "/\(sid).jsonl", cache: &cache), "cf")
    let wasCache = TokenomicsCache.root; TokenomicsCache.root = root + "/cache"
    let t = Tokenomics.scan(since: Date(timeIntervalSince1970: 0), root: root)
    TokenomicsCache.clear(); TokenomicsCache.root = wasCache
    eq("subagents: their turns are counted under the desk that ran them", t.byDesk["cf"]?.turns, 3)
    eq("subagents: and in the total", t.all.turns, 3)
    let wasU = UsageCache.root; UsageCache.root = root + "/ucache"
    let r = Usage.scan(since: Date(timeIntervalSince1970: 0), claudeRoot: root)
    UsageCache.clear(); UsageCache.root = wasU
    eq("subagents: the usage report agrees", r.byDesk["cf"]?.calls, 3)
    try? fm.removeItem(atPath: root)
}

// MARK: - review fixes: what picking up really costs

do {
    let c = ConversationInfo(path: "/x", tokens: 600_000, lastUsed: Date().addingTimeInterval(-3 * 86_400), model: "claude-opus-5-5")
    check("reopen: the rebuild is priced as a one-hour cache write", abs(c.rebuildUsd - 4.80) < 0.001)
    check("reopen: a warm turn as a cache read at that model's rate", abs(c.warmUsd - 0.12) < 0.001)
    let q = Reopen.question(desk: Desk(name: "cf", runtime: "claude"), c, wrappedAt: nil)
    check("reopen: the question says both numbers", q.body.contains("costs about $4.80") && q.body.contains("costs about $0.12"))
    check("reopen: and no longer says twice", !q.body.contains("twice"))
    let fable = ConversationInfo(path: "/x", tokens: 600_000, lastUsed: Date(), model: "claude-fable-5-1")
    check("reopen: on Fable the gap is 80x", abs(fable.rebuildUsd / fable.warmUsd - 80) < 0.01)
    eq("reopen: small amounts keep their cents", Reopen.usd(0.12), "$0.12")
    eq("reopen: big ones don't", Reopen.usd(12.4), "$12")

    // a cheap week that is really write-heavy no longer gets "nothing to change"
    var w = Tokenomics(); var s = Tokenomics.DeskStats()
    s.turns = 100; s.fresh = 0; s.cacheWrite = 290_000; s.cacheRead = 710_000; s.output = 1000; s.byModel = ["sonnet": 1]
    w.all = s; w.byDesk = ["x": s]
    check("advice: a write-heavy week is not called cheap", !w.notes().contains { $0.advice.contains("Nothing to change") })

    // budget: spent rounds down, so $49.60 never reads as $50 of $50
    eq("budget: label rounds spent down", DeskBudget.label(.near(spent: 49.6, budget: 50)), "$49 of $50 this week")
}

// MARK: - review fixes: quoting, pricing, the release URL

do {
    eq("quote: a leading = is quoted, zsh would expand it", Shell.quote("=ls"), "'=ls'")
    eq("quote: a plain path is left alone", Shell.quote("/srv/demo/x"), "/srv/demo/x")
    check("quote: a discovered Codex profile is quoted",
          Discovery.desk(from: DiscoveredAgent(name: "x; rm -rf ~", runtime: "codex", description: nil, model: nil, path: "/srv/demo/p", isProjectLevel: false), cwd: "/srv/demo").command == "codex -p 'x; rm -rf ~'")
    check("quote: an ssh alias is quoted", SSHHost(alias: "box;id", hostName: nil, user: nil, port: nil).command == "ssh -t 'box;id'")
    eq("price: an unknown haiku is priced as haiku", Pricing.model("claude-haiku-5").input, 1)
    eq("price: an unknown sonnet as sonnet", Pricing.model("claude-sonnet-6").input, 2)
    eq("price: anything else as opus", Pricing.model("claude-something").input, 5)
    eq("url: a release page passes", UpdateCheck.releaseURL("https://github.com/anthonyproctor/project-coldfall/releases/tag/v1"), "https://github.com/anthonyproctor/project-coldfall/releases/tag/v1")
    eq("url: a file: URL saved in update.json does not", UpdateCheck.releaseURL("file:///etc/passwd"), nil)
    eq("url: nor another host", UpdateCheck.releaseURL("https://github.com.evil/anthonyproctor/project-coldfall/"), nil)
}

// MARK: - review fixes: the limits recorder

do {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "coldfall-rec-\(UUID().uuidString)"
    let home = root + "/home"
    try? fm.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: true)
    let wasCfg = Limits.configDir
    Limits.configDir = root + "/config"
    defer { Limits.configDir = wasCfg; try? fm.removeItem(atPath: root) }
    let acct = ClaudeAccount(folder: home + "/.claude-work", home: home)!
    let settings = home + "/.claude-work/settings.json"
    // their own statusline, with the characters that used to break the script
    try? #"{"statusLine":{"type":"command","command":"~/bin/mine \"$@\" 'q' `date`"},"model":"opus"}"#
        .write(toFile: settings, atomically: true, encoding: .utf8)
    _ = Limits.installRecorder(for: acct)
    let script = root + "/config/statusline-recorder-work.sh"
    let text = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
    check("recorder: the wrapped command is single-quoted", text.contains("WRAPPED='~/bin/mine \"$@\" '\\''q'\\'' `date`'"))
    eq("recorder: and read back exactly", Uninstall.wrappedStatusline(recorder: script), "~/bin/mine \"$@\" 'q' `date`")
    // pressing the button again keeps it
    _ = Limits.installRecorder(for: acct)
    eq("recorder: a second install still wraps it", Uninstall.wrappedStatusline(recorder: script), "~/bin/mine \"$@\" 'q' `date`")
    eq("recorder: the old double-quoted form still reads", Uninstall.unquoteFromRecorder("\"~/bin/old\""), "~/bin/old")
    check("recorder: the desk file name is sanitised in the script", text.contains("tr -c 'A-Za-z0-9._ -' '_'") && text.contains("sed -e 's/"))
    check("recorder: reading a desk's state refuses a path", DeskState.load("../x") == nil && DeskState.load("a/b") == nil)

    // run the script for real: a hostile session name stays inside the folder
    if fm.isExecutableFile(atPath: "/usr/bin/jq") || fm.isExecutableFile(atPath: "/opt/homebrew/bin/jq") || fm.isExecutableFile(atPath: "/usr/local/bin/jq") {
        let fakeHome = root + "/fakehome"
        try? fm.createDirectory(atPath: fakeHome + "/.claude", withIntermediateDirectories: true)
        try? "{\"keep\":true}".write(toFile: fakeHome + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = fakeHome
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let stdin = Pipe(); p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        stdin.fileHandleForWriting.write(#"{"session_name":"../../.claude/settings","context_window":{"used_percentage":40}}"#.data(using: .utf8)!)
        try? stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        eq("recorder: a path in the session name cannot leave the sessions folder",
           (try? String(contentsOfFile: fakeHome + "/.claude/settings.json", encoding: .utf8)), "{\"keep\":true}")
        let written = (try? fm.contentsOfDirectory(atPath: fakeHome + "/.local/share/coldfall/sessions")) ?? []
        let limitsDir = (try? fm.contentsOfDirectory(atPath: fakeHome + "/.local/share/coldfall/limits")) ?? []
        check("recorder: it wrote a plainly named file instead", written == ["claude_settings.json"],
              "got \(written), exit \(p.terminationStatus), limits: \(limitsDir)")
    }
}

// MARK: - desk budgets

do {
    eq("budget: none set, nothing to say", DeskBudget.status(spent: 90, budget: nil), .unset)
    eq("budget: well under", DeskBudget.status(spent: 20, budget: 50), .ok(spent: 20, budget: 50))
    eq("budget: close at 80%", DeskBudget.status(spent: 40, budget: 50), .near(spent: 40, budget: 50))
    eq("budget: over", DeskBudget.status(spent: 62, budget: 50), .over(spent: 62, budget: 50))
    eq("budget: nothing spent yet is fine", DeskBudget.status(spent: nil, budget: 50), .ok(spent: 0, budget: 50))
    eq("budget: said in full", DeskBudget.label(.near(spent: 46.2, budget: 50)), "$46 of $50 this week")
    eq("budget: short for the rail", DeskBudget.short(.over(spent: 62, budget: 50)), "$62/$50")
    eq("budget: quiet in the rail while well under", DeskBudget.short(.ok(spent: 10, budget: 50)), nil)

    // spend is found under the conversation's title
    var r = Usage.Report()
    var b = Usage.Bucket(); b.usd = 47; r.byDesk["money"] = b
    var cpa = Desk(name: "cpa", runtime: "claude", command: "desk money"); cpa.conversation = "money"; cpa.budget = 50
    eq("budget: a desk's spend, under its conversation's title", DeskBudget.spent(by: cpa, in: r), 47)

    // desks.toml keeps it, and takes "$50" too
    let tmp = NSTemporaryDirectory() + "coldfall-budget-\(UUID().uuidString).toml"
    DeskConfig.write([cpa], to: tmp)
    eq("budget: saved and read back", DeskConfig.load(path: tmp).first?.budget, 50)
    try? "[desk.x]\nruntime = \"claude\"\nbudget = \"$75\"\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    eq("budget: a dollar sign is fine", DeskConfig.load(path: tmp).first?.budget, 75)
    try? "[desk.x]\nruntime = \"claude\"\nbudget = 0\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    eq("budget: zero means none", DeskConfig.load(path: tmp).first?.budget, nil)
    try? FileManager.default.removeItem(atPath: tmp)
}

// MARK: - launch, and more shells

do {
    var hidden = Desk(name: "old", runtime: "claude"); hidden.hidden = true
    let desks = [Desk(name: "shell", runtime: "shell"), Desk(name: "hub", runtime: "claude", isDefault: true),
                 Desk(name: "cf", runtime: "claude"), hidden]
    eq("launch: opens the desk you were on", DeskConfig.startup(in: desks, last: "cf"), 2)
    eq("launch: or the default, the first time", DeskConfig.startup(in: desks, last: nil), 1)
    eq("launch: or when that desk is gone", DeskConfig.startup(in: desks, last: "removed"), 1)
    eq("launch: or hidden", DeskConfig.startup(in: desks, last: "old"), 1)

    let s2 = DeskConfig.newShellDesk(in: desks, cwd: "/srv/demo")
    eq("shell: the next free name", s2.name, "shell-2")
    eq("shell: a plain shell", s2.launchCommand(), "exec $SHELL -l")
    eq("shell: in the folder asked for", s2.cwd, "/srv/demo")
    let s3 = DeskConfig.newShellDesk(in: desks + [s2], cwd: nil)
    eq("shell: and the one after", s3.name, "shell-3")
    eq("shell: the first one is just shell", DeskConfig.newShellDesk(in: [], cwd: nil).name, "shell")
    // saved and read back as a shell, not guessed as an agent
    let tmp = NSTemporaryDirectory() + "coldfall-shells-\(UUID().uuidString).toml"
    DeskConfig.write([s2], to: tmp)
    eq("shell: stays a shell in desks.toml", DeskConfig.load(path: tmp).first?.runtime, "shell")
    try? FileManager.default.removeItem(atPath: tmp)
}

// MARK: - agents that updated

do {
    eq("version: Claude Code's", AgentVersions.parse("2.1.280 (Claude Code)"), "2.1.280")
    eq("version: Codex's", AgentVersions.parse("codex-cli 0.155.1"), "0.155.1")
    eq("version: Copilot's, with a trailing period", AgentVersions.parse("GitHub Copilot CLI 1.0.87.\nRun 'copilot update'"), "1.0.87")
    eq("version: a v prefix", AgentVersions.parse("ollama version is v0.12.3"), "0.12.3")
    eq("version: nothing that looks like one", AgentVersions.parse("usage: agy [options]"), nil)

    let changes = AgentVersions.changes(from: ["claude": "2.1.279", "codex": "0.155.1"],
                                        to: ["claude": "2.1.280", "codex": "0.155.1", "copilot": "1.0.87"])
    eq("updates: only what changed", changes.map(\.runtime), ["claude"])
    eq("updates: said plainly", changes.first?.line, "Claude Code updated to 2.1.280")
    eq("updates: with the old version in the detail", changes.first?.detail, "Claude Code went from 2.1.279 to 2.1.280.")
    eq("updates: with the vendor's own notes", changes.first?.url, "https://code.claude.com/docs/en/changelog")
    check("updates: an agent seen for the first time is not news", !changes.contains { $0.runtime == "copilot" })

    // A CLI that prints its version, then leaves something running in the
    // background holding its output open. With a pipe this never returned.
    let dir = NSTemporaryDirectory() + "coldfall-ver-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let cli = dir + "/fakeagent"
    try? "#!/bin/sh\necho 'fakeagent 3.4.5'\n( sleep 20 ) &\nexit 0\n".write(toFile: cli, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    let started = Date()
    eq("version: read even when the CLI leaves a process behind", AgentVersions.version(of: cli), "3.4.5")
    check("version: and without waiting for that process", Date().timeIntervalSince(started) < 5)
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - what's filling the conversations

do {
    let when = "2026-09-22T10:00:00.000Z"
    let lines = [
        #"{"type":"custom-title","customTitle":"cf"}"#,
        #"{"timestamp":"\#(when)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash"},{"type":"tool_use","id":"t2","name":"Read"},{"type":"tool_use","id":"t3","name":"Task"},{"type":"tool_use","id":"t4","name":"mcp__chrome-devtools__take_screenshot"}]}}"#,
        #"{"timestamp":"\#(when)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(String(repeating: "x", count: 40_000))"},{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"\#(String(repeating: "y", count: 4000))"}]},{"type":"tool_result","tool_use_id":"t4","content":[{"type":"image","source":{"data":"\#(String(repeating: "z", count: 900_000))"}}]}]}}"#,
    ]
    var t = Tokenomics()
    Tokenomics.read(lines.joined(separator: "\n"), since: Date(timeIntervalSince1970: 0), into: &t)
    let cf = t.byDesk["cf"]
    eq("contents: command output, at four characters a token", cf?.toolTokens["command output"], 10_000)
    eq("contents: file reads", cf?.toolTokens["file reads"], 1_000)
    eq("contents: a screenshot is an image, not its bytes", cf?.toolTokens["browser automation"], Tokenomics.imageTokens)
    eq("contents: images counted", cf?.images, 1)
    eq("contents: subagent jobs counted", cf?.subagents, 1)

    var week = Tokenomics()
    var s = Tokenomics.DeskStats()
    s.turns = 100; s.cacheRead = 9_000_000; s.cacheWrite = 100_000; s.output = 10_000
    s.byModel = ["sonnet": 1]; s.toolTokens = ["command output": 700_000, "file reads": 300_000]
    s.images = 150; s.subagents = 0
    week.all = s; week.byDesk = ["cf": s]
    let notes = week.notes()
    let c = notes.first { $0.kind == .contents }
    check("contents: names the desk and what filled it",
          c?.finding.contains("cf's conversation took in about 1.0M") == true && c?.finding.contains("command output") == true)
    check("contents: suggests a subagent", c?.advice.contains("subagent") == true)
    check("contents: and says it didn't use one", c?.advice.contains("didn't use a subagent once") == true)
    check("contents: an estimate, not a measurement", c?.measured == false)
    check("contents: many screenshots get their own note", notes.contains { $0.kind == .images && $0.finding.contains("150 images") })
}

// MARK: - prices

do {
    // The official table, checked 2026-09-23.
    let opus55 = Pricing.model("claude-opus-5-5")
    eq("price: Opus 5.5 input", opus55.input, 4)
    eq("price: Opus 5.5 reads cache at a twentieth", opus55.cacheRead, 0.05)
    eq("price: Fable 5.1 reads cache at a fortieth", Pricing.model("claude-fable-5-1").cacheRead, 0.025)
    eq("price: Opus 5 at the standard tenth", Pricing.model("claude-opus-5").cacheRead, 0.1)
    eq("price: Sonnet 5 stays $2 in", Pricing.model("claude-sonnet-5").input, 2)
    eq("price: a dated id finds its model", Pricing.model("claude-opus-5-5-20260922").input, 4)
    // a million tokens read from cache on each
    check("price: a million cached tokens on Opus 5.5 is $0.20",
          abs(Pricing.cost(model: "claude-opus-5-5", fresh: 0, read: 1_000_000, write: 0, output: 0) - 0.20) < 1e-9)
    check("price: and $0.25 on Fable 5.1",
          abs(Pricing.cost(model: "claude-fable-5-1", fresh: 0, read: 1_000_000, write: 0, output: 0) - 0.25) < 1e-9)
    // a cache write, split and unsplit
    check("price: an unsplit write is priced as the one-hour cache Claude Code uses",
          abs(Pricing.writeCost(model: "claude-opus-5", write: 1_000_000) - 10) < 1e-9)
    check("price: a recorded split is priced by its parts",
          abs(Pricing.writeCost(model: "claude-opus-5", write: 1_000_000, write5m: 500_000, write1h: 500_000)
              - (0.5 * 1.25 * 5 + 0.5 * 2 * 5)) < 1e-9)
    let split = Pricing.writeSplit(["cache_creation": ["ephemeral_5m_input_tokens": 10, "ephemeral_1h_input_tokens": 90]])
    check("price: the split is read from the record", split.0 == 10 && split.1 == 90)
}

// MARK: - coming back to a big conversation

do {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "coldfall-reopen-\(UUID().uuidString)"
    let cwd = "/srv/demo"
    let proj = Resume.claudeProjectDir(for: cwd, root: root)
    try? fm.createDirectory(atPath: proj, withIntermediateDirectories: true)
    let sid = "22222222-3333-4444-5555-666666666666"
    // a long transcript: padding first, so the last turn is only found by
    // reading from the end
    var lines = [#"{"type":"custom-title","customTitle":"money","sessionId":"x"}"#]
    lines += Array(repeating: #"{"type":"user","message":{"role":"user","content":"\#(String(repeating: "x", count: 900))"}}"#, count: 800)
    lines.append(#"{"timestamp":"2026-09-20T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":2000,"cache_read_input_tokens":600000,"output_tokens":400}}}"#)
    try? lines.joined(separator: "\n").write(toFile: proj + "/\(sid).jsonl", atomically: true, encoding: .utf8)

    // a script desk called cpa whose conversation is titled "money"
    var cpa = Desk(name: "cpa", runtime: "claude", cwd: cwd, command: "desk money")
    check("reopen: a script desk without `fresh` can't start fresh", cpa.freshCommand() == nil)
    cpa.fresh = "desk money new"
    eq("reopen: it uses the script's own way", cpa.freshCommand(), "desk money new")
    eq("reopen: the conversation's title can differ from the desk", Reopen.title(of: cpa), "cpa")
    check("reopen: and isn't found under the desk's name", Reopen.claude(cpa, root: root) == nil)
    cpa.conversation = "money"
    let c = Reopen.claude(cpa, root: root)
    eq("reopen: found by its conversation title, sized from the last turn", c?.tokens, 602_003)

    let now = Date()
    let big = ConversationInfo(path: "/x", tokens: 600_000, lastUsed: now.addingTimeInterval(-3 * 86_400))
    check("reopen: a big conversation left for days is asked about", Reopen.shouldAsk(big, now: now))
    let warm = ConversationInfo(path: "/x", tokens: 600_000, lastUsed: now.addingTimeInterval(-600))
    check("reopen: not one used ten minutes ago", !Reopen.shouldAsk(warm, now: now))
    let small = ConversationInfo(path: "/x", tokens: 40_000, lastUsed: now.addingTimeInterval(-3 * 86_400))
    check("reopen: nor a small one, however old", !Reopen.shouldAsk(small, now: now))

    // opening, not wrapped up: leads with picking up where it was
    let q = Reopen.question(desk: cpa, big, wrappedAt: nil, now: now)
    check("reopen: leads with what resuming does", q.body.hasPrefix("cpa will pick up this conversation right where it was"))
    check("reopen: says the size and the age", q.body.contains("600K") && q.body.contains("3 days ago"))
    check("reopen: says what a clean start keeps",
          q.body.contains("keeps its name, folder, instructions and memory files"))
    check("reopen: and where the rest stays", q.body.contains("stays in the old conversation"))
    check("reopen: and that nothing is deleted", q.body.contains("Nothing is deleted") && q.body.contains("/resume"))
    check("reopen: picking up is the default", !q.freshIsDefault)

    // opening after a wrap-up: a clean start is what was asked for
    let wrapped = Reopen.question(desk: cpa, big, wrappedAt: now.addingTimeInterval(-7200), now: now)
    check("reopen: after a wrap-up, starting fresh is the default", wrapped.freshIsDefault)
    check("reopen: and it says why", wrapped.body.contains("You wrapped cpa up 2 hours ago"))

    // when to ask at all
    check("reopen: a wrapped-up desk is asked even when small",
          Reopen.shouldAsk(desk: cpa, small, wrapped: true, enabled: true, now: now))
    check("reopen: nothing is asked with the switch off",
          !Reopen.shouldAsk(desk: cpa, big, wrapped: true, enabled: false, now: now))
    var quiet = cpa; quiet.alwaysResume = true
    check("reopen: nor for a desk told not to ask",
          !Reopen.shouldAsk(desk: quiet, big, wrapped: false, enabled: true, now: now))
    var noFresh = cpa; noFresh.fresh = nil
    check("reopen: nor where it can't start fresh",
          !Reopen.shouldAsk(desk: noFresh, big, wrapped: false, enabled: true, now: now))

    // stopping: says first that nothing is lost; wrap up is an option
    let stop = Reopen.stopBody(desk: cpa, memory: "820 MB", big)
    check("stop: says first that it picks up where you left off",
          stop.hasPrefix("Ends its processes and frees about 820 MB. When you open it again, it picks up this conversation right where you left off."))
    check("stop: wrap up is framed as finishing a topic", stop.contains("Done with this topic? Wrap Up first"))
    check("stop: and never as saving something from loss",
          !stop.lowercased().contains("lose") && !stop.lowercased().contains("lost") && !stop.lowercased().contains("forget"))
    check("stop: a small conversation isn't offered a wrap up", !Reopen.offersWrapUp(desk: cpa, small))
    check("stop: a big one is", Reopen.offersWrapUp(desk: cpa, big))
    check("stop: the small one's text has no wrap-up line", !Reopen.stopBody(desk: cpa, memory: nil, small).contains("Wrap Up"))
    check("wrap up: asks the desk to use its own memory, not a file of ours",
          Reopen.wrapUpPrompt.contains("your memory or notes, the way you normally would"))

    // a built-in Claude desk starts fresh with a new named conversation
    let built = Desk(name: "api", runtime: "claude", cwd: cwd)
    check("reopen: a built-in desk starts fresh without --resume",
          built.freshCommand().map { !$0.contains("--resume") && $0.contains("-n api") } == true)

    // desks.toml keeps both settings
    let tmp = NSTemporaryDirectory() + "coldfall-fresh-\(UUID().uuidString).toml"
    DeskConfig.write([cpa], to: tmp)
    let back = DeskConfig.load(path: tmp).first
    eq("reopen: conversation saved", back?.conversation, "money")
    eq("reopen: fresh saved", back?.fresh, "desk money new")
    try? fm.removeItem(atPath: tmp)
    try? fm.removeItem(atPath: root)
}

// rebuilds: coming back after a break
do {
    var t = Tokenomics()
    let lines = [
        #"{"type":"custom-title","customTitle":"money"}"#,
        #"{"timestamp":"2026-09-22T07:30:00.000Z","message":{"id":"r0","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":900,"cache_read_input_tokens":600000,"output_tokens":300}}}"#,
        #"{"timestamp":"2026-09-22T09:00:00.000Z","message":{"id":"r1","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":580000,"cache_read_input_tokens":20000,"output_tokens":300}}}"#,
        #"{"timestamp":"2026-09-22T09:01:00.000Z","message":{"id":"r2","model":"claude-opus-5","usage":{"input_tokens":3,"cache_creation_input_tokens":900,"cache_read_input_tokens":600000,"output_tokens":300}}}"#,
    ]
    Tokenomics.read(lines.joined(separator: "\n"), since: Date(timeIntervalSince1970: 0), into: &t)
    eq("rebuild: the big write 90 minutes after the last turn is counted", t.byDesk["money"]?.rebuilds, 1)
    eq("rebuild: a warm turn is not", t.all.rebuilds, 1)
    // the same big write with no previous turn (a new conversation) is not a rebuild
    var fresh = Tokenomics()
    Tokenomics.read([lines[0], lines[2]].joined(separator: "\n"), since: Date(timeIntervalSince1970: 0), into: &fresh)
    eq("rebuild: a new conversation's first turn is not one", fresh.all.rebuilds, 0)
    // nor a big write two minutes after the last turn (a compaction, a big file)
    var soon = Tokenomics()
    let compact = lines[2].replacingOccurrences(of: "09:00:00", with: "07:32:00")
    Tokenomics.read([lines[0], lines[1], compact].joined(separator: "\n"), since: Date(timeIntervalSince1970: 0), into: &soon)
    eq("rebuild: a big write two minutes later is not one either", soon.all.rebuilds, 0)
    check("rebuild: priced as a one-hour cache write", abs((t.all.rebuildUsd) - 2.0 * 0.58 * 5) < 0.01)

    var week = Tokenomics()
    var s = Tokenomics.DeskStats()
    s.turns = 50; s.cacheRead = 5_000_000; s.cacheWrite = 2_000_000; s.output = 10_000
    s.rebuilds = 6; s.rebuildUsd = 40; s.byModel = ["sonnet": 1]
    week.all = s; week.byDesk = ["money": s]
    let n = week.notes().first { $0.kind == .rebuild }
    check("rebuild: named in the advice, with its cost", n?.finding.contains("6 times") == true && n?.finding.contains("$40") == true)
    check("rebuild: and says the break is the cause, not the stop", n?.advice.contains("not stopping the desk") == true)
}

// MARK: - where the week went

func turn(_ model: String, fresh: Int, write: Int, read: Int, out: Int, id: String, at: String) -> String {
    #"{"timestamp":"\#(at)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(fresh),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"output_tokens":\#(out)}}}"#
}

do {
    let since = Date(timeIntervalSince1970: 0)
    let when = "2026-09-22T10:00:00.000Z"
    var lines = [#"{"type":"custom-title","customTitle":"api"}"#]
    // a conversation: a big first request, then cheap cached turns
    lines.append(turn("claude-opus-5", fresh: 4000, write: 26000, read: 0, out: 500, id: "a1", at: when))
    for i in 2...6 {
        lines.append(turn("claude-opus-5", fresh: 200, write: 300, read: 30000, out: 400, id: "a\(i)", at: when))
    }
    // the same reply written twice, as a streamed one is
    lines.append(turn("claude-opus-5", fresh: 200, write: 300, read: 30000, out: 400, id: "a6", at: when))

    var t = Tokenomics()
    Tokenomics.read(lines.joined(separator: "\n"), since: since, into: &t)
    eq("week: a repeated record is counted once", t.all.turns, 6)
    eq("week: the desk is named from the transcript", Array(t.byDesk.keys), ["api"])
    eq("week: the cheapest turn of the week is the floor", t.byDesk["api"]?.floor, 30000)
    check("week: most input came from cache", t.cacheReadShare > 0.8 && t.freshShare < 0.06)
    eq("week: the model mix is by family", t.modelMix.first?.model, "opus")

    // advice: quiet when there is barely anything to judge
    check("advice: says nothing about a handful of turns", t.notes(minTurns: 50).isEmpty)

    // a week spent rebuilding context rather than reusing it
    var waste = Tokenomics()
    var w = Tokenomics.DeskStats()
    w.turns = 100; w.fresh = 800_000; w.cacheRead = 200_000; w.cacheWrite = 100_000; w.output = 50_000
    w.usd = 120; w.byModel = ["opus": 1_000_000]; w.floor = 62_000
    waste.all = w
    waste.byDesk = ["api": w]
    let notes = waste.notes(servers: ["api": 4])
    check("advice: names the uncached share, writes included", notes.contains { $0.kind == .cache && $0.finding.contains("82%") })
    check("advice: says what the desk pays before you type",
          notes.contains { $0.kind == .start && $0.finding.contains("62K") })
    check("advice: and points at that desk's MCP servers",
          notes.contains { $0.kind == .start && $0.advice.contains("4 MCP servers") && $0.advice.contains("new conversation") })
    check("advice: prices the same week on a smaller model",
          notes.contains { $0.kind == .model && !$0.measured && $0.advice.contains("Sonnet") })
    check("advice: the smaller model is quoted as the cheaper number",
          notes.contains { $0.kind == .model && $0.advice.contains("about $3 instead of $120") })
    check("advice: a projection is never presented as measured",
          notes.allSatisfy { $0.kind == .model ? !$0.measured : $0.measured })

    // a week that reuses context well is told so, and nothing else
    var good = Tokenomics()
    var g = Tokenomics.DeskStats()
    g.turns = 100; g.fresh = 50_000; g.cacheRead = 900_000; g.cacheWrite = 50_000; g.output = 40_000
    g.usd = 20; g.byModel = ["sonnet": 1_000_000]; g.floor = 8_000
    good.all = g; good.byDesk = ["api": g]
    let ok = good.notes()
    eq("advice: a cheap week gets one note, not a lecture", ok.count, 1)
    check("advice: and it says there is nothing to change", ok.first?.advice.contains("Nothing to change") == true)

    // the desk that costs most per turn, when it stands out
    var outlier = Tokenomics()
    func desk(turns: Int, read: Int) -> Tokenomics.DeskStats {
        var s = Tokenomics.DeskStats(); s.turns = turns; s.cacheRead = read; s.output = 1000
        s.byModel = ["sonnet": read]; s.floor = 5000; return s
    }
    outlier.all = desk(turns: 60, read: 1_000_000)
    outlier.byDesk = ["small": desk(turns: 20, read: 100_000),
                      "middle": desk(turns: 20, read: 120_000),
                      "hungry": desk(turns: 20, read: 2_000_000)]
    check("advice: names the desk that costs the most a turn",
          outlier.notes().contains { $0.kind == .desk && $0.finding.contains("hungry") })
}

// MARK: - the desk menu

do {
    let m = DeskMenu.items(runtime: "claude", running: true, hidden: false,
                           canReveal: false, canMakeDefault: false, hasInventory: true, hasMcp: true)
    let stop = m.first { $0.action == .stop }
    let remove = m.first { $0.action == .remove }
    eq("menu: stopping a desk is a caution, not a danger", stop?.tone, .caution)
    eq("menu: removing one is the danger", remove?.tone, .danger)
    check("menu: each says what it does",
          stop?.subtitle?.contains("start it again") == true && remove?.subtitle?.contains("desks.toml") == true)
    check("menu: and carries its own icon", stop?.symbol == "stop.circle.fill" && remove?.symbol == "trash")
    check("menu: the destructive one is kept apart", DeskMenu.destructiveIsIsolated(m))
    eq("menu: it is last, where nothing follows it by accident", m.last?.action, .remove)
    check("menu: stop and remove are never neighbours",
          !zip(m, m.dropFirst()).contains { ($0.action == .stop && $1.action == .remove)
                                            || ($0.action == .remove && $1.action == .stop) })
    let idle = DeskMenu.items(runtime: "codex", running: false, hidden: false,
                              canReveal: false, canMakeDefault: false, hasInventory: true, hasMcp: false)
    check("menu: a desk that isn't running has nothing to stop", !idle.contains { $0.action == .stop })
    check("menu: still isolated without it", DeskMenu.destructiveIsIsolated(idle))
    let hidden = DeskMenu.items(runtime: "claude", running: false, hidden: true,
                                canReveal: true, canMakeDefault: true, hasInventory: false, hasMcp: false)
    check("menu: a hidden desk offers to come back", hidden.contains { $0.action == .unhide })
    check("menu: and is not offered hiding twice", !hidden.contains { $0.action == .hide })
}

do {
    let on = DeskMenu.items(runtime: "claude", running: true, hidden: false, canReveal: false,
                            canMakeDefault: false, hasInventory: true, hasMcp: true, askResume: true)
    let item = on.first { $0.action == .askResume }
    eq("menu: asking before reopening is a checkmark, on", item?.checked, true)
    check("menu: and says what off means", item?.subtitle?.contains("always picks up where you left off") == true)
    let off = DeskMenu.items(runtime: "claude", running: false, hidden: false, canReveal: false,
                             canMakeDefault: false, hasInventory: true, hasMcp: true, askResume: false)
    eq("menu: switched off for a desk, it shows off", off.first { $0.action == .askResume }?.checked, false)
    let none = DeskMenu.items(runtime: "copilot", running: false, hidden: false, canReveal: false,
                              canMakeDefault: false, hasInventory: true, hasMcp: false)
    check("menu: not offered where a desk can't start fresh", !none.contains { $0.action == .askResume })
    check("menu: remove is still kept apart", DeskMenu.destructiveIsIsolated(on))

    // desks.toml remembers "don't ask"
    var d = Desk(name: "cpa", runtime: "claude", command: "desk money"); d.fresh = "desk money new"; d.alwaysResume = true
    let tmp = NSTemporaryDirectory() + "coldfall-ask-\(UUID().uuidString).toml"
    DeskConfig.write([d], to: tmp)
    eq("menu: don't ask is saved per desk", DeskConfig.load(path: tmp).first?.alwaysResume, true)
    try? FileManager.default.removeItem(atPath: tmp)
}

// MARK: - one look answers for every desk

do {
    let root = NSTemporaryDirectory() + "coldfall-seen-\(UUID().uuidString)"
    let was = InventorySeen.root
    InventorySeen.root = root

    check("shared: your own skill counts for every desk", Inventory.isShared(key: "skill|writing|you, every folder"))
    check("shared: so does anything a plugin brought", Inventory.isShared(key: "hook|SessionStart|plugin acme|cmd"))
    check("local: this folder's server is this desk's own", !Inventory.isShared(key: "MCP server|db|this folder"))
    check("local: including Claude's per-folder settings",
          !Inventory.isShared(key: "MCP server|db|this folder, in Claude's settings"))

    // Two desks, same account. One sees a new account-wide hook; the other
    // must not still be asking about it afterwards.
    let before = ["skill|writing|you, every folder": "v1", "MCP server|db|this folder": "local"]
    InventorySeen.markSeen(desk: "api", runtime: "claude", seen: before)
    InventorySeen.markSeen(desk: "docs", runtime: "claude", seen: before)

    var now = before
    now["hook|SessionStart|you, every folder|run.sh"] = "run.sh"     // installed since
    now["MCP server|new|this folder"] = "only api has this"

    var inv = Inventory()
    inv.skills = [Inventory.Item(name: "writing", detail: "v1", source: "you, every folder")]
    inv.hooks = [Inventory.Item(name: "SessionStart", detail: "run.sh", source: "you, every folder")]
    inv.mcp = [Inventory.Item(name: "db", detail: "local", source: "this folder")]

    let apiBefore = InventorySeen.baseline(desk: "api", runtime: "claude", current: inv.seen)
    eq("shared: the new hook shows up", inv.changes(since: apiBefore).count, 1)
    let docsBefore = InventorySeen.baseline(desk: "docs", runtime: "claude", current: inv.seen)
    eq("shared: on the other desk too, until someone looks", inv.changes(since: docsBefore).count, 1)

    // api's turn to look
    InventorySeen.markSeen(desk: "api", runtime: "claude", seen: inv.seen)
    let docsAfter = InventorySeen.baseline(desk: "docs", runtime: "claude", current: inv.seen)
    eq("shared: one look answers for every desk", inv.changes(since: docsAfter).count, 0)

    // but a change in ONE desk's own folder is still that desk's
    var inv2 = inv
    inv2.mcp.append(Inventory.Item(name: "cache", detail: "runs node", source: "this folder"))
    let apiLocal = InventorySeen.baseline(desk: "api", runtime: "claude", current: inv2.seen)
    eq("local: this folder's new server is still news", inv2.changes(since: apiLocal).count, 1)
    let codexSide = InventorySeen.baseline(desk: "cx", runtime: "codex", current: inv.seen)
    eq("shared: a runtime with no baseline yet starts clean", codexSide, nil)

    InventorySeen.root = was
    try? FileManager.default.removeItem(atPath: root)
}

// MARK: - leaving

do {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "coldfall-bye-\(UUID().uuidString)"
    let cfg = root + "/config", data = root + "/data", home = root + "/home"
    for d in [cfg, data, home + "/.claude", home + "/.claude-second"] {
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
    }
    try? String(repeating: "x", count: 2048).write(toFile: cfg + "/desks.toml", atomically: true, encoding: .utf8)
    try? "{}".write(toFile: data + "/ui.json", atomically: true, encoding: .utf8)

    let items = Uninstall.items(configRoot: cfg, dataRoot: data)
    eq("leaving: both folders are listed", items.count, 2)
    eq("leaving: with what is in them", items.first?.bytes, 2048)
    eq("leaving: sizes are readable", Uninstall.humanSize(2_100_000), "2.0 MB")
    eq("leaving: a folder that isn't there isn't listed",
       Uninstall.items(configRoot: root + "/gone", dataRoot: root + "/gone2").count, 0)

    // the statusline: Coldfall's recorder, wrapping someone's own command
    let recorder = cfg + "/statusline-recorder.sh"
    try? "#!/bin/bash\ninput=$(cat)\nWRAPPED=\"~/bin/my-statusline\"\n"
        .write(toFile: recorder, atomically: true, encoding: .utf8)
    eq("leaving: the wrapped statusline is read back", Uninstall.wrappedStatusline(recorder: recorder), "~/bin/my-statusline")
    let settings = home + "/.claude/settings.json"
    try? #"{"statusLine":{"type":"command","command":"\#(recorder)","padding":0},"model":"opus"}"#
        .write(toFile: settings, atomically: true, encoding: .utf8)
    check("leaving: the recorder is spotted", Limits.recorderInstalledAt(settings))
    _ = Uninstall.revertStatusline(settings: settings)
    let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings)))) as? [String: Any]
    eq("leaving: their own statusline is back",
       (after?["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/my-statusline")
    eq("leaving: the rest of their settings is untouched", after?["model"] as? String, "opus")

    // one that wrapped nothing loses the key entirely
    let bare = cfg + "/statusline-recorder-second.sh"
    try? "#!/bin/bash\nWRAPPED=\"\"\n".write(toFile: bare, atomically: true, encoding: .utf8)
    let s2 = home + "/.claude-second/settings.json"
    try? #"{"statusLine":{"type":"command","command":"\#(bare)"}}"#
        .write(toFile: s2, atomically: true, encoding: .utf8)
    _ = Uninstall.revertStatusline(settings: s2)
    let after2 = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: s2)))) as? [String: Any]
    check("leaving: a recorder that wrapped nothing leaves no statusLine", after2?["statusLine"] == nil)

    // someone else's statusline is not ours to touch
    let theirs = home + "/.claude/other.json"
    try? #"{"statusLine":{"type":"command","command":"~/bin/theirs"}}"#
        .write(toFile: theirs, atomically: true, encoding: .utf8)
    eq("leaving: a statusline that isn't Coldfall's is left alone", Uninstall.revertStatusline(settings: theirs), nil)

    // every account's settings file is checked
    var d = Desk(name: "side", runtime: "claude"); d.account = home + "/.claude-second"
    eq("leaving: the default account and each other one",
       Uninstall.settingsFiles(desks: [d], home: home),
       [home + "/.claude/settings.json", home + "/.claude-second/settings.json"])

    let words = Uninstall.summary(items: items, recorders: [settings])
    check("leaving: it leads with what is NOT touched", words.hasPrefix("Your agents are not touched."))
    check("leaving: it names each folder and its size", words.contains(cfg) && words.contains("2 KB"))
    check("leaving: it says the desk list goes too", words.contains("Your desk list goes with it"))
    check("leaving: with nothing left, it says so",
          Uninstall.summary(items: [], recorders: []).hasSuffix("There is nothing of Coldfall's left to remove."))

    let log = Uninstall.removeEverything(desks: [d], configRoot: cfg, dataRoot: data, home: home)
    check("leaving: the folders are gone", !fm.fileExists(atPath: cfg) && !fm.fileExists(atPath: data))
    check("leaving: and it says what it did", log.contains { $0.hasPrefix("deleted ") })
    check("leaving: the agent's own files stay", fm.fileExists(atPath: settings))
    try? fm.removeItem(atPath: root)
}

// MARK: - two usage scans at once

do {
    // The meter strip and the usage panel each scan on their own queue. When
    // both ran at once they wrote to one shared set and the app died inside
    // Set.insert (a real crash, v0.3.8). Nothing may be shared between passes.
    let root = NSTemporaryDirectory() + "coldfall-usagerace-\(UUID().uuidString)"
    let wasRoot = UsageCache.root
    UsageCache.root = root
    let slice = UsageSlice(vendor: "claude", desk: "api", day: "2026-09-22", tokens: 10, calls: 1, usd: 1)
    let group = DispatchGroup()
    for i in 0..<8 {
        DispatchQueue.global().async(group: group) {
            for j in 0..<200 {
                let path = "/srv/demo/\(i)-\(j).jsonl"
                UsageCache.store([slice], for: path, key: "k", since: Date(timeIntervalSince1970: 0))
                _ = UsageCache.slices(for: path, key: "k", since: Date(timeIntervalSince1970: 0))
            }
            UsageCache.flush(keeping: [])
        }
    }
    check("usage cache: survives eight scanners at once", group.wait(timeout: .now() + 30) == .success)

    // And the scan itself, twice over, on two queues.
    let g2 = DispatchGroup()
    for _ in 0..<2 {
        DispatchQueue.global().async(group: g2) { _ = Usage.scan(since: Date()) }
    }
    check("usage: two scans at once finish", g2.wait(timeout: .now() + 60) == .success)
    UsageCache.clear()
    UsageCache.root = wasRoot
    try? FileManager.default.removeItem(atPath: root)
}

// MARK: - a second Claude account

do {
    let home = "/srv/home"
    eq("account: named after its folder", ClaudeAccount(folder: "~/.claude-second", home: home)?.label, "second")
    eq("account: any folder name works", ClaudeAccount(folder: "/srv/accounts/Work", home: home)?.vendor, "claude-work")
    check("account: the default folder is not another account", ClaudeAccount(folder: "~/.claude", home: home) == nil)
    check("account: nor is an empty one", ClaudeAccount(folder: " ", home: home) == nil)

    var d = Desk(name: "side", runtime: "claude", cwd: "/srv/demo")
    d.account = "/srv/accounts/claude-second"
    check("account: the desk starts Claude on that folder",
          d.launchCommand().hasPrefix("CLAUDE_CONFIG_DIR=/srv/accounts/claude-second claude "))
    var spaced = d; spaced.account = "/srv/my accounts/second"
    check("account: a folder with a space is quoted",
          spaced.launchCommand().hasPrefix("CLAUDE_CONFIG_DIR='/srv/my accounts/second' claude "))
    eq("account: the rail names it", d.vendorLabel, "claude-second")
    var codex = Desk(name: "cx", runtime: "codex"); codex.account = "/srv/accounts/claude-second"
    eq("account: only Claude desks have one", codex.claudeAccount(), nil)
    eq("account: a Codex desk's command is untouched", codex.launchCommand(), "codex")

    // desks.toml round trip
    let tmp = NSTemporaryDirectory() + "coldfall-acct-\(UUID().uuidString).toml"
    DeskConfig.write([d], to: tmp)
    eq("account: saved and read back", DeskConfig.load(path: tmp).first?.account, "/srv/accounts/claude-second")
    try? FileManager.default.removeItem(atPath: tmp)

    // one list per account, each once
    var d2 = d; d2.name = "side2"
    eq("account: used by desks, once each", ClaudeAccount.used(by: [d, d2, Desk(name: "hub")], home: home).map(\.vendor), ["claude-second"])

    // agent mail can ask Claude on the other account
    let accts = ClaudeAccount.used(by: [d], home: home)
    let rt = Bridge.runtime(named: "claude-second", accounts: accts)
    eq("account: mail can address it by name", rt?.name, "claude-second")
    eq("account: and runs Claude on its folder", rt?.env["CLAUDE_CONFIG_DIR"], "/srv/accounts/claude-second")
    eq("account: still read-only enforced", rt?.readOnlyEnforced, true)

    // resume reads that account's conversations
    let root = NSTemporaryDirectory() + "coldfall-acctresume-\(UUID().uuidString)"
    var r = Desk(name: "side", runtime: "claude", cwd: "/srv/demo"); r.account = root
    let proj = Resume.claudeProjectDir(for: "/srv/demo", root: root + "/projects")
    try? FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
    let sid = "11111111-2222-3333-4444-555555555555"
    try? #"{"type":"custom-title","customTitle":"side","sessionId":"x"}"#
        .write(toFile: proj + "/\(sid).jsonl", atomically: true, encoding: .utf8)
    check("account: resumes from that account's history",
          r.resumingLaunchCommand(claudeRoot: "/srv/nowhere").contains("--resume \(sid)"))
    try? FileManager.default.removeItem(atPath: root)
}

// MARK: - a repaint is not news

do {
    let left = ["> fix the build", "", "Done. Tests pass.", "", "╭────╮", "│ >  │", "╰────╯", "  ctx 40%", "  ? for shortcuts", "", ""]
    var repaint = left; repaint[7] = "  ctx 41%"
    check("repaint: status line ticking is not news", !ScreenChange.meaningful(before: left, after: repaint))
    check("repaint: an identical screen is not news", !ScreenChange.meaningful(before: left, after: left.map { $0 + "  " }))
    var reply = left; reply[3] = "Also pushed it."
    check("repaint: a new line above the input box is news", ScreenChange.meaningful(before: left, after: reply))
    let scrolled = Array(left.dropFirst()) + [""]
    check("repaint: scrolled content is news", ScreenChange.meaningful(before: left, after: scrolled))
}

// MARK: - clearing needs-you, and desks that stay removed

do {
    var st = ActivityState()
    let t0 = Date()
    st.noteOutput(at: t0)
    eq("needs you: output unseen", st.activity(now: t0.addingTimeInterval(10)), .ready)
    st.markSeen()
    eq("needs you: Clear counts as seen", st.activity(now: t0.addingTimeInterval(10)), .quiet)
    let a = Desk(name: "g", runtime: "antigravity"), c = Desk(name: "c", runtime: "claude")
    eq("removed: a runtime whose last desk went", AgentOffer.removed(before: [a, c], after: [c]), ["antigravity"])
    eq("removed: not while another desk has it",
       AgentOffer.removed(before: [a, Desk(name: "g2", runtime: "antigravity")], after: [a]), [])
    eq("removed: a shell desk is not an agent",
       AgentOffer.removed(before: [Desk(name: "sh", runtime: "shell")], after: []), [])
    check("gemini is no longer a runtime", Bridge.runtime(named: "gemini") == nil && VendorInstall.of("gemini") == nil)
}

// MARK: - Copilot usage

do {
    let text = "2026-09-19T23:46:16.397Z\t10794\t224\tuser\t1.0\n"
             + "2026-09-19T23:07:12.290Z\t78314\t173\tagent\t1.0\n"
             + "2026-09-19T23:50:00.000Z\t100\t50\tuser\t0.33\n"
             + "not a row\n"
    let rows = Usage.copilotRows(text)
    eq("copilot: bad lines are skipped", rows.count, 3)
    eq("copilot: input already includes cached tokens", rows.first?.tokens, 11018)
    eq("copilot: a turn the person starts is one premium request", rows.first?.premium, 1.0)
    eq("copilot: the agent's own follow-up calls are not premium", rows[1].premium, 0)
    eq("copilot: a cheaper model counts by its multiplier", rows[2].premium, 0.33)
    let mid = ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z")!
    let ms = Usage.monthStart(mid)
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    check("copilot: the month starts at midnight UTC on the 1st, as GitHub's does",
          utc.component(.day, from: ms) == 1 && utc.component(.hour, from: ms) == 0 && ms <= mid)
}

// MARK: - offering a desk for a newly installed agent

do {
    let ws = "/srv/demo/ws"
    let desks = [Desk(name: "hub", runtime: "claude", cwd: ws, command: "/srv/demo/ws/scripts/desk hub", isDefault: true),
                 Desk(name: "codex", runtime: "codex", cwd: ws, isDefault: true),
                 Desk(name: "shell", runtime: "shell", cwd: "/srv/demo", command: "exec zsh -l")]
    eq("an installed agent with no desk is offered",
       AgentOffer.missing(installed: ["claude", "codex", "copilot"], desks: desks, dismissed: []), ["copilot"])
    eq("a desk run by a script still counts as having one",
       AgentOffer.missing(installed: ["claude"], desks: desks, dismissed: []), [])
    eq("an agent that isn't installed isn't offered",
       AgentOffer.missing(installed: ["claude", "codex"], desks: desks, dismissed: []), [])
    eq("Not now is remembered",
       AgentOffer.missing(installed: ["copilot", "antigravity"], desks: desks, dismissed: ["copilot"]), ["antigravity"])
    let d = AgentOffer.desk(for: "copilot", in: desks, home: "/srv/home")
    eq("the new desk is named after the agent", d.name, "copilot")
    eq("it's that agent's home desk", d.isDefault, true)
    eq("and works where the other home desks do", d.cwd, ws)
    eq("a taken name gets a number", AgentOffer.desk(for: "codex", in: desks).name, "codex-2")
    eq("with no desks at all it works in the home folder",
       AgentOffer.desk(for: "antigravity", in: [], home: "/srv/home").cwd, "/srv/home")
    eq("it launches that agent's own CLI", d.launchCommand(), "copilot")
}

// MARK: - the suite must not touch a real home directory
//
// Checked LAST, after every other test has run. A test that writes to the
// user's real ~/.local/share/coldfall creates exactly the directory that makes
// the rename's migration refuse to act — so this is not tidiness, it is the
// difference between an upgrade that works and one that loses history.
do {
    let real = NSString(string: "~/.local/share/coldfall/cache/usage.json").expandingTildeInPath
    let createdByUs = FileManager.default.fileExists(atPath: real) && !preexistingCache
    check("the test suite left no cache in the real home directory", !createdByUs)
}

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
    print("\nfailures:")
    failures.forEach { print("  " + $0) }
    exit(1)
}
