import Foundation
@testable import RemoteBuddy

/// Virtual deadlines plus explicit delivery of callbacks already dequeued at cancellation.
final class ControlledTestScheduler: HIDRemoteScheduling {
    final class Task: HIDRemoteScheduledTask {
        let delay: UInt64
        fileprivate(set) var due: UInt64
        private let callback: () -> Void
        private let interval: UInt64?
        private(set) var cancelled = false
        private var completed = false
        var action: (() -> Void)? { cancelled || completed ? nil : callback }

        init(delay: UInt64, due: UInt64, interval: UInt64?, action: @escaping () -> Void) {
            self.delay = delay
            self.due = due
            self.interval = interval
            self.callback = action
        }
        func cancel() { cancelled = true }
        func fire(includingCancelled: Bool = false) {
            guard includingCancelled || action != nil else { return }
            if let interval { due += interval } else { completed = true }
            callback()
        }
    }
    private(set) var now: UInt64 = 0
    private(set) var tasks: [Task] = []
    var activeCount: Int { tasks.filter { $0.action != nil }.count }

    func schedule(afterMilliseconds: UInt64, repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void) -> HIDRemoteScheduledTask {
        let task = Task(delay: afterMilliseconds, due: now + afterMilliseconds,
                        interval: repeatingEveryMilliseconds, action: action)
        tasks.append(task)
        return task
    }
    func voiceSchedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledOperation {
        let task = schedule(afterMilliseconds: UInt64((delay * 1_000).rounded()),
            repeatingEveryMilliseconds: nil, action)
        return ScheduledOperation { task.cancel() }
    }
    func fire(afterMilliseconds delay: UInt64) {
        for task in tasks.filter({ $0.delay == delay && $0.action != nil }) { task.fire() }
    }
    func runNext() {
        guard let task = tasks.filter({ $0.action != nil }).min(by: { $0.due < $1.due }) else { return }
        now = task.due
        task.fire()
    }
    func runAll() {
        for _ in 0..<100 where activeCount > 0 { runNext() }
    }
    func advance(to end: UInt64) {
        precondition(end >= now)
        while let task = tasks.filter({ $0.action != nil && $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = task.due
            task.fire()
        }
        now = end
    }
}
