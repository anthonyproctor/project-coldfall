// Reading a file that only grows, a little at a time.
//
// Claude's transcripts are append-only: a line per message. A desk in use
// changes its file every few seconds, so a cache keyed on size and time never
// hits for it, and reading it whole each pass cost minutes on a file in the
// hundreds of megabytes (see ClaudeTail). A LineTail remembers, per file, how
// far it read and what the reader had worked out by then, and hands the reader
// only the whole lines added since.

import Foundation

public final class LineTail<State> {
    struct Entry {
        var offset: UInt64      // just past the last whole line read
        var head: Data          // the file's first bytes, to notice a rewrite
        var tag: String         // what the state was worked out for (window, prices)
        var state: State
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    static var headBytes: Int { 256 }
    let chunk: Int

    public init(chunk: Int = 8 << 20) { self.chunk = chunk }

    /// The state for `path` after every whole line in it. Starts over (from
    /// `fresh()`) for a new tag, a file that shrank, or one whose first bytes
    /// changed. Nil when the file can't be opened.
    public func read(_ path: String, tag: String, fresh: () -> State,
                     line: (Data, inout State) -> Void) -> State? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: Self.headBytes)) ?? Data()
        let size = (try? fh.seekToEnd()) ?? 0

        lock.lock()
        var e = entries[path]
        lock.unlock()
        if let q = e, q.tag != tag || size < q.offset || head.prefix(q.head.count) != q.head { e = nil }
        var cur = e ?? Entry(offset: 0, head: head, tag: tag, state: fresh())
        if cur.head.count < Self.headBytes { cur.head = head }

        if size > cur.offset {
            try? fh.seek(toOffset: cur.offset)
            var carry = Data()
            var more = true
            // Each chunk in its own pool: the buffer a read hands back and the
            // records parsed from it are let go of before the next one, rather
            // than all at the end (which held a big file's worth at once).
            while more {
                more = autoreleasepool { () -> Bool in
                    guard let got = try? fh.read(upToCount: chunk), !got.isEmpty else {
                        // The end with no newline after it: a line still being
                        // written, or a file that doesn't end in one. A record cut
                        // short can't parse (no closing brace yet), so a last line
                        // that parses is whole.
                        if !carry.isEmpty, (try? JSONSerialization.jsonObject(with: carry)) != nil {
                            line(carry, &cur.state)
                            cur.offset += UInt64(carry.count)
                        }
                        return false
                    }
                    carry.append(got)
                    // Whole lines only; a line still being written waits for next time.
                    guard let last = carry.lastIndex(of: 0x0A) else { return true }
                    let whole = carry[carry.startIndex...last]
                    for l in whole.split(separator: 0x0A, omittingEmptySubsequences: true) { line(l, &cur.state) }
                    cur.offset += UInt64(whole.count)
                    carry = Data(carry[carry.index(after: last)...])
                    return true
                }
            }
        }
        lock.lock()
        entries[path] = cur
        lock.unlock()
        return cur.state
    }

    /// Forget files that are gone (called with the files a pass saw).
    public func keep(_ live: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for k in entries.keys where !live.contains(k) { entries.removeValue(forKey: k) }
    }

    /// Forget everything.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
    }

    /// How many files it is following (tests).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}
