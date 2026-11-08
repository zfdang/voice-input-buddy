import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    func cancelVoiceTestTasks() {
        voiceTestTasks.forEach { $0.cancel() }
        voiceTestTasks.removeAll()
    }

    func requestTranscriptFocus() {
        guard settings.onboardingStep == .voiceTest else { return }
        transcriptFocusRequest &+= 1
    }

    func updateTranscriptFocus(_ snapshot: OnboardingTranscriptFocusSnapshot) {
        let changed = transcriptEditorMounted != snapshot.editorMounted ||
            transcriptWindowKey != snapshot.windowKey ||
            transcriptFirstResponder != snapshot.firstResponder
        transcriptEditorMounted = snapshot.editorMounted
        transcriptWindowKey = snapshot.windowKey
        transcriptFirstResponder = snapshot.firstResponder
        if voiceAttempt.phase == .recording || voiceAttempt.phase == .awaitingTranscript {
            let now = ProcessInfo.processInfo.systemUptime
            let targetReady = snapshot.editorMounted && snapshot.windowKey && snapshot.firstResponder
            if !targetReady {
                voiceAttempt.focusLost = true
                voiceAttempt.focusEditorUnmounted = voiceAttempt.focusEditorUnmounted || !snapshot.editorMounted
                voiceAttempt.focusWindowNotKey = voiceAttempt.focusWindowNotKey || !snapshot.windowKey
                voiceAttempt.focusFirstResponderChanged =
                    voiceAttempt.focusFirstResponderChanged || !snapshot.firstResponder
                if activeFocusLossStartedAtUptime == nil {
                    activeFocusLossStartedAtUptime = now
                    voiceAttempt.focusLossCount += 1
                    if voiceAttempt.firstFocusLossLatencyMilliseconds == nil,
                       let voiceAttemptStartedAtUptime {
                        voiceAttempt.firstFocusLossLatencyMilliseconds = max(
                            0,
                            Int((now - voiceAttemptStartedAtUptime) * 1_000)
                        )
                    }
                }
            } else if let lossStartedAt = activeFocusLossStartedAtUptime {
                voiceAttempt.totalFocusLossMilliseconds += max(
                    0,
                    Int((now - lossStartedAt) * 1_000)
                )
                activeFocusLossStartedAtUptime = nil
                voiceAttempt.focusRecovered = true
            }
            voiceAttempt.editorMounted = snapshot.editorMounted
        }
        if changed {
            AppLogger.shared.write(
                "ONBOARDING TRANSCRIPT_TARGET attempt=\(voiceAttempt.attemptID) " +
                    "phase=\(voiceAttempt.phase.rawValue) mounted=\(snapshot.editorMounted) " +
                    "window_key=\(snapshot.windowKey) first_responder=\(snapshot.firstResponder) " +
                    "ready=\(snapshot.editorMounted && snapshot.windowKey && snapshot.firstResponder) " +
                    "loss_count=\(voiceAttempt.focusLossCount)"
            )
        }
    }

    func beginVoiceAttempt(triggerPath: String) {
        cancelVoiceTestTasks()
        voiceTranscriptDeadlineToken = UUID()
        voiceAttemptStartedAtUptime = ProcessInfo.processInfo.systemUptime
        voiceTranscriptWaitStartedAtUptime = nil
        activeFocusLossStartedAtUptime = nil
        voiceSessionStarted = true
        voiceSamplesReceived = false
        voiceSessionEnded = false
        lastVoiceTranscriptCandidate = ""
        manualTranscriptInputObserved = false
        transcript = ""

        let targetReady = transcriptEditorMounted && transcriptWindowKey && transcriptFirstResponder
        voiceAttempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: voiceAttempt.attemptID + 1,
            phase: .recording,
            triggerPath: triggerPath,
            triggerReady: targetReady,
            editorMounted: transcriptEditorMounted,
            windowKeyAtStart: transcriptWindowKey,
            firstResponderAtStart: transcriptFirstResponder,
            firstResponderAtEnd: false,
            focusLost: false,
            firstSampleLatencyMilliseconds: nil,
            sessionDurationMilliseconds: nil,
            transcriptWaitMilliseconds: nil,
            externalToolVoiceKeyUserConfirmed: false,
            externalToolExpectedVoiceKey: externalToolExpectedVoiceKeyDiagnosticValue,
            externalToolGlobalVoiceApplicable: externalToolGlobalVoiceConfirmationRequired,
            externalToolGlobalVoiceUserConfirmed: false,
            externalToolMicrophoneUserConfirmed: false,
            audioDelivery: model.voiceAudioDeliveryDiagnosticSnapshot(),
            result: .none
        )
        lastRecordedFailure = nil
        if !targetReady {
            requestTranscriptFocus()
        }
        AppLogger.shared.write(
            "ONBOARDING VOICE_ATTEMPT started attempt=\(voiceAttempt.attemptID) " +
                "trigger_path=\(triggerPath) trigger_ready=\(targetReady) " +
                "editor_mounted=\(transcriptEditorMounted) window_key=\(transcriptWindowKey) " +
                "first_responder=\(transcriptFirstResponder) " +
                "external_microphone_observable=false " +
                "external_microphone_user_confirmed=false " +
                "audio_generation=\(voiceAttempt.audioDelivery.generation) " +
                "audio_selected=\(voiceAttempt.audioDelivery.outputAtStart.selectedDeviceKind.rawValue) " +
                "audio_actual=\(voiceAttempt.audioDelivery.outputAtStart.actualDeviceKind.rawValue) " +
                "audio_bound=\(voiceAttempt.audioDelivery.outputAtStart.boundToSelectedDevice.map(String.init) ?? "unknown")"
        )
    }

    func endVoiceAttempt() {
        guard voiceAttempt.phase == .recording else { return }
        voiceSessionEnded = true
        voiceAttempt.phase = .awaitingTranscript
        let attemptID = voiceAttempt.attemptID
        let transcriptCandidate = lastVoiceTranscriptCandidate
        transcriptCommitRequest &+= 1
        scheduleTranscriptRecovery(
            attemptID: attemptID,
            candidate: transcriptCandidate
        )
        let targetReadyAtEnd = transcriptEditorMounted && transcriptWindowKey && transcriptFirstResponder
        voiceAttempt.firstResponderAtEnd = targetReadyAtEnd
        voiceAttempt.focusReadyAtEnd = targetReadyAtEnd
        voiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        if let voiceAttemptStartedAtUptime {
            voiceAttempt.sessionDurationMilliseconds = elapsedMilliseconds(
                sinceUptime: voiceAttemptStartedAtUptime
            )
        }
        voiceTranscriptWaitStartedAtUptime = ProcessInfo.processInfo.systemUptime

        let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
            manualInputObserved: manualTranscriptInputObserved,
            samplesReceived: voiceSamplesReceived,
            transcriptionAppeared: transcriptionAppeared,
            triggerReady: voiceAttempt.triggerReady,
            focusReadyAtDeadline: targetReadyAtEnd,
            audioDeliveryResult: voiceAttempt.audioDelivery.result,
            finalObservation: false
        )
        if result == .manualInput || result == .noSamples || result == .audioDeliveryFailed {
            finishVoiceAttempt(result: result)
        } else {
            // Text may already exist when the key is released. Recheck playback
            // after the tail drains even if no further text-change event arrives.
            scheduleVoiceCompletionEvaluation(attemptID: attemptID)
            scheduleVoiceTranscriptDeadline(attemptID: attemptID)
        }
    }

    private func scheduleTranscriptRecovery(attemptID: Int, candidate: String) {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for delay in [0.05, 0.2, 0.5] {
            voiceTestTasks.append(ScheduledOperation.mainQueue(after: delay) {
                guard settings.onboardingStep == .voiceTest,
                      voiceAttempt.attemptID == attemptID,
                      voiceSessionEnded,
                      !manualTranscriptInputObserved,
                      transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                transcript = candidate
                AppLogger.shared.write(
                    "ONBOARDING TRANSCRIPT restored_after_voice_release=true source=voice_candidate"
                )
            })
        }
    }

    func scheduleVoiceCompletionEvaluation(attemptID: Int) {
        for delay in [0.05, 0.2, 0.5] {
            voiceTestTasks.append(ScheduledOperation.mainQueue(after: delay) {
                guard settings.onboardingStep == .voiceTest,
                      voiceAttempt.attemptID == attemptID,
                      voiceAttempt.phase == .awaitingTranscript,
                      voiceSessionEnded,
                      !manualTranscriptInputObserved,
                      transcriptionAppeared else {
                    return
                }
                refreshVoiceAttemptObservableState(atDeadline: false)
                if voiceAttempt.audioDelivery.result == .deliveredToSelectedDevice {
                    finishVoiceAttempt(result: .passed)
                }
            })
        }
    }

    private func scheduleVoiceTranscriptDeadline(attemptID: Int) {
        let token = UUID()
        voiceTranscriptDeadlineToken = token
        voiceTestTasks.append(ScheduledOperation.mainQueue(after: 3) {
            guard settings.onboardingStep == .voiceTest,
                  voiceTranscriptDeadlineToken == token,
                  voiceAttempt.attemptID == attemptID,
                  voiceAttempt.phase == .awaitingTranscript else { return }
            refreshVoiceAttemptObservableState(atDeadline: true)
            let result = FirstUseVoiceAttemptPolicy.terminalResultAfterSession(
                manualInputObserved: manualTranscriptInputObserved,
                samplesReceived: voiceSamplesReceived,
                transcriptionAppeared: transcriptionAppeared,
                triggerReady: voiceAttempt.triggerReady,
                focusReadyAtDeadline: voiceAttempt.focusReadyAtDeadline == true,
                audioDeliveryResult: voiceAttempt.audioDelivery.result,
                finalObservation: true
            )
            finishVoiceAttempt(result: result)
        })
    }

    func finishVoiceAttempt(result: FirstUseVoiceAttemptResult) {
        guard voiceAttempt.phase == .awaitingTranscript else { return }
        cancelVoiceTestTasks()
        voiceTranscriptDeadlineToken = UUID()
        refreshVoiceAttemptObservableState(atDeadline: false)
        if let voiceTranscriptWaitStartedAtUptime {
            voiceAttempt.transcriptWaitMilliseconds = elapsedMilliseconds(
                sinceUptime: voiceTranscriptWaitStartedAtUptime
            )
        }
        voiceAttempt.result = result
        voiceAttempt.phase = result == .passed ? .passed : .failed
        let failure = result.failureReason
        settings.recordFirstUseEvent(
            result == .passed ? .passed : .blocked,
            step: .voiceTest,
            failureReason: failure,
            voiceAttemptID: voiceAttempt.attemptID,
            voiceResult: result
        )
        lastRecordedFailure = failure
        let delivery = voiceAttempt.audioDelivery
        let totalElapsedMilliseconds = (voiceAttempt.sessionDurationMilliseconds ?? 0) +
            (voiceAttempt.transcriptWaitMilliseconds ?? 0)
        let publicEvent = PublicDiagnosticEvent(
            operationID: "onboarding_voice_\(voiceAttempt.attemptID)",
            component: "onboarding",
            action: "voice_test",
            phase: "completed",
            result: result == .passed ? "passed" : "failed",
            reason: result.rawValue,
            elapsedMS: totalElapsedMilliseconds,
            receivedSamples: delivery.receivedSamples,
            scheduledSamples: delivery.scheduledSamples,
            playedSamples: delivery.playedSamples,
            interruptedSamples: delivery.interruptedSamples,
            pendingSamples: delivery.outputAtObservation.pendingSamples,
            failureCount: delivery.enqueueFailures,
            source: "onboarding",
            audioDeviceKind: AppEnvironmentSnapshot.audioDeviceKind(
                for: settings.selectedAudioDeviceUID
            ),
            voiceTool: settings.onboardingVoiceTool.rawValue
        )
        if let publicEvent {
            AppLogger.shared.record(publicEvent)
        }
        AppLogger.shared.write(
            "ONBOARDING VOICE_ATTEMPT terminal attempt=\(voiceAttempt.attemptID) " +
                "result=\(result.rawValue) observed_failure=\(result.observedFailure) " +
                "probable_cause=\(voiceAttempt.probableCause) " +
                "probable_cause_confirmed=\(voiceAttempt.probableCauseConfirmed) " +
                "boundary=\(result.diagnosticBoundary) " +
                "audio_generation=\(voiceAttempt.audioDelivery.generation) " +
                "audio_route=\(voiceAttempt.audioDelivery.route.rawValue) " +
                "audio_result=\(voiceAttempt.audioDelivery.result.rawValue) " +
                "audio_selected=\(voiceAttempt.audioDelivery.outputAtStart.selectedDeviceKind.rawValue) " +
                "audio_actual_start=\(voiceAttempt.audioDelivery.outputAtStart.actualDeviceKind.rawValue) " +
                "audio_bound_start=\(voiceAttempt.audioDelivery.outputAtStart.boundToSelectedDevice.map(String.init) ?? "unknown") " +
                "audio_actual_observation=\(voiceAttempt.audioDelivery.outputAtObservation.actualDeviceKind.rawValue) " +
                "audio_bound_observation=\(voiceAttempt.audioDelivery.outputAtObservation.boundToSelectedDevice.map(String.init) ?? "unknown") " +
                "audio_received_samples=\(voiceAttempt.audioDelivery.receivedSamples) " +
                "audio_scheduled_samples=\(voiceAttempt.audioDelivery.scheduledSamples) " +
                "audio_played_samples=\(voiceAttempt.audioDelivery.playedSamples) " +
                "audio_interrupted_samples=\(voiceAttempt.audioDelivery.interruptedSamples) " +
                "audio_pending_samples=\(voiceAttempt.audioDelivery.outputAtObservation.pendingSamples) " +
                "audio_enqueue_failures=\(voiceAttempt.audioDelivery.enqueueFailures) " +
                "focus_loss_count=\(voiceAttempt.focusLossCount) " +
                "focus_editor_unmounted=\(voiceAttempt.focusEditorUnmounted) " +
                "focus_window_not_key=\(voiceAttempt.focusWindowNotKey) " +
                "focus_first_responder_changed=\(voiceAttempt.focusFirstResponderChanged) " +
                "focus_recovered=\(voiceAttempt.focusRecovered) " +
                "focus_ready_at_end=\(voiceAttempt.focusReadyAtEnd) " +
                "focus_ready_at_deadline=\(voiceAttempt.focusReadyAtDeadline.map(String.init) ?? "unknown") " +
                "focus_total_loss_ms=\(voiceAttempt.totalFocusLossMilliseconds) " +
                "external_voice_key_observable=false " +
                "external_voice_key_user_confirmed=\(voiceAttempt.externalToolVoiceKeyUserConfirmed) " +
                "external_expected_voice_key=\(voiceAttempt.externalToolExpectedVoiceKey) " +
                "external_global_voice_observable=false " +
                "external_global_voice_applicable=\(voiceAttempt.externalToolGlobalVoiceApplicable) " +
                "external_global_voice_user_confirmed=\(voiceAttempt.externalToolGlobalVoiceUserConfirmed) " +
                "external_microphone_observable=false " +
                "external_microphone_user_confirmed=\(voiceAttempt.externalToolMicrophoneUserConfirmed) " +
                "external_next_checks=trigger_matches_binding,global_voice_enabled_if_required," +
                "microphone_matches_selected_device " +
                "first_sample_latency_ms=\(voiceAttempt.firstSampleLatencyMilliseconds.map(String.init) ?? "unavailable") " +
                "session_duration_ms=\(voiceAttempt.sessionDurationMilliseconds.map(String.init) ?? "unavailable") " +
                "session_under_1s=\((voiceAttempt.sessionDurationMilliseconds ?? 1_000) < 1_000) " +
                "transcript_wait_ms=\(voiceAttempt.transcriptWaitMilliseconds.map(String.init) ?? "unavailable")"
        )
    }

    func refreshVoiceAttemptObservableState(atDeadline: Bool) {
        voiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        let targetReady = transcriptEditorMounted && transcriptWindowKey && transcriptFirstResponder
        if atDeadline {
            voiceAttempt.focusReadyAtDeadline = targetReady
        }
        if let lossStartedAt = activeFocusLossStartedAtUptime {
            let now = ProcessInfo.processInfo.systemUptime
            voiceAttempt.totalFocusLossMilliseconds += max(
                0,
                Int((now - lossStartedAt) * 1_000)
            )
            activeFocusLossStartedAtUptime = targetReady ? nil : now
            voiceAttempt.focusRecovered = voiceAttempt.focusRecovered || targetReady
        }
    }

    func elapsedMilliseconds(sinceUptime uptime: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - uptime) * 1_000))
    }
}
