import Darwin
import Foundation
@testable import RCCore
import XCTest

@MainActor
final class ServerSupervisorTests: XCTestCase {
    private var launcher: FakeLauncher!
    private var clock: FakeClock!
    private var inspector: FakeInspector!
    private var sup: ServerSupervisor!

    override func setUp() {
        launcher = FakeLauncher()
        clock = FakeClock()
        inspector = FakeInspector()
        sup = ServerSupervisor(launcher: launcher, clock: clock, inspector: inspector)
    }

    private func repo(enabled: Bool = true, worktree: Bool = false, id: UUID = UUID()) -> Repo {
        Repo(id: id, path: "/fake/q", enabled: enabled, worktreeMode: worktree)
    }

    private let connectedLine = "·✔︎· Connected · q · main\n"
    private let connectingLine = "·|· Connecting · q · main\n"
    private let untrustedLine = "Error: Workspace not trusted. Please run `claude` in /fake/q first.\n"
    private let alreadyServedLine = "Error: This folder is already served by a terminal `claude remote-control` on this device. Stop it first.\n"

    // MARK: Connect

    func testConnectAndStatusUpdates() throws {
        let r = repo()
        sup.apply([r])
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(sup.statuses[r.id], .starting)

        launcher.last.emit(connectedLine)
        XCTAssertEqual(sup.statuses[r.id], .connected(sessions: 0, url: nil))

        launcher.last.emit("    Capacity: 1/32 · New sessions\n")
        XCTAssertEqual(sup.statuses[r.id], .connected(sessions: 1, url: nil))

        let url = try XCTUnwrap(URL(string: "https://claude.ai/code?environment=env_x"))
        launcher.last.emit("Continue coding in the Claude mobile app or \(url.absoluteString)\n")
        XCTAssertEqual(sup.statuses[r.id], .connected(sessions: 1, url: url))
    }

    func testDisabledRepoIsNotLaunched() {
        let r = repo(enabled: false)
        sup.apply([r])
        XCTAssertEqual(launcher.launches.count, 0)
        XCTAssertEqual(sup.statuses[r.id], .stopped)
    }

    // MARK: Failure paths

