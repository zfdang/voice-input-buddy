import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var microphoneDriverInstalled: Bool {
        model.audioDevices.contains {
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: $0.uid, name: $0.name)
        }
    }

    var capabilities: OnboardingCapabilities {
        OnboardingCapabilities(
            systemFunctionKeyAvailable: systemFunctionKeyAvailable,
            bluetoothGranted: bluetoothAuthorization == .allowedAlways,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            remoteConnected: selectedControlConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            microphoneDriverInstalled: microphoneDriverInstalled,
            audioReady: model.isAudioOutputVerified,
            audioOutputSelected: audioOutputSelected,
            voiceSessionStarted: voiceSessionStarted,
            voiceSamplesReceived: voiceSamplesReceived,
            voiceSessionEnded: voiceSessionEnded,
            transcriptionAppeared: transcriptionAppeared,
            manualTranscriptInputObserved: manualTranscriptInputObserved,
            testedRemoteButtonCount: testedControlButtons.count
        )
    }

    var canContinue: Bool {
        if settings.onboardingStep == .complete,
           let completeRuntimeReadyOverride {
            return completeRuntimeReadyOverride
        }
        let policyAllowsContinue = OnboardingFlowPolicy.canContinue(
            from: settings.onboardingStep,
            voiceTool: settings.onboardingVoiceTool,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            voiceKeyMode: settings.voiceKeyMode,
            voiceToolGuideStepsCompleted: inputMethodGuideStepsCompleted,
            selectedDevice: settings.onboardingDevice,
            capabilities: capabilities
        )
        if settings.onboardingStep == .voiceTest {
            return policyAllowsContinue &&
                voiceAttempt.result == .passed &&
                verifiedTranscriptionAppeared &&
                selectedVoiceToolRuntimeReady
        }
        return policyAllowsContinue &&
            (settings.onboardingStep != .voiceTool ||
                (voiceToolSelectionIsValid &&
                    proposedPairingPlan != nil))
    }

    private var inputMethodGuideStepsCompleted: Bool {
        let steps = inputMethodGuideSteps(for: settings.onboardingVoiceTool)
        return !steps.isEmpty && steps.allSatisfy { completedInputMethodGuideSteps.contains($0.id) }
    }

    var visibleVoiceTools: [OnboardingVoiceTool] {
        OnboardingVoiceToolVisibilityPolicy.tools
    }

    var allRecognizedVoiceToolsUnavailable: Bool {
        [OnboardingVoiceTool.weixin, .doubao, .bageshuo, .typeless].allSatisfy {
            voiceToolAvailability[$0] == .notInstalled
        }
    }

    private var voiceToolSelectionIsValid: Bool {
        switch settings.onboardingVoiceTool {
        case .unselected:
            return false
        case .voicecursor, .macosDictation, .other:
            return true
        case .weixin, .doubao, .bageshuo, .typeless:
            return voiceToolAvailability[settings.onboardingVoiceTool] == .available
        }
    }

    var effectivePreferredGesture: VoiceGestureMode {
        settings.onboardingPreferredGesture ?? proposedPairingPlan?.binding.gestureMode ?? .hold
    }

    var proposedPairingPlan: OnboardingVoicePairingPlan? {
        let selectedBinding: VoiceToolUserBinding?
        if let staged = settings.stagedVoiceToolBinding,
           staged.tool == settings.onboardingVoiceTool {
            selectedBinding = staged
        } else if let verified = settings.verifiedVoiceToolBinding,
                  verified.tool == settings.onboardingVoiceTool,
                  verified.validationState == .verified {
            // 重跑 Onboarding 时，已验证的用户 Binding 高于工具文档默认值。
            // 如果它与当前来源不兼容，resolve 会拒绝并回退到可用的推荐路径。
            selectedBinding = verified
        } else {
            selectedBinding = nil
        }
        return OnboardingVoicePairingPlan.resolve(
            tool: settings.onboardingVoiceTool,
            controlSource: settings.onboardingControlSource,
            preferredGesture: settings.onboardingPreferredGesture,
            userBinding: selectedBinding,
            forceFunctionKey: true
        )
    }

    var diagnosticContext: FirstUseDiagnosticContext {
        FirstUseDiagnosticContext(
            step: settings.onboardingStep,
            remoteAvailability: settings.onboardingRemoteAvailability,
            controlMethod: settings.onboardingControlMethod,
            capabilities: capabilities,
            hasSelectedAudioUID: !settings.selectedAudioDeviceUID.isEmpty,
            voiceAttempt: settings.onboardingStep == .voiceTest ? voiceAttempt : nil,
            remoteInput: remoteInputDiagnostic
        )
    }

    var failureReason: FirstUseFailureReason? {
        if settings.onboardingStep == .complete,
           let completeRuntimeReadyOverride,
           completeRuntimeReadyOverride {
            return nil
        }
        return diagnosticContext.failureReason
    }

    var supportedAudioDevices: [AudioDeviceInfo] {
        model.audioDevices.filter { device in
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: device.uid, name: device.name)
        }
    }

    var selectedAudioDevice: AudioDeviceInfo? {
        supportedAudioDevices.first { $0.uid == settings.selectedAudioDeviceUID }
    }

    private var selectedAudioDeviceDiagnosticKind: VirtualAudioDeviceDiagnosticKind {
        .classify(selectedAudioDevice)
    }

    var audioOutputSelected: Bool {
        OnboardingAudioSelectionPolicy.isSupportedDeviceSelected(
            selectedUID: settings.selectedAudioDeviceUID,
            availableSupportedUIDs: supportedAudioDevices.lazy.map(\.uid)
        )
    }

    var onboardingAudioReady: Bool {
        audioOutputSelected && model.isAudioOutputVerified
    }

    var transcriptionAppeared: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func captureVoiceTranscriptCandidate(_ text: String) {
        guard settings.onboardingStep == .voiceTest,
              voiceAttempt.phase == .recording || voiceAttempt.phase == .awaitingTranscript,
              !manualTranscriptInputObserved,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        lastVoiceTranscriptCandidate = text
    }

    var verifiedTranscriptionAppeared: Bool {
        transcriptionAppeared && !manualTranscriptInputObserved
    }

    var selectedControlConnected: Bool {
        if settings.onboardingControlMethod == .physicalRemote {
            return OnboardingFlowPolicy.isPhysicalRemoteRecognized(
                at: settings.onboardingStep,
                voiceConnectionReady: model.isOnboardingControlSourceConnected(
                    settings.onboardingControlSource
                ),
                validatedHIDButtonObserved: !observedRemoteButtons.isEmpty
            )
        }
        return model.isOnboardingControlSourceConnected(settings.onboardingControlSource)
    }

    var selectedControlConnectedKey: String {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            return "onboarding.side.remote_connected"
        case .unselected:
            return "onboarding.side.control_selected"
        }
    }

    var primaryActionKey: String {
        switch settings.onboardingStep {
        case .complete: return "onboarding.action.open_app"
        default: return "onboarding.action.continue"
        }
    }

    private var aiPromptCopyStatusKey: String {
        switch aiPromptCopyResult {
        case true: return "onboarding.welcome.ai_prompt.copied"
        case false: return "onboarding.welcome.ai_prompt.failed"
        case nil: return "onboarding.welcome.ai_prompt.action"
        }
    }

    private func copyAIAssistantPrompt() {
        let prompt = OnboardingAIAssistantPrompt.text(for: localization.locale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(prompt, forType: .string)
        aiPromptCopyResult = copied
        AppLogger.shared.write("ONBOARDING AI_PROMPT copied=\(copied)")
    }
}
