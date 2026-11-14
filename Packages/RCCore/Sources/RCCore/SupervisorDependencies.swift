import Darwin
import Foundation

/// Checks and signals processes by pid. Injected so tests never touch real pids.
public protocol ProcessInspector {
    func isAlive(_ pid: Int32) -> Bool
    func send(_ signal: Int32, to pid: Int32)
    func sleep(_ seconds: TimeInterval)
    /// Full command line of a pid, or nil if it cannot be read.
    func commandLine(of pid: Int32) -> String?
}

public struct SystemProcessInspector: ProcessInspector {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    public func send(_ signal: Int32, to pid: Int32) {
        _ = Darwin.kill(pid, signal)
    }

    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    public func commandLine(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public protocol Cancellable: AnyObject {
    func cancel()
}

/// Wall clock plus delayed actions. Injected so tests can advance time.
public protocol SupervisorClock {
    func now() -> Date
    /// Runs `action` on the main queue after `seconds`, unless cancelled.
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> Cancellable
}

public final class SystemClock: SupervisorClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return WorkItemHandle(item: item)
    }
}

private final class WorkItemHandle: Cancellable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}
