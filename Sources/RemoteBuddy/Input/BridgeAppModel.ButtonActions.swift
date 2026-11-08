import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func performExternalConfiguredAction(_ configured: ConfiguredButtonAction) -> Bool {
        guard !audio.suspensionState.isSuspended else { return false }
        let applicationProfile = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )
        if configured.action == .openCustomApplication {
            guard let profile = applicationProfile,
                !settings.portableApplicationRequiresVerification(profile),
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier) != nil
            else { return false }
        }
        let sendAction: (UInt64?) -> Bool = { [weak self] requestID in
            guard let self else { return false }
            let handled = KeyboardInjector.send(
                configured.action,
                shortcut: configured.shortcut,
                applicationProfile: applicationProfile,
                focusInputCompletion: { [weak self] succeeded in
                    if let requestID {
                        self?.voiceInputDestinationCoordinator.completeFocusOperation(
                            requestID: requestID, succeeded: succeeded)
                    }
                }
            )
            if !handled, let requestID {
                self.voiceInputDestinationCoordinator.cancel(requestID: requestID, reason: .actionFailed)
            }
            return handled
        }
        if settings.voiceFnTapModeEnabled,
           let intent = VoiceInputDestinationIntent.resolve(configured: configured, applicationProfile: applicationProfile) {
            voiceInputDestinationCoordinator.beginTargetSwitch(intent: intent) { requestID in
                _ = sendAction(requestID)
            }
            return true
        }
        return sendAction(nil)
    }

    func handleVoiceInputDestinationState(_ state: VoiceInputDestinationState) {
        guard settings.voiceFnTapModeEnabled else { return }
        switch state {
        case .waiting:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting_for_input")
        case .ready:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_ready")
        case .cancelled:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_unavailable")
        }
    }

    static func commonPhraseHIDSource(_ profileID: UUID?) -> String {
        "hid:\(profileID?.uuidString ?? "unassigned")"
    }

    func cancelPendingCommonPhraseButtonActions() {
        hidMonitors.values.forEach { $0.cancelPendingButtonActions() }
        discoveryHIDMonitor?.cancelPendingButtonActions()

    }

    @discardableResult
    func performInternalAction(_ action: ButtonAction, source: String = "host_action") -> Bool {
        guard !audio.suspensionState.isSuspended else { return false }
        if action == .openCommonPhrases {
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                commonPhrases.open(source: source, localization: LocalizationStore(settings: settings))
            }
        }
        guard action == .toggleLongRecording else { return false }
        guard action.isEnabled(
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ) else {
            AppLogger.shared.write("LONG RECORDING ignored feature_enabled=false")
            return false
        }
        return toggleLongRecording()
    }
}
