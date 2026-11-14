import Foundation
import ColdfallCore

// Regression tests for faults that actually shipped today, not invented cases.
// Each one names the bug it stops coming back.
//
// Deliberately not XCTest: that ships with Xcode, and this project builds on
// Command Line Tools alone. A test suite that reintroduces a 15GB dependency
// defeats the point.

var failures: [String] = []

// Nothing a test does may land in the real ~/.config/coldfall or
// ~/.local/share/coldfall. These roots default to the real folders, so point
// them all at a scratch folder before any test runs. (Running the suite used
// to delete the real done-hook.sh: 0.3.24 to 0.3.27.)
let testSandbox = NSTemporaryDirectory() + "coldfall-tests-\(UUID().uuidString)"
Limits.configDir = testSandbox + "/config"
DoneSignal.logPath = testSandbox + "/share/signals.log"
ScreenChange.logPath = testSandbox + "/share/logs/green.log"
RemoteOpen.root = testSandbox + "/share/remote"
// Short: a unix socket path has to fit in 104 bytes.
Holder.root = NSTemporaryDirectory() + "cfh\(getpid())"
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

    // The desk on screen says what it is doing, but never badges.
    var open = ActivityState()
    open.setVisible(true)
    open.noteOutput(at: t0)
    eq("the desk you are looking at reads as working while output arrives",
       open.activity(now: t0.addingTimeInterval(0.5)), .working)
    eq("and as quiet, never ready, once it stops", open.activity(now: t0.addingTimeInterval(quiet + 5)), .quiet)
    var typing = ActivityState()
    typing.setVisible(true)
    typing.noteInput(at: t0)
    typing.noteOutput(at: t0.addingTimeInterval(0.05))
    eq("typing's echo doesn't read as the agent working", typing.activity(now: t0.addingTimeInterval(0.1)), .quiet)
    typing.noteOutput(at: t0.addingTimeInterval(ActivityState.echoGrace + 0.1))
    eq("output after the echo does",
       typing.activity(now: t0.addingTimeInterval(ActivityState.echoGrace + 0.2)), .working)
    var away = ActivityState()
    away.setVisible(false)
    away.noteInput(at: t0)
    away.noteOutput(at: t0.addingTimeInterval(0.05))
    eq("away from a desk, output still counts however soon after input",
       away.activity(now: t0.addingTimeInterval(0.1)), .working)

    // The screen to compare is the live one, not the scrolled view.
    eq("live rows are the end of the buffer", ScreenChange.liveRows(buffer: "a\nb\nc\nd\n", rows: 2), ["c", "d"])
    eq("however far you scrolled up to read", ScreenChange.liveRows(buffer: "only\n", rows: 3), ["only"])
    eq("blank rows on screen are kept", ScreenChange.liveRows(buffer: "x\n\n\n", rows: 2), ["", ""])

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

// New setups follow the Mac; a file with no mode is an older setup and stays
// dark, so nobody's terminal turns white because they updated.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("desks.toml").path
    defer { try? FileManager.default.removeItem(at: dir) }
    try? "[desk.one]\nruntime = \"claude\"\n".write(toFile: f, atomically: true, encoding: .utf8)
    eq("no theme table means no mode set, so the app default applies",
       DeskConfig.themeSettings(path: f).mode, nil)
    try? (DeskConfig.starterTheme + "\n[desk.one]\nruntime = \"claude\"\n").write(toFile: f, atomically: true, encoding: .utf8)
    eq("a new setup follows the system", DeskConfig.themeSettings(path: f).mode, "system")
    DeskConfig.write(DeskConfig.load(path: f), to: f)
    eq("and saving the desks keeps that", DeskConfig.themeSettings(path: f).mode, "system")
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
    eq("one finished desk reads as a sentence", NeedsYou.summary(["career"]), "career is done")
    eq("several are counted and named", NeedsYou.summary(q), "3 done: career, hub, study")
    eq("a long queue is cut short", NeedsYou.summary(q + ["work"]), "4 done: career, hub, study, …")
    eq("an empty queue says nothing", NeedsYou.summary([]), nil)
    eq("a question is 'needs you'", NeedsYou.summary(["api"], blocked: ["api"]), "api needs you")
    eq("questions and answers are told apart", NeedsYou.summary(["api", "golf", "hub"], blocked: ["api"]), "api needs you · 2 done")
    eq("several questions are named", NeedsYou.summary(["a", "b", "c"], blocked: ["a", "b", "c"]), "3 need you: a, b, c")
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

// MARK: - section labels

eq("label: capitals become a sentence", TextStyle.sentence("RUNTIMES DETECTED"), "Runtimes detected")
eq("label: acronyms stay", TextStyle.sentence("SSH HOSTS"), "SSH hosts")
eq("label: apostrophes survive", TextStyle.sentence("WHAT'S FILLING THE CONVERSATIONS  (tool output, estimated)"),
   "What's filling the conversations  (tool output, estimated)")
eq("label: a date stays as written", TextStyle.sentence("THIS WEEK, SINCE Sep 21"), "This week, since Sep 21")
eq("label: the product's name keeps its capitals", TextStyle.sentence("REMOVE PROJECT COLDFALL"), "Remove Project Coldfall")
eq("label: empty is empty", TextStyle.sentence(""), "")

