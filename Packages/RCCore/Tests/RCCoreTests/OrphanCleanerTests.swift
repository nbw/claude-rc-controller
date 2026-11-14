import Darwin
import Foundation
@testable import RCCore
import XCTest

final class OrphanCleanerTests: XCTestCase {
    private var dir: URL!
    private var store: PidRecordStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrphanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = PidRecordStore(fileURL: dir.appendingPathComponent("pids.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStoreRoundTrip() throws {
        let records = [LiveProcess(pid: 10, path: "/a"), LiveProcess(pid: 20, path: "/b")]
        try store.save(records)
        XCTAssertEqual(store.load(), records)
    }

    func testMissingOrCorruptFileLoadsEmpty() throws {
        XCTAssertEqual(store.load(), [])
        try "not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), [])
    }

    func testKillsOnlyRecordedPidsThatAreStillRemoteControl() throws {
        try store.save([
            LiveProcess(pid: 10, path: "/a"), // our server, still alive
            LiveProcess(pid: 20, path: "/b"), // pid reused by something else
            LiveProcess(pid: 30, path: "/c"), // gone
        ])
        let inspector = FakeInspector()
        inspector.alive = [10, 20]
        inspector.commandLines = [
            10: "/Users/x/.local/bin/claude remote-control --spawn worktree",
            20: "/usr/bin/some-other-tool --remote-control-like",
        ]

        OrphanCleaner.run(store: store, inspector: inspector)

        XCTAssertEqual(inspector.signals.map(\.pid), [10])
        XCTAssertEqual(inspector.signals.map(\.signal), [SIGTERM])
        XCTAssertFalse(inspector.alive.contains(10))
        XCTAssertTrue(inspector.alive.contains(20))
        XCTAssertEqual(store.load(), [])
    }

    func testSigkillsSurvivorAfterGrace() throws {
        try store.save([LiveProcess(pid: 10, path: "/a")])
        let inspector = FakeInspector()
        inspector.alive = [10]
        inspector.stubborn = [10]
        inspector.commandLines = [10: "claude remote-control"]

        OrphanCleaner.run(store: store, inspector: inspector)

        XCTAssertEqual(inspector.signals.map(\.signal), [SIGTERM, SIGKILL])
        XCTAssertTrue(inspector.alive.isEmpty)
    }
}
