import Foundation

struct ScheduledOperation: Sendable {
    private let cancellation: @Sendable () -> Void

    init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }

    /// Cancellation that mutates main-queue state runs there even during off-main teardown.
    /// PendingOperation makes repeated cancellation deliver the cleanup at most once.
    static func mainQueueCancellation(_ cancellation: @escaping () -> Void) -> ScheduledOperation {
        let pending = PendingOperation(cancellation)
        return ScheduledOperation {
            if Thread.isMainThread { pending.perform() }
            else { DispatchQueue.main.async { pending.perform() } }
        }
    }

    static func mainQueue(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) -> ScheduledOperation {
        scheduled(after: delay, enqueue: { delay, item in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }, operation: operation)
    }

    static func scheduled(after delay: TimeInterval,
                          enqueue: (TimeInterval, DispatchWorkItem) -> Void,
                          operation: @escaping () -> Void) -> ScheduledOperation {
        let pending = PendingOperation(operation)
        let item = DispatchWorkItem { pending.perform() }
        enqueue(delay, item)
        return ScheduledOperation {
            pending.cancel()
        }
    }
}

/// Owns the callback without capturing its DispatchWorkItem. Clearing it on both
/// terminal paths also releases captured objects when the task handle is retained.
// Only the locked callback slot crosses queues. Execution stays on the enqueueing
// scheduler's queue; cancelling clears the slot without invoking its callback.
private final class PendingOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (() -> Void)?

    init(_ operation: @escaping () -> Void) {
        self.operation = operation
    }

    func perform() {
        lock.lock()
        let operation = self.operation
        self.operation = nil
        lock.unlock()
        operation?()
    }

    func cancel() {
        lock.lock()
        let cancelledOperation = operation
        operation = nil
        lock.unlock()
        withExtendedLifetime(cancelledOperation) {}
    }
}

typealias OperationScheduler = (TimeInterval, @escaping () -> Void) -> ScheduledOperation