    func testUntrustedDoesNotRetry() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit(untrustedLine)
        launcher.last.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .untrusted)
        clock.advance(by: 3600)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testAlreadyServedSendsSigtermAndRetriesWithClearError() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit(alreadyServedLine)
        XCTAssertEqual(launcher.last.process.terminateCount, 1)

        launcher.last.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 1,
            at: clock.now().addingTimeInterval(5),
            lastError: "Already served by another process"
        ))
        clock.advance(by: 5)
        XCTAssertEqual(launcher.launches.count, 2)
    }

    func testExit127ReportsMissingBinary() {
        let r = repo()
        sup.apply([r])
        launcher.last.exit(127)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 1,
            at: clock.now().addingTimeInterval(5),
            lastError: "claude not found at ~/.local/bin/claude"
        ))
    }

    func testUnknownExitUsesLastLineAndBackoffDelays() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit("boom\n")
        launcher.last.exit(2)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 1,
            at: clock.now().addingTimeInterval(5),
            lastError: "boom (exit 2)"
        ))

        clock.advance(by: 4)
        XCTAssertEqual(launcher.launches.count, 1)
        clock.advance(by: 1)
        XCTAssertEqual(launcher.launches.count, 2)

        launcher.last.exit(2)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 2,
            at: clock.now().addingTimeInterval(30),
            lastError: "Exited (exit 2)"
        ))
        clock.advance(by: 29)
        XCTAssertEqual(launcher.launches.count, 2)
        clock.advance(by: 1)
        XCTAssertEqual(launcher.launches.count, 3)
    }

    func testLaunchErrorRetries() {
        launcher.failures = [TestError.boom]
        let r = repo()
        sup.apply([r])
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 1,
            at: clock.now().addingTimeInterval(5),
            lastError: "Cannot start: boom"
        ))
        clock.advance(by: 5)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(sup.statuses[r.id], .starting)
    }

    // MARK: Streak reset

    func testStableConnectionResetsBackoff() {
        let r = repo()
        sup.apply([r])
        launcher.last.exit(1) // attempt 1
        clock.advance(by: 5)
        launcher.last.emit(connectedLine)
        clock.advance(by: 60) // stable: streak ends
        launcher.last.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 1,
            at: clock.now().addingTimeInterval(5),
            lastError: "Exited (exit 1)"
        ))
    }

    func testShortConnectionDoesNotResetBackoff() {
        let r = repo()
        sup.apply([r])
        launcher.last.exit(1) // attempt 1
        clock.advance(by: 5)
        launcher.last.emit(connectedLine)
        clock.advance(by: 30)
        launcher.last.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 2,
            at: clock.now().addingTimeInterval(30),
            lastError: "Exited (exit 1)"
        ))
    }

    func testReconnectRestartsStabilityWindow() {
        let r = repo()
        sup.apply([r])
        launcher.last.exit(1) // attempt 1
        clock.advance(by: 5)
        launcher.last.emit(connectedLine)
        clock.advance(by: 50)
        launcher.last.emit(connectingLine) // reconnect: back to starting
        XCTAssertEqual(sup.statuses[r.id], .starting)
        launcher.last.emit(connectedLine)
        clock.advance(by: 30) // 80s since first connect, but only 30s since reconnect
        launcher.last.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 2,
            at: clock.now().addingTimeInterval(30),
            lastError: "Exited (exit 1)"
        ))
    }

    // MARK: Stop

    func testStopFromStartingSendsSigtermThenStopped() {
        let r = repo()
        sup.apply([r])
        sup.apply([repo(enabled: false, id: r.id)])
        XCTAssertEqual(launcher.last.process.terminateCount, 1)
        XCTAssertEqual(sup.statuses[r.id], .stopping)

        launcher.last.exit(15)
        XCTAssertEqual(sup.statuses[r.id], .stopped)
        clock.advance(by: 3600)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testStopFromConnectedSigkillsAfterGrace() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit(connectedLine)
        sup.apply([repo(enabled: false, id: r.id)])
        clock.advance(by: 4)
        XCTAssertEqual(launcher.last.process.killCount, 0)
        clock.advance(by: 1)
        XCTAssertEqual(launcher.last.process.killCount, 1)
    }

    func testStopFromRetryingCancelsTimer() {
        let r = repo()
        sup.apply([r])
        launcher.last.exit(1)
        sup.apply([repo(enabled: false, id: r.id)])
        XCTAssertEqual(sup.statuses[r.id], .stopped)
        clock.advance(by: 100)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testRemovedRepoDisappearsOnceStopped() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit(connectedLine)
        sup.apply([])
        XCTAssertEqual(sup.statuses[r.id], .stopping)
        launcher.last.exit(15)
        XCTAssertNil(sup.statuses[r.id])
        clock.advance(by: 3600)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testRemovedUntrustedRepoDisappears() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit(untrustedLine)
        launcher.last.exit(1)
        sup.apply([])
        XCTAssertNil(sup.statuses[r.id])
    }

    func testOffThenOnWhileStoppingStartsOnceExitArrives() {
        let r = repo()
        sup.apply([r])
        sup.apply([repo(enabled: false, id: r.id)])
        sup.apply([r])
        XCTAssertEqual(sup.statuses[r.id], .stopping)
        XCTAssertEqual(launcher.launches.count, 1)

        launcher.last.exit(0)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(sup.statuses[r.id], .starting)
    }

    // MARK: Worktree change

    func testWorktreeChangeRestartsWithNewFlag() {
        let r = repo()
        sup.apply([r])
        launcher.last.emit(connectedLine)
        sup.apply([repo(worktree: true, id: r.id)])
        XCTAssertEqual(sup.statuses[r.id], .stopping)
        XCTAssertEqual(launcher.last.process.terminateCount, 1)

        launcher.last.exit(0)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertTrue(launcher.last.repo.worktreeMode)
        XCTAssertEqual(sup.statuses[r.id], .starting)
    }

    // MARK: Stale callbacks and retry now

    func testStaleGenerationCallbacksAreIgnored() {
        let r = repo()
        sup.apply([r])
        let old = launcher.last
        old.emit(connectedLine)
        sup.apply([repo(enabled: false, id: r.id)])
        old.exit(0)
        sup.apply([r])
        XCTAssertEqual(launcher.launches.count, 2)

        old.emit(connectedLine)
        old.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .starting)
        XCTAssertEqual(launcher.launches.count, 2)
    }

    func testRetryNowStartsAtOnceAndResetsBackoff() {
        let r = repo()
        sup.apply([r])
        launcher.last.exit(1)
        clock.advance(by: 5)
        launcher.last.exit(1) // attempt 2
        sup.retryNow(r.id)
        XCTAssertEqual(launcher.launches.count, 3)
        XCTAssertEqual(sup.statuses[r.id], .starting)

        launcher.last.exit(1)
        XCTAssertEqual(sup.statuses[r.id], .retrying(
            attempt: 1,
            at: clock.now().addingTimeInterval(5),
            lastError: "Exited (exit 1)"
        ))
    }

    func testRetryNowIgnoredWhileStarting() {
        let r = repo()
        sup.apply([r])
        sup.retryNow(r.id)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    // MARK: Stop all

    func testStopAllTerminatesThenKillsSurvivors() {
        let a = repo()
        let b = repo()
        sup.apply([a, b])
        let pidA = launcher.launches[0].process.pid
        let pidB = launcher.launches[1].process.pid
        inspector.alive = [pidA, pidB]
        inspector.stubborn = [pidB]

        sup.stopAll()

        XCTAssertEqual(inspector.signals.map(\.signal), [SIGTERM, SIGTERM, SIGKILL])
        XCTAssertEqual(inspector.signals.last?.pid, pidB)
        XCTAssertTrue(inspector.alive.isEmpty)
        XCTAssertEqual(inspector.slept, 3.0, accuracy: 0.01)
    }

    func testStopAllIgnoresLateCallbacks() {
        let r = repo()
        sup.apply([r])
        let launch = launcher.last
        inspector.alive = [launch.process.pid]
        sup.stopAll()
        launch.emit(connectedLine)
        launch.exit(0)
        XCTAssertEqual(sup.statuses[r.id], .stopped)
        XCTAssertEqual(launcher.launches.count, 1)
    }
}
