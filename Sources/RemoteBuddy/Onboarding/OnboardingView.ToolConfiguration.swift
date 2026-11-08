import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    func refreshVoiceToolAvailability() {
        if let voiceToolAvailabilityOverride {
            voiceToolAvailability = voiceToolAvailabilityOverride
            refreshSelectedVoiceToolRuntimeState()
            return
        }
        voiceToolAvailability = Self.detectVoiceToolAvailability()
        refreshSelectedVoiceToolRuntimeState()
    }

    static func detectVoiceToolAvailability()
        -> [OnboardingVoiceTool: OnboardingVoiceToolAvailability] {
        var availability: [OnboardingVoiceTool: OnboardingVoiceToolAvailability] = [:]
        for tool in OnboardingVoiceToolVisibilityPolicy.tools {
            availability[tool] = OnboardingInputSourceSwitcher.availability(for: tool)
        }
        return availability
    }

    func refreshSelectedVoiceToolRuntimeState() {
        let tool = settings.onboardingVoiceTool
        let state = OnboardingInputSourceSwitcher.runtimeState(for: tool)
        if voiceToolRuntimeState[tool] != state { voiceToolRuntimeState[tool] = state }
    }

    func selectControlSource(_ source: OnboardingControlSource) {
        if source != .siriRemote {
            settings.setOnboardingAppleRemoteGeneration(nil)
        }
        settings.setOnboardingControlSource(source)
        if source.supportedGestureModes.count == 1 {
            settings.setOnboardingPreferredGesture(source.supportedGestureModes.first)
        } else {
            settings.setOnboardingPreferredGesture(nil)
        }
        observedRemoteButtons.removeAll()
        remoteInputDiagnostic = FirstUseRemoteInputDiagnostic()
        testedControlButtons.removeAll()
        secureInputActive = nil
        secureInputWaitStartedAtUptime = nil
        lastLoggedSecureInputState = nil
    }

    func selectAppleRemote(_ generation: OnboardingAppleRemoteGeneration) {
        settings.setOnboardingAppleRemoteGeneration(generation)
        selectControlSource(.siriRemote)
    }

    func handleLearnedShortcut(_ shortcut: CustomKeyboardShortcut) {
        isCapturingVoiceShortcut = false
        guard let modifier = shortcut.standaloneModifier,
              let mode = VoiceKeyMode(standaloneModifier: modifier) else {
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.unsupported"
            return
        }
        let gesture = settings.onboardingPreferredGesture ??
            VoiceToolAdapterProfile.profile(for: settings.onboardingVoiceTool).recommendedMode ??
            .hold
        guard let plan = settings.stageLearnedOnboardingBinding(
            shortcut: mode,
            gesture: gesture
        ) else {
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.incompatible"
            return
        }
        shortcutCaptureErrorKey = nil
        model.setVoiceKeyMode(plan.binding.shortcut)
        model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)
    }

    func handleShortcutCaptureFailure(_ failure: ShortcutCaptureStartFailure) {
        isCapturingVoiceShortcut = false
        switch failure {
        case .accessibilityPermissionRequired:
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.permission_required"
        case .eventTapUnavailable:
            shortcutCaptureErrorKey = "onboarding.shortcut_learning.unavailable"
        }
    }

    private func selectRemoteAvailability(_ availability: OnboardingRemoteAvailability) {
        guard settings.onboardingRemoteAvailability != availability else { return }
        settings.setOnboardingRemoteAvailability(availability)
        switch availability {
        case .hasRemote:
            selectControlMethod(.physicalRemote)
        case .noRemote:
            selectControlMethod(.unselected)
        case .unselected:
            break
        }
    }

    private func selectControlMethod(_ method: OnboardingControlMethod) {
        guard settings.onboardingControlMethod != method else { return }
        settings.setOnboardingControlMethod(method)
        observedRemoteButtons.removeAll()
        remoteInputDiagnostic = FirstUseRemoteInputDiagnostic()
        testedControlButtons.removeAll()
        secureInputActive = nil
        secureInputWaitStartedAtUptime = nil
        lastLoggedSecureInputState = nil
    }

    func refreshSelectedInputMethodStatus() {
        guard settings.onboardingStep == .voiceTool else { return }
        let tool = settings.onboardingVoiceTool
        guard tool.requiresFunctionKeySetup else {
            inputSourceSwitchResult = .notApplicable
            return
        }
        if interactionProbe != nil, !allowsInputSourceSwitching {
            inputSourceSwitchResult = .notSelected
            return
        }
        inputSourceSwitchResult = OnboardingInputSourceSwitcher.selectionState(for: tool)
        AppLogger.shared.write(
            "ONBOARDING INPUT SOURCE tool=\(tool.rawValue) observed=\(inputSourceSwitchResult.rawValue)"
        )
    }

    func activateSelectedInputMethod() {
        guard settings.onboardingStep == .voiceTool else { return }
        let tool = settings.onboardingVoiceTool
        guard tool.requiresFunctionKeySetup else { return }
        guard allowsInputSourceSwitching else {
            inputSourceSwitchResult = .selected
            return
        }

        inputSourceSwitchResult = OnboardingInputSourceSwitcher.selectIfNeeded(tool)
        AppLogger.shared.write(
            "ONBOARDING INPUT SOURCE tool=\(tool.rawValue) action=explicit_user result=\(inputSourceSwitchResult.rawValue)"
        )
    }

    func inputSourceSwitchStatusText(for tool: OnboardingVoiceTool) -> String {
        let toolName = localization.text(tool.titleKey)
        let key: String
        switch inputSourceSwitchResult {
        case .selected:
            key = "onboarding.voice_tool.switch.selected"
        case .notSelected:
            key = "onboarding.voice_tool.switch.not_selected"
        case .unavailable:
            key = "onboarding.voice_tool.switch.unavailable"
        case .failed:
            key = "onboarding.voice_tool.switch.failed"
        case .notApplicable:
            key = "onboarding.voice_tool.switch.waiting"
        }
        return LocalizedMessage(key, arguments: [toolName]).text(using: localization)
    }

    func refreshSystemFunctionKeyUsage() {
        guard systemFunctionKeyAvailableOverride == nil else { return }
        let usage = OnboardingSystemFunctionKeyUsage.current
        if systemFunctionKeyUsage != usage { systemFunctionKeyUsage = usage }
    }
}
