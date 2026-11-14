import Foundation

/// One thing the supervisor reports about a server.
public enum LogEntry: Equatable {
    /// A state change or lifecycle event, such as "start" or "exit 1".
    case event(String)
    /// A line of output from `claude remote-control`.
    case output(String)
}

/// Appends timestamped lines to the controller log. When the file passes 1 MB, it
/// keeps only the last 500 lines.
public final class EventLog {
    public static let rotateBytes = 1_000_000
    public static let keepLines = 500

    private let fileURL: URL
    private let now: () -> Date
    private let stamp = ISO8601DateFormatter()
    private var lastOutput: [String: String] = [:]

    public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    /// Output lines identical to the previous output line for the same repo are
    /// skipped. Events are always written.
    public func record(repo: String, _ entry: LogEntry) {
        let message: String
        switch entry {
        case let .event(text):
            message = text
        case let .output(line):
            if lastOutput[repo] == line { return }
            lastOutput[repo] = line
            message = line
        }
        append("\(stamp.string(from: now())) \(repo) \(message)")
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
        let bytes = Data((line + "\n").utf8)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes?[.size] as? Int, size > Self.rotateBytes,
              let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(Self.keepLines).joined(separator: "\n") + "\n"
        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
