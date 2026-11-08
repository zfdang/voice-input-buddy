import Foundation

/// Checks the system connection snapshot without restarting scans or making offline connection attempts.
final class BluetoothReconnectWakeMonitor {
    private let scheduler: HIDRemoteScheduling
    private var task: HIDRemoteScheduledTask?
    private var generation: UInt64 = 0

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler()) {
        self.scheduler = scheduler
    }

    func arm(isCurrent: @escaping () -> Bool, checkConnected: @escaping () -> Void) {
        cancel()
        let token = generation
        task = scheduler.schedule(afterMilliseconds: 2_000, repeatingEveryMilliseconds: 2_000) { [weak self] in
            guard let self, self.generation == token else { return }
            guard isCurrent() else { self.cancel(); return }
            checkConnected()
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit { cancel() }
}

enum BluetoothReconnectWakePolicy {
    static func canRecover(phase: BluetoothLifecyclePhase, shouldRun: Bool, suspended: Bool) -> Bool {
        guard shouldRun, !suspended else { return false }
        switch phase {
        case .scanning, .waitingReconnect: return true
        default: return false
        }
    }
}
