import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var usesG9N9NButtonTestWorkaround: Bool {
        settings.onboardingControlSource == .chromecastRemote &&
            (settings.onboardingDevice ?? .chromecastG9N9N) == .chromecastG9N9N
    }

    var controlsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingTitle("onboarding.controls.title")
            Text(verbatim: localization.text(controlsDetailKey))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowSecureInputWarning {
                secureInputWarningCard
            }

            if let buttons = displayedControlButtons {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(buttons) { button in
                        let tested = testedControlButtons.contains(button)
                        HStack(spacing: 8) {
                            Image(systemName: tested ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(tested ? Color.green : Color.secondary)
                            Text(button.displayName(using: localization))
                                .font(.system(size: 12, weight: tested ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(
                            tested ? Color.green.opacity(0.10) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        HStack(spacing: 8) {
                            Image(systemName: testedControlButtons.count > index
                                ? "checkmark.circle.fill"
                                : "circle")
                                .foregroundStyle(testedControlButtons.count > index
                                    ? Color.green
                                    : Color.secondary)
                            Text(LocalizedMessage(
                                "onboarding.controls.mobile_slot",
                                arguments: [String(index + 1)]
                            ).text(using: localization))
                            .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: testedControlButtons.count > index ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(testedControlButtons.count > index ? Color.green : Color.secondary)
                }
                Text(verbatim: localization.text(
                    testedControlButtons.count >= 3
                        ? usesG9N9NButtonTestWorkaround
                            ? "onboarding.controls.g9n9n.ready"
                            : "onboarding.controls.ready"
                        : "onboarding.controls.waiting"
                ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    var physicalRemotePairingKeys: (
        title: String,
        firstStep: String,
        secondStep: String,
        thirdStep: String?
    ) {
        let keys = Self.physicalRemotePairingKeys(for: settings.onboardingControlSource)
        return (keys.title, keys.firstStep, keys.secondStep,
            usesG9N9NButtonTestWorkaround ? "onboarding.remote.g9n9n_pairing.third" : keys.thirdStep)
    }

    static func physicalRemotePairingKeys(
        for source: OnboardingControlSource
    ) -> (title: String, firstStep: String, secondStep: String, thirdStep: String?) {
        switch source {
        case .siriRemote:
            return (
                "onboarding.remote.siri_pairing.title",
                "onboarding.remote.siri_pairing.first",
                "onboarding.remote.siri_pairing.second",
                "onboarding.remote.siri_pairing.third"
            )
        case .chromecastRemote:
            return (
                "onboarding.remote.chromecast_pairing.title",
                "onboarding.remote.chromecast_pairing.first",
                "onboarding.remote.chromecast_pairing.second",
                "onboarding.remote.chromecast_pairing.third"
            )
        case .xiaomiRemote, .unselected:
            return (
                "onboarding.remote.first_pairing.title",
                "onboarding.remote.first_pairing.wake",
                "onboarding.remote.first_pairing.pair",
                nil
            )
        }
    }

    var controlsDetailKey: String {
        usesG9N9NButtonTestWorkaround
            ? "onboarding.controls.g9n9n.detail"
            : Self.controlsDetailKey(for: settings.onboardingControlSource)
    }

    static func controlsDetailKey(for source: OnboardingControlSource) -> String {
        switch source {
        case .xiaomiRemote:
            return "onboarding.controls.xiaomi.detail"
        case .siriRemote:
            return "onboarding.controls.siri.detail"
        case .chromecastRemote:
            return "onboarding.controls.chromecast.detail"
        case .unselected:
            return "onboarding.controls.detail"
        }
    }

    private var displayedControlButtons: [RemoteButton]? {
        Self.displayedControlButtons(for: settings.onboardingControlSource)
    }

    static func displayedControlButtons(
        for source: OnboardingControlSource
    ) -> [RemoteButton]? {
        switch source {
        case .xiaomiRemote:
            return RemoteButton.xiaomiCases
        case .siriRemote:
            return [
                .power, .up, .left, .ok, .right, .down,
                .back, .volumeUp, .volumeDown, .tv, .playPause, .mute,
            ]
        case .chromecastRemote:
            return [
                .power, .up, .left, .ok, .right, .down, .back,
                .home, .volumeUp, .volumeDown, .mute, .youtube, .netflix, .input,
            ]
        case .unselected:
            return nil
        }
    }

    private var completionTitleKey: String {
        switch settings.onboardingPurpose {
        case .initialSetup: return "onboarding.complete.title"
        case .addDevice: return "onboarding.add_device.complete.title"
        case .integration: return "onboarding.integration.complete.title"
        }
    }

    private var completionDetailKey: String {
        switch settings.onboardingPurpose {
        case .initialSetup: return "onboarding.complete.detail"
        case .addDevice: return "onboarding.add_device.complete.detail"
        case .integration: return "onboarding.integration.complete.detail"
        }
    }

    var completeContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.green)
            onboardingTitle(completionTitleKey)
            Text(verbatim: localization.text(completionDetailKey))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                if settings.onboardingPurpose != .addDevice {
                    featureLine("mic.fill", "onboarding.complete.voice")
                }
                if usesG9N9NButtonTestWorkaround {
                    featureLine("mic.fill", "onboarding.complete.g9n9n.voice_only")
                } else if settings.onboardingPurpose != .integration {
                    featureLine("button.programmable", "onboarding.complete.controls")
                }
                featureLine("gearshape", "onboarding.complete.settings")
            }
            .padding(.top, 8)

            if !canContinue {
                statusCard(
                    icon: "exclamationmark.triangle.fill",
                    title: localization.text("onboarding.complete.runtime_changed"),
                    detail: localization.text("onboarding.complete.runtime_changed_detail"),
                    isComplete: false
                )
            }
        }
    }

    func recoveryCard(for failure: FirstUseFailureReason) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text("onboarding.recovery.\(failure.rawValue).title"))
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recoveryDetailText(for: failure))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                onboardingActionButton(id: "recovery.\(failure.rawValue)") {
                    performRecovery(for: failure)
                } label: {
                    Text(localization.text("onboarding.recovery.\(failure.rawValue).action"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                onboardingActionButton(id: "diagnostics.copy") {
                    copyDiagnosticSummary()
                } label: {
                    Text(verbatim: localization.text("onboarding.diagnostics.copy"))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    func shouldShowStandaloneRecoveryCard(_ failure: FirstUseFailureReason) -> Bool {
        if settings.onboardingStep == .remote,
           settings.onboardingControlMethod == .physicalRemote,
           failure == .remoteNotFound {
            return false
        }
        return true
    }

    private func recoveryDetailKey(for failure: FirstUseFailureReason) -> String {
        if usesG9N9NButtonTestWorkaround {
            switch failure {
            case .remoteButtonNotReady: return "onboarding.remote.g9n9n.button_waiting_detail"
            case .controlsNotConfirmed: return "onboarding.controls.g9n9n.detail"
            default: break
            }
        }
        guard failure == .remoteNotFound else {
            return "onboarding.recovery.\(failure.rawValue).detail"
        }
        return Self.remoteNotFoundRecoveryDetailKey(for: settings.onboardingControlSource)
    }

    private func recoveryDetailText(for failure: FirstUseFailureReason) -> String {
        switch failure {
        case .voiceSessionNotStarted:
            return LocalizedMessage(
                "onboarding.recovery.voice.session_not_started.detail",
                arguments: [recoveryVoiceGestureInstruction]
            ).text(using: localization)
        case .voiceNoSamples:
            return LocalizedMessage(
                "onboarding.recovery.voice.no_samples.detail",
                arguments: [recoveryVoiceGestureInstruction]
            ).text(using: localization)
        case .voiceSessionNotEnded:
            return LocalizedMessage(
                "onboarding.recovery.voice.session_not_ended.detail",
                arguments: [recoveryVoiceFinishInstruction]
            ).text(using: localization)
        default:
            return localization.text(recoveryDetailKey(for: failure))
        }
    }

    private var recoveryVoiceGestureInstruction: String {
        switch effectivePreferredGesture {
        case .hold:
            return localization.text("onboarding.recovery.voice.gesture.hold")
        case .toggle:
            return localization.text("onboarding.recovery.voice.gesture.toggle")
        }
    }

    private var recoveryVoiceFinishInstruction: String {
        switch effectivePreferredGesture {
        case .hold:
            return localization.text("onboarding.recovery.voice.finish.hold")
        case .toggle:
            return localization.text("onboarding.recovery.voice.finish.toggle")
        }
    }

    static func remoteNotFoundRecoveryDetailKey(for source: OnboardingControlSource) -> String {
        switch source {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return "onboarding.recovery.remote.not_found.physical_detail"
        case .unselected:
            return "onboarding.recovery.remote.not_found.detail"
        }
    }
}
