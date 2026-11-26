// How much memory Coldfall is using, and whether that is worth a line in the
// exit log.
//
// Coldfall once grew to about 100GB over half a day and macOS ended it. An
// ended app writes nothing, so the only trace was a "started" with no stop
// after it. Now the app reads its own footprint every minute and notes each
// doubling past 1GB, and the next start says when the last run ended without
// a word.

import Foundation

public enum MemoryUse {
    /// This process's footprint in bytes: what Activity Monitor shows as
    /// Memory, and what macOS weighs when memory runs out.
    public static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// The first mark worth a note: 1GB, then each doubling.
    public static let firstMark: UInt64 = 1 << 30

    /// The mark `bytes` has reached, when it is past `noted` (the last one
    /// written down); nil when there is nothing new to say.
    public static func mark(_ bytes: UInt64, noted: UInt64) -> UInt64? {
        guard bytes >= firstMark else { return nil }
        var m = firstMark
        while m <= bytes / 2 { m *= 2 }
        return m > noted ? m : nil
    }

    /// "1.4GB", "820MB".
    public static func text(_ bytes: UInt64) -> String {
        bytes >= 1 << 30 ? String(format: "%.1fGB", Double(bytes) / Double(1 << 30)) : "\(bytes >> 20)MB"
    }

    /// The last run in an exit log, when it stopped without saying why: its
    /// last line, which is "started" or a memory note. Nil when it said why
    /// it stopped (or there was no earlier run).
    public static func unexplained(log: String) -> String? {
        guard let last = log.split(separator: "\n").last(where: { !$0.isEmpty }) else { return nil }
        let l = String(last)
        let quiet = l.hasSuffix(" started") || l.contains(" memory: ")
        return quiet ? l : nil
    }
}
