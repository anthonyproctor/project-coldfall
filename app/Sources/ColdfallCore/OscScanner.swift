import Foundation

/// Finds OSC sequences (ESC ] code ; payload, ended by BEL or ESC \) in a
/// program's raw output, however the bytes are cut up as they arrive.
///
/// SwiftTerm hands Coldfall these through handlers. With Ghostty drawing
/// the terminal there are none: the desk's output reaches Coldfall as a
/// copy from its holder (see Holder.Kind.tap), and this reads the status
/// reports (7501), notifications (9, 99, 777) and titles (0, 2) out of it.
public struct OscScanner {
    public struct Sequence: Equatable {
        public let code: Int
        public let payload: String
        public init(code: Int, payload: String) { self.code = code; self.payload = payload }
    }

    private enum State { case text, esc, osc, oscEsc }
    private var state: State = .text
    private var buf: [UInt8] = []
    /// Longer than this isn't a status report; it is dropped, not kept.
    public static let limit = 64 * 1024

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Sequence] {
        var out: [Sequence] = []
        for b in bytes {
            switch state {
            case .text:
                if b == 0x1b { state = .esc }
            case .esc:
                if b == 0x5d { state = .osc; buf = [] }            // ]
                else { state = b == 0x1b ? .esc : .text }
            case .osc:
                if b == 0x07 { if let s = finish() { out.append(s) }; state = .text }
                else if b == 0x1b { state = .oscEsc }
                else if buf.count < OscScanner.limit { buf.append(b) }
                else { buf = []; state = .text }                     // runaway: give up on it
            case .oscEsc:
                if b == 0x5c { if let s = finish() { out.append(s) }; state = .text }   // ESC \
                else if b == 0x5d { state = .osc; buf = [] }          // a new one began
                else { buf = []; state = .text }
            }
        }
        return out
    }

    private mutating func finish() -> Sequence? {
        defer { buf = [] }
        guard let semi = buf.firstIndex(of: 0x3b) else {
            // "ESC ] 0 BEL" with nothing after the code is not something we read.
            return nil
        }
        guard let code = Int(String(decoding: buf[..<semi], as: UTF8.self)) else { return nil }
        return Sequence(code: code, payload: String(decoding: buf[(semi + 1)...], as: UTF8.self))
    }
}
