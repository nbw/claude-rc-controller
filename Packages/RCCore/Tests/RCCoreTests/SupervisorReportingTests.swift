import Foundation
@testable import RCCore
import XCTest

/// Checks what the supervisor reports outward: live pids for orphan cleanup, and
/// log entries.
@MainActor
final class SupervisorReportingTests: XCTestCase {
    func testLiveChangeReportsPidAndPathThenEmpty() {
        let launcher = FakeLauncher()
        var reports: [[LiveProcess]] = []
        let sup = ServerSupervisor(
            launcher: launcher,
            clock: FakeClock(),
            inspector: FakeInspector(),
            onLiveChange: { reports.append($0) }
        )
        let repo = Repo(path: "/fake/q", enabled: true, worktreeMode: false)
        sup.apply([repo])
        XCTAssertEqual(reports.last, [LiveProcess(pid: launcher.last.process.pid, path: "/fake/q")])

        launcher.last.exit(0)
        XCTAssertEqual(reports.last, [])
    }

    func testLogReceivesEventsAndOutputWithRepoPath() {
        let launcher = FakeLauncher()
        var entries: [(String, LogEntry)] = []
        let sup = ServerSupervisor(
            launcher: launcher,
            clock: FakeClock(),
            inspector: FakeInspector(),
            log: { entries.append(($0, $1)) }
        )
        sup.apply([Repo(path: "/fake/q", enabled: true, worktreeMode: false)])
        launcher.last.emit("mise WARN  missing: rust@stable\n")
        launcher.last.exit(3)

        XCTAssertEqual(entries.map(\.0), ["/fake/q", "/fake/q", "/fake/q"])
        XCTAssertEqual(entries.map(\.1), [
            .event("start"),
            .output("mise WARN  missing: rust@stable"),
            .event("exit 3"),
        ])
    }
}
