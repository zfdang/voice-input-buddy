import Foundation

protocol HIDRemoteScheduledTask: AnyObject {
    func cancel()
}

protocol HIDRemoteScheduling {
    @discardableResult
    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask
}

enum HIDRemoteTiming {
    static let doubleClickMilliseconds: UInt64 = 300
    static let longPressMilliseconds: UInt64 = 550
    static let repeatStartMilliseconds: UInt64 = 350
    static let stableReleaseMilliseconds: UInt64 = 600
    static let missingReleaseTimeoutMilliseconds: UInt64 = 8_000
    static let permissionPollMilliseconds: UInt64 = 1_000
    static let appSwitcherTimeoutMilliseconds: UInt64 = 15_000
    static let appSwitcherFrontmostPollMilliseconds: UInt64 = 500
    static let appSwitcherConfirmationProbeMilliseconds: UInt64 = 300
    static let appSwitcherVisibilityProbeMilliseconds: [UInt64] = [0, 150, 500, 1_000]

    static func repeatIntervalMilliseconds(for action: ButtonAction) -> UInt64 {
        action == .deleteBackward ? 50 : 100
    }
}

final class DispatchHIDRemoteScheduledTask: HIDRemoteScheduledTask {
    private let source: DispatchSourceTimer

    init(source: DispatchSourceTimer) {
        self.source = source
    }

    func cancel() {
        source.setEventHandler(handler: nil)
        source.cancel()
    }

    deinit { cancel() }
}

struct DispatchHIDRemoteScheduler: HIDRemoteScheduling {
    let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let deadline = DispatchTime.now() + .milliseconds(Int(clamping: afterMilliseconds))
        if let repeatingEveryMilliseconds {
            source.schedule(
                deadline: deadline,
                repeating: .milliseconds(Int(clamping: repeatingEveryMilliseconds))
            )
        } else {
            source.schedule(deadline: deadline)
        }
        let task = DispatchHIDRemoteScheduledTask(source: source)
        source.setEventHandler { [weak task] in
            guard let task else { return }
            // One-shot callbacks release their captures even if the handle is retained.
            if repeatingEveryMilliseconds == nil { task.cancel() }
            action()
        }
        source.resume()
        return task
    }
}
