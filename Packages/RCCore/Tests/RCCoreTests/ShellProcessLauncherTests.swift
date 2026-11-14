import Foundation
@testable import RCCore
import XCTest

/// Collects events in the order they arrive. Callbacks run on the main queue.
private final class Recorder {
    var events: [String] = []
    var output = Data()
    var exitCode: Int32?
}

final class ShellProcessLauncherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellLauncherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingDirectoryThrows() {
        let launcher = ShellProcessLauncher(executable: "/bin/sh", arguments: ["-c"], command: "true")
        let repo = Repo(path: dir.appendingPathComponent("missing").path, enabled: true, worktreeMode: false)
        XCTAssertThrowsError(try launcher.launch(repo: repo, onOutput: { _ in }, onExit: { _ in }))
    }

    /// Stub server: prints the connected fixture, then stays alive (exec, so no
    /// orphaned child holds the pipe open).
    func testOutputArrivesTerminateEndsAndExitFollowsOutput() throws {
        let fixture = try XCTUnwrap(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/connected.txt").path
        let launcher = ShellProcessLauncher(
            executable: "/bin/sh",
            arguments: ["-c"],
            command: "cat '\(fixture)'; exec sleep 60"
        )
        let repo = Repo(path: dir.path, enabled: true, worktreeMode: false)
        let recorder = Recorder()
        let sawConnected = expectation(description: "output arrives")
        let exited = expectation(description: "exit delivered")

        let process = try launcher.launch(
            repo: repo,
            onOutput: { data in
                recorder.events.append("output")
                recorder.output.append(data)
                if String(decoding: recorder.output, as: UTF8.self).contains("Connected ·") {
                    sawConnected.fulfill()
                }
            },
            onExit: { code in
                recorder.events.append("exit")
                recorder.exitCode = code
                exited.fulfill()
            }
        )

        wait(for: [sawConnected], timeout: 10)
        process.terminate()
        wait(for: [exited], timeout: 10)

        XCTAssertNotNil(recorder.exitCode)
        XCTAssertEqual(recorder.events.last, "exit", "onExit must come after the last output")
        XCTAssertTrue(String(decoding: recorder.output, as: UTF8.self).contains("environment=env_"))
    }
}
