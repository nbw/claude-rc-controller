import Darwin
import Foundation

/// A server the app started, recorded so it can be cleaned up after a crash.
public struct LiveProcess: Codable, Equatable {
    public var pid: Int32
    public var path: String

    public init(pid: Int32, path: String) {
        self.pid = pid
        self.path = path
    }
}

/// Reads and writes `pids.json`. A missing or unreadable file is an empty list.
public struct PidRecordStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [LiveProcess] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LiveProcess].self, from: data)) ?? []
    }

    public func save(_ records: [LiveProcess]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }
}

/// Kills servers left behind by a crashed app. A recorded pid is killed only if it
/// is alive and its command line still contains both `claude` and `remote-control`.
/// Servers the app did not start are never touched.
public enum OrphanCleaner {
    static let grace: TimeInterval = 3

    public static func run(store: PidRecordStore, inspector: ProcessInspector) {
        var targets: [Int32] = []
        for record in store.load() where inspector.isAlive(record.pid) {
            guard let command = inspector.commandLine(of: record.pid),
                  command.contains("claude"),
                  command.contains("remote-control")
            else {
                continue
            }
            inspector.send(SIGTERM, to: record.pid)
            targets.append(record.pid)
        }

        var waited: TimeInterval = 0
        while waited < grace, targets.contains(where: inspector.isAlive) {
            inspector.sleep(0.1)
            waited += 0.1
        }
        for pid in targets where inspector.isAlive(pid) {
            inspector.send(SIGKILL, to: pid)
        }

        try? store.save([])
    }
}
