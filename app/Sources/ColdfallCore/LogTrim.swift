// Logs Coldfall appends to for as long as it is installed, kept to a size.
//
// exit.log and signals.log were already trimmed; holders.log, wake.log and
// schedule-runs.jsonl grew for good. Each is trimmed once a launch to its
// newest lines.

import Foundation

public enum LogTrim {
    /// Keep the newest `lines` of `path` once it passes `over` bytes. A line
    /// appended while this runs may be lost; these are histories, not records.
    @discardableResult
    public static func trim(_ path: String, over: Int = 1 << 20, lines: Int = 2000) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              (a[.size] as? Int ?? 0) > over,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n") + "\n"
        let perms = a[.posixPermissions] as? Int ?? 0o600
        guard (try? kept.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: path)
        return true
    }

    /// The logs trimmed at launch.
    public static func atLaunch() {
        trim((Holder.root as NSString).appendingPathComponent("holders.log"))
        trim(Wake.logPath)
        trim(Schedule.logPath)
    }
}
