import Foundation

public enum OutputEvent: Equatable {
    case connecting
    case connected
    case sessions(Int)
    case environmentURL(URL)
    case untrustedWorkspace
    case alreadyServed
    case other(String)
}

/// Turns raw `claude remote-control` output into events. Feed it chunks as they
/// arrive. Bytes are buffered until a line ends, so multi-byte characters split
/// across chunks decode correctly.
public struct OutputParser {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [OutputEvent] {
        var events: [OutputEvent] = []
        for byte in data {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                events += flushLine()
            } else {
                pending.append(byte)
            }
        }
        return events
    }

    /// Call at end of output. Emits any unterminated last line.
    public mutating func finish() -> [OutputEvent] {
        flushLine()
    }

    // MARK: Private

    private mutating func flushLine() -> [OutputEvent] {
        defer { pending.removeAll(keepingCapacity: true) }
        let raw = String(decoding: pending, as: UTF8.self)
        let line = Self.stripEscapes(raw).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        return [Self.classify(line)]
    }

    static func classify(_ line: String) -> OutputEvent {
        if line.contains("Connecting ·") { return .connecting }
        if line.contains("Connected ·") { return .connected }
        if let n = capacity(in: line) { return .sessions(n) }
        if let url = environmentURL(in: line) { return .environmentURL(url) }
        if line.contains("Workspace not trusted") { return .untrustedWorkspace }
        if line.contains("already served by") { return .alreadyServed }
        return .other(line)
    }

    /// `Capacity: N/32` → N.
    private static func capacity(in line: String) -> Int? {
        guard let range = line.range(of: "Capacity: ") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, line[range.upperBound...].dropFirst(digits.count).first == "/" else {
            return nil
        }
        return Int(digits)
    }

    private static func environmentURL(in line: String) -> URL? {
        let prefix = "https://claude.ai/code?environment="
        guard let range = line.range(of: prefix) else { return nil }
        let rest = line[range.lowerBound...].prefix { !$0.isWhitespace }
        return URL(string: String(rest))
    }

    /// Removes CSI (`ESC [ … final`) and OSC (`ESC ] … BEL` or `ESC \`)
    /// sequences, including the URL inside OSC 8 hyperlinks.
    static func stripEscapes(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        let esc: Unicode.Scalar = "\u{1B}"
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == esc else {
                out.append(c)
                i += 1
                continue
            }
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if next == "[" {
                var j = i + 2
                while j < scalars.count, !(0x40 ... 0x7E).contains(scalars[j].value) {
                    j += 1
                }
                i = j + 1
            } else if next == "]" {
                var j = i + 2
                while j < scalars.count {
                    if scalars[j] == "\u{07}" {
                        j += 1
                        break
                    }
                    if scalars[j] == esc, j + 1 < scalars.count, scalars[j + 1] == "\\" {
                        j += 2
                        break
                    }
                    j += 1
                }
                i = j
            } else {
                i += 2
            }
        }
        return String(out)
    }
}
