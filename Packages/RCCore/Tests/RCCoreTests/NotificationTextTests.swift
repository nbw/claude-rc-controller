import Foundation
@testable import RCCore
import XCTest

final class NotificationTextTests: XCTestCase {
    private let connected = ServerStatus.connected(sessions: 1, url: nil)

    func testSummaryWhenAllUp() {
        let text = NotificationText.startupSummary([
            .init(name: "q", status: connected),
            .init(name: "stitch", status: connected),
        ])
        XCTAssertEqual(text, "Remote Control up: q, stitch")
    }

    func testSummaryWhenSomeNotUp() {
        let text = NotificationText.startupSummary([
            .init(name: "q", status: connected),
            .init(name: "stitch", status: .untrusted),
        ])
        XCTAssertEqual(text, "Remote Control: 1 of 2 up. stitch: not trusted")
    }

    func testSummaryListsEveryProblemRepo() {
        let text = NotificationText.startupSummary([
            .init(name: "a", status: .untrusted),
            .init(name: "b", status: .retrying(attempt: 1, at: Date(), lastError: "x")),
            .init(name: "c", status: connected),
        ])
        XCTAssertEqual(text, "Remote Control: 1 of 3 up. a: not trusted; b: retrying")
    }

    func testSummaryNilWithNoRepos() {
        XCTAssertNil(NotificationText.startupSummary([]))
    }

    func testFailureNoticeOncePerStreak() {
        var notifier = FailureNotifier()
        let id = UUID()
        let untrusted = notifier.notice(repoID: id, name: "stitch", status: .untrusted)
        XCTAssertNotNil(untrusted)
        XCTAssertNil(notifier.notice(repoID: id, name: "stitch", status: .untrusted))
    }

    func testRetryNoticeOnlyAtAttemptThree() {
        var notifier = FailureNotifier()
        let id = UUID()
        let early = ServerStatus.retrying(attempt: 2, at: Date(), lastError: "boom")
        XCTAssertNil(notifier.notice(repoID: id, name: "q", status: early))

        let third = ServerStatus.retrying(attempt: 3, at: Date(), lastError: "boom")
        XCTAssertEqual(notifier.notice(repoID: id, name: "q", status: third), "q keeps failing: boom")
        XCTAssertNil(notifier.notice(repoID: id, name: "q", status: third))
    }

    func testStoppingStartsANewStreak() {
        var notifier = FailureNotifier()
        let id = UUID()
        XCTAssertNotNil(notifier.notice(repoID: id, name: "q", status: .untrusted))
        XCTAssertNil(notifier.notice(repoID: id, name: "q", status: .stopped))
        XCTAssertNotNil(notifier.notice(repoID: id, name: "q", status: .untrusted))
    }

    func testFailureNotifierTracksReposIndependently() {
        var notifier = FailureNotifier()
        XCTAssertNotNil(notifier.notice(repoID: UUID(), name: "a", status: .untrusted))
        XCTAssertNotNil(notifier.notice(repoID: UUID(), name: "b", status: .untrusted))
    }
}
