import Darwin
import Foundation

/// Checks and signals processes by pid. Injected so tests never touch real pids.
public protocol ProcessInspector {
    func isAlive(_ pid: Int32) -> Bool
    func send(_ signal: Int32, to pid: Int32)
    func sleep(_ seconds: TimeInterval)
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
