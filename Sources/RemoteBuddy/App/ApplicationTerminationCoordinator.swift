import Foundation

/// Coalesces quit requests and bounds asynchronous Fn/audio cleanup.
@MainActor
final class ApplicationTerminationCoordinator {
    private(set) var isTerminating = false
    private var didReply = false
    private var watchdog: ScheduledOperation?
    private let schedule: OperationScheduler

    init(schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue) {
        self.schedule = schedule
    }

    isolated deinit { watchdog?.cancel() }

    func request(timeout: TimeInterval = 15,
                 begin: (@escaping () -> Void) -> Void, reply: @escaping () -> Void) {
        guard !isTerminating else { return }
        isTerminating = true
        watchdog = schedule(timeout) { [weak self] in
            guard let self, !self.didReply else { return }
            AppLogger.shared.write("APP TERMINATION cleanup_timeout=true")
            self.finish(reply: reply)
        }
        begin { [weak self] in self?.finish(reply: reply) }
    }

    private func finish(reply: () -> Void) {
        guard !didReply else { return }
        didReply = true
        watchdog?.cancel()
        watchdog = nil
        reply()
    }
}
