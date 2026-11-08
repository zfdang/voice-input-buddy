import CoreGraphics
import Foundation

/// Main-queue confined cleanup ownership for one-shot modifier mappings.
final class StandaloneModifierReleaseRecovery {
    static let shared = StandaloneModifierReleaseRecovery()
    private struct Pending {
        let token = UUID()
        let post: KeyboardInjector.KeyStatePoster
        var attempts: Int
        var task: ScheduledOperation?
    }
    private var pending: [CGKeyCode: Pending] = [:]
    private let schedule: OperationScheduler

    init(schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue) {
        self.schedule = schedule
    }

    func permitsPress(_ code: CGKeyCode) -> Bool {
        guard let state = pending[code] else { return true }
        guard state.post(code, false, []) else { return false }
        state.task?.cancel()
        pending.removeValue(forKey: code)
        return true
    }

    func recover(_ code: CGKeyCode, post: @escaping KeyboardInjector.KeyStatePoster) {
        guard pending[code] == nil else { return }
        pending[code] = Pending(post: post, attempts: 0)
        scheduleRetry(code)
    }

    private func scheduleRetry(_ code: CGKeyCode) {
        guard let state = pending[code], state.attempts < 8 else { return }
        let token = state.token
        let task = schedule(min(1, 0.05 * pow(2, Double(state.attempts)))) { [weak self] in
            guard let self, var state = self.pending[code], state.token == token else { return }
            if state.post(code, false, []) {
                self.pending.removeValue(forKey: code)
                return
            }
            state.attempts += 1
            self.pending[code] = state
            self.scheduleRetry(code)
        }
        pending[code]?.task = task
    }

    deinit { pending.values.forEach { $0.task?.cancel() } }
}
