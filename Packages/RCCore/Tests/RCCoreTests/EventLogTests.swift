import Foundation
@testable import RCCore
import XCTest

final class EventLogTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("logs/controller.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testWritesTimestampedLinesAndCreatesDirectory() throws {
        let log = EventLog(fileURL: file, now: { Date(timeIntervalSince1970: 0) })
        log.record(repo: "/a/q", .event("start"))
        log.record(repo: "/a/q", .event("exit 1"))
        let written = try lines()
        XCTAssertEqual(written.count, 2)
        XCTAssertTrue(written[0].hasSuffix("/a/q start"))
        XCTAssertTrue(written[1].hasSuffix("/a/q exit 1"))
    }

    func testSkipsOutputLineRepeatedForSameRepo() throws {
        let log = EventLog(fileURL: file)
        log.record(repo: "/a", .output("same"))
        log.record(repo: "/a", .output("same"))
        log.record(repo: "/b", .output("same"))
        log.record(repo: "/a", .output("different"))
        XCTAssertEqual(try lines().count, 3)
    }

    func testEventsAreNeverDeduplicated() throws {
        let log = EventLog(fileURL: file)
        log.record(repo: "/a", .event("exit 1"))
        log.record(repo: "/a", .event("exit 1"))
        XCTAssertEqual(try lines().count, 2)
    }

    func testRotatesToLastFiveHundredLinesWhenOverOneMegabyte() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let padding = String(repeating: "x", count: 1000)
        let old = (1 ... 1200).map { "line \($0) \(padding)" }.joined(separator: "\n") + "\n"
        try old.write(to: file, atomically: true, encoding: .utf8)

        let log = EventLog(fileURL: file)
        log.record(repo: "/a", .event("new"))

        let written = try lines()
        XCTAssertEqual(written.count, 501)
        XCTAssertTrue(written[0].hasPrefix("line 701 "))
        XCTAssertTrue(written[499].hasPrefix("line 1200 "))
        XCTAssertTrue(written[500].hasSuffix("/a new"))
    }
}
