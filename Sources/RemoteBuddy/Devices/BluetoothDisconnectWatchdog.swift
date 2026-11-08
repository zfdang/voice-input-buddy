import Foundation

/// Finishes a disconnect attempt even when bluetoothd never sends its callback.
final class BluetoothDisconnectWatchdog {
    private let scheduler: HIDRemoteScheduling
    private var task: HIDRemoteScheduledTask?
    private var token: UInt64 = 0

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler()) {
        self.scheduler = scheduler
    }

    func arm(isCurrent: @escaping () -> Bool, onTimeout: @escaping () -> Void) {
        cancel()
        let current = token
        task = scheduler.schedule(afterMilliseconds: 5_000, repeatingEveryMilliseconds: nil) { [weak self] in
            guard let self, self.token == current, isCurrent() else { return }
            self.cancel()
            onTimeout()
        }
    }

    func cancel() {
        token &+= 1
        task?.cancel()
        task = nil
    }

    deinit { cancel() }
}
