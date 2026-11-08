import Foundation

enum VoiceFnTapFailure: String, Equatable {
    case startTapFailed = "start_tap_failed"
    case stopTapFailed = "stop_tap_failed"
}

final class VoiceFnTapSessionController {
    enum Phase: Equatable {
        case idle
        case starting(UInt64)
        case active(UInt64)
        case draining(UInt64)
        case stopping(UInt64)
    }

    typealias Scheduler = OperationScheduler
    typealias FunctionKeySetter = (Bool) -> Bool
    typealias AudioEnqueuer = ([Int16]) -> Void
    typealias AudioDrainer = (UInt64, @escaping () -> Void) -> Void
    typealias DestinationReadiness = (
        @escaping (VoiceInputDestinationWaitResult) -> Void
    ) -> VoiceInputDestinationWait

    private struct PendingVoice {
        var samples: [Int16] = []
        var ended = false
    }

    /// Upper bound on `.draining`. Comfortably above the audio side's own drain fallback,
    /// so a healthy session always leaves `.draining` through `drainAudio` and this only
    /// fires when no drain answer arrives at all.
    private let pendingPlaybackDuration: () -> TimeInterval
    private var drainTimeout: TimeInterval { max(2, pendingPlaybackDuration() + 1.5) }
    private let startDelay: TimeInterval
    private let tapDuration: TimeInterval
    /// Time between the key-down edges of consecutive start taps.
    private let startTapInterval: TimeInterval
    private var startTapGap: TimeInterval { max(0, startTapInterval - tapDuration) }
    private let startTapCount: () -> Int
    private let maximumPreRollSampleCount: Int
    private let schedule: Scheduler
    private let destinationReadiness: DestinationReadiness
    private let setFunctionKeyPressed: FunctionKeySetter
    private let enqueueAudio: AudioEnqueuer
    private let enqueuePreRollAudio: AudioEnqueuer
    private let drainAudio: AudioDrainer
    private let onFailure: (VoiceFnTapFailure) -> Void
    private let logger: (String) -> Void
    private let uptime: () -> TimeInterval
    private let onIdle: () -> Void

    private(set) var phase: Phase = .idle
    private(set) var isEnabled = false
    private(set) var isSuspended = false
    private var generation: UInt64 = 0
    private var preRoll: [Int16] = []
    private var remoteEnded = false
    private var pendingVoice: PendingVoice?
    private var scheduledTasks: [ScheduledOperation] = []
    private var functionKeyIsPressed = false
    /// Once the first start tap is sent, the rest of the start sequence must follow.
    private var startSequenceBegan = false
    private var keyReleaseRetryTask: ScheduledOperation?
    private var nextKeyReleaseRetryDelay: TimeInterval = 1
    private var idleCompletions: [(Bool) -> Void] = []
    private var failedKeyReleaseAttempts = 0
    private let maximumKeyReleaseAttempts = 4
    private(set) var releaseRecoveryBlocked = false
    private var suppressAudioUntilRemoteStop = false
    private var drainOperationID: UInt64?
    private var drainStartedAtUptime: TimeInterval?

    /// Allow drain fallback, all taps, and the full bounded key-release retry budget.
    var terminationTimeout: TimeInterval {
        let retries = (0..<(maximumKeyReleaseAttempts - 1)).reduce(0.0) {
            $0 + min(30, pow(2, Double($1)))
        }
        let startTaps = Double(max(1, startTapCount()))
        let startPulses = startTaps * tapDuration + (startTaps - 1) * startTapGap
        return max(10, drainTimeout + startPulses + tapDuration + startDelay + retries + 1)
    }

    /// Key-release recovery alone must not keep the audio device running.
    var hasPendingAudioSession: Bool {
        phase != .idle || pendingVoice != nil
    }

    var requiresCleanupBeforeMapping: Bool {
        phase != .idle || functionKeyIsPressed
    }

