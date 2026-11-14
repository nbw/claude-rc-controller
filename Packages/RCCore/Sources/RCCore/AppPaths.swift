import Foundation

/// Where the app keeps its files. `home` is injectable for tests.
public struct AppPaths {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/claude-rc-controller", isDirectory: true)
    }

    public var reposFile: URL {
        supportDirectory.appendingPathComponent("repos.json")
    }

    public var pidsFile: URL {
        supportDirectory.appendingPathComponent("pids.json")
    }

    public var logFile: URL {
        home.appendingPathComponent("Library/Logs/claude-rc-controller/controller.log")
    }

    /// The old launchd setup's repo list, imported once on first run.
    public var legacyDirsFile: URL {
        home.appendingPathComponent(".claude/remote-control/dirs.txt")
    }
}
