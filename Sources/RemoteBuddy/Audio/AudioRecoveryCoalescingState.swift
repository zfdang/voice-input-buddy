import Foundation

struct AudioRecoveryCoalescingState {
    private(set) var pendingEventCount = 0
    private(set) var includesHardwareChange = false

    mutating func recordEvent(reason: String) {
        pendingEventCount += 1
        if reason == "hardware_change" {
            includesHardwareChange = true
        }
    }

    mutating func consumePendingEvents() -> (count: Int, includesHardwareChange: Bool) {
        let result = (pendingEventCount, includesHardwareChange)
        pendingEventCount = 0
        includesHardwareChange = false
        return result
    }

    mutating func reset() {
        pendingEventCount = 0
        includesHardwareChange = false
    }
}

