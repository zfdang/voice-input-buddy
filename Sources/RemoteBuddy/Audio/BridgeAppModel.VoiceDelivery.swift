import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    /// Includes pending activation and draining tails, before their async callbacks
    /// publish isStreaming. Transport-specific identity checks remain at each entry.
    func canAcceptNewVoiceSession(from owner: VoiceKeyLatch.Owner) -> Bool {
        guard !isTerminating, !audio.suspensionState.isSuspended,
              voiceKeyReleaseRetry == nil else { return false }
        if let pending = pendingVoiceKeyActivationOwner, pending != owner { return false }
        if owner != .bluetooth,
           voiceSession.isActive || hasPendingBluetoothVoiceWork || voiceSession.pendingStart.identifier != nil ||
            voiceFnTapSession.requiresCleanupBeforeMapping { return false }
        return true
    }

    func resetCurrentVoiceSampleReceipt() {
        guard hasReceivedCurrentVoiceSamples else { return }
        hasReceivedCurrentVoiceSamples = false
    }

    func publishCurrentVoiceSampleReceiptIfNeeded(sampleCount: Int) {
        guard VoiceSamplePresentationPolicy.shouldPublishReceipt(
            hasReceivedSamples: hasReceivedCurrentVoiceSamples,
            sampleCount: sampleCount
        ) else { return }
        hasReceivedCurrentVoiceSamples = true
    }

    func voiceAudioDeliveryDiagnosticSnapshot() -> VoiceAudioDeliveryDiagnostic {
        var diagnostic = voiceSession.voiceAudioDeliveryDiagnostic
        diagnostic.observeOutput(audio.output.diagnosticSnapshot(
            deliveryGeneration: diagnostic.generation
        ))
        return diagnostic
    }

    func preserveCompletedVoiceAudioDelivery() {
        let diagnostic = voiceAudioDeliveryDiagnosticSnapshot()
        guard diagnostic.result == .deliveredToSelectedDevice else { return }
        voiceSession.voiceAudioDeliveryDiagnostic = diagnostic
    }

    func recordVoiceAudioReceipt(
        samples: [Int16],
        route: VoiceAudioDeliveryRoute
    ) {
        guard !samples.isEmpty, voiceSession.voiceAudioDeliveryDiagnostic.generation > 0 else { return }
        voiceSession.voiceAudioDeliveryDiagnostic.route = route
        voiceSession.voiceAudioDeliveryDiagnostic.receivedBatches += 1
        voiceSession.voiceAudioDeliveryDiagnostic.receivedSamples += samples.count
        voiceSession.voiceAudioDeliveryDiagnostic.outputAtObservation = audio.output.diagnosticSnapshot(
            deliveryGeneration: voiceSession.voiceAudioDeliveryDiagnostic.generation
        )
    }

    func recordVoiceAudioEnqueueOutcome(
        accepted: Bool,
        deliveryGeneration: Int
    ) {
        guard !accepted,
              deliveryGeneration > 0,
              voiceSession.voiceAudioDeliveryDiagnostic.generation == deliveryGeneration
        else { return }
        voiceSession.voiceAudioDeliveryDiagnostic.enqueueFailures += 1
        voiceSession.voiceAudioDeliveryDiagnostic.outputAtObservation = audio.output.diagnosticSnapshot(
            deliveryGeneration: deliveryGeneration
        )
    }

    func enqueueVoiceFnTapAudio(_ samples: [Int16], isPreRoll: Bool = false) {
        let deliveryGeneration = voiceSession.voiceAudioDeliveryDiagnostic.generation
        let accepted = audio.output.enqueue(
            samples: samples,
            deliveryGeneration: deliveryGeneration,
            isPreRoll: isPreRoll
        )
        recordVoiceAudioEnqueueOutcome(
            accepted: accepted,
            deliveryGeneration: deliveryGeneration
        )
        if !accepted {
            voiceSession.bluetoothVoiceEnqueueFailureCount += 1
        }
    }

    func beginVoiceSessionIfNeeded() {
        guard !isTerminating, !isStreaming else { return }

        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.blocked_voice_active"),
            logReason: "voice_start"
        )
        let source = currentVoiceSource
        let sessionID = UUID()
        voiceSession.voiceAudioDeliveryGeneration &+= 1
        let audioSnapshot = audio.output.diagnosticSnapshot(
            deliveryGeneration: voiceSession.voiceAudioDeliveryGeneration
        )
        voiceSession.voiceAudioDeliveryDiagnostic = VoiceAudioDeliveryDiagnostic(
            generation: voiceSession.voiceAudioDeliveryGeneration,
            source: source.rawValue,
            outputAtStart: audioSnapshot,
            outputAtObservation: audioSnapshot,
            countersAtStart: audioSnapshot.counters
        )
        activeVoiceSource = source
        voiceSession.voiceSessionID = sessionID
        isStreaming = true
    }

    func endVoiceSessionIfNeeded(flushAudio: Bool = true, applyPendingMappings: (() -> Void)? = nil) {
        defer { flushPendingVoiceToolMappingRefresh(applyMappings: applyPendingMappings) }
        guard !voiceSession.isActive,
              isStreaming
        else { return }
        voiceSession.voiceSessionID = nil
        voiceSession.voiceAudioDeliveryDiagnostic.sessionEnded = true
        voiceSession.voiceAudioDeliveryDiagnostic.outputAtObservation = audio.output.diagnosticSnapshot(
            deliveryGeneration: voiceSession.voiceAudioDeliveryDiagnostic.generation
        )
        isStreaming = false
        activeVoiceSource = nil
        if flushAudio {
            audio.output.endSession()
        }

    }

    private var currentVoiceSource: RemoteInputSource { voiceSession.isActive ? .bluetoothRemote : .unknown }

    @discardableResult
    func applyVoiceFunctionMapping(neutralizeVoiceKey: Bool) -> Bool {
        voiceFunctionMapper.additionalIdentities = Set(settings.compatibleHIDIdentities(
            includeXiaomi: true, includeGoogle: false))
        let applied = voiceFunctionMapper.apply(
            suppressPowerKey: settings.customMappingEnabled,
            neutralizeVoiceKey: neutralizeVoiceKey
        )
        if !isStreaming {
            isVoiceTriggerEnabled = applied
            voiceShortcutStatus = LocalizedMessage(
                applied
                    ? "voice_button.status.\(settings.voiceKeyMode.rawValue)_enabled"
                    : "voice_button.status.waiting"
            )
        }
        return !settings.customMappingEnabled || voiceFunctionMapper.isPowerKeySuppressed
    }

    @discardableResult
    // Main-queue state transitions; source activation completes without a nested run loop.
    func updateVoiceKeyState(
        streaming: Bool,
        forceSoftware: Bool,
        owner: VoiceKeyLatch.Owner,
        keySetter: @escaping (VoiceKeyMode, Bool) -> Bool = { KeyboardInjector.setVoiceKeyPressed($0, isPressed: $1) },
        completion: @escaping (Bool) -> Void = { _ in }
    ) -> Bool {
        guard !streaming || (!audio.suspensionState.isSuspended && voiceKeyReleaseRetry == nil) else {
            completion(false)
            return false
        }
        let mode = streaming
            ? settings.voiceKeyMode
            : (heldVoiceKeyMode ?? pendingVoiceKeyMode ?? settings.voiceKeyMode)
        guard forceSoftware || !mode.usesHardwareMapping else { completion(true); return true }
        if VoiceKeyPendingDownPolicy.shouldRejectStart(
            streaming: streaming,
            pendingDown: pendingVoiceKeyMode != nil || voiceKeyActivationInProgress
        ) {
            AppLogger.shared.write(
                "VOICE KEY start_rejected reason=pending_down owner=\(owner)"
            )
            completion(false)
            return false
        }
        guard let transition = voiceKeyLatch.transition(
            streaming: streaming,
            owner: owner
        ) else {
            completion(true)
            return true
        }
        let shouldHold = transition == .press
        if shouldHold {
            pendingVoiceKeyMode = mode
            voiceKeyActivationInProgress = true
            voiceKeyActivationGeneration &+= 1
            let generation = voiceKeyActivationGeneration
            pendingVoiceKeyActivationOwner = owner
            pendingVoiceKeyActivationCompletion = completion
            if owner == .bluetooth { voiceSession.commandAudio.begin() }
            var immediateResult: Bool?
            preferredInputSourceMonitor.beginVoiceSession { [weak self] activated in
                guard let self else { completion(false); return }
                guard self.voiceKeyActivationGeneration == generation,
                      self.pendingVoiceKeyActivationOwner == owner else { immediateResult = false; return }
                self.voiceKeyActivationInProgress = false
                self.pendingVoiceKeyActivationOwner = nil
                let finish = self.pendingVoiceKeyActivationCompletion
                self.pendingVoiceKeyActivationCompletion = nil
                defer { self.flushPendingVoiceToolMappingRefresh() }
                guard activated, !self.isTerminating, !self.audio.suspensionState.isSuspended, self.pendingVoiceKeyMode == mode else {
                    self.pendingVoiceKeyMode = nil
                    if owner == .bluetooth { self.voiceSession.commandAudio.cancel() }
                    self.voiceKeyLatch.rollback(transition, owner: owner)
                    immediateResult = false
                    finish?(false)
                    return
                }
                let submitted = self.submitVoiceKeyState(mode: mode, shouldHold: true,
                    transition: transition, owner: owner, keySetter: keySetter)
                immediateResult = submitted
                finish?(submitted)
            }
            // An asynchronous start is accepted; the caller continues only at completion.
            return immediateResult ?? true
        }
        defer { flushPendingVoiceToolMappingRefresh() }
        if !shouldHold,
           heldVoiceKeyMode == nil, pendingVoiceKeyMode != nil {
            pendingVoiceKeyMode = nil
            if owner == .bluetooth {
                voiceSession.commandAudio.cancel()
            }
            cancelPendingVoiceKeyActivation()
            isVoiceTriggerEnabled = true
            AppLogger.shared.write(
                "VOICE KEY mode=\(mode.rawValue) pending_down_cancelled"
            )
            completion(true)
            return true
        }
        let submitted = submitVoiceKeyState(mode: mode, shouldHold: shouldHold,
            transition: transition, owner: owner, keySetter: keySetter)
        completion(submitted)
        return submitted
    }

    private func cancelPendingVoiceKeyActivation() {
        voiceKeyActivationGeneration &+= 1
        voiceKeyActivationInProgress = false
        pendingVoiceKeyActivationOwner = nil
        let completion = pendingVoiceKeyActivationCompletion
        pendingVoiceKeyActivationCompletion = nil
        preferredInputSourceMonitor.endVoiceSession()
        completion?(false)
    }

    private func submitVoiceKeyState(
        mode: VoiceKeyMode, shouldHold: Bool,
        transition: VoiceKeyTransition, owner: VoiceKeyLatch.Owner,
        keySetter: (VoiceKeyMode, Bool) -> Bool
    ) -> Bool {
        guard keySetter(mode, shouldHold) else {
            if shouldHold {
                pendingVoiceKeyMode = nil
                if owner == .bluetooth {
                    voiceSession.commandAudio.cancel()
                }
                preferredInputSourceMonitor.endVoiceSession()
            }
            voiceKeyLatch.rollback(transition, owner: owner)
            AppLogger.shared.write(
                "VOICE KEY \(mode.rawValue) \(shouldHold ? "DOWN" : "UP") failed"
            )
            return false
        }
        if shouldHold {
            preferredInputSourceMonitor.markVoiceTriggerSubmitted()
        } else {
            preferredInputSourceMonitor.endVoiceSession()
        }
        if shouldHold {
            voiceKeyReleaseRetry?.cancel()
            voiceKeyReleaseRetry = nil
            voiceKeyReleaseRetryGeneration &+= 1
            pendingVoiceKeyMode = nil
            heldVoiceKeyMode = mode
        } else {
            heldVoiceKeyMode = nil
        }
        isVoiceTriggerEnabled = !shouldHold
        voiceShortcutStatus = LocalizedMessage(
            shouldHold
                ? "voice_button.status.\(mode.rawValue)_pressed"
                : "voice_button.status.\(mode.rawValue)_released"
        )
        AppLogger.shared.write(
            "VOICE KEY mode=\(mode.rawValue) edge=\(shouldHold ? "down" : "up") " +
                "result=event_submitted target_response=unknown"
        )
        return true
    }

    @discardableResult
    func releaseVoiceKeyIfNeeded(
        owner: VoiceKeyLatch.Owner,
        forceSoftware: Bool
    ) -> Bool {
        guard !updateVoiceKeyState(
            streaming: false,
            forceSoftware: forceSoftware,
            owner: owner
        ) else { return true }
        return releaseVoiceKeyIfNeeded()
    }

    @discardableResult
    func releaseVoiceKeyIfNeeded(
        releaseKey: @escaping (VoiceKeyMode) -> Bool = {
            KeyboardInjector.setVoiceKeyPressed($0, isPressed: false)
        }
    ) -> Bool {
        defer { flushPendingVoiceToolMappingRefresh() }
        voiceKeyReleaseRetry?.cancel()
        voiceKeyReleaseRetry = nil
        voiceKeyReleaseRetryGeneration &+= 1
        let generation = voiceKeyReleaseRetryGeneration
        guard voiceKeyLatch.isHeld else {
            heldVoiceKeyMode = nil
            pendingVoiceKeyMode = nil
            voiceSession.commandAudio.cancel()
            if pendingVoiceKeyActivationCompletion != nil { cancelPendingVoiceKeyActivation() }
            return true
        }
        guard let heldVoiceKeyMode else {
            guard pendingVoiceKeyMode != nil else { return false }
            voiceKeyLatch.reset()
            pendingVoiceKeyMode = nil
            voiceSession.commandAudio.cancel()
            cancelPendingVoiceKeyActivation()
            isVoiceTriggerEnabled = true
            AppLogger.shared.write("VOICE KEY pending_down_cancelled reason=forced_release")
            return true
        }

        // A denied post must not erase the held-key safety state. Retry after permission recovery.
        guard releaseKey(heldVoiceKeyMode) else {
            AppLogger.shared.write("VOICE KEY cleanup deferred reason=release_failed mode=\(heldVoiceKeyMode.rawValue)")
            voiceKeyReleaseRetry = scheduleVoiceKeyReleaseRetry(1) { [weak self] in
                guard let self, self.voiceKeyReleaseRetryGeneration == generation,
                      self.heldVoiceKeyMode == heldVoiceKeyMode else { return }
                _ = self.releaseVoiceKeyIfNeeded(releaseKey: releaseKey)
            }
            return false
        }

        voiceKeyLatch.reset()
        self.heldVoiceKeyMode = nil
        preferredInputSourceMonitor.endVoiceSession()
        isVoiceTriggerEnabled = true
        voiceShortcutStatus = LocalizedMessage(
            "voice_button.status.\(heldVoiceKeyMode.rawValue)_released"
        )
        AppLogger.shared.write(
            "VOICE KEY mode=\(heldVoiceKeyMode.rawValue) edge=up " +
                "result=event_submitted target_response=unknown"
        )
        return true
    }

    /// 苹果遥控器自报能力的日志标记（真机核对用）。
}
