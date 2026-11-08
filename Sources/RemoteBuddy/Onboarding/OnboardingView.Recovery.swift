import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    func prepareForStep(_ step: OnboardingStep) {
        refreshPermissionStates()
        switch step {
        case .voiceTool:
            // The current flow always uses the documented Fn-based path. Keep
            // legacy learn-current state readable, but do not expose or resume
            // that obsolete capture UI in a normal onboarding run.
            if settings.onboardingVoiceBindingPreference != .documentedDefault {
                settings.setOnboardingVoiceBindingPreference(.documentedDefault)
            }
            refreshVoiceToolAvailability()
            refreshSelectedInputMethodStatus()
            refreshSystemFunctionKeyUsage()
        case .remoteAvailability:
            if settings.onboardingControlSource == .siriRemote,
               settings.onboardingAppleRemoteGeneration == nil {
                let generation: OnboardingAppleRemoteGeneration =
                    settings.selectedRemoteProfile?.model == .appleSiriRemoteA2540
                    ? .generation6
                    : .generation7
                settings.setOnboardingAppleRemoteGeneration(generation)
            }
            routeConnectedPhysicalRemoteIfNeeded()
        case .remote:
            observedRemoteButtons.removeAll()
            remoteInputDiagnostic = remoteInputDiagnosticOverride ?? FirstUseRemoteInputDiagnostic()
            requestedRemoteConnectionRecovery = false
            secureInputWaitStartedAtUptime = nil
            prepareSelectedControlConnection()
        case .permissions, .audio:
            model.refreshAudioDevices()
        case .voiceTest:
            refreshSelectedVoiceToolRuntimeState()
            ensureSelectedVoiceToolRunning()
            resetVoiceTestForRetry()
        case .controls:
            testedControlButtons.removeAll()
            secureInputWaitStartedAtUptime = nil
        case .complete:
            if secureInputActive != nil { secureInputActive = nil }
            if secureInputWaitStartedAtUptime != nil { secureInputWaitStartedAtUptime = nil }
            if lastLoggedSecureInputState != nil { lastLoggedSecureInputState = nil }
            prepareSelectedControlConnection()
            model.refreshAudioDevices()
        }
        settings.recordFirstUseEvent(.entered, step: step)
        lastRecordedFailure = nil
        DispatchQueue.main.async {
            recordFailureTransition(failureReason)
        }
    }

    func recordFailureTransition(_ failure: FirstUseFailureReason?) {
        guard settings.onboardingStep != .voiceTest else { return }
        if let failure {
            guard failure != lastRecordedFailure else { return }
            if let previousFailure = lastRecordedFailure {
                settings.recordFirstUseEvent(
                    .recovered,
                    step: settings.onboardingStep,
                    failureReason: previousFailure
                )
            }
            settings.recordFirstUseEvent(.blocked, step: settings.onboardingStep, failureReason: failure)
        } else if let previousFailure = lastRecordedFailure {
            settings.recordFirstUseEvent(
                .recovered,
                step: settings.onboardingStep,
                failureReason: previousFailure
            )
            settings.recordFirstUseEvent(.passed, step: settings.onboardingStep)
        }
        lastRecordedFailure = failure
    }

    func performRecovery(for failure: FirstUseFailureReason) {
        settings.recordFirstUseEvent(
            .retry,
            step: settings.onboardingStep,
            failureReason: failure
        )
        switch failure {
        case .bluetoothPermissionDenied:
            requestBluetoothPermission()
        case .inputMonitoringPermissionDenied:
            requestInputMonitoringPermission()
        case .accessibilityPermissionDenied:
            requestAccessibilityPermission()
        case .remoteNotFound:
            restartSelectedControlConnection()
        case .remoteButtonNotReady, .controlsNotConfirmed:
            if settings.onboardingControlMethod == .physicalRemote {
                model.applyHIDSettings()
            } else {
                prepareSelectedControlConnection()
            }
        case .audioNoOutputDevice, .audioSelectedDeviceMissing:
            model.refreshAudioDevices()
        case .audioOutputNotReady:
            model.applyAudioSettings(reason: "onboarding_recovery")
        case .voiceSessionNotStarted,
             .voiceSessionNotEnded,
             .voiceManualInput,
             .voiceNoTranscript,
             .voiceInputTargetNotReady,
             .voiceInputTargetFocusLost,
             .voiceExternalToolNoCommit:
            resetVoiceTestForRetry()
        case .voiceNoSamples, .voiceAudioDeliveryFailed:
            model.applyAudioSettings(reason: "onboarding_voice_retry")
            resetVoiceTestForRetry()
        case .completeRuntimeRegressed:
            guard let recoveryStep = OnboardingFlowPolicy.recoveryStep(
                from: .complete,
                voiceTool: settings.onboardingVoiceTool,
                remoteAvailability: settings.onboardingRemoteAvailability,
                controlMethod: settings.onboardingControlMethod,
                capabilities: capabilities,
                hasSelectedAudioUID: !settings.selectedAudioDeviceUID.isEmpty
            ) else { return }
            settings.setOnboardingStep(recoveryStep)
        }
    }

    private func restartSelectedControlConnection() {
        switch settings.onboardingControlSource {
        case .siriRemote:
            prepareSelectedControlConnection()
        case .xiaomiRemote, .chromecastRemote, .unselected:
            prepareSelectedControlConnection()
        }
    }

    private func resetVoiceTestForRetry() {
        cancelVoiceTestTasks()
        voiceTranscriptDeadlineToken = UUID()
        voiceAttemptStartedAtUptime = nil
        voiceTranscriptWaitStartedAtUptime = nil
        activeFocusLossStartedAtUptime = nil
        voiceSessionStarted = false
        voiceSamplesReceived = false
        voiceSessionEnded = false
        lastVoiceTranscriptCandidate = ""
        manualTranscriptInputObserved = false
        transcript = ""
        voiceAttempt = FirstUseVoiceAttemptDiagnostic(
            attemptID: voiceAttempt.attemptID,
            phase: .idle,
            triggerPath: "none",
            triggerReady: false,
            editorMounted: transcriptEditorMounted,
            windowKeyAtStart: false,
            firstResponderAtStart: false,
            firstResponderAtEnd: false,
            focusLost: false,
            firstSampleLatencyMilliseconds: nil,
            sessionDurationMilliseconds: nil,
            transcriptWaitMilliseconds: nil,
            result: .none
        )
        lastRecordedFailure = nil
        requestTranscriptFocus()
    }
}
