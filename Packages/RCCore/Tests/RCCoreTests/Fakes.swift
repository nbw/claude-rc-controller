import Foundation
@testable import RCCore

final class FakeProcess: RunningProcess {
    let pid: Int32
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(pid: Int32) {
        self.pid = pid
    }

    func terminate() {
        terminateCount += 1
    }

    func kill() {
        killCount += 1
    }
}

struct FakeLaunch {
    let repo: Repo
    let process: FakeProcess
    let output: (Data) -> Void
    let exit: (Int32) -> Void

    func emit(_ text: String) {
        output(Data(text.utf8))
    }
}

final class FakeLauncher: ProcessLauncher {
    private(set) var launches: [FakeLaunch] = []
    /// Errors thrown by the next launch calls, in order.
    var failures: [Error] = []
    private var nextPid: Int32 = 100

    func launch(
        repo: Repo,
        onOutput: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws -> RunningProcess {
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        nextPid += 1
        let process = FakeProcess(pid: nextPid)
        launches.append(FakeLaunch(repo: repo, process: process, output: onOutput, exit: onExit))
        return process
    }

    var last: FakeLaunch {
        launches[launches.count - 1]
    }
}

final class FakeClock: SupervisorClock {
    private final class Timer: Cancellable {
        var cancelled = false
        func cancel() {
            cancelled = true
        }
    }

    private struct Item {
        let due: Date
        let timer: Timer
        let action: () -> Void
    }

    private(set) var current = Date(timeIntervalSince1970: 1000)
    private var items: [Item] = []

    func now() -> Date {
        current
    }

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> Cancellable {
        let timer = Timer()
        items.append(Item(due: current.addingTimeInterval(seconds), timer: timer, action: action))
        return timer
    }

    /// Runs every due, uncancelled action in time order, then sets the clock.
    func advance(by seconds: TimeInterval) {
        let target = current.addingTimeInterval(seconds)
        while true {
            let due = items.indices
                .filter { items[$0].due <= target && !items[$0].timer.cancelled }
                .min { items[$0].due < items[$1].due }
            guard let index = due else { break }
            let item = items.remove(at: index)
            current = item.due
            item.action()
        }
        current = target
    }
}

final class FakeInspector: ProcessInspector {
    var alive: Set<Int32> = []
    /// Pids that ignore SIGTERM.
    var stubborn: Set<Int32> = []
    private(set) var signals: [(signal: Int32, pid: Int32)] = []
    private(set) var slept: TimeInterval = 0

    func isAlive(_ pid: Int32) -> Bool {
        alive.contains(pid)
    }

    func send(_ signal: Int32, to pid: Int32) {
        signals.append((signal, pid))
        if signal == SIGKILL || !stubborn.contains(pid) {
            alive.remove(pid)
        }
    }

    func sleep(_ seconds: TimeInterval) {
        slept += seconds
    }
}

enum TestError: Error {
    case boom
}
