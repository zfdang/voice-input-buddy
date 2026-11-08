import Foundation

/// Serializes unacknowledged ATT writes without exceeding the peripheral's send budget.
final class FlowControlledBluetoothWriteQueue {
    private let canSend: () -> Bool
    private let send: (Data) -> Void
    private let onFailure: () -> Void
    private let scheduler: HIDRemoteScheduling
    private var pending: [Data] = []
    private var timeout: HIDRemoteScheduledTask?
    private var generation: UInt64 = 0

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
         canSend: @escaping () -> Bool, send: @escaping (Data) -> Void,
         onFailure: @escaping () -> Void) {
        self.scheduler = scheduler
        self.canSend = canSend
        self.send = send
        self.onFailure = onFailure
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard pending.count < 32 else { return false }
        pending.append(data)
        pump()
        return true
    }

    func pump() {
        var progressed = false
        while !pending.isEmpty, canSend() {
            send(pending.removeFirst())
            progressed = true
        }
        if progressed {
            generation &+= 1
            timeout?.cancel()
            timeout = nil
        }
        if pending.isEmpty {
            generation &+= 1
            timeout?.cancel()
            timeout = nil
        } else if timeout == nil {
            let current = generation
            timeout = scheduler.schedule(afterMilliseconds: 5_000, repeatingEveryMilliseconds: nil) { [weak self] in
                guard let self, self.generation == current, !self.pending.isEmpty else { return }
                self.reset()
                self.onFailure()
            }
        }
    }

    func reset() {
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        pending.removeAll()
    }

    deinit { reset() }
}
