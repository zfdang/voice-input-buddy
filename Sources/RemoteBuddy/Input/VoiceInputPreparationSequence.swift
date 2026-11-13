import Foundation

/// Serial preparation stages share one deadline rather than adding each stage's
/// independent timeout. The returned cancellation handle is silent: the owning
/// voice session has already invalidated itself before cancelling its work.
@MainActor
final class VoiceInputPreparationSequence {
    typealias Completion = (VoiceInputDestinationWaitResult) -> Void
    typealias Stage = (@escaping Completion) -> VoiceInputDestinationWait
    static let maximumWait: TimeInterval = 4
    // Reserve time for destination validation after optional focus expires.
    static let maximumFocusWait: TimeInterval = 3

    private let schedule: OperationScheduler
    private var stages: [Stage] = []
    private var completion: Completion?
    private var wait: ScheduledOperation?
    private var deadline: ScheduledOperation?
    private var generation = 0
    private var starting = true
    private var result: VoiceInputDestinationWaitResult?

    init(schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue) {
        self.schedule = schedule
    }

    func start(stages: [Stage], completion: @escaping Completion) -> VoiceInputDestinationWait {
        self.stages = stages
        self.completion = completion
        deadline = schedule(Self.maximumWait) { [weak self] in self?.finish(.cancelled(.timedOut)) }
        advance(to: 0)
        starting = false
        if let result {
            switch result {
            case .ready: return .immediate
            case let .cancelled(reason): return .cancelled(reason)
            }
        }
        // Retain the sequence until its owner finishes or cancels the wait.
        return .waiting(.mainQueueCancellation { self.cancel() })
    }

    private func advance(to index: Int) {
        guard result == nil else { return }
        guard index < stages.count else { finish(.ready); return }
        generation += 1
        let token = generation
        let stage = stages[index]
        let task = stage { [weak self] value in
            guard let self, self.result == nil, self.generation == token else { return }
            self.wait = nil
            switch value {
            case .ready: self.advance(to: index + 1)
            case .cancelled: self.finish(value)
            }
        }
        guard result == nil, generation == token else {
            if case let .waiting(operation) = task { operation.cancel() }
            return
        }
        switch task {
        case .immediate: advance(to: index + 1)
        case let .cancelled(reason): finish(.cancelled(reason))
        case let .waiting(operation): wait = operation
        }
    }

    private func finish(_ value: VoiceInputDestinationWaitResult) {
        guard result == nil else { return }
        result = value
        generation += 1
        let callback = completion
        completion = nil
        let pending = wait
        wait = nil
        stages.removeAll()
        deadline?.cancel()
        deadline = nil
        pending?.cancel()
        if !starting { callback?(value) }
    }

    private func cancel() {
        completion = nil
        finish(.cancelled(.superseded))
    }
}
