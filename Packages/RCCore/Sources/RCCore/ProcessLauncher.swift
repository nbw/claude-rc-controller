import Darwin
import Foundation

/// Starts one `claude remote-control` server for a repo.
///
/// Callbacks are delivered on the main queue, in order, and `onExit` always
/// comes after the last `onOutput`.
public protocol ProcessLauncher {
    func launch(
        repo: Repo,
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws -> RunningProcess
}

public protocol RunningProcess: AnyObject {
    var pid: Int32 { get }
    /// SIGTERM. No-op if already exited.
    func terminate()
    /// SIGKILL. No-op if already exited.
    func kill()
}

/// Launches through a shell so the user's `~/.zshrc` environment applies.
public struct ShellProcessLauncher: ProcessLauncher {
    public var executable: String
    public var arguments: [String]
    public var command: String

    public init(
        executable: String = "/bin/zsh",
        arguments: [String] = ["-ilc"],
        command: String = #"exec "$HOME/.local/bin/claude" remote-control"#
    ) {
        self.executable = executable
        self.arguments = arguments
        self.command = command
    }

    public func launch(
        repo: Repo,
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws -> RunningProcess {
        var commandString = command
        if repo.worktreeMode {
            commandString += " --spawn worktree"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [commandString]
        process.currentDirectoryURL = URL(fileURLWithPath: repo.path, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let running = ShellRunningProcess(
            process: process,
            pipe: pipe,
            onOutput: onOutput,
            onExit: onExit
        )
        try running.start()
        return running
    }
}

/// Wraps a Foundation `Process`. Output and exit are funnelled through one
/// private serial queue, then delivered to the main queue.
final class ShellRunningProcess: RunningProcess {
    private let process: Process
    private let pipe: Pipe
    private let onOutput: (Data) -> Void
    private let onExit: (Int32) -> Void
    private let queue = DispatchQueue(label: "RCCore.ShellRunningProcess")

    // Only touched on `queue`.
    private var reachedEOF = false
    private var graceExpired = false
    private var exitStatus: Int32?
    private var delivered = false

    init(
        process: Process,
        pipe: Pipe,
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) {
        self.process = process
        self.pipe = pipe
        self.onOutput = onOutput
        self.onExit = onExit
    }

    var pid: Int32 {
        process.processIdentifier
    }

    func start() throws {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            queue.async { self.handleReadable(data, handle: handle) }
        }
        process.terminationHandler = { [self] _ in
            queue.async { self.handleTermination() }
        }
        try process.run()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: Queue-confined

    private func handleReadable(_ data: Data, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            reachedEOF = true
            finishIfReady()
        } else {
            DispatchQueue.main.async { self.onOutput(data) }
        }
    }

    private func handleTermination() {
        exitStatus = process.terminationStatus
        // A surviving child can hold the pipe open, so wait at most 1 second.
        queue.asyncAfter(deadline: .now() + 1) {
            self.graceExpired = true
            self.finishIfReady()
        }
        finishIfReady()
    }

    private func finishIfReady() {
        guard !delivered, let status = exitStatus, reachedEOF || graceExpired else { return }
        delivered = true
        pipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        DispatchQueue.main.async { self.onExit(status) }
    }
}