// MARK: - agents saying when they're done

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("coldfall-done-\(UUID().uuidString)").path
    let home = root + "/home"
    try? fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
    let wasCfg = Limits.configDir, wasLog = DoneSignal.logPath
    Limits.configDir = root + "/config"
    DoneSignal.logPath = home + "/.local/share/coldfall/signals.log"
    defer { Limits.configDir = wasCfg; DoneSignal.logPath = wasLog; try? fm.removeItem(atPath: root) }

    eq("done: a desk name can't break the log line", DoneSignal.fileName("my desk/../x"), "my_desk_.._x")
    do {
        let m = Data("Claude needs your permission to use Bash".utf8).base64EncodedString()
        let sig = DoneSignal.parse(Substring("1700000000 notify hub \(m)"))
        eq("done: a line can carry why it waits", sig?.message, "Claude needs your permission to use Bash")
        eq("done: and the desk is still the desk", sig?.desk, "hub")
        eq("done: an old line has no message", DoneSignal.parse("1700000000 notify hub")?.message, nil)
        eq("reason: the desk's name already says who", DeskDetail.reason(message: "Claude needs your permission to use Bash"), "wants to use Bash")
        eq("reason: other words pass through", DeskDetail.reason(message: "Which branch should I use?"), "Which branch should I use?")
        eq("reason: no message, the kind will do", DeskDetail.reason(message: nil, kind: "permission"), "wants permission")
        eq("reason: nothing to say", DeskDetail.reason(message: "", kind: nil), nil)
        check("reason: long ones are cut", (DeskDetail.reason(message: String(repeating: "x", count: 300))?.count ?? 0) == DeskDetail.maxLength)
        eq("title: the agent's task, without its spinner", DeskDetail.title("✳ Fix the invoice parser", desk: "work"), "Fix the invoice parser")
        eq("title: the program's own name says nothing", DeskDetail.title("✳ Claude Code", desk: "work"), nil)
        eq("title: nor the desk's", DeskDetail.title("work", desk: "work"), nil)
        eq("title: nor a shell's folder", DeskDetail.title("~/srv/demo", desk: "work"), nil)
        eq("title: nor user@host:path", DeskDetail.title("me@box:/srv/demo", desk: "work"), nil)
        eq("detail: waiting shows why", DeskDetail.line(blocked: true, reason: "wants to use Bash", title: "Fix it"), "wants to use Bash")
        eq("detail: otherwise what it's doing", DeskDetail.line(blocked: false, reason: "old", title: "Fix it"), "Fix it")
        eq("detail: waiting with no reason shows nothing stale", DeskDetail.line(blocked: true, reason: nil, title: "Fix it"), nil)

        let ds = [Desk(name: "a", group: "x"), Desk(name: "b", group: "x"), Desk(name: "c", group: "y"), Desk(name: "d")]
        typealias L = DeskOrder.Live
        let t0 = Date(timeIntervalSince1970: 1000)
        let pr = DeskOrder.priority(ds, live: ["a": L(rank: 2, lastOutput: t0), "b": L(rank: 0, lastOutput: t0),
                                               "c": L(rank: 0, lastOutput: t0.addingTimeInterval(-60))])
        eq("priority: sections in order, empty ones left out", pr.map(\.urgency), [.needsYou, .working])
        eq("priority: the longest wait first, across groups", pr.first?.names, ["c", "b"])
        eq("priority: a stopped desk isn't listed", pr.flatMap(\.names).contains("d"), false)
        eq("step: next", DeskOrder.step(["a", "b", "c"], from: "a", by: 1), "b")
        eq("step: wraps", DeskOrder.step(["a", "b", "c"], from: "c", by: 1), "a")
        eq("step: back wraps too", DeskOrder.step(["a", "b", "c"], from: "a", by: -1), "c")
        eq("step: from a desk not listed, the first", DeskOrder.step(["a", "b"], from: "z", by: 1), "a")
        eq("step: one desk, nowhere to go", DeskOrder.step(["a"], from: "a", by: 1), nil)

        eq("gauge: fine", ContextGauge.level(41), .fine)
        eq("gauge: high from 60", ContextGauge.level(60), .high)
        eq("gauge: full from 80", ContextGauge.level(80.5), .full)
        eq("git: main says nothing", GitTail.branch(head: "ref: refs/heads/main\n"), nil)
        eq("git: another branch is named", GitTail.branch(head: "ref: refs/heads/fix/parser\n"), "fix/parser")
        eq("git: detached shows a short hash", GitTail.branch(head: "0123456789abcdef0123456789abcdef01234567\n"), "0123456")
        eq("git: a worktree's HEAD is in its gitdir",
           GitTail.headPath(folder: "/srv/demo/wt", read: { _ in "gitdir: /srv/demo/.git/worktrees/wt\n" }, isDir: { _ in false }),
           "/srv/demo/.git/worktrees/wt/HEAD")
        eq("git: no repo, no branch", GitTail.headPath(folder: "/srv/demo", read: { _ in nil }, isDir: { _ in false }), nil)

        var u = ActivityState()
        u.setVisible(true); u.noteOutput(at: t0); u.setVisible(false, at: t0.addingTimeInterval(10))
        eq("unread: a read desk is quiet", u.activity(now: t0.addingTimeInterval(20)), .quiet)
        u.markUnread()
        eq("unread: marked, it is done again", u.activity(now: t0.addingTimeInterval(20)), .ready)
        u.setVisible(true)
        eq("unread: and opening it clears it", u.activity(now: t0.addingTimeInterval(30)), .quiet)
        u.markUnread()
        eq("unread: marked while on screen, it shows", u.activity(now: t0.addingTimeInterval(30)), .ready)
        u.setVisible(false, at: t0.addingTimeInterval(31))
        eq("unread: and stays when you leave", u.activity(now: t0.addingTimeInterval(40)), .ready)
        u.setVisible(true)
        eq("unread: until you come back", u.activity(now: t0.addingTimeInterval(50)), .quiet)

        // The hook itself, run for real against a notification.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coldfall-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = dir.appendingPathComponent("hook.sh")
        try? DoneSignal.script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [sh.path, "notify"]
        p.environment = ["HOME": dir.path, "CLAUDE_DESK": "hub", "PATH": "/usr/bin:/bin"]
        let inp = Pipe(); p.standardInput = inp
        try? p.run()
        inp.fileHandleForWriting.write(Data(#"{"session_id":"x","message":"Claude needs your permission to use Bash","hook_event_name":"Notification"}"#.utf8))
        inp.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        let line = (try? String(contentsOf: dir.appendingPathComponent(".local/share/coldfall/signals.log"), encoding: .utf8)) ?? ""
        eq("hook: writes why it waits", line.split(separator: "\n").first.flatMap { DoneSignal.parse($0) }?.message,
           "Claude needs your permission to use Bash")
        try? FileManager.default.removeItem(at: dir)
    }
    do {
        let screen = """
        ● Edited 3 files

        ╭──────────────────────────────────────────────╮
        │ Bash command                                 │
        │                                              │
        │   npm test                                   │
        │   Run the test suite                         │
        │                                              │
        │ Do you want to proceed?                      │
        │ ❯ 1. Yes                                     │
        │   2. Yes, and don't ask again for npm        │
        │      commands in /srv/demo                   │
        │   3. No, and tell Claude what to do (esc)    │
        ╰──────────────────────────────────────────────╯
        """
        let p = Prompt.parse(screen: screen)
        eq("prompt: the question", p?.question, "Do you want to proceed?")
        eq("prompt: its options, by key", p?.options.map(\.key), ["1", "2", "3"])
        eq("prompt: a wrapped label is one label", p?.options[1].label, "Yes, and don't ask again for npm commands in /srv/demo")
        eq("prompt: what it's about", p?.context, ["npm test", "Run the test suite"])
        eq("prompt: no numbered choice, no prompt", Prompt.parse(screen: "● Reading files\n> tidy the parser\n"), nil)
        eq("prompt: a numbered list in prose isn't one unless it starts at 1",
           Prompt.parse(screen: "steps:\n2. build\n3. ship\n"), nil)
        eq("prompt: one line isn't a choice", Prompt.parse(screen: "1. only\n"), nil)
        let yes = Prompt.Option(key: "1", label: "Yes")
        eq("prompt: an option still on screen is pressed by its key", Prompt.key(for: yes, on: screen), [49])
        eq("prompt: one that has gone is not", Prompt.key(for: yes, on: "Which file?\n1. a.txt\n2. b.txt\n"), nil)
        eq("prompt: button labels drop the key hint", Prompt.short("No, and tell Claude what to do (esc)"), "No, and tell Claude what to do")
    }
    do {
        let st = Changes.parseStatus(" M src/a.swift\0?? notes.txt\0R  new.swift\0old.swift\0D  gone.swift\0A  added.swift\0")
        eq("changes: status reads each file", st.map(\.path), ["src/a.swift", "notes.txt", "new.swift", "gone.swift", "added.swift"])
        eq("changes: and what happened to it", st.map(\.status), ["M", "?", "R", "D", "A"])
        let d = Changes.parseDiff("""
        diff --git a/a.swift b/a.swift
        index 1..2 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -10,3 +10,4 @@ func f() {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         return a
        """)
        eq("diff: kinds in order", d.map(\.kind), [.meta, .meta, .meta, .meta, .hunk, .context, .removed, .added, .added, .context])
        eq("diff: new-file line numbers", d.map(\.number), [nil, nil, nil, nil, nil, 10, nil, 11, 12, 13])
        eq("diff: the marker is not part of the text", d[7].text, "let b = 3")
        eq("diff: a new file is all additions", Changes.asAdded("a\nb").map(\.number), [1, 2])
        let msg = Changes.compose([Changes.Comment(file: "a.swift", line: 11, quote: "let b = 3", text: "Why 3?"),
                                   Changes.Comment(file: "notes.txt", line: nil, quote: "", text: "Delete this.")])
        check("compose: says how many", msg.hasPrefix("2 review comments on your changes:"))
        check("compose: names file and line and quotes the code", msg.contains("1. a.swift:11  `let b = 3`\n   Why 3?"))
        check("compose: a comment on a whole file", msg.contains("2. notes.txt\n   Delete this."))
        check("compose: no trailing newline, sending adds the Return", !msg.hasSuffix("\n"))
        eq("compose: nothing to say", Changes.compose([]), "")

        // Against a real repository, in a temp folder.
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("coldfall-git-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let id = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
        _ = Changes.git(["init", "-q"], in: repo)
        try? "one\ntwo\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        _ = Changes.git(["add", "."], in: repo)
        _ = Changes.git(id + ["commit", "-q", "-m", "first"], in: repo)
        try? "one\nTWO\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try? "new\n".write(toFile: repo + "/n.txt", atomically: true, encoding: .utf8)
        let fs = Changes.files(in: repo) ?? []
        eq("git: a changed and a new file", Set(fs.map { $0.status + $0.path }), ["Mf.txt", "?n.txt"])
        if let m = fs.first(where: { $0.path == "f.txt" }) {
            let dl = Changes.diff(m, in: repo)
            check("git: the change is in the diff", dl.contains(Changes.Line(.added, "TWO", 2)) && dl.contains(Changes.Line(.removed, "two")))
        }
        eq("turn: name-status reads changes and a rename",
           Changes.parseNameStatus("M\0a.txt\0A\0b.txt\0R100\0old.txt\0new.txt\0D\0gone.txt\0").map { $0.status + $0.path },
           ["Ma.txt", "Ab.txt", "Rnew.txt", "Dgone.txt"])
        let before = Changes.snapshot(in: repo)
        check("turn: a snapshot is a tree", (before?.count ?? 0) >= 40)
        eq("turn: taking it leaves the real index alone", Set((Changes.files(in: repo) ?? []).map { $0.status + $0.path }), ["Mf.txt", "?n.txt"])
        try? "one\nTWO\nthree\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try? "made this turn\n".write(toFile: repo + "/turn.txt", atomically: true, encoding: .utf8)
        let after = Changes.snapshot(in: repo)
        if let a = before, let b = after {
            let tf = Changes.files(from: a, to: b, in: repo) ?? []
            eq("turn: only what changed since the snapshot, new files included", Set(tf.map { $0.status + $0.path }), ["Mf.txt", "Aturn.txt"])
            if let m = tf.first(where: { $0.path == "f.txt" }) {
                check("turn: and only that turn's lines", Changes.diff(m, from: a, to: b, in: repo).filter { $0.kind == .added }.map(\.text) == ["three"])
            }
            eq("turn: nothing changed, nothing listed", Changes.files(from: b, to: b, in: repo)?.count, 0)
        } else { check("turn: snapshots were taken", false) }
        eq("turn: not a repository, no snapshot", Changes.snapshot(in: FileManager.default.temporaryDirectory.path + "/coldfall-none-\(UUID().uuidString)"), nil)
        eq("git: not a repository, no list", Changes.files(in: FileManager.default.temporaryDirectory.path + "/coldfall-none-\(UUID().uuidString)") == nil, true)
        try? FileManager.default.removeItem(atPath: repo)
    }
    do {
        eq("colour: a palette name", DeskColor.rgb("teal"), 0x39C5BB)
        eq("colour: a hex value, with or without #", DeskColor.rgb("#FF8800"), DeskColor.rgb("ff8800"))
        eq("colour: nonsense is no colour", DeskColor.rgb("sparkly"), nil)
        eq("colour: nothing is no colour", DeskColor.rgb(nil), nil)
        eq("colour: none of it leaves the base", DeskColor.mix(0x202020, 0xFF0000, amount: 0), 0x202020)
        eq("colour: all of it is the colour", DeskColor.mix(0x202020, 0xFF0000, amount: 1), 0xFF0000)
        eq("colour: half way", DeskColor.mix(0x000000, 0xFF8000, amount: 0.5), 0x804000)
        let cd = parse("[desk.a]\ncolor = \"Teal\"\n[desk.b]\ncolor = \"sparkly\"\n[desk.c]\ncolour = \"#ff8800\"\n")
        eq("colour: read from the file, in either spelling", cd.map(\.color), ["teal", nil, "#ff8800"])
        let cf = FileManager.default.temporaryDirectory.appendingPathComponent("coldfall-colour-\(UUID().uuidString).toml")
        DeskConfig.write(cd, to: cf.path)
        eq("colour: and survives a save", DeskConfig.load(path: cf.path).map(\.color), ["teal", nil, "#ff8800"])
        try? FileManager.default.removeItem(at: cf)
        let cm = DeskMenu.items(runtime: "claude", running: true, hidden: false, canReveal: false,
                                canMakeDefault: false, hasInventory: true, hasMcp: true)
        check("menu: a desk can be given a colour", cm.contains { $0.action == .color })
    }
    do {
        typealias E = NeedsYou.Entry
        let t0 = Date(timeIntervalSince1970: 1000)
        let es = [E(name: "a", activity: .ready, lastOutput: t0), E(name: "b", activity: .ready, lastOutput: t0.addingTimeInterval(10)),
                  E(name: "c", activity: .blocked, lastOutput: t0.addingTimeInterval(20))]
        eq("defer: without any, the usual order", NeedsYou.queue(es), ["c", "a", "b"])
        eq("defer: a put-off desk goes to the back", NeedsYou.queue(es, deferred: ["c": t0]), ["a", "b", "c"])
        eq("defer: two put off keep the order you put them off in",
           NeedsYou.queue(es, deferred: ["c": t0.addingTimeInterval(5), "a": t0]), ["b", "a", "c"])
        eq("defer: forgotten once the desk stops waiting", NeedsYou.prune(["a": t0, "z": t0], queue: ["a", "b"]).keys.sorted(), ["a"])

        var h = VisitHistory()
        h.visit("a"); h.visit("b"); h.visit("c"); h.visit("c")
        eq("history: back one", h.step(-1), "b")
        eq("history: and again", h.step(-1), "a")
        eq("history: nothing before the first", h.step(-1), nil)
        eq("history: forward again", h.step(1), "b")
        h.visit("d")
        eq("history: a new visit drops what was forward", h.step(1), nil)
        eq("history: back skips a desk that is gone", h.step(-1, exists: { $0 != "b" }), "a")
        var cl = ClosedDesks()
        cl.closed("a"); cl.closed("b")
        eq("reopen: the last one stopped", cl.reopen(exists: { _ in true }, running: { _ in false }), "b")
        eq("reopen: then the one before, unless it's running again", cl.reopen(exists: { _ in true }, running: { $0 == "a" }), nil)

        eq("notice: OSC 9 is the message", TerminalNotice.message(code: 9, payload: "Build finished"), "Build finished")
        eq("notice: OSC 9;4 is progress, not a message", TerminalNotice.message(code: 9, payload: "4;1;40"), nil)
        eq("notice: OSC 777 has a title and a body", TerminalNotice.message(code: 777, payload: "notify;Codex;Approve the command?"), "Codex: Approve the command?")
        eq("notice: OSC 99 after its metadata", TerminalNotice.message(code: 99, payload: "i=1:d=0;Turn complete"), "Turn complete")
        eq("notice: a question needs you", TerminalNotice.event("Codex: Approve the command?"), .notify)
        eq("notice: a permission request needs you", TerminalNotice.event("Claude needs your permission to use Bash"), .notify)
        eq("notice: anything else is a finished turn", TerminalNotice.event("Turn complete"), .stop)
    }
    do {
        let now = Date(timeIntervalSince1970: 100_000)
        var f = Hibernate.Facts(runtime: "claude", resumes: true, running: true, visible: false, activity: .quiet,
                                lastOutput: now.addingTimeInterval(-3600), lastKey: now.addingTimeInterval(-4000), panes: 1, draft: false)
        check("sleep: done, seen and untouched for long enough", Hibernate.shouldSleep(f, now: now, after: 1800))
        check("sleep: off means never", !Hibernate.shouldSleep(f, now: now, after: 0))
        check("sleep: not yet long enough", !Hibernate.shouldSleep(f, now: now, after: 7200))
        var g = f; g.visible = true
        check("sleep: never the desk on screen", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.activity = .ready
        check("sleep: never an answer you haven't read", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.activity = .blocked
        check("sleep: never one that's asking", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.activity = .working
        check("sleep: never one that's working", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.resumes = false
        check("sleep: never one that can't be brought back", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.runtime = "shell"
        check("sleep: never a shell", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.panes = 2
        check("sleep: never with a shell split beside it", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.draft = true
        check("sleep: never with a message half typed", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.lastKey = now.addingTimeInterval(-60)
        check("sleep: a key pressed since counts as use", !Hibernate.shouldSleep(g, now: now, after: 1800))
        g = f; g.lastOutput = nil
        check("sleep: never one that hasn't spoken yet", !Hibernate.shouldSleep(g, now: now, after: 1800))
        f.running = false
        check("sleep: nothing to do for one that isn't running", !Hibernate.shouldSleep(f, now: now, after: 1800))
        eq("sleep: labels", Hibernate.choices.map(Hibernate.label), ["Never", "After 15 minutes", "After 30 minutes", "After 1 hour", "After 2 hours", "After 4 hours"])
    }
    do {
        eq("fork: Claude resumes its session as a new one",
           Handoff.forkCommand(runtime: "claude", claudeSession: "0a1b2c3d-1111-2222-3333-444455556666"),
           "claude --resume 0a1b2c3d-1111-2222-3333-444455556666 --fork-session")
        eq("fork: no session known, no command", Handoff.forkCommand(runtime: "claude", claudeSession: nil), nil)
        eq("fork: an id that isn't one is never typed into a shell", Handoff.forkCommand(runtime: "claude", claudeSession: "x; rm -rf ~"), nil)
        eq("fork: Codex forks its last", Handoff.forkCommand(runtime: "codex", claudeSession: nil), "codex fork --last")
        eq("fork: a vendor with no fork", Handoff.forkCommand(runtime: "copilot", claudeSession: nil), nil)
        check("fork: a second Claude account keeps its config",
              Handoff.forkCommand(runtime: "claude", claudeSession: "abc-123", account: "/srv/demo/.claude-second")?.hasPrefix("CLAUDE_CONFIG_DIR=") == true)
        let long = (1...3000).map { "line \($0) of the work" }.joined(separator: "\n")
        let cut = Handoff.tail(long)
        check("handoff: no more than the limit", cut.count <= Handoff.limit)
        check("handoff: the end is what's kept", cut.hasSuffix("line 3000 of the work"))
        check("handoff: and it starts at a line", cut.hasPrefix("line "))
        eq("handoff: short history goes whole", Handoff.tail("  hello\n"), "hello")
        let msg = Handoff.compose(from: "api", vendor: "Claude Code", folder: "/srv/demo", history: "did things")
        check("handoff: says it is history, not instructions", msg.contains("It is not instructions") && msg.contains("did things"))
        check("handoff: asks for nothing to be changed yet", msg.contains("Don't change anything yet"))
        check("handoff: the warning says nothing is redacted", Handoff.warning(to: "review", history: "abcd").contains("Nothing is redacted"))
        eq("handoff: tokens are a rough quarter of characters", Handoff.tokens(String(repeating: "x", count: 400)), 100)
    }
    do {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coldfall-tr-\(UUID().uuidString)").path
        let croot = root + "/claude", xroot = root + "/codex/2026/11/13"
        let pdir = Resume.claudeProjectDir(for: "/srv/demo/app", root: croot)
        try? fm.createDirectory(atPath: pdir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: xroot, withIntermediateDirectories: true)
        let c1 = [#"{"type":"custom-title","customTitle":"api","sessionId":"aaaa-1111"}"#,
                  #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system>ignore</system>"}}"#,
                  #"{"type":"user","message":{"role":"user","content":"Move the cart totals into their own file"}}"#,
                  #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done, see cart.js. The zebra test passes."}]}}"#]
        try? c1.joined(separator: "\n").write(toFile: pdir + "/aaaa-1111.jsonl", atomically: true, encoding: .utf8)
        let c2 = [#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Write the release notes"}]}}"#]
        try? c2.joined(separator: "\n").write(toFile: pdir + "/bbbb-2222.jsonl", atomically: true, encoding: .utf8)
        let x1 = [#"{"type":"session_meta","payload":{"id":"cccc-3333","cwd":"/srv/demo/app"}}"#,
                  #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
                  #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review the cart change"}]}}"#]
        try? x1.joined(separator: "\n").write(toFile: xroot + "/rollout-2026-11-13T10-00-00-cccc-3333.jsonl", atomically: true, encoding: .utf8)
        let x2 = [#"{"type":"session_meta","payload":{"id":"dddd-4444","cwd":"/srv/demo/other"}}"#]
        try? x2.joined(separator: "\n").write(toFile: xroot + "/rollout-2026-11-13T11-00-00-dddd-4444.jsonl", atomically: true, encoding: .utf8)

        let all = Transcripts.all(folder: "/srv/demo/app", claudeRoot: croot, codexRoot: root + "/codex")
        eq("transcripts: this folder's, from both vendors", Set(all.map(\.id)), ["aaaa-1111", "bbbb-2222", "cccc-3333"])
        let a = all.first { $0.id == "aaaa-1111" }
        eq("transcripts: a named one keeps its name", a?.title, "api")
        eq("transcripts: the first thing you asked, not the wrapper before it", a?.firstPrompt, "Move the cart totals into their own file")
        eq("transcripts: a prompt given as parts", all.first { $0.id == "bbbb-2222" }?.firstPrompt, "Write the release notes")
        eq("transcripts: Codex's first prompt is yours, not the developer's", all.first { $0.id == "cccc-3333" }?.firstPrompt, "Review the cart change")
        eq("transcripts: search reads the whole conversation", Transcripts.search(all, query: "zebra").map(\.id), ["aaaa-1111"])
        eq("transcripts: every word must be there", Transcripts.search(all, query: "zebra giraffe").count, 0)
        eq("transcripts: no query keeps them all", Transcripts.search(all, query: " ").count, 3)
        eq("transcripts: Claude's resume command", a.flatMap(Transcripts.resumeCommand), "claude --resume aaaa-1111")
        eq("transcripts: Codex's", all.first { $0.vendor == "codex" }.flatMap(Transcripts.resumeCommand), "codex resume cccc-3333")
        eq("transcripts: an id that isn't one is never a command",
           Transcripts.resumeCommand(Transcripts.Conversation(vendor: "claude", id: "x; rm -rf ~", path: "", folder: nil, modified: Date(), bytes: 1, title: nil, firstPrompt: nil)), nil)
        try? fm.removeItem(atPath: root)
    }
    do {
        let j = #"{"number":12,"title":"Cart totals","state":"OPEN","isDraft":false,"url":"https://example.com/pr/12","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://example.com/1"},{"name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://example.com/2"},{"name":"lint","status":"IN_PROGRESS","conclusion":""},{"context":"deploy/preview","state":"ERROR","targetUrl":"https://example.com/3"},{"name":"docs","status":"COMPLETED","conclusion":"SKIPPED"}]}"#
        let pr = PullRequest.parse(j)
        eq("pr: its number", pr?.number, 12)
        eq("pr: what failed, a check run and a commit status alike", pr?.failed.map(\.name), ["test", "deploy/preview"])
        eq("pr: what's still running", pr?.pending.map(\.name), ["lint"])
        eq("pr: what passed (skipped isn't passed)", pr?.passed.map(\.name), ["build"])
        eq("pr: one line", pr?.summary, "PR #12 · 2 checks failing · changes requested")
        check("pr: the fix message names each failing check and its link",
              pr?.fixChecksMessage?.contains("- test (https://example.com/2)") == true && pr?.fixChecksMessage?.contains("- deploy/preview") == true)
        check("pr: and asks not to push yet", pr?.fixChecksMessage?.contains("Don't push") == true)
        let ok = PullRequest.parse(#"{"number":3,"title":"t","state":"OPEN","isDraft":true,"url":"u","reviewDecision":"","statusCheckRollup":[{"name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#)
        eq("pr: all green", ok?.summary, "PR #3 · draft · all 1 checks passed")
        eq("pr: nothing failing, nothing to fix", ok?.fixChecksMessage, nil)
        eq("pr: merged says so", PullRequest.parse(#"{"number":4,"state":"MERGED"}"#)?.summary, "PR #4 · merged")
        eq("pr: not JSON, no pull request", PullRequest.parse("no pull requests found"), nil)
        eq("pr: no gh, no answer", PullRequest.fetch(folder: "/srv/demo", gh: nil), nil)
    }
    do {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))! }
        // 13 Nov 2026 is a Friday.
        let wk = Schedule(name: "plan", desk: "hub", prompt: "Plan today", at: "09:00", days: ["mon", "tue", "wed", "thu", "fri"])
        eq("schedule: due at its time today", wk.lastDue(before: at(2026, 11, 13, 9, 5), calendar: cal), at(2026, 11, 13, 9, 0))
        eq("schedule: before its time, the last one was yesterday", wk.lastDue(before: at(2026, 11, 13, 8, 0), calendar: cal), at(2026, 11, 12, 9, 0))
        eq("schedule: weekends are skipped", wk.lastDue(before: at(2026, 11, 15, 12, 0), calendar: cal), at(2026, 11, 13, 9, 0))
        let start = at(2026, 11, 13, 7, 0)
        eq("schedule: runs within the grace", wk.due(now: at(2026, 11, 13, 9, 5), handled: nil, since: start, calendar: cal), .run(at(2026, 11, 13, 9, 0)))
        eq("schedule: not twice", wk.due(now: at(2026, 11, 13, 9, 6), handled: at(2026, 11, 13, 9, 0), since: start, calendar: cal), .no)
        eq("schedule: too late is missed, not run", wk.due(now: at(2026, 11, 13, 10, 0), handled: nil, since: start, calendar: cal), .missed(at(2026, 11, 13, 9, 0)))
        eq("schedule: a time from before Coldfall opened isn't held against it",
           wk.due(now: at(2026, 11, 13, 10, 0), handled: nil, since: at(2026, 11, 13, 9, 30), calendar: cal), .no)
        var off = wk; off.enabled = false
        eq("schedule: off does nothing", off.due(now: at(2026, 11, 13, 9, 5), handled: nil, since: start, calendar: cal), .no)
        eq("schedule: in words", wk.when, "weekdays at 09:00")
        eq("schedule: every day", Schedule(name: "n", desk: "hub", prompt: "p", at: "18:30").when, "every day at 18:30")
        eq("schedule: a bad time is said", Schedule(name: "n", desk: "hub", prompt: "p", at: "9am").problem(desks: ["hub"]), "\"9am\" isn't a time. Use 24-hour HH:MM, like 09:00.")
        eq("schedule: an unknown desk is said", wk.problem(desks: ["api"]), "There's no desk called \"hub\".")
        eq("schedule: a good one has no problem", wk.problem(desks: ["hub"]), nil)
        check("schedule: the template is valid and switched off", { () -> Bool in
            let t = (try? JSONDecoder().decode([Schedule].self, from: Data(Schedule.template.utf8))) ?? []
            return t.count == 1 && t[0].isOn == false && t[0].time != nil
        }())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("coldfall-sched-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/runs.jsonl"
        Schedule.record(Schedule.Run(name: "plan", at: 1, outcome: .sent), path: log)
        Schedule.record(Schedule.Run(name: "plan", at: 2, outcome: .skippedPrecheck, note: "no"), path: log)
        eq("schedule: runs are kept, in order", Schedule.runs(path: log).map(\.outcome), [.sent, .skippedPrecheck])
        try? "not json".write(toFile: dir + "/s.json", atomically: true, encoding: .utf8)
        check("schedule: a file that isn't schedules is known to be broken", Schedule.broken(path: dir + "/s.json") && Schedule.load(path: dir + "/s.json").isEmpty)
        check("schedule: no precheck passes", Schedule.precheckPasses(nil, folder: dir) && Schedule.precheckPasses("  ", folder: dir))
        check("schedule: a precheck that exits 0 passes", Schedule.precheckPasses("true", folder: dir))
        check("schedule: one that doesn't, doesn't", !Schedule.precheckPasses("exit 3", folder: dir))
        try? FileManager.default.removeItem(atPath: dir)
    }
    do {
        var sc = OscScanner()
        let a = sc.feed(Array("hello \u{1b}]7501;state=working\u{07} world \u{1b}]0;my title\u{1b}\\ end".utf8))
        eq("osc: sequences out of the stream, BEL or ST ended", a, [OscScanner.Sequence(code: 7501, payload: "state=working"),
                                                                   OscScanner.Sequence(code: 0, payload: "my title")])
        var cut = OscScanner()
        let first = cut.feed(Array("x\u{1b}]7501;state=bl".utf8))
        let second = cut.feed(Array("ocked:kind=permission\u{07}y".utf8))
        eq("osc: nothing until it is whole", first, [])
        eq("osc: then the whole of it, across the cut", second, [OscScanner.Sequence(code: 7501, payload: "state=blocked:kind=permission")])
        var esc = OscScanner()
        _ = esc.feed([0x1b])
        eq("osc: even cut between ESC and ]", esc.feed(Array("]9;done\u{07}".utf8)), [OscScanner.Sequence(code: 9, payload: "done")])
        var csi = OscScanner()
        eq("osc: colour codes and the like are not OSC", csi.feed(Array("\u{1b}[1;32mgreen\u{1b}[0m".utf8)), [])
        var big = OscScanner()
        _ = big.feed(Array("\u{1b}]52;".utf8) + [UInt8](repeating: 65, count: OscScanner.limit + 10))
        eq("osc: a runaway one is dropped, and the next still reads", big.feed(Array("\u{07}\u{1b}]9;ok\u{07}".utf8)), [OscScanner.Sequence(code: 9, payload: "ok")])
        var nocode = OscScanner()
        eq("osc: no code, nothing", nocode.feed(Array("\u{1b}]junk\u{07}".utf8)), [])
        eq("osc: a 7501 payload reads as a report", ProgramStatus.parse(a[0].payload)?.state, "working")
    }
    eq("done: a line reads back", DoneSignal.parse("1700000000 stop hub"),
       DoneSignal.Signal(at: Date(timeIntervalSince1970: 1_700_000_000), event: .stop, desk: "hub"))
    check("done: junk is ignored", DoneSignal.parse("hello") == nil && DoneSignal.parse("1 maybe hub") == nil)

    // Settings: Coldfall's entry goes in beside the person's own hooks and
    // comes out again leaving theirs exactly as they were.
    let mine: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
    let added = DoneSignal.adding(to: mine, events: [("Stop", .stop), ("Notification", .notify)], script: "/x/done-hook.sh")
    check("done: added to Stop and Notification", added.map { DoneSignal.installed(in: $0, events: ["Stop", "Notification"]) } == true)
    let stopRules = (added?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
    eq("done: the person's own Stop hook stays", stopRules?.count, 2)
    check("done: adding twice changes nothing", added.flatMap { DoneSignal.adding(to: $0, events: [("Stop", .stop)], script: "/x/done-hook.sh") } == nil)
    let removed = added.flatMap { DoneSignal.removing(from: $0) }
    let back = (removed?["hooks"] as? [String: Any])
    check("done: removing leaves only theirs",
          (back?["Stop"] as? [[String: Any]])?.count == 1 && back?["Notification"] == nil && removed?["model"] as? String == "opus")
    check("done: nothing of ours, nothing to remove", DoneSignal.removing(from: mine) == nil)
    let onlyOurs = DoneSignal.adding(to: [:], events: [("Stop", .stop)], script: "/x/done-hook.sh")!
    check("done: an emptied hooks table is dropped", DoneSignal.removing(from: onlyOurs).map { $0["hooks"] == nil } == true)

    // Install into a fake home: Claude's settings and Codex's hooks.json.
    try? #"{"theme": "dark"}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
    let log = DoneSignal.install(desks: [], home: home, codex: true)
    check("done: installed for Claude and Codex", log.count == 2 && log.allSatisfy { $0.hasPrefix("Turned on") })
    let claudeJSON = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: home + "/.claude/settings.json")!)) as? [String: Any]
    check("done: Claude's other settings survive", claudeJSON?["theme"] as? String == "dark")
    let codexJSON = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: home + "/.codex/hooks.json")!)) as? [String: Any]
    check("done: Codex gets Stop only", codexJSON.map { DoneSignal.installed(in: $0, events: ["Stop"])
                                                        && !DoneSignal.installed(in: $0, events: ["Notification"]) } == true)
    check("done: the script is executable", fm.isExecutableFile(atPath: DoneSignal.scriptPath))

    // The script itself, run the way a hook runs it.
    func runHook(_ ev: String, desk: String?, stdin: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [DoneSignal.scriptPath, ev]
        var env = ["HOME": home, "PATH": "/usr/bin:/bin"]
        if let desk { env["CLAUDE_DESK"] = desk }
        p.environment = env
        let pipe = Pipe(); p.standardInput = pipe
        try? p.run()
        pipe.fileHandleForWriting.write(stdin.data(using: .utf8)!); try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
    }
    let reader = DoneSignal.Reader(path: DoneSignal.logPath, fromStart: true)
    runHook("stop", desk: "hub", stdin: #"{"hook_event_name":"Stop"}"#)
    runHook("notify", desk: "cars", stdin: #"{"notification_type":"permission_prompt"}"#)
    runHook("notify", desk: "golf", stdin: #"{"notification_type":"idle_prompt"}"#)
    runHook("stop", desk: nil, stdin: "{}")
    runHook("stop", desk: "odd name", stdin: "{}")
    let got = reader.read()
    eq("done: the hook writes what happened, to which desk", got.map { "\($0.event.rawValue) \($0.desk)" },
       ["stop hub", "notify cars", "stop odd_name"])
    eq("done: and nothing is read twice", reader.read().count, 0)
    try? "1700000000 sto".write(toFile: DoneSignal.logPath, atomically: true, encoding: .utf8)
    eq("done: a half-written line waits; a trimmed log starts over", reader.read().count, 0)

    let gone = DoneSignal.uninstall(desks: [], home: home)
    check("done: uninstall takes it out of both", gone.count == 2 && !fm.fileExists(atPath: DoneSignal.scriptPath))
    let afterJSON = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: home + "/.claude/settings.json")!)) as? [String: Any]
    check("done: and Claude's settings are as they were", afterJSON?["hooks"] == nil && afterJSON?["theme"] as? String == "dark")
    check("done: the remove-files text says so", Uninstall.summary(items: [], recorders: [], doneHook: true).contains("done hook"))

    // The rail, once a desk reports.
    let t0 = Date()
    var s = ActivityState()
    s.setVisible(false)
    s.noteAsked()
    s.noteSignal(at: t0)
    eq("done: the agent's word turns a desk green", s.activity(now: t0.addingTimeInterval(0.1)), .ready)
    s.setVisible(true); s.setVisible(false, at: t0.addingTimeInterval(10))
    s.noteOutput(at: t0.addingTimeInterval(20))
    eq("done: after that, output shows it working", s.activity(now: t0.addingTimeInterval(20.5)), .working)
    eq("done: but never turns it green on its own", s.activity(now: t0.addingTimeInterval(30)), .quiet)
    var w = ActivityState()
    w.setVisible(true)
    w.noteAsked()
    w.noteSignal(at: t0)
    w.setVisible(false, at: t0.addingTimeInterval(1))
    eq("done: finishing while you watched isn't news later", w.activity(now: t0.addingTimeInterval(9)), .quiet)
    w.noteSignal(at: t0.addingTimeInterval(10))
    eq("done: nor is a timer's turn after it", w.activity(now: t0.addingTimeInterval(20)), .quiet)

    // A timer inside the conversation finishes turns nobody asked for.
    var loop = ActivityState()
    loop.setVisible(false)
    loop.noteSignal(at: t0)
    loop.noteSignal(at: t0.addingTimeInterval(600))
    eq("timer: a turn you didn't ask for isn't green", loop.activity(now: t0.addingTimeInterval(700)), .quiet)
    loop.noteSignal(.notify, at: t0.addingTimeInterval(800))
    eq("timer: but needing you always is, as blocked", loop.activity(now: t0.addingTimeInterval(900)), .blocked)
    var asked = ActivityState()
    asked.setVisible(true)
    asked.noteAsked()
    asked.setVisible(false, at: t0)
    asked.setVisible(true, at: t0.addingTimeInterval(5))
    asked.setVisible(false, at: t0.addingTimeInterval(6))
    asked.noteSignal(at: t0.addingTimeInterval(60))
    eq("timer: a glance mid-job doesn't lose the finish", asked.activity(now: t0.addingTimeInterval(70)), .ready)
    asked.setVisible(true, at: t0.addingTimeInterval(80))
    asked.setVisible(false, at: t0.addingTimeInterval(81))
    asked.noteSignal(at: t0.addingTimeInterval(700))
    eq("timer: once read, the next timer turn is quiet", asked.activity(now: t0.addingTimeInterval(800)), .quiet)
    var perm = ActivityState()
    perm.setVisible(false)
    perm.noteAsked()
    perm.noteSignal(.notify, at: t0)
    check("timer: being asked for permission keeps the ask open", perm.asked)
    check("submit: a return counts", ActivityState.isSubmit([104, 105, 13]))
    check("submit: a key doesn't", !ActivityState.isSubmit([104]))
    check("submit: a focus report doesn't", !ActivityState.isSubmit([27, 91, 73]) && !ActivityState.isSubmit([27, 91, 79]))
    check("submit: Enter in the kitty encoding does", ActivityState.isSubmit(Array("\u{1b}[13u".utf8)))
    check("submit: shift-Enter doesn't", !ActivityState.isSubmit(Array("\u{1b}[13;2u".utf8)))
    check("submit: returns inside a paste don't", !ActivityState.isSubmit(Array("\u{1b}[200~a\nb\u{1b}[201~".utf8)))
    check("submit: a paste then Enter does", ActivityState.isSubmit(Array("\u{1b}[200~a\u{1b}[201~\r".utf8)))
}

// MARK: - pinned desks, and ready desks floating to the top

do {
    var list = [Desk(name: "shell"), Desk(name: "hub"),
                Desk(name: "cpa", group: "money"), Desk(name: "market", group: "money"),
                Desk(name: "golf", group: "personal"), Desk(name: "cars", group: "personal"),
                Desk(name: "old", group: "personal")]
    list[6].hidden = true
    eq("zones: nothing pinned, nothing ready, nothing on top",
       DeskOrder.zones(list, floated: []), DeskOrder.Zones(pinned: [], floated: []))
    typealias L = DeskOrder.Live
    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
    eq("active: a running desk comes up, out of its group", DeskOrder.active(list, live: ["golf": L(rank: 3, lastOutput: t(5))], enabled: true), ["golf"])
    eq("active: needs you, done, working, idle",
       DeskOrder.active(list, live: ["hub": L(rank: 3, lastOutput: t(9)), "cpa": L(rank: 2, lastOutput: t(8)),
                                     "golf": L(rank: 0, lastOutput: t(1)), "cars": L(rank: 1, lastOutput: t(2))], enabled: true),
       ["golf", "cars", "cpa", "hub"])
    eq("active: the longest wait first among those waiting",
       DeskOrder.active(list, live: ["hub": L(rank: 1, lastOutput: t(9)), "cpa": L(rank: 1, lastOutput: t(3))], enabled: true), ["cpa", "hub"])
    eq("active: the most recent first among the rest",
       DeskOrder.active(list, live: ["hub": L(rank: 3, lastOutput: t(3)), "cpa": L(rank: 3, lastOutput: t(9))], enabled: true), ["cpa", "hub"])
    eq("active: off means nothing moves", DeskOrder.active(list, live: ["golf": L(rank: 0, lastOutput: nil)], enabled: false), [])
    eq("active: a hidden desk stays hidden", DeskOrder.active(list, live: ["old": L(rank: 0, lastOutput: nil), "golf": L(rank: 3, lastOutput: nil)], enabled: true), ["golf"])
    eq("active: a desk that is gone is ignored", DeskOrder.active(list, live: ["nope": L(rank: 0, lastOutput: nil)], enabled: true), [])
    list[5].pinned = true      // cars
    list[1].pinned = true      // hub
    eq("zones: pinned desks come first, in your order",
       DeskOrder.zones(list, floated: []).pinned, [1, 5])
    eq("active: a pinned desk keeps the very top instead",
       DeskOrder.active(list, live: ["cars": L(rank: 0, lastOutput: nil), "golf": L(rank: 3, lastOutput: nil)], enabled: true), ["golf"])
    do {
        var t = [Desk(name: "hub"), Desk(name: "work", group: "w"), Desk(name: "a", group: "w"),
                 Desk(name: "b", group: "w"), Desk(name: "golf", group: "home"), Desk(name: "old", group: "w")]
        t[5].hidden = true
        eq("tabs: the running desks in this desk's group, in rail order",
           DeskTabs.list(t, current: "work", running: ["b", "work", "golf"]), ["work", "b"])
        eq("tabs: the desk on screen has a tab even when stopped",
           DeskTabs.list(t, current: "a", running: ["b"]), ["a", "b"])
        eq("tabs: another group is another set", DeskTabs.list(t, current: "golf", running: ["b", "golf"]), ["golf"])
        eq("tabs: ungrouped desks share a set", DeskTabs.list(t, current: "hub", running: ["work"]), ["hub"])
        eq("tabs: a hidden desk gets no tab", DeskTabs.list(t, current: "work", running: ["old", "work"]), ["work"])
        eq("tabs: a desk on screen has a tab, from another group, after the one with the keys",
           DeskTabs.list(t, current: "work", running: ["b", "work", "golf"], onScreen: ["work", "golf"]), ["work", "golf", "b"])
        eq("tabs: a desk on screen from this group keeps its place",
           DeskTabs.list(t, current: "work", running: ["b", "work"], onScreen: ["b", "work"]), ["work", "b"])
        eq("tabs: several from other groups keep their screen order",
           DeskTabs.list(t, current: "a", running: ["a"], onScreen: ["golf", "a", "hub"]), ["a", "golf", "hub"])
        eq("tabs: a desk on screen that no longer exists adds nothing",
           DeskTabs.list(t, current: "work", running: ["work"], onScreen: ["work", "gone"]), ["work"])
    }
    do {
        check("grid: choosing a desk that is on screen goes to it", DeskGrid.place("b", onScreen: ["a", "b", "c"], key: 0) == .focus(1))
        check("grid: any other desk replaces the one with the keys", DeskGrid.place("d", onScreen: ["a", "b", "c"], key: 2) == .replace(2))
        check("grid: nothing on screen yet, it takes the first place", DeskGrid.place("a", onScreen: [], key: 0) == .replace(0))
        check("grid: one more fits", DeskGrid.canAdd("b", onScreen: ["a"]))
        check("grid: a desk is on screen once", !DeskGrid.canAdd("a", onScreen: ["a", "b"]))
        check("grid: nothing on screen, nothing to be beside", !DeskGrid.canAdd("a", onScreen: []))
        check("grid: twelve is full", !DeskGrid.canAdd("z", onScreen: (0..<12).map { "d\($0)" }))
        eq("grid: taking off one before the keys keeps the same desk", DeskGrid.keyAfterRemoving(0, key: 2, count: 3), 1)
        eq("grid: taking off the one with the keys goes left", DeskGrid.keyAfterRemoving(2, key: 2, count: 3), 1)
        eq("grid: taking off the first, with the keys, stays first", DeskGrid.keyAfterRemoving(0, key: 0, count: 3), 0)
        eq("grid: taking off one after the keys changes nothing", DeskGrid.keyAfterRemoving(2, key: 0, count: 3), 0)
        for (n, want) in [(1, (1, 1)), (2, (1, 2)), (3, (1, 3)), (4, (2, 2)), (5, (2, 3)), (6, (2, 3)), (8, (2, 4)), (9, (3, 3)), (12, (3, 4))] {
            let got = DeskGrid.shape(n)
            check("grid: \(n) desks are \(want.0) by \(want.1)", got.rows == want.0 && got.cols == want.1)
        }
        let two = DeskGrid.frames(count: 2, width: 1000, height: 600, split: 0.9)
        eq("grid: two split where dragged, each keeping a usable width", two.map { Double($0.size.width) }, [740, 260])
        let five = DeskGrid.frames(count: 5, width: 900, height: 600)
        eq("grid: five are three over two", five.map { Double($0.origin.y) }, [0, 0, 0, 300, 300])
        eq("grid: a short last row shares the whole width", five.map { Double($0.size.width) }, [300, 300, 300, 450, 450])
        for n in 1...12 {
            let f = DeskGrid.frames(count: n, width: 1001, height: 701)
            let area = f.reduce(0.0) { $0 + Double($1.size.width) * Double($1.size.height) }
            check("grid: \(n) desks cover the space exactly, none overlapping", f.count == n && abs(area - 1001 * 701) < 0.5)
        }
        do {
            let all: [(name: String, group: String?, running: Bool, hidden: Bool)] = [
                ("a", "one", true, false), ("b", "one", false, false), ("c", "two", true, false),
                ("d", "two", true, true), ("e", nil, true, false)]
            let c = DeskGrid.choices(all, onScreen: ["a", "e"])
            eq("grid: choices cross groups, running first, none on screen or hidden", c.map(\.name), ["c", "b"])
            eq("grid: a choice names its group", c.first?.title, "c  ·  two")
            eq("grid: a desk with no group is just its name", DeskGrid.Choice(name: "e", group: nil, running: true).title, "e")
            check("grid: nothing on screen, nothing to be beside", DeskGrid.choices(all, onScreen: []).isEmpty)
        }
        let bm = DeskMenu.items(runtime: "claude", running: true, hidden: false, canReveal: false, canMakeDefault: false,
                                hasInventory: true, hasMcp: true, canBeside: true)
        check("menu: a desk can open beside", bm.contains { $0.action == .beside })
        let many = ["a", "b", "c", "d", "e"]
        check("tabs: all shown when there is room", DeskTabs.fit(many, current: "a", room: 5) == (many, []))
        check("tabs: the rest go to the more menu", DeskTabs.fit(many, current: "a", room: 3) == (["a", "b", "c"], ["d", "e"]))
        check("tabs: the desk on screen always keeps a tab", DeskTabs.fit(many, current: "e", room: 3) == (["a", "b", "e"], ["c", "d"]))
        check("tabs: no room, no tabs", DeskTabs.fit(many, current: "a", room: 0) == ([], many))
        eq("counts: one of each", DeskCounts.of([.blocked, .working, .ready, .quiet, .ready]),
           DeskCounts(needsYou: 1, working: 1, done: 2))
        eq("counts: chips read as a sentence", DeskCounts(needsYou: 1, working: 2, done: 0).chips, ["1 needs you", "2 working"])
        eq("counts: plural", DeskCounts(needsYou: 2).chips, ["2 need you"])
        eq("counts: nothing going on, no chips", DeskCounts().chips, [])
    }
    eq("badge: Claude is a C on its colour", VendorBadge.badge(runtime: "claude", icon: nil), VendorBadge.Badge(text: "C", fill: 0xC96442))
    eq("badge: Codex an X", VendorBadge.badge(runtime: "codex", icon: nil).text, "X")
    eq("badge: a desk's own letter wins", VendorBadge.badge(runtime: "claude", icon: "m").text, "M")
    eq("badge: an emoji has no fill", VendorBadge.badge(runtime: "claude", icon: "⛳️").fill, nil)
    let z = DeskOrder.zones(list, floated: ["golf", "golf", "cars"])
    eq("zones: no desk appears twice", z, DeskOrder.Zones(pinned: [1, 5], floated: [4]))
    check("zones: and a desk in a zone is known to be there", z.contains(4) && z.contains(5) && !z.contains(0))
    eq("cmd-1..9 start with the pinned desks, as the rail does", DeskOrder.shortcuts(list), [1, 5, 0, 2, 3, 4])
    list[6].pinned = true
    eq("zones: hidden wins over pinned", DeskOrder.zones(list, floated: []).pinned, [1, 5])

    let back = parse("[desk.a]\npinned = true\n[desk.b]\n")
    check("config: pinned is read", back.first?.pinned == true && back.last?.pinned == false)
    let f = FileManager.default.temporaryDirectory.appendingPathComponent("coldfall-pin-\(UUID().uuidString).toml")
    var two = [Desk(name: "a"), Desk(name: "b")]; two[1].pinned = true
    DeskConfig.write(two, to: f.path)
    let again = DeskConfig.load(path: f.path)
    check("config: and survives a save", again.map(\.pinned) == [false, true])
    try? FileManager.default.removeItem(at: f)

    let m = DeskMenu.items(runtime: "claude", running: false, hidden: false, canReveal: false,
                           canMakeDefault: false, hasInventory: true, hasMcp: true, pinned: false)
    check("menu: a desk can be pinned", m.contains { $0.action == .pin } && !m.contains { $0.action == .unpin })
    let p = DeskMenu.items(runtime: "claude", running: true, hidden: false, canReveal: false,
                           canMakeDefault: false, hasInventory: true, hasMcp: true, pinned: true)
    check("menu: a pinned one can be unpinned", p.contains { $0.action == .unpin } && !p.contains { $0.action == .pin })
    check("menu: pinning keeps the destructive entry apart", DeskMenu.destructiveIsIsolated(p))
    eq("menu: and remove is still last", p.last?.action, .remove)
    let fresh = DeskMenu.items(runtime: "claude", running: true, hidden: false, canReveal: true,
                               canMakeDefault: false, hasInventory: true, hasMcp: true, pinned: false, news: 2)
    eq("menu: news puts the way to see it first", fresh.first?.action, .inventory)
    check("menu: saying how many and that looking clears it",
          fresh.first?.title.contains("(2)") == true && fresh.first?.subtitle?.contains("clears") == true)
    eq("menu: and it is offered once", fresh.filter { $0.action == .inventory }.count, 1)
    check("menu: news is never in a warning tone", fresh.first?.tone == .normal)
    check("menu: news keeps the destructive entry apart", DeskMenu.destructiveIsIsolated(fresh))
    let h = DeskMenu.items(runtime: "claude", running: false, hidden: true, canReveal: false,
                           canMakeDefault: false, hasInventory: true, hasMcp: true, pinned: nil)
    check("menu: a hidden desk isn't offered a pin", !h.contains { $0.action == .pin || $0.action == .unpin })
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
        if Reopen.lastTurn(path, tail: tail)?.tokens == 602_003 { ok += 1 }
    }
    eq("tail: found from any cut point", ok, 5)
    // the record is further back than the tail: read further, once
    lines.append(contentsOf: Array(repeating: #"{"type":"user","message":{"content":"\#(String(repeating: "z", count: 2000))"}}"#, count: 400))
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    eq("tail: a huge trailing tool result doesn't hide the last turn", Reopen.lastTurn(path, tail: 64 * 1024)?.tokens, 602_003)
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

    // The suite's stand-in for the real config folder: its hook must survive
    // an uninstall that was pointed somewhere else.
    try? fm.createDirectory(atPath: Limits.configDir, withIntermediateDirectories: true)
    try? "#!/bin/sh\n".write(toFile: DoneSignal.scriptPath, atomically: true, encoding: .utf8)
    let log = Uninstall.removeEverything(desks: [d], configRoot: cfg, dataRoot: data, home: home)
    check("leaving: an uninstall of another folder leaves the real done hook alone",
          fm.fileExists(atPath: DoneSignal.scriptPath))
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
    check("repaint: status line ticking is not news", ScreenChange.newLines(before: left, after: repaint).isEmpty)
    check("repaint: an identical screen is not news", ScreenChange.newLines(before: left, after: left.map { $0 + "  " }).isEmpty)
    var reply = left; reply[3] = "Also pushed it."
    check("repaint: a new line above the input box is news", !ScreenChange.newLines(before: left, after: reply).isEmpty)
    // A notice under the input box pushes everything up a row. Nothing new
    // was said, and this is what turned read desks green after a while.
    let pushed = Array(left.dropFirst()) + ["  ✓ Update installed · Restart to apply"]
    check("repaint: rows pushed up by a notice below are not news", ScreenChange.newLines(before: left, after: pushed).isEmpty)
    let shifted = Array(left.dropFirst()) + [""]
    check("repaint: the same lines, moved, are not news", ScreenChange.newLines(before: left, after: shifted).isEmpty)
    var timer = left; timer[2] = "Done. Tests pass in 12s."
    var timer2 = left; timer2[2] = "Done. Tests pass in 13s."
    check("repaint: a number ticking in the text is not news", ScreenChange.newLines(before: timer, after: timer2).isEmpty)
    var answer = left; answer[0] = "> fix the build"; answer[1] = "Fixed two imports."
    eq("repaint: a new line anywhere above the footer is news, and is named",
       ScreenChange.newLines(before: left, after: answer), ["Fixed two imports."])
    let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("coldfall-green-\(UUID().uuidString)")
    let realLog = ScreenChange.logPath
    ScreenChange.logPath = logDir.appendingPathComponent("green.log").path
    for i in 0..<105 { ScreenChange.logGreen(desk: "d\(i)", lines: [String(repeating: "x", count: 200)]) }
    let logged = (try? String(contentsOfFile: ScreenChange.logPath, encoding: .utf8))?.split(separator: "\n") ?? []
    eq("green log: keeps the last hundred", logged.count, 100)
    check("green log: newest last, line cut short", logged.last?.contains("d104") == true && (logged.last?.count ?? 999) < 140)
    ScreenChange.logPath = realLog
    try? FileManager.default.removeItem(at: logDir)
    let grown = ["> fix the build", "Done. Tests pass.", "Also pushed it."] + Array(left.suffix(from: 4))
    check("repaint: a reply that scrolled the screen is still news", !ScreenChange.newLines(before: left, after: grown).isEmpty)
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

// MARK: - opening a desk from outside

do {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "cf-remote-\(UUID().uuidString)"
    let was = RemoteOpen.root
    RemoteOpen.root = root
    defer { RemoteOpen.root = was; try? fm.removeItem(atPath: root) }

    let names = ["hub", "market", "golf", "secret"]
    eq("remote: a desk in the list starts", RemoteOpen.decide("market", names: names, hidden: [], running: []).outcome, .started)
    eq("remote: one already going is left alone",
       RemoteOpen.decide("hub", names: names, hidden: [], running: ["hub"]).outcome, .alreadyRunning)
    eq("remote: a name not in desks.toml opens nothing",
       RemoteOpen.decide("rm -rf", names: names, hidden: [], running: []).outcome, .unknownDesk)
    eq("remote: names are exact", RemoteOpen.decide("Market", names: names, hidden: [], running: []).outcome, .unknownDesk)
    check("remote: a near miss suggests the real name",
          RemoteOpen.decide("Market", names: names, hidden: [], running: []).message.contains("\"market\""))
    eq("remote: a hidden desk stays hidden",
       RemoteOpen.decide("secret", names: names, hidden: ["secret"], running: []).outcome, .hiddenDesk)

    let now = Date()
    let r = RemoteOpen.Request(desk: "golf", time: now.timeIntervalSince1970)
    try? RemoteOpen.submit(r)
    let old = RemoteOpen.Request(desk: "hub", time: now.timeIntervalSince1970 - 600)
    try? RemoteOpen.submit(old)
    try? "not json".write(toFile: root + "/requests/junk.json", atomically: true, encoding: .utf8)
    eq("remote: a fresh request waits, stale and broken ones don't", RemoteOpen.pending(now: now).map(\.desk), ["golf"])
    check("remote: the stale one is cleared away", !fm.fileExists(atPath: root + "/requests/\(old.id).json"))
    RemoteOpen.answer(r, .init(.started, "Started golf in Coldfall."))
    eq("remote: an answered request leaves the queue", RemoteOpen.pending(now: now).count, 0)
    eq("remote: the asker reads the answer", RemoteOpen.wait(for: r, timeout: 1)?.outcome, .started)
    let lost = RemoteOpen.Request(desk: "golf")
    try? RemoteOpen.submit(lost)
    eq("remote: no answer is nil", RemoteOpen.wait(for: lost, timeout: 0.3), nil)
    check("remote: and the unanswered request is withdrawn", RemoteOpen.pending().isEmpty)

    let st = RemoteOpen.Status(time: now.timeIntervalSince1970, pid: 42,
                               desks: [.init(name: "hub", running: true, activity: "ready")])
    RemoteOpen.writeStatus(st)
    eq("remote: status reads back while the app is alive", RemoteOpen.status(now: now, alive: { _ in true }), st)
    eq("remote: not once the app has gone", RemoteOpen.status(now: now, alive: { _ in false }), nil)
    eq("remote: nor when it has gone quiet", RemoteOpen.status(now: now.addingTimeInterval(60), alive: { _ in true }), nil)
}

// MARK: - desks that keep running (Holder)

do {
    let fm = FileManager.default
    // The wire: frames survive being cut anywhere.
    do {
        var d = Holder.Decoder()
        let f = d.push(Holder.Wire.encode(.tap, Holder.Wire.tap()) + Holder.Wire.encode(.output, Array("hi".utf8)))
        check("holder: a tap is its own kind", f.first?.0 == .tap)
        eq("holder: and carries the version", f.first.flatMap { Holder.Wire.readVersion($0.1) }, Holder.protocolVersion)
        check("holder: a tap doesn't break the stream after it", !d.broken && f.count == 2)
        eq("holder: a hello's version reads the same way", Holder.Wire.readVersion(Holder.Wire.hello(cols: 1, rows: 1)), Holder.protocolVersion)
    }
    let frames = Holder.Wire.encode(.hello, Holder.Wire.hello(cols: 120, rows: 40))
        + Holder.Wire.encode(.input, Array("ls\r".utf8))
        + Holder.Wire.encode(.exit, Holder.Wire.status(7))
    var dec = Holder.Decoder()
    var got: [(Holder.Kind, [UInt8])] = []
    for b in frames { got += dec.push([b]) }
    eq("holder: three frames back from a byte-at-a-time stream", got.count, 3)
    check("holder: hello carries the size", got.first.flatMap { Holder.Wire.readSize($0.1) }.map { $0.cols == 120 && $0.rows == 40 } == true)
    eq("holder: input intact", got.count > 1 ? String(decoding: got[1].1, as: UTF8.self) : nil, "ls\r")
    eq("holder: exit status intact", got.count > 2 ? Holder.Wire.readStatus(got[2].1) : nil, 7)
    eq("holder: a negative status round-trips", Holder.Wire.readStatus(Holder.Wire.status(-1)), -1)
    var bad = Holder.Decoder()
    _ = bad.push([0x00, 0, 0, 0, 1, 9])
    check("holder: an unknown frame marks the stream broken", bad.broken)
    var big = Holder.Decoder()
    _ = big.push([Holder.Kind.output.rawValue, 0x7f, 0xff, 0xff, 0xff])
    check("holder: an oversized length is refused, not waited for", big.broken)

    // Replay keeps the tail and starts on a clean line once trimmed.
    var r = Holder.Replay(capacity: 10)
    r.append(Array("abc".utf8))
    eq("holder: replay before any trim is everything", String(decoding: r.snapshot, as: UTF8.self), "abc")
    r.append(Array("\u{1b}[31mred\nnext line\n".utf8))
    let snap = String(decoding: r.snapshot, as: UTF8.self)
    check("holder: trimmed replay stays within capacity", r.snapshot.count <= 10)
    check("holder: and never starts mid escape sequence", !snap.contains("[31m") && !snap.hasPrefix("m"), snap)

    // Paths.
    let p = Holder.socketPath(desk: "hub", root: "/srv/h")
    eq("holder: a plain desk name is readable", p, "/srv/h/hub.sock")
    let odd = Holder.socketPath(desk: "my desk/../x", root: "/srv/h")
    check("holder: an odd name gets a hash, inside the folder", odd.hasPrefix("/srv/h/d-") && !odd.contains(".."), odd)
    eq("holder: the hash is stable", odd, Holder.socketPath(desk: "my desk/../x", root: "/srv/h"))
    let long = Holder.socketPath(desk: String(repeating: "a", count: 90), root: "/srv/h")
    check("holder: a long name is hashed to fit", Holder.fits(long), long)
    check("holder: a folder too deep doesn't fit", !Holder.fits(Holder.socketPath(desk: "hub", root: "/" + String(repeating: "x", count: 120))))
    eq("holder: pid file beside the socket", Holder.pidPath(socket: p), "/srv/h/hub.pid")

    // Which desks keep running.
    var d = Desk(name: "hub", runtime: "claude")
    check("holder: a desk follows the setting", d.keepsRunning(global: true) && !d.keepsRunning(global: false))
    d.keepRunning = false
    check("holder: a desk can opt out", !d.keepsRunning(global: true))
    d.keepRunning = true
    check("holder: or in", d.keepsRunning(global: false))
    let sh = Desk(name: "sh", runtime: "shell")
    check("holder: a plain shell desk isn't held unless it asks", !sh.keepsRunning(global: true))
    try? fm.createDirectory(atPath: testSandbox, withIntermediateDirectories: true)
    let tomlPath = testSandbox + "/keep.toml"
    DeskConfig.write([d], to: tomlPath)
    let toml = (try? String(contentsOfFile: tomlPath, encoding: .utf8)) ?? ""
    check("holder: keep_running is written", toml.contains("keep_running = true"), toml)
    eq("holder: and read back", DeskConfig.load(path: tomlPath).first?.keepRunning, true)
    try? "[desk.a]\nruntime = \"claude\"\n".write(toFile: tomlPath, atomically: true, encoding: .utf8)
    eq("holder: absent means follow the setting", DeskConfig.load(path: tomlPath).first.map { $0.keepRunning == nil }, true)

    // Quitting.
    let one = QuitPrompt.text(desks: ["hub"])
    eq("quit: one desk is named in the title", one.title, "Keep hub running after Coldfall quits?")
    check("quit: it says what it costs", one.body.contains("400 to 600 MB"))
    let many = QuitPrompt.text(desks: ["hub", "work", "golf"])
    eq("quit: several are counted", many.title, "Keep 3 desks running after Coldfall quits?")
    check("quit: and listed", many.body.hasPrefix("hub, work and golf keep working"), many.body)
    eq("quit: keep is the first button", many.keep, "Keep Them Running")

    // Offering desks back after a restart.
    eq("restore: what ran and isn't back, in order, once each",
       RestoreOffer.desks(wasRunning: ["hub", "gone", "work", "secret", "golf", "hub"], names: ["hub", "work", "golf", "secret"],
                          hidden: ["secret"], runningNow: ["golf"]), ["hub", "work"])
    eq("restore: nothing to say for nothing", RestoreOffer.line([]), nil)
    check("restore: names them", RestoreOffer.line(["hub", "work"])?.contains("hub and work") == true)
    eq("restore: one button", RestoreOffer.button(["hub"]), "Start hub Again")
    eq("text: lists join like a person would", TextStyle.list(["a", "b", "c"]), "a, b and c")
    eq("text: a name keeps its capital in a heading", TextStyle.sentence("WHEN COLDFALL QUITS"), "When Coldfall quits")
    eq("text: long lists are cut", TextStyle.list(["a", "b", "c", "d"], max: 2), "a, b and 2 more")

    // State: older ui.json files still load.
    let old = try? JSONDecoder().decode(UIState.self, from: Data(#"{"seenWelcome":true}"#.utf8))
    check("ui: an older file loads with holding off and nothing remembered",
          old.map { $0.seenWelcome && !$0.keepDesksRunning && $0.runningDesks.isEmpty } == true)

    // Activity: a reattach's replay is not news.
    var a = ActivityState()
    a.setVisible(false, at: Date(timeIntervalSince1970: 0))
    a.mute(for: 3, at: Date(timeIntervalSince1970: 100))
    a.noteOutput(at: Date(timeIntervalSince1970: 101))
    check("activity: replayed output doesn't mark a desk unseen", !a.unseen)
    a.noteOutput(at: Date(timeIntervalSince1970: 110))
    check("activity: output after the replay does", a.unseen)

    // The real thing: the holder binary, held, survives its terminal, ends on request.
    let bin = ((CommandLine.arguments[0] as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("coldfall-holder")
    if fm.isExecutableFile(atPath: bin) {
        let root = Holder.root
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: bin)
        attach.arguments = ["attach", "suite", "--", "/bin/sh", "-c", "echo HELD; sleep 60"]
        attach.environment = ["COLDFALL_HOLDER_DIR": root, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        attach.standardInput = input; attach.standardOutput = output; attach.standardError = FileHandle.nullDevice
        try? attach.run()
        var held = false
        for _ in 0..<60 where !held { usleep(50_000); held = Holder.held(root: root).contains("suite") }
        check("holder: attach starts a holder for the desk", held)
        usleep(600_000)    // let the first output arrive before the terminal goes
        // Coldfall's terminal goes away: the attach exits, the holder doesn't.
        try? input.fileHandleForWriting.close()
        attach.waitUntilExit()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check("holder: output reached the terminal", out.contains("HELD"), out)
        check("holder: still held after its terminal closed", Holder.isHeld(desk: "suite", root: root))
        check("holder: knows the held shell's pid", (Holder.heldPid(desk: "suite", root: root) ?? 0) > 0)
        check("holder: ending it is delivered", Holder.end(desk: "suite", root: root))
        var gone = false
        for _ in 0..<120 where !gone { usleep(50_000); gone = !Holder.isHeld(desk: "suite", root: root) }
        check("holder: and it's gone", gone)
        check("holder: its files are cleared", Holder.held(root: root).isEmpty
              && !fm.fileExists(atPath: Holder.socketPath(desk: "suite", root: root)))
    } else {
        print("  skip  holder binary not built beside the tests")
    }
    try? fm.removeItem(atPath: Holder.root)
}

// MARK: - needs you, notifications, read and send

do {
    let t0 = Date(timeIntervalSince1970: 1000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // Blocked: a question for you outranks everything and stays until answered.
    var a = ActivityState()
    a.setVisible(false, at: at(0))
    a.noteSignal(.notify, at: at(10))
    eq("blocked: a question makes the desk blocked", a.activity(now: at(11)), .blocked)
    a.setVisible(true, at: at(12)); a.setVisible(false, at: at(13))
    eq("blocked: looking doesn't answer it", a.activity(now: at(20)), .blocked)
    a.noteTyping(Array("1".utf8), at: at(21))
    check("blocked: a keystroke into the desk does", !a.needsYou)
    var b = ActivityState()
    b.setVisible(false, at: at(0))
    b.noteSignal(.notify, at: at(10))
    b.noteOutput(at: at(12))
    eq("blocked: a repaint right after the question isn't an answer", b.activity(now: at(13)), .blocked)
    b.noteOutput(at: at(20))
    check("blocked: output alone never answers it (it may be a repaint)", b.needsYou)
    b.noteTyping([27, 91, 66], at: at(21))
    check("blocked: moving through the choices doesn't answer it", b.needsYou)
    b.noteTyping([13], at: at(22))
    check("blocked: Return does", !b.needsYou)
    var bb = ActivityState()
    bb.noteSignal(.notify, at: at(1))
    bb.noteResumed()
    check("blocked: the agent saying it's working again does (answered elsewhere)", !bb.needsYou)
    var c = ActivityState()
    c.noteSignal(.notify, at: at(1)); c.noteSignal(.stop, at: at(2))
    check("blocked: the turn finishing clears it", !c.needsYou)
    var d = ActivityState()
    d.noteSignal(.notify, at: at(1)); d.markSeen()
    check("blocked: Clear dismisses it", !d.needsYou)
    eq("blocked: first in the needs-you line, ahead of an older answer",
       NeedsYou.queue([.init(name: "old", activity: .ready, lastOutput: at(0)),
                       .init(name: "ask", activity: .blocked, lastOutput: at(50))]), ["ask", "old"])

    // Drafts: a send waits for a message you're halfway through.
    var e = ActivityState()
    e.noteTyping(Array("half a tho".utf8), at: at(0))
    check("draft: keys without Enter hold a send", e.holdsDraft(at: at(5)))
    check("draft: a minute after the last key it's abandoned", !e.holdsDraft(at: at(61)))
    e.noteTyping([13], at: at(6))
    check("draft: Enter sends it, and the hold lifts", !e.holdsDraft(at: at(7)))
    var f = ActivityState()
    f.noteTyping([27, 91, 73], at: at(0))
    check("draft: a focus report isn't typing", !f.holdsDraft(at: at(1)) && f.keyAt == nil)

    // Notifications: on the agent's word, for a desk you aren't watching.
    typealias N = NotifyRule
    eq("notify: blocked in the background is a notification", N.decide(from: .working, to: .blocked, signaled: true, appActive: false, deskVisible: false), .banner)
    eq("notify: done with Coldfall in front is a sound", N.decide(from: .working, to: .ready, signaled: true, appActive: true, deskVisible: false), .sound)
    eq("notify: nothing for the desk you're looking at", N.decide(from: .working, to: .blocked, signaled: true, appActive: true, deskVisible: true), .silent)
    eq("notify: nothing on a guess from output", N.decide(from: .working, to: .ready, signaled: false, appActive: false, deskVisible: false), .silent)
    eq("notify: once per change, not every tick", N.decide(from: .ready, to: .ready, signaled: true, appActive: false, deskVisible: false), .silent)
    eq("notify: blocked then answered-and-done isn't a second alarm", N.decide(from: .blocked, to: .ready, signaled: true, appActive: false, deskVisible: false), .silent)
    check("notify: the text holds nothing from the conversation", N.text(desk: "api", .blocked) == ("api needs you", "It's waiting for your answer."))
    do {
        // One finished turn, then the desk goes on printing: working, done,
        // working, done. One alert, not one per return to done.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var st = ActivityState()
        st.setVisible(false, at: t0.addingTimeInterval(-60))
        st.noteInput(at: t0.addingTimeInterval(-30)); st.noteAsked()
        st.noteSignal(.stop, at: t0)
        var last = DeskActivity.working, alerted: Date?, alerts = 0
        var now = t0.addingTimeInterval(ActivityState.quietFor + 1)
        for _ in 0..<6 {
            for a in [st.activity(now: now)] {
                if N.decide(from: last, to: a, signaled: st.signaled, appActive: false, deskVisible: false,
                            event: st.alertEvent, alerted: alerted) != .silent { alerts += 1; alerted = st.alertEvent ?? .distantPast }
                last = a
            }
            st.noteOutput(at: now.addingTimeInterval(1))                       // a status line ticks
            let busy = st.activity(now: now.addingTimeInterval(1.5))
            _ = N.decide(from: last, to: busy, signaled: st.signaled, appActive: false, deskVisible: false,
                         event: st.alertEvent, alerted: alerted)
            last = busy
            now = now.addingTimeInterval(ActivityState.quietFor + 5)
        }
        eq("notify: one finished turn alerts once, however often the mark returns", alerts, 1)
        // The next turn is news again.
        st.noteInput(at: now); st.noteAsked()
        st.noteSignal(.stop, at: now.addingTimeInterval(20))
        let again = N.decide(from: .working, to: st.activity(now: now.addingTimeInterval(20 + ActivityState.quietFor + 1)),
                             signaled: st.signaled, appActive: false, deskVisible: false, event: st.alertEvent, alerted: alerted)
        eq("notify: the next finished turn alerts again", again, .banner)
        let e = Date(timeIntervalSince1970: 5)
        eq("notify: a question after an alerted finish still alerts",
           N.decide(from: .ready, to: .blocked, signaled: true, appActive: false, deskVisible: false, event: e.addingTimeInterval(9), alerted: e), .banner)
        eq("notify: with no report time, once is still once",
           N.decide(from: .working, to: .ready, signaled: true, appActive: false, deskVisible: false, event: nil, alerted: .distantPast), .silent)
    }

    // Read and send.
    let names = ["hub", "api", "notes"], hidden: Set<String> = ["notes"]
    let live = RemoteOpen.Target(running: true, agent: true)
    eq("send: goes ahead on a running agent", RemoteOpen.refuseSend("api", names: names, hidden: hidden, target: live, text: "hi"), nil)
    eq("send: refused on a desk stopped on a question",
       RemoteOpen.refuseSend("api", names: names, hidden: hidden, target: .init(running: true, agent: true, blocked: true), text: "hi")?.outcome, .blocked)
    eq("send: waits on a half-typed message",
       RemoteOpen.refuseSend("api", names: names, hidden: hidden, target: .init(running: true, agent: true, draft: true), text: "hi")?.outcome, .draft)
    eq("send: never into a shell",
       RemoteOpen.refuseSend("api", names: names, hidden: hidden, target: .init(running: true, agent: false), text: "ls")?.outcome, .notAnAgent)
    eq("send: not to a desk that isn't running", RemoteOpen.refuseSend("api", names: names, hidden: hidden, target: nil, text: "hi")?.outcome, .notRunning)
    eq("send: nor a hidden one", RemoteOpen.refuseSend("notes", names: names, hidden: hidden, target: live, text: "hi")?.outcome, .hiddenDesk)
    eq("send: nothing to send", RemoteOpen.refuseSend("api", names: names, hidden: hidden, target: live, text: "  ")?.outcome, .notAnAgent)
    eq("read: goes ahead on a running desk", RemoteOpen.refuseRead("hub", names: names, hidden: hidden, target: live), nil)
    eq("read: says so when it isn't running", RemoteOpen.refuseRead("hub", names: names, hidden: hidden, target: nil)?.outcome, .notRunning)
    eq("send: one line is typed, then Enter", RemoteOpen.keystrokes("do x"), Array("do x".utf8) + [13])
    let multi = RemoteOpen.keystrokes("a\nb")
    check("send: several lines go as one paste, so Enter sends it once",
          multi == Array("\u{1b}[200~a\nb\u{1b}[201~".utf8) + [13] && ActivityState.isSubmit(multi))
    eq("read: the last lines, without the blank rows below", RemoteOpen.lastLines("one\ntwo  \nthree\n\n\n", lines: 2), "two\nthree")
    let old = try? JSONDecoder().decode(RemoteOpen.Request.self, from: Data(#"{"id":"x","desk":"hub","show":false,"time":1}"#.utf8))
    check("remote: an open request from an older CLI still reads", old?.action == nil && old?.desk == "hub")
    let ui = try? JSONDecoder().decode(UIState.self, from: Data("{}".utf8))
    check("ui: notifications are on unless turned off", ui?.notifyDesks == true)
}

// MARK: - OSC 7501, the Program Status Protocol

do {
    let msg = Data("Allow edit?".utf8).base64EncodedString()
    let r = ProgramStatus.parse("state=blocked:kind=permission:app=codex:msg=\(msg)")
    eq("7501: a blocked report reads", r?.state, "blocked")
    eq("7501: with its kind", r?.kind, "permission")
    eq("7501: and its message decoded", r?.message, "Allow edit?")
    eq("7501: blocked means it needs you", r.flatMap(ProgramStatus.event), .notify)
    eq("7501: error does too", ProgramStatus.parse("state=error").flatMap(ProgramStatus.event), .notify)
    eq("7501: done is a finished turn", ProgramStatus.parse("state=done").flatMap(ProgramStatus.event), .stop)
    eq("7501: working changes nothing (output says it)", ProgramStatus.parse("state=working:progress=40").flatMap(ProgramStatus.event), nil)
    eq("7501: a subtask's record doesn't speak for the desk", ProgramStatus.parse("state=blocked:id=sub1").flatMap(ProgramStatus.event), nil)
    eq("7501: an unknown state is ignored", ProgramStatus.parse("state=dancing"), nil)
    eq("7501: so is junk", ProgramStatus.parse("hello"), nil)
    var a = ActivityState()
    a.setVisible(false, at: Date(timeIntervalSince1970: 0))
    a.mute(for: 3, at: Date(timeIntervalSince1970: 10))
    a.noteSignal(.notify, at: Date(timeIntervalSince1970: 11))
    check("7501: a replayed report on reattach isn't news", !a.needsYou)
    a.noteSignal(.notify, at: Date(timeIntervalSince1970: 20))
    check("7501: a new one after is", a.needsYou)
}

// MARK: - command palette

do {
    let M = Commands.Mods.self
    eq("commands: ⌘P", Commands.shortcut(key: "p", modifiers: M.command), "⌘P")
    eq("commands: modifiers in the menu's order", Commands.shortcut(key: "p", modifiers: M.command | M.shift | M.option), "⌥⇧⌘P")
    eq("commands: an upper-case key means Shift", Commands.shortcut(key: "P", modifiers: M.command), "⇧⌘P")
    eq("commands: Return has a symbol", Commands.shortcut(key: "\r", modifiers: M.command), "⌘↩")
    eq("commands: an arrow too", Commands.shortcut(key: "\u{F701}", modifiers: M.command | M.option), "⌥⌘↓")
    eq("commands: no key, no shortcut", Commands.shortcut(key: "", modifiers: M.command), "")
    eq("commands: > asks for commands", Commands.commandQuery(">  stop "), "stop")
    eq("commands: anything else doesn't", Commands.commandQuery("stop"), nil)
    let list = Commands.offer([
        .init(path: ["Desk", "Stop Desk…"], key: "", modifiers: 0),
        .init(path: ["Desk", "Split Right"], key: "d", modifiers: M.command, enabled: false),
        .init(path: ["Services", "Make Sticky"], key: "", modifiers: 0),
        .init(path: ["View", "Stop Desk…"], key: "", modifiers: 0),
        .init(path: ["View", "Run a Command…"], key: "p", modifiers: M.command | M.shift),
    ])
    eq("commands: enabled, not the system's lists, each once", list.map(\.title), ["Stop Desk…", "Run a Command…"])
    eq("commands: found by menu and name", list.first?.searchKey, "Desk Stop Desk")
}

// MARK: - peek

do {
    func menu(running: Bool, canPeek: Bool) -> [DeskMenu.Entry] {
        DeskMenu.items(runtime: "claude", running: running, hidden: false, canReveal: false, canMakeDefault: false,
                       hasInventory: false, hasMcp: false, canPeek: canPeek)
    }
    eq("peek: first in a running desk's menu", menu(running: true, canPeek: true).first?.action, .peek)
    check("peek: not for a desk that isn't running", !menu(running: false, canPeek: true).contains { $0.action == .peek })
    check("peek: not where it isn't offered (the desk on screen)", !menu(running: true, canPeek: false).contains { $0.action == .peek })
    check("peek: the menu's danger stays apart", DeskMenu.destructiveIsIsolated(menu(running: true, canPeek: true)))
    var a = ActivityState()
    a.setVisible(false, at: Date(timeIntervalSince1970: 0))
    a.noteAsked()
    a.noteSignal(.stop, at: Date(timeIntervalSince1970: 10))
    a.notePeeked()
    eq("peek: a peeked answer isn't news any more", a.activity(now: Date(timeIntervalSince1970: 20)), .quiet)
    var b = ActivityState()
    b.setVisible(false, at: Date(timeIntervalSince1970: 0))
    b.noteSignal(.notify, at: Date(timeIntervalSince1970: 10))
    b.notePeeked()
    eq("peek: but a question it's waiting on still is", b.activity(now: Date(timeIntervalSince1970: 20)), .blocked)
}

// MARK: - weekly pace

do {
    let reset = Date(timeIntervalSince1970: 1_800_000_000)
    let start = reset.addingTimeInterval(-WeekPace.window)
    // Half the week gone, 75% used: out at two-thirds, well before the reset.
    let mid = start.addingTimeInterval(WeekPace.window / 2)
    let r = WeekPace.assess(usedPct: 75, resetsAt: reset, now: mid)
    check("pace: ahead of the week is called out", r != nil)
    eq("pace: it runs out when the rate says", r.map { Int($0.runsOutAt.timeIntervalSince(start) / 3600) }, Int(WeekPace.window * (2.0 / 3.0) / 3600))
    eq("pace: on pace says nothing", WeekPace.assess(usedPct: 45, resetsAt: reset, now: mid), nil)
    eq("pace: too early in the week says nothing", WeekPace.assess(usedPct: 20, resetsAt: reset, now: start.addingTimeInterval(3600)), nil)
    eq("pace: a few hours early is noise", WeekPace.assess(usedPct: 99, resetsAt: reset, now: reset.addingTimeInterval(-7200)), nil)
    eq("pace: after the reset says nothing", WeekPace.assess(usedPct: 50, resetsAt: reset, now: reset.addingTimeInterval(60)), nil)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    if let r { check("pace: the line says when and how early", WeekPace.line(vendor: "claude", r, calendar: cal).hasPrefix("claude: at this pace you run out ")
                     && WeekPace.line(vendor: "claude", r, calendar: cal).hasSuffix("before the week resets.")) }
}

// MARK: - your own shortcuts (keys.json)

do {
    let M = Commands.Mods.self
    eq("keys: cmd+shift+k", KeyMap.parse(shortcut: "cmd+shift+k"), KeyMap.Shortcut(key: "k", modifiers: M.command | M.shift))
    eq("keys: names and symbols both", KeyMap.parse(shortcut: "⌥+⌘+Return"), KeyMap.Shortcut(key: "\r", modifiers: M.command | M.option))
    eq("keys: none takes one away", KeyMap.parse(shortcut: "none"), KeyMap.Shortcut.none)
    eq("keys: a bare letter would steal typing", KeyMap.parse(shortcut: "shift+k"), nil)
    eq("keys: two keys isn't one shortcut", KeyMap.parse(shortcut: "cmd+k+j"), nil)
    eq("keys: nonsense isn't either", KeyMap.parse(shortcut: "cmd+banana"), nil)
    let m = KeyMap.parse(json: #"{"Run a Command…": "cmd+k", "Show or Hide Rail": "none", "Stop Desk": "cmd+k", "Oops": "k"}"#)
    eq("keys: names match without case or the …", m.shortcuts[KeyMap.normal("run a command")], KeyMap.Shortcut(key: "k", modifiers: M.command))
    eq("keys: none is kept, to clear it", m.shortcuts["show or hide rail"], KeyMap.Shortcut.none)
    check("keys: one key given twice is kept for the first and reported", m.shortcuts["stop desk"] == nil
          && m.problems.contains { $0.contains("given to both") })
    check("keys: an unusable one is reported, not applied", m.shortcuts["oops"] == nil && m.problems.contains { $0.contains("Oops") })
    eq("keys: a broken file says so", KeyMap.parse(json: "[1,2]").problems.count, 1)
}

// MARK: - wait and ask

do {
    typealias D = RemoteOpen.DeskState
    let t0 = 1000.0
    eq("wait: a turn ending after the send is done", RemoteOpen.waitResult(D(name: "a", running: true, activity: "ready", turnEndedAt: 1005, signaled: true), since: t0, now: 1006), .done(guessed: false))
    eq("wait: one from before the send isn't", RemoteOpen.waitResult(D(name: "a", running: true, activity: "working", turnEndedAt: 990, signaled: true), since: t0, now: 1006), nil)
    eq("wait: a question for you ends the wait", RemoteOpen.waitResult(D(name: "a", running: true, activity: "blocked", needsYou: true), since: t0, now: 1006), .needsYou)
    eq("wait: a stopped desk ends it", RemoteOpen.waitResult(D(name: "a", running: false, activity: "quiet"), since: t0, now: 1006), .stopped)
    eq("wait: an agent that doesn't report is done when it goes quiet",
       RemoteOpen.waitResult(D(name: "a", running: true, activity: "quiet", outputAt: 1003, signaled: false), since: t0, now: 1003 + RemoteOpen.quietMeansDone), .done(guessed: true))
    eq("wait: but not while output is fresh",
       RemoteOpen.waitResult(D(name: "a", running: true, activity: "working", outputAt: 1003, signaled: false), since: t0, now: 1005), nil)
    eq("wait: a reporting agent's quiet isn't taken as done",
       RemoteOpen.waitResult(D(name: "a", running: true, activity: "quiet", outputAt: 1003, signaled: true), since: t0, now: 1100), nil)
    let old = try? JSONDecoder().decode(D.self, from: Data(#"{"name":"a","running":true,"activity":"quiet"}"#.utf8))
    check("wait: an older app's status still reads", old?.turnEndedAt == nil && old?.name == "a")

    let foot = "\n────\n❯ \n────\n  status\n  mode"
    let before = "● earlier answer\n\n> previous question\n\n● previous reply line" + foot
    let after = "● earlier answer\n\n> previous question\n\n● previous reply line\n\n> new question\n\n● First paragraph.\n\n  Second paragraph." + foot
    eq("ask: the reply is what came after, breaks kept, footer dropped",
       RemoteOpen.reply(before: before, after: after), "> new question\n\n● First paragraph.\n\n  Second paragraph.")
    eq("ask: an agent with no input box keeps its last rows",
       RemoteOpen.reply(before: "● starting bot\n  sh bot.sh\n$ sh bot.sh", after: "● starting bot\n  sh bot.sh\n$ sh bot.sh\n● Reply to: hi\n\n  A second paragraph."),
       "● Reply to: hi\n\n  A second paragraph.")
    eq("ask: a status row whose numbers tick is still the footer",
       RemoteOpen.reply(before: "old\n❯\nctx 40% $1.20", after: "old\nnew line\n❯\nctx 41% $1.35"), "new line")
    eq("ask: two replies ending alike aren't a footer",
       RemoteOpen.reply(before: "$ run\n● Reply to: one\n\n  Same ending.", after: "$ run\n● Reply to: one\n\n  Same ending.\n● Reply to: two\n\n  Same ending."),
       "● Reply to: two\n\n  Same ending.")
    eq("ask: a redrawn screen falls back to the new lines",
       RemoteOpen.reply(before: "a\nb\nc" + foot, after: "x\ny\nz" + foot), "x\ny\nz")
}

// MARK: - inbox

final class FakeInboxHost: InboxHost {
    var sent: [(String, String)] = [], pressed: [(String, [UInt8])] = [], opened: [String] = []
    var blocked = Set<String>()
    func inboxRows() -> [Inbox.Row] {
        [Inbox.Row(name: "idle", group: nil, runtime: "claude", running: true, activity: "quiet", lastOutput: 50),
         Inbox.Row(name: "asks", group: "work", runtime: "claude", running: true, activity: "blocked", lastOutput: 10),
         Inbox.Row(name: "off", group: nil, runtime: "codex", running: false, activity: "quiet", lastOutput: nil),
         Inbox.Row(name: "done", group: nil, runtime: "codex", running: true, activity: "ready", lastOutput: 20)]
    }
    func inboxDesk(_ name: String, lines: Int) -> Inbox.DeskView? {
        name == "nope" ? nil : Inbox.DeskView(text: "<b>screen</b> of \(name)", running: true, activity: "quiet", runtime: "claude", agent: true)
    }
    func inboxSend(_ name: String, text: String) -> RemoteOpen.Answer { sent.append((name, text)); return .init(.sent, "Sent.") }
    func inboxPress(_ name: String, keys: [UInt8]) -> RemoteOpen.Answer {
        guard blocked.contains(name) else { return .init(.notAsking, "not asking") }
        pressed.append((name, keys)); return .init(.pressed, "Pressed.")
    }
    func inboxOpen(_ name: String) -> RemoteOpen.Answer { opened.append(name); return .init(.started, "Started.") }
}

do {
    let tok = String(repeating: "k", count: 43)
    let hosts = ["100.101.102.103", "127.0.0.1", "localhost"]
    func req(_ m: String, _ target: String, host: String = "100.101.102.103:47100", cookie: String? = "cf_inbox=" + String(repeating: "k", count: 43),
             header: Bool = true, body: String = "") -> Inbox.Request {
        var raw = "\(m) \(target) HTTP/1.1\r\nHost: \(host)\r\n"
        if let c = cookie { raw += "Cookie: \(c)\r\n" }
        if header { raw += "X-Coldfall: 1\r\n" }
        raw += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .request(let r) = Inbox.parse(Data(raw.utf8)) else { return Inbox.Request(method: "BAD", path: "") }
        return r
    }
    let h = FakeInboxHost()
    func respond(_ r: Inbox.Request) -> Inbox.Response { Inbox.respond(r, token: tok, allowedHosts: hosts, host: h) }

    eq("inbox: half a request waits for the rest", Inbox.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
    eq("inbox: a body not all here yet waits", Inbox.parse(Data("POST /a HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), .incomplete)
    eq("inbox: junk is refused", Inbox.parse(Data("hello\r\n\r\n".utf8)), .bad)
    eq("inbox: a huge body is refused", Inbox.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)), .bad)
    eq("inbox: query read", req("GET", "/api/read?desk=a%20b&lines=5").query["desk"], "a b")

    eq("inbox: another Host is refused (no DNS rebinding)", respond(req("GET", "/", host: "evil.example")).status, 403)
    eq("inbox: no secret, nothing", respond(req("GET", "/api/desks", cookie: nil)).status, 401)
    eq("inbox: a wrong secret, nothing", respond(req("GET", "/api/desks", cookie: "cf_inbox=" + String(repeating: "x", count: 43))).status, 401)
    let first = respond(req("GET", "/?t=" + tok, cookie: nil))
    eq("inbox: the link's secret becomes a cookie", first.status, 302)
    check("inbox: a private, same-site cookie", first.header("Set-Cookie")?.contains("HttpOnly; SameSite=Strict") == true)
    eq("inbox: and the secret leaves the address bar", first.header("Location"), "/")
    eq("inbox: a change without the page's header is refused", respond(req("POST", "/api/send", header: false, body: #"{"desk":"a","text":"hi"}"#)).status, 403)
    check("inbox: refused changes did nothing", h.sent.isEmpty)

    let page = respond(req("GET", "/"))
    eq("inbox: the page", page.status, 200)
    check("inbox: with a strict content policy", page.header("Content-Security-Policy")?.contains("default-src 'none'") == true)
    let html = String(decoding: page.body, as: UTF8.self)
    check("inbox: agent output only ever as text", !html.contains("innerHTML") && html.contains("textContent"))
    check("inbox: never cached, never framed", String(decoding: page.serialize(), as: UTF8.self).contains("Cache-Control: no-store")
          && String(decoding: page.serialize(), as: UTF8.self).contains("X-Frame-Options: DENY"))

    let desks = (try? JSONSerialization.jsonObject(with: respond(req("GET", "/api/desks")).body) as? [String: Any])?["desks"] as? [[String: Any]]
    eq("inbox: needs you, done, working, idle, not started", desks?.compactMap { $0["name"] as? String }, ["asks", "done", "idle", "off"])
    let read = (try? JSONSerialization.jsonObject(with: respond(req("GET", "/api/read?desk=x")).body) as? [String: Any])
    eq("inbox: a screen reads back as text", read?["text"] as? String, "<b>screen</b> of x")
    eq("inbox: no such desk", respond(req("GET", "/api/read?desk=nope")).status, 404)
    _ = respond(req("POST", "/api/send", body: #"{"desk":"idle","text":"go"}"#))
    check("inbox: a send reaches the desk", h.sent.first.map { $0 == ("idle", "go") } == true)
    eq("inbox: a key it doesn't press", respond(req("POST", "/api/keys", body: #"{"desk":"asks","key":"ctrl-c"}"#)).status, 400)
    _ = respond(req("POST", "/api/keys", body: #"{"desk":"idle","key":"1"}"#))
    check("inbox: keys only for a desk asking a question (the host decides)", h.pressed.isEmpty)
    h.blocked = ["asks"]
    _ = respond(req("POST", "/api/keys", body: #"{"desk":"asks","key":"down"}"#))
    check("inbox: an arrow, as the terminal sends it", h.pressed.first.map { $0.0 == "asks" && $0.1 == [27, 91, 66] } == true)
    _ = respond(req("POST", "/api/open", body: #"{"desk":"off"}"#))
    eq("inbox: open starts a desk", h.opened, ["off"])
    eq("inbox: a wrong method", respond(req("DELETE", "/api/desks")).status, 405)
    eq("inbox: an unknown path", respond(req("GET", "/etc/passwd")).status, 404)

    check("inbox: only a tunnel interface counts", Inbox.isTunnel("utun4") && !Inbox.isTunnel("en0") && !Inbox.isTunnel("bridge100"))
    check("inbox: Tailscale's range", Inbox.isTailscale("100.102.175.106") && Inbox.isTailscale("100.64.0.1")
          && !Inbox.isTailscale("100.128.0.1") && !Inbox.isTailscale("192.168.1.10"))
    let tp = testSandbox + "/inbox-token"
    let t1 = Inbox.token(path: tp)
    check("inbox: a long random secret", (t1?.count ?? 0) >= 40)
    eq("inbox: kept between runs", Inbox.token(path: tp), t1)
    let perm = (try? FileManager.default.attributesOfItem(atPath: tp))?[.posixPermissions] as? Int
    eq("inbox: readable by this account only", perm, 0o600)
    check("inbox: New Link makes a different one", Inbox.resetToken(path: tp) != t1)
}

// MARK: - audit fixes (11/12)

do {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    check("report: cursor position isn't typing", ActivityState.isReport(bytes("\u{1b}[12;40R")))
    check("report: device attributes aren't", ActivityState.isReport(bytes("\u{1b}[?62;22c")))
    check("report: a colour answer (OSC) isn't", ActivityState.isReport(bytes("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{1b}\\")))
    check("report: focus in isn't", ActivityState.isReport([27, 91, 73]))
    check("report: an arrow key is typing", !ActivityState.isReport(bytes("\u{1b}[A")))
    check("report: a kitty Enter is typing", !ActivityState.isReport(bytes("\u{1b}[13u")))
    check("report: a function key is typing", !ActivityState.isReport(bytes("\u{1b}[15~")))
    var r = ActivityState()
    r.noteSignal(.notify, at: Date(timeIntervalSince1970: 1))
    r.noteTyping(bytes("\u{1b}[?62;22c"), at: Date(timeIntervalSince1970: 2))
    check("report: the terminal answering doesn't answer a question", r.needsYou && !r.holdsDraft(at: Date(timeIntervalSince1970: 3)))

    // A reattach: what the desk said while Coldfall was closed still stands.
    var a = ActivityState()
    a.setVisible(false, at: Date(timeIntervalSince1970: 0))
    a.mute(for: 3, at: Date(timeIntervalSince1970: 10))
    a.noteSignal(.stop, at: Date(timeIntervalSince1970: 10.5))
    a.noteSignal(.notify, at: Date(timeIntervalSince1970: 11))
    check("reattach: replayed reports wait", !a.needsYou)
    a.endMute(logged: nil, at: Date(timeIntervalSince1970: 14))
    check("reattach: the last one replayed stands once it's over", a.needsYou)
    var b = ActivityState()
    b.mute(for: 3, at: Date(timeIntervalSince1970: 10))
    b.endMute(logged: .notify, at: Date(timeIntervalSince1970: 14))
    check("reattach: a question only in the hook's log stands too", b.needsYou)
    var c = ActivityState()
    c.mute(for: 3, at: Date(timeIntervalSince1970: 10))
    c.endMute(logged: .stop, at: Date(timeIntervalSince1970: 14))
    check("reattach: a finished turn isn't a question", !c.needsYou)

    // Looking at a desk doesn't answer its question.
    var d = ActivityState()
    d.setVisible(true, at: Date(timeIntervalSince1970: 0))
    d.noteSignal(.notify, at: Date(timeIntervalSince1970: 1))
    d.noteOutput(at: Date(timeIntervalSince1970: 20))
    check("needs you: a redraw while you look isn't an answer", d.needsYou)
    d.setVisible(false, at: Date(timeIntervalSince1970: 21))
    d.noteOutput(at: Date(timeIntervalSince1970: 40))
    check("needs you: nor is output while you're away", d.needsYou)
    check("liveness: the shell at its prompt isn't an agent", !ProcessTree.runsForeground(shell: 500, foreground: 500))
    check("liveness: a program in the foreground is", ProcessTree.runsForeground(shell: 500, foreground: 612))
    check("liveness: no answer from ps isn't one", !ProcessTree.runsForeground(shell: 500, foreground: nil))

    // The hook's log: a desk's last word.
    let log = testSandbox + "/signals-test.log"
    try? "1000 notify hub\n1001 stop work\n1002 stop hub\n1003 notify hub\n".write(toFile: log, atomically: true, encoding: .utf8)
    eq("signals: a desk's last word", DoneSignal.last(desk: "hub", since: Date(timeIntervalSince1970: 0), path: log)?.event, .notify)
    eq("signals: only newer than asked", DoneSignal.last(desk: "work", since: Date(timeIntervalSince1970: 1001.5), path: log), nil)
}

// MARK: - claimed requests

do {
    let r = RemoteOpen.Request(desk: "hub", action: "send", text: "hi")
    try? RemoteOpen.submit(r)
    check("claim: a waiting request can be taken", RemoteOpen.claim(r))
    check("claim: and isn't offered again", !RemoteOpen.pending().contains { $0.id == r.id })
    check("claim: a caller that gives up can see it was taken", RemoteOpen.taken(r))
    RemoteOpen.answer(r, .init(.sent, "Sent."))
    check("claim: answered, nothing is left taken", !RemoteOpen.taken(r))
    _ = RemoteOpen.wait(for: r, timeout: 0.5)
    let late = RemoteOpen.Request(desk: "hub", action: "send", text: "late")
    try? RemoteOpen.submit(late)
    eq("claim: withdrawn before it was taken", RemoteOpen.wait(for: late, timeout: 0.3), nil)
    check("claim: can't be taken after", !RemoteOpen.claim(late) && !RemoteOpen.taken(late))
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
