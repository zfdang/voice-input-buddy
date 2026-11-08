import Foundation

/// Periodically rechecks system-connected devices while no advertisement is arriving.
final class BluetoothScanWatchdog {
    private let scheduler: HIDRemoteScheduling
    private var task: HIDRemoteScheduledTask?
    private var generation: UInt64 = 0

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler()) {
        self.scheduler = scheduler
    }

    func arm(isCurrent: @escaping () -> Bool, rediscover: @escaping () -> Void) {
        cancel()
        let token = generation
        task = scheduler.schedule(afterMilliseconds: 20_000, repeatingEveryMilliseconds: nil) { [weak self] in
            guard let self, self.generation == token, isCurrent() else { return }
            self.cancel()
            rediscover()
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit { cancel() }
}