    init(
        startDelay: TimeInterval = 0.15,
        tapDuration: TimeInterval = 0.12,
        startTapInterval: TimeInterval = 0.15,
        startTapCount: @escaping () -> Int = { 1 },
        maximumPreRollSampleCount: Int = VoicePlaybackQueueCapacity.maximumPreRollSamples,
        schedule: @escaping Scheduler = ScheduledOperation.mainQueue,
        destinationReadiness: @escaping DestinationReadiness = { _ in .immediate },
        setFunctionKeyPressed: @escaping FunctionKeySetter,
        enqueueAudio: @escaping AudioEnqueuer,
        drainAudio: @escaping AudioDrainer,
        onFailure: @escaping (VoiceFnTapFailure) -> Void,
        enqueuePreRollAudio: AudioEnqueuer? = nil,
        pendingPlaybackDuration: @escaping () -> TimeInterval = { 0 },
        logger: @escaping (String) -> Void = { _ in },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onIdle: @escaping () -> Void = {}
    ) {
        self.startDelay = startDelay
        self.tapDuration = tapDuration
        self.startTapInterval = startTapInterval
        self.startTapCount = startTapCount
        self.maximumPreRollSampleCount = maximumPreRollSampleCount
        self.schedule = schedule
        self.destinationReadiness = destinationReadiness
        self.setFunctionKeyPressed = setFunctionKeyPressed
        self.enqueueAudio = enqueueAudio
        self.enqueuePreRollAudio = enqueuePreRollAudio ?? enqueueAudio
        self.pendingPlaybackDuration = pendingPlaybackDuration
        self.drainAudio = drainAudio
        self.onFailure = onFailure
        self.logger = logger
        self.uptime = uptime
        self.onIdle = onIdle
    }

    deinit {
        scheduledTasks.forEach { $0.cancel() }
        keyReleaseRetryTask?.cancel()
        if functionKeyIsPressed { _ = setFunctionKeyPressed(false) }
    }

