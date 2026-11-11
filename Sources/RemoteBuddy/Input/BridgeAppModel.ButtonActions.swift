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

    /// The panel source a voice-key press may close: only a Chromecast remote's
    /// own panel, and never while long recording owns the microphone.
    static func commonPhraseVoiceKeySource(profile: RemoteDeviceProfile?, longRecordingRequested: Bool) -> String? {
        guard !longRecordingRequested, let profile, profile.model.isChromecastRemote else { return nil }
        return commonPhraseHIDSource(profile.id)
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
                commonPhrases.open(
                    source: source,
                    buttons: CommonPhraseStore.buttons(
                        chromecast: settings.selectedRemoteProfile?.model.isChromecastRemote == true),
                    localization: LocalizationStore(settings: settings))
            }
        }
        guard action == .toggleLongRecording else { return false }
        return toggleLongRecording()
    }
}
