import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var externalToolExpectedVoiceKeyDiagnosticValue: String {
        guard let plan = proposedPairingPlan else { return "unresolved" }
        return "\(plan.binding.shortcut.rawValue)_\(plan.binding.gestureMode.rawValue)"
    }

    var voiceGestureInstruction: String {
        guard let plan = proposedPairingPlan else {
            return localization.text("onboarding.voice_test.waiting_voice")
        }
        return OnboardingVoiceGesturePrompt.text(
            for: plan.binding.gestureMode,
            fnTapModeEnabled: plan.fnTapModeEnabled,
            controlSource: settings.onboardingControlSource,
            locale: localization.locale
        )
    }

    func fnTapExplanationText(fallbackKey: String) -> String {
        if settings.onboardingControlSource == .t1Remote {
            return localization.text(
                settings.onboardingVoiceTool == .macosDictation
                    ? "onboarding.voice_tool.t1_dictation_fn_tap_explanation"
                    : "onboarding.voice_test.t1_fn_tap_explanation"
            )
        }
        return localization.text(
            settings.onboardingVoiceTool == .macosDictation
                ? "onboarding.voice_tool.dictation_fn_tap_explanation"
                : fallbackKey
        )
    }

    var externalToolGlobalVoiceConfirmationRequired: Bool {
        OnboardingVoiceTestConfigurationPolicy.requiresGlobalVoiceConfirmation(
            for: settings.onboardingVoiceTool
        )
    }

    var selectedVoiceToolRuntimeReady: Bool {
        let tool = settings.onboardingVoiceTool
        let runtimeState = voiceToolRuntimeState[tool] ?? .unknown
        return !OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: tool) ||
            runtimeState == .running
    }

    var selectedVoiceToolRuntimeStatusText: String? {
        switch voiceToolRuntimeState[settings.onboardingVoiceTool] ?? .unknown {
        case .running, .notApplicable:
            return nil
        case .notRunning:
            return LocalizedMessage(
                "onboarding.voice_tool.runtime.not_running",
                arguments: [localization.text(settings.onboardingVoiceTool.titleKey)]
            ).text(using: localization)
        case .unknown:
            guard OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(
                for: settings.onboardingVoiceTool
            ) else { return nil }
            return LocalizedMessage(
                "onboarding.voice_tool.runtime.unknown",
                arguments: [localization.text(settings.onboardingVoiceTool.titleKey)]
            ).text(using: localization)
        }
    }

    func openSelectedVoiceTool() {
        let tool = settings.onboardingVoiceTool
        if let interactionProbe {
            interactionProbe.recordVoiceToolLaunch(tool)
            refreshSelectedVoiceToolRuntimeState()
            return
        }
        _ = OnboardingInputSourceSwitcher.launchApplication(for: tool, activates: true) { success in
            DispatchQueue.main.async {
                AppLogger.shared.write(
                    "ONBOARDING VOICE_TOOL open tool=\(tool.rawValue) success=\(success)"
                )
                refreshSelectedVoiceToolRuntimeState()
            }
        }
    }

    func ensureSelectedVoiceToolRunning() {
        let tool = settings.onboardingVoiceTool
        guard OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: tool),
              voiceToolRuntimeState[tool] != .running else { return }
        if let interactionProbe {
            interactionProbe.recordVoiceToolLaunch(tool)
            return
        }
        _ = OnboardingInputSourceSwitcher.launchApplication(for: tool, activates: false) { success in
            DispatchQueue.main.async {
                AppLogger.shared.write(
                    "ONBOARDING VOICE_TOOL auto_launch tool=\(tool.rawValue) success=\(success)"
                )
                refreshSelectedVoiceToolRuntimeState()
            }
        }
    }

    var voiceTestStatusText: String {
        if !selectedVoiceToolRuntimeReady {
            return localization.text("onboarding.voice_test.tool_not_running")
        }
        if manualTranscriptInputObserved {
            return localization.text("onboarding.voice_test.manual_input")
        }
        if voiceAttempt.result == .audioDeliveryFailed {
            return localization.text("onboarding.recovery.voice.audio_delivery_failed.title")
        }
        if voiceAttempt.result == .passed {
            return localization.text("onboarding.voice_test.success")
        }
        if voiceSamplesReceived {
            return localization.text("onboarding.voice_test.waiting_text")
        }
        if voiceSessionStarted {
            return localization.text("onboarding.voice_test.receiving")
        }
        return localization.text("onboarding.voice_test.waiting_voice")
    }

    func bundledRemoteImage(resourceName: String) -> NSImage? {
        guard let url = RemoteBuddyResourceBundle.mainOrDevelopment.url(
            forResource: resourceName,
            withExtension: "png"
        ) else {
            return nil
        }
        return OnboardingImageCache.image(at: url)
    }

    func voiceToolIcon(_ tool: OnboardingVoiceTool) -> String {
        switch tool {
        case .weixin: return "message.fill"
        case .doubao: return "quote.bubble.fill"
        case .voiceBuddy: return "waveform.circle.fill"
        case .bageshuo: return "waveform.and.mic"
        case .typeless: return "waveform.badge.mic"
        case .macosDictation: return "mic.fill"
        case .other: return "ellipsis.circle.fill"
        case .unselected: return "circle"
        }
    }

    func controlSourceIcon(_ source: OnboardingControlSource) -> String {
        switch source {
        case .xiaomiRemote: return "appletvremote.gen4.fill"
        case .t1Remote: return "keyboard"
        case .siriRemote: return "appletvremote.gen4.fill"
        case .chromecastRemote: return "tv.and.hifispeaker.fill"
        case .unselected: return "circle"
        }
    }

    var systemFunctionKeyAvailable: Bool {
        systemFunctionKeyAvailableOverride ?? (systemFunctionKeyUsage == .available)
    }
}