    func setEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        isEnabled = enabled
        if enabled {
            completion?(!requiresCleanupBeforeMapping)
            return
        }
        let hasSession = phase != .idle
        terminateCurrentSession(
            remoteHasEnded: remoteEnded,
            suppressUntilRemoteStop: hasSession && !remoteEnded,
            completion: completion
        )
    }

    func suspend(completion: ((Bool) -> Void)? = nil) {
        isSuspended = true
        terminateCurrentSession(
            remoteHasEnded: true,
            suppressUntilRemoteStop: false,
            completion: completion
        )
    }

    func resume() {
        isSuspended = false
        retryCleanupAfterPermissionRecovery()
    }

    func retryCleanupAfterPermissionRecovery() {
        guard releaseRecoveryBlocked else { return }
        releaseRecoveryBlocked = false
        failedKeyReleaseAttempts = 0
        nextKeyReleaseRetryDelay = 1
        _ = releaseFunctionKeyIfNeeded()
        runIdleCompletions()
    }

    @discardableResult
    func startVoice() -> Bool {
        guard isEnabled else {
            logger("VOICE FN TAP start rejected reason=disabled")
            return false
        }
        guard !isSuspended else {
            logger("VOICE FN TAP start rejected reason=suspended")
            return false
        }
        let queuesNextVoice: Bool
        switch phase {
        case .draining, .stopping: queuesNextVoice = true
        case .starting: queuesNextVoice = remoteEnded
        case .idle, .active: queuesNextVoice = false
        }
        if queuesNextVoice {
            // The previous session owns its remaining key edges. Start this
            // press only after its stop pulse has been successfully released.
            if pendingVoice == nil { pendingVoice = PendingVoice() }
            return true
        }
        guard !functionKeyIsPressed else {
            logger("VOICE FN TAP start rejected reason=key_held")
            return false
        }
        switch phase {
        case .idle:
            beginSession()
        case .starting, .active, .draining, .stopping:
            break
        }
        return true
    }

    @discardableResult
    func receive(_ samples: [Int16], isPreRoll: Bool = false) -> Bool {
        guard !samples.isEmpty else {
            return phase != .idle || pendingVoice != nil || suppressAudioUntilRemoteStop
        }
        if pendingVoice != nil {
            appendPreRoll(samples, toPendingVoice: true)
            return true
        }
        switch phase {
        case .starting:
            appendPreRoll(samples, toPendingVoice: false)
            return true
        case .active:
            if isPreRoll { enqueuePreRollAudio(samples) } else { enqueueAudio(samples) }
            return true
        case .draining, .stopping:
            return true
        case .idle:
            return suppressAudioUntilRemoteStop
        }
    }

    @discardableResult
    func stopVoice() -> Bool {
        suppressAudioUntilRemoteStop = false
        if pendingVoice != nil {
            pendingVoice?.ended = true
            return true
        }
        switch phase {
        case let .starting(sessionGeneration):
            remoteEnded = true
            if !functionKeyIsPressed && !startSequenceBegan {
                // A released button must not start dictation after the start
                // delay or destination wait finally completes.
                cancelSessionAwaitingDestination(generation: sessionGeneration)
            }
            return true
        case let .active(sessionGeneration):
            remoteEnded = true
            beginDrain(generation: sessionGeneration)
            return true
        case .draining, .stopping:
            remoteEnded = true
            return true
        case .idle:
            releaseFunctionKeyIfNeeded()
            runIdleCompletions()
            return false
        }
    }

    func shutdown() {
        isEnabled = false
        isSuspended = true
        suppressAudioUntilRemoteStop = false
        pendingVoice = nil
        let needsStopTap: Bool
        switch phase {
        case .active, .draining: needsStopTap = true
        case .starting where functionKeyIsPressed || startSequenceBegan:
            // Finish the start pulses before issuing a full-duration stop pulse.
            remoteEnded = true
            preRoll.removeAll()
            return
        case .stopping:
            // The existing stop pulse already owns its scheduled release.
            return
        case .starting, .idle: needsStopTap = false
        }
        generation &+= 1
        cancelScheduledTasks()
        if needsStopTap {
            phase = .stopping(generation)
            let token = generation
            performFunctionKeyTap(generation: token) { [weak self] success in
                guard let self, self.generation == token else { return }
                if !success { self.onFailure(.stopTapFailed) }
                self.logDrainTerminalIfNeeded(result: "cancelled", reason: "shutdown")
                self.resetSessionState()
                self.runIdleCompletions()
            }
        } else {
            logDrainTerminalIfNeeded(result: "cancelled", reason: "shutdown")
            resetSessionState()
            runIdleCompletions()
        }
    }

    private func beginSession(preloaded: PendingVoice? = nil) {
        generation &+= 1
        let sessionGeneration = generation
        phase = .starting(sessionGeneration)
        preRoll = preloaded?.samples ?? []
        remoteEnded = preloaded?.ended ?? false
        switch destinationReadiness({ [weak self] result in
            self?.destinationReadinessCompleted(result, generation: sessionGeneration)
        }) {
        case .immediate:
            scheduleStartTap(generation: sessionGeneration, after: startDelay)
        case .cancelled:
            cancelSessionAwaitingDestination(generation: sessionGeneration)
        case let .waiting(task):
            scheduledTasks.append(task)
        }
    }

    private func destinationReadinessCompleted(
        _ result: VoiceInputDestinationWaitResult,
        generation sessionGeneration: UInt64
    ) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        switch result {
        case .ready:
            beginStartTap(generation: sessionGeneration)
        case .cancelled:
            cancelSessionAwaitingDestination(generation: sessionGeneration)
        }
    }

    private func scheduleStartTap(generation sessionGeneration: UInt64, after delay: TimeInterval) {
        let task = schedule(delay) { [weak self] in
            self?.beginStartTap(generation: sessionGeneration)
        }
        scheduledTasks.append(task)
    }

    private func cancelSessionAwaitingDestination(generation sessionGeneration: UInt64) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        let shouldSuppressAudioUntilRemoteStop = !remoteEnded
        generation &+= 1
        resetSessionState()
        suppressAudioUntilRemoteStop = shouldSuppressAudioUntilRemoteStop
        runIdleCompletions()
    }

    private func beginStartTap(generation sessionGeneration: UInt64) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        startSequenceBegan = true
        performStartTaps(remaining: max(1, startTapCount()), generation: sessionGeneration)
    }

    /// Tools such as macOS Dictation start on a double press but stop on one press.
    private func performStartTaps(remaining: Int, generation sessionGeneration: UInt64) {
        guard phase == .starting(sessionGeneration), generation == sessionGeneration else { return }
        performFunctionKeyTap(generation: sessionGeneration) { [weak self] success in
            guard let self,
                  self.phase == .starting(sessionGeneration),
                  self.generation == sessionGeneration
            else { return }
            guard success else {
                self.fail(.startTapFailed)
                return
            }
            if remaining > 1 {
                self.scheduledTasks.append(self.schedule(self.startTapGap) { [weak self] in
                    self?.performStartTaps(remaining: remaining - 1, generation: sessionGeneration)
                })
                return
            }
            self.startSequenceBegan = false
            self.phase = .active(sessionGeneration)
            if !self.preRoll.isEmpty {
                self.enqueuePreRollAudio(self.preRoll)
                self.preRoll.removeAll(keepingCapacity: false)
            }
            if self.remoteEnded {
                self.beginDrain(generation: sessionGeneration)
            }
        }
    }

    private func beginDrain(generation sessionGeneration: UInt64) {
        guard generation == sessionGeneration else { return }
        switch phase {
        case .active(sessionGeneration):
            phase = .draining(sessionGeneration)
        case .draining(sessionGeneration), .stopping(sessionGeneration):
            return
        default:
            return
        }
        drainOperationID = sessionGeneration
        drainStartedAtUptime = uptime()
        logger(
            "VOICE FN TAP drain operation_id=\(sessionGeneration) " +
                "phase=requested result=pending timeout_ms=\(Int(drainTimeout * 1_000))"
        )
        // Safety net for a drain answer that never arrives at all: the audio side's own
        // fallback holds its output weakly, so a released output reports nothing and this
        // session would sit in `.draining` refusing every later voice press. Armed before
        // `drainAudio` so a synchronous answer cancels it through `resetSessionState`, and
        // funnelled through the generation-guarded `beginStopTap` so a late fire cannot
        // touch a healthy later session.
        scheduledTasks.append(schedule(drainTimeout) { [weak self] in
            self?.resolveDrain(generation: sessionGeneration, result: "timed_out")
        })
        drainAudio(sessionGeneration) { [weak self] in
            self?.resolveDrain(generation: sessionGeneration, result: "answered")
        }
    }

    private func resolveDrain(generation sessionGeneration: UInt64, result: String) {
        guard phase == .draining(sessionGeneration), generation == sessionGeneration else {
            logger(
                "VOICE FN TAP drain operation_id=\(sessionGeneration) " +
                    "phase=ignored result=stale trigger=\(result)"
            )
            return
        }
        logger(
            "VOICE FN TAP drain operation_id=\(sessionGeneration) " +
                "phase=resolved result=\(result) elapsed_ms=\(drainElapsedMilliseconds())"
        )
        beginStopTap(generation: sessionGeneration)
    }

    private func beginStopTap(generation sessionGeneration: UInt64) {
        guard phase == .draining(sessionGeneration), generation == sessionGeneration else { return }
        phase = .stopping(sessionGeneration)
        performFunctionKeyTap(generation: sessionGeneration) { [weak self] success in
            guard let self,
                  self.phase == .stopping(sessionGeneration),
                  self.generation == sessionGeneration
            else { return }
            guard success else {
                self.fail(.stopTapFailed)
                return
            }
            self.logDrainTerminalIfNeeded(result: "session_closed", reason: "stop_tap_completed")
            self.finishSession()
        }
    }

    private func performFunctionKeyTap(
        generation sessionGeneration: UInt64,
        completion: @escaping (Bool) -> Void
    ) {
        guard generation == sessionGeneration else { completion(false); return }
        guard setFunctionKeyPressed(true) else {
            completion(false)
            return
        }
        functionKeyIsPressed = true
        let result = TapResult(completion)
        let task = schedule(tapDuration) { [weak self] in
            guard let self, self.generation == sessionGeneration else {
                result.finish(false)
                return
            }
            result.finish(self.releaseFunctionKeyIfNeeded())
        }
        scheduledTasks.append(ScheduledOperation.mainQueueCancellation {
            task.cancel()
            result.finish(false)
        })
    }

    private func terminateCurrentSession(
        remoteHasEnded: Bool,
        suppressUntilRemoteStop: Bool,
        completion: ((Bool) -> Void)?
    ) {
        if let completion {
            idleCompletions.append(completion)
        }
        pendingVoice = nil
        suppressAudioUntilRemoteStop = suppressUntilRemoteStop
        switch phase {
        case .idle:
            releaseFunctionKeyIfNeeded()
            runIdleCompletions()
        case .starting:
            if functionKeyIsPressed || startSequenceBegan {
                // Keep the start taps' scheduled work, then drain and stop normally.
                remoteEnded = true
                preRoll.removeAll()
            } else {
                generation &+= 1
                resetSessionState()
                runIdleCompletions()
            }
        case let .active(sessionGeneration):
            remoteEnded = remoteHasEnded
            beginDrain(generation: sessionGeneration)
        case .draining, .stopping:
            remoteEnded = remoteHasEnded
        }
    }

    private func finishSession() {
        resetSessionState()
        runIdleCompletions()
        guard isEnabled, !isSuspended, let pendingVoice else {
            self.pendingVoice = nil
            return
        }
        self.pendingVoice = nil
        beginSession(preloaded: pendingVoice)
    }

    private func fail(_ failure: VoiceFnTapFailure) {
        isEnabled = false
        pendingVoice = nil
        generation &+= 1
        cancelScheduledTasks()
        releaseFunctionKeyIfNeeded()
        logDrainTerminalIfNeeded(result: "failed", reason: failure.rawValue)
        resetSessionState()
        runIdleCompletions()
        onFailure(failure)
    }

    private func resetSessionState() {
        phase = .idle
        startSequenceBegan = false
        preRoll.removeAll(keepingCapacity: false)
        remoteEnded = false
        drainOperationID = nil
        drainStartedAtUptime = nil
        cancelScheduledTasks()
        releaseFunctionKeyIfNeeded()
    }

    private func cancelScheduledTasks() {
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }

    @discardableResult
    private func releaseFunctionKeyIfNeeded() -> Bool {
        guard functionKeyIsPressed else { return false }
        let success = setFunctionKeyPressed(false)
        functionKeyIsPressed = !success
        if success {
            keyReleaseRetryTask?.cancel()
            keyReleaseRetryTask = nil
            nextKeyReleaseRetryDelay = 1
            failedKeyReleaseAttempts = 0
            releaseRecoveryBlocked = false
        } else if keyReleaseRetryTask == nil {
            failedKeyReleaseAttempts += 1
            if failedKeyReleaseAttempts >= maximumKeyReleaseAttempts {
                releaseRecoveryBlocked = true
                logger("VOICE FN TAP cleanup blocked reason=key_release_failed attempts=\(failedKeyReleaseAttempts)")
                onFailure(.stopTapFailed)
                finishCleanupCompletions(success: false)
                return false
            }
            // Keep the safety gate until a real key-up succeeds, but retry without
            // requiring a new voice event after Accessibility permission recovers.
            let delay = nextKeyReleaseRetryDelay
            nextKeyReleaseRetryDelay = min(delay * 2, 30)
            keyReleaseRetryTask = schedule(delay) { [weak self] in
                guard let self else { return }
                self.keyReleaseRetryTask = nil
                _ = self.releaseFunctionKeyIfNeeded()
                self.runIdleCompletions()
            }
        }
        return success
    }

    private func logDrainTerminalIfNeeded(result: String, reason: String) {
        guard let drainOperationID, drainStartedAtUptime != nil else { return }
        logger(
            "VOICE FN TAP drain operation_id=\(drainOperationID) " +
                "phase=completed result=\(result) reason=\(reason) " +
                "elapsed_ms=\(drainElapsedMilliseconds())"
        )
    }

    private func drainElapsedMilliseconds() -> Int {
        guard let drainStartedAtUptime else { return 0 }
        return max(0, Int((uptime() - drainStartedAtUptime) * 1_000))
    }

    private func appendPreRoll(_ samples: [Int16], toPendingVoice: Bool) {
        if toPendingVoice {
            pendingVoice?.samples.append(contentsOf: samples)
            if let count = pendingVoice?.samples.count, count > maximumPreRollSampleCount {
                pendingVoice?.samples.removeFirst(count - maximumPreRollSampleCount)
            }
            return
        }
        preRoll.append(contentsOf: samples)
        if preRoll.count > maximumPreRollSampleCount {
            preRoll.removeFirst(preRoll.count - maximumPreRollSampleCount)
        }
    }

    private func runIdleCompletions() {
        if releaseRecoveryBlocked { finishCleanupCompletions(success: false); return }
        guard phase == .idle, !functionKeyIsPressed else { return }
        finishCleanupCompletions(success: true)
        if phase == .idle, !functionKeyIsPressed { onIdle() }
    }

    private func finishCleanupCompletions(success: Bool) {
        let completions = idleCompletions
        idleCompletions.removeAll()
        completions.forEach { $0(success) }
    }
}

private final class TapResult {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func finish(_ success: Bool) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(success)
    }
}
