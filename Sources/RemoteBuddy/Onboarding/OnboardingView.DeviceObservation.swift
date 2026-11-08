import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    func copyDiagnosticSummary() {
        guard interactionProbe == nil else { return }
        var diagnosticVoiceAttempt = voiceAttempt
        diagnosticVoiceAttempt.audioDelivery = model.voiceAudioDeliveryDiagnosticSnapshot()
        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: FirstUseDiagnosticSnapshot.architecture,
            voiceTool: settings.onboardingVoiceTool,
            voiceKeyMode: settings.voiceKeyMode,
            voiceFnTapModeEnabled: settings.voiceFnTapModeEnabled,
            context: diagnosticContext,
            voiceAttempt: diagnosticVoiceAttempt,
            bluetoothStatus: model.connectionStatus.key,
            buttonStatus: model.hidStatus.key,
            audioStatus: model.audioStatus.key,
            events: settings.firstUseEvents,
            appLanguage: localization.locale.identifier,
            controlSource: settings.onboardingControlSource,
            voiceBinding: settings.stagedVoiceToolBinding ?? settings.verifiedVoiceToolBinding
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.redactedText, forType: .string)
        AppLogger.shared.write(
            "ONBOARDING DIAGNOSTICS copied step=\(settings.onboardingStep.rawValue) " +
                "failure=\(failureReason?.rawValue ?? "none")"
        )
        AppLogger.shared.writeDiagnosticSummary(
            snapshot.redactedText,
            event: "ONBOARDING DIAGNOSTICS"
        )
    }

    func recoverRemoteConnectionIfNeeded() {
        guard settings.onboardingControlMethod == .physicalRemote else { return }
        guard OnboardingFlowPolicy.shouldRequestRemoteReconnect(
            remoteConnected: model.isConnected,
            remoteButtonObserved: !observedRemoteButtons.isEmpty,
            recoveryRequested: requestedRemoteConnectionRecovery
        ) else { return }
        requestedRemoteConnectionRecovery = true
        model.reconnect()
    }

    func recordRemoteVoiceButtonPress() {
        remoteInputDiagnostic.recordVoiceButtonPress()
        AppLogger.shared.write(
            "ONBOARDING REMOTE_INPUT observed=voice " +
                "source=\(model.activeVoiceSource?.rawValue ?? "unknown") " +
                "voice_count=\(remoteInputDiagnostic.voiceButtonPressCount) " +
                "control_count=\(remoteInputDiagnostic.controlButtonObservationCount) " +
                "last_input=\(remoteInputDiagnostic.lastInputKind.rawValue)"
        )
    }

    func recordRemoteControlButtons(_ buttons: Set<RemoteButton>, source: String) {
        let newlyObserved = buttons.subtracting(observedRemoteButtons)
        guard !newlyObserved.isEmpty else { return }
        observedRemoteButtons.formUnion(newlyObserved)
        for _ in newlyObserved {
            remoteInputDiagnostic.recordControlButtonObservation()
        }
        AppLogger.shared.write(
            "ONBOARDING REMOTE_INPUT observed=control source=\(source) " +
                "new_count=\(newlyObserved.count) " +
                "voice_count=\(remoteInputDiagnostic.voiceButtonPressCount) " +
                "control_count=\(remoteInputDiagnostic.controlButtonObservationCount) " +
                "last_input=\(remoteInputDiagnostic.lastInputKind.rawValue)"
        )
    }

    func prepareSelectedControlConnection() {
        switch settings.onboardingControlSource {
        case .xiaomiRemote:
            model.refreshRemoteDiscovery()
            model.applyHIDSettings()
        case .siriRemote:
            model.applyHIDSettings()
        case .chromecastRemote:
            model.refreshRemoteDiscovery()
            model.applyHIDSettings()
        case .unselected:
            break
        }
    }

    func routeConnectedPhysicalRemoteIfNeeded() {
        let suppressForUserBack = suppressConnectedPhysicalRemoteAutoRouteOnce
        suppressConnectedPhysicalRemoteAutoRouteOnce = false
        guard !suppressForUserBack,
              settings.onboardingStep == .remoteAvailability,
              settings.onboardingDevice == nil,
              settings.onboardingControlSource == .unselected,
              model.isOnboardingControlSourceConnected(.xiaomiRemote) else { return }
        // Keep the control-device page visible so the user can see and confirm the
        // selected hardware; an existing connection only preselects the card.
        selectControlSource(.xiaomiRemote)
        AppLogger.shared.write(
            "ONBOARDING CONTROL_SOURCE preselected=xiaomi_remote reason=connected_physical_remote"
        )
    }

    func selectedControlAccepts(_ source: RemoteInputSource) -> Bool {
        switch settings.onboardingControlMethod {
        case .physicalRemote, .unselected:
            return false
        }
    }

    func selectedControlAcceptsVoice(_ source: RemoteInputSource?) -> Bool {
        switch settings.onboardingControlSource {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return source == .bluetoothRemote &&
                (model.activePhysicalVoiceControlSource.map { $0 == settings.onboardingControlSource }
                    ?? selectedPhysicalRemoteProfileMatchesSource)
        case .unselected:
            return false
        }
    }

    var selectedPhysicalRemoteProfileMatchesSource: Bool {
        guard let model = settings.selectedRemoteProfile?.model else { return false }
        switch settings.onboardingControlSource {
        case .xiaomiRemote:
            return !model.usesPrivateAdapter && !model.isChromecastRemote
        case .siriRemote:
            guard model.isAppleSiriRemote else { return false }
            guard let generation = settings.onboardingAppleRemoteGeneration else { return true }
            return model == generation.model
        case .chromecastRemote:
            return model.isChromecastRemote
        case .unselected:
            return false
        }
    }
}
