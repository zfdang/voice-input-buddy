import Foundation

/// Serializes ATT writes with response; acceptance is distinct from acknowledgement.
final class AcknowledgedBluetoothWriteQueue {
    private let send: (Data) -> Void
    private let onFailure: () -> Void
    private let scheduler: HIDRemoteScheduling
    private var pending: [Data] = []
    private var inFlight = false
    private var sequence: UInt64 = 0
    private var timeout: HIDRemoteScheduledTask?

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
         send: @escaping (Data) -> Void, onFailure: @escaping () -> Void) {
        self.scheduler = scheduler
        self.send = send
        self.onFailure = onFailure
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard pending.count + (inFlight ? 1 : 0) < 32 else { return false }
        pending.append(data)
        pump()
        return true
    }

    func acknowledge(success: Bool) {
        guard inFlight else { return }
        timeout?.cancel()
        timeout = nil
        inFlight = false
        if success { pump() }
        else { reset(); onFailure() }
    }

    func reset() {
        sequence &+= 1
        timeout?.cancel()
        timeout = nil
        inFlight = false
        pending.removeAll()
    }

    private func pump() {
        guard !inFlight, !pending.isEmpty else { return }
        let data = pending.removeFirst()
        inFlight = true
        sequence &+= 1
        let current = sequence
        timeout = scheduler.schedule(afterMilliseconds: 5_000, repeatingEveryMilliseconds: nil) { [weak self] in
            guard let self, self.inFlight, self.sequence == current else { return }
            self.reset()
            self.onFailure()
        }
        send(data)
    }

    deinit { reset() }
}
