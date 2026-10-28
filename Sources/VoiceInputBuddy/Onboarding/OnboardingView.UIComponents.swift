import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    @ViewBuilder
    var sideStatusPanel: some View {
        switch settings.onboardingStep {
        case .permissions:
            sidePanel(titleKey: "onboarding.side.permissions") {
                if settings.onboardingControlMethod.requiresBluetoothPermission || settings.onboardingStep == .permissions {
                    sideCheck(
                        "permission.bluetooth.title",
                        isComplete: bluetoothAuthorization == .allowedAlways
                    )
                }
                if settings.onboardingControlMethod.requiresInputMonitoringPermission || settings.onboardingStep == .permissions {
                    sideCheck(
                        "permission.input_monitoring.title",
                        isComplete: inputMonitoringGranted
                    )
                }
                sideCheck("permission.accessibility.title", isComplete: accessibilityGranted)
            }
        case .remote:
            sidePanel(titleKey: "onboarding.side.remote") {
                sideCheck(
                    selectedControlConnectedKey,
                    isComplete: selectedControlConnected
                )
                sideCheck("onboarding.side.button_received", isComplete: !observedRemoteButtons.isEmpty)
            }
        case .audio:
            sidePanel(titleKey: "onboarding.side.audio") {
                sideCheck("onboarding.side.device_found", isComplete: !supportedAudioDevices.isEmpty)
                sideCheck("onboarding.side.device_selected", isComplete: audioOutputSelected)
                sideCheck("onboarding.side.audio_ready", isComplete: onboardingAudioReady)
            }
        case .voiceTest:
            sidePanel(titleKey: "onboarding.side.voice_test") {
                sideCheck("onboarding.side.voice_key", isComplete: voiceSessionStarted && voiceSessionEnded)
                sideCheck("onboarding.side.samples", isComplete: voiceSamplesReceived)
                sideCheck(
                    "onboarding.side.audio_ready",
                    isComplete: onboardingAudioReady
                )
                sideCheck("onboarding.side.transcript", isComplete: verifiedTranscriptionAppeared)
            }
        case .controls:
            sidePanel(titleKey: "onboarding.side.controls") {
                sideCheck("onboarding.side.three_buttons", isComplete: testedControlButtons.count >= 3)
                sideCheck(usesG9N9NButtonTestWorkaround
                    ? "onboarding.side.g9n9n_test_enabled" : "onboarding.side.mapping_enabled",
                    isComplete: settings.customMappingEnabled)
            }
        default:
            EmptyView()
        }
    }

    private func sidePanel<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.text(titleKey))
                .font(.system(size: 14, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    private func sideCheck(_ titleKey: String, isComplete: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isComplete ? Color.green : Color.accentColor.opacity(0.65))
            Text(localization.text(titleKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }

    func onboardingActionButton<Label: View>(
        id: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let wrappedAction = {
            action()
        }
        interactionProbe?.registerAction(id, action: wrappedAction)
        return Button(action: wrappedAction, label: label)
    }

    func onboardingLink<Label: View>(
        id: String,
        destination: URL,
        @ViewBuilder label: () -> Label
    ) -> some View {
        interactionProbe?.registerAction(id) {
            self.openOnboardingURL(destination)
        }
        return Link(destination: destination, label: label)
    }

    var rightPaneGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.10, green: 0.13, blue: 0.18),
                Color(red: 0.13, green: 0.15, blue: 0.20)
            ]
        }
        return [
            Color(red: 0.91, green: 0.96, blue: 1.0),
            Color(red: 0.97, green: 0.98, blue: 1.0)
        ]
    }

    var rightPaneHighlightColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.55)
    }

    func onboardingTitle(_ key: String) -> some View {
        Text(localization.text(key))
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focusedStepTitle, equals: settings.onboardingStep)
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    func featureLine(_ icon: String, _ titleKey: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            Text(localization.text(titleKey))
                .font(.system(size: 14, weight: .medium))
        }
    }

    func permissionRow(
        id: String,
        icon: String,
        titleKey: String,
        detailKey: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        onboardingActionButton(id: id, action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(granted ? Color.green : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background((granted ? Color.green : Color.accentColor).opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(localization.text(titleKey))
                        .font(.system(size: 14, weight: .semibold))
                    Text(localization.text(detailKey))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(granted ? Color.green : Color.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    func statusCard(
        icon: String,
        title: String,
        detail: String,
        isComplete: Bool,
        pendingColor: Color? = nil,
        compact: Bool = false
    ) -> some View {
        let statusColor = isComplete ? Color.green : (pendingColor ?? Color.accentColor)
        return HStack(spacing: compact ? 10 : 13) {
            Image(systemName: icon)
                .font(.system(size: compact ? 18 : 20, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: compact ? 32 : 36, height: compact ? 32 : 36)
                .background(statusColor.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(compact ? 10 : 14)
        .background(
            (pendingColor?.opacity(0.08) ?? Color.primary.opacity(0.035)),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}
