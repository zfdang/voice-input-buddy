import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    @ViewBuilder
    var remoteContent: some View {
        switch settings.onboardingControlMethod {
        case .physicalRemote:
            physicalRemoteContent
        case .unselected:
            remoteAvailabilityContent
        }
    }

    private func learnSelectedHIDIdentity() {
        if let bridge = model.selectedBluetoothBridge { model.learnSelectedRemoteHIDIdentity(bridge) }
    }

    private var physicalRemoteContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.remote.title")
            Text(verbatim: localization.text("onboarding.remote.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let profiles = model.onboardingRemoteProfiles
            if !profiles.isEmpty {
                Picker(localization.text("onboarding.remote.choose_device"), selection: Binding(
                    get: { profiles.contains(where: { $0.id == settings.selectedRemoteProfileID }) ? settings.selectedRemoteProfileID : nil },
                    set: { if let id = $0 { model.selectRemoteProfile(id) } }
                )) {
                    Text(localization.text("onboarding.remote.choose_device")).tag(Optional<UUID>.none)
                    ForEach(profiles) { profile in
                        Text(model.systemDeviceName(for: profile) ?? localization.text(profile.model.localizationKey))
                            .tag(Optional(profile.id))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(localization.text(physicalRemotePairingKeys.title))
                    .font(.system(size: 14, weight: .semibold))

                Label {
                    Text(localization.text(physicalRemotePairingKeys.firstStep))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                Label {
                    Text(localization.text(physicalRemotePairingKeys.secondStep))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }

                if let thirdStep = physicalRemotePairingKeys.thirdStep {
                    Label {
                        Text(localization.text(thirdStep))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "3.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            }

            statusCard(
                icon: selectedControlConnected
                    ? "checkmark.circle.fill"
                    : "dot.radiowaves.left.and.right",
                title: !selectedControlConnected && !observedRemoteButtons.isEmpty
                    ? localization.text("onboarding.remote.hid_connected")
                    : selectedControlConnected
                        ? localization.text("onboarding.remote.connected")
                        : localization.text("onboarding.remote.searching"),
                detail: localization.text(
                    selectedControlConnected
                        ? "onboarding.remote.connected_detail"
                        : !observedRemoteButtons.isEmpty
                            ? "onboarding.remote.hid_connected_detail"
                            : "onboarding.remote.searching_detail"
                ),
                isComplete: selectedControlConnected,
                compact: true
            )

            statusCard(
                icon: remoteInputDiagnostic.shouldShowVoiceButtonCorrection
                    ? "exclamationmark.triangle.fill"
                    : observedRemoteButtons.isEmpty
                        ? "button.programmable"
                        : "checkmark.circle.fill",
                title: localization.text(
                    remoteInputDiagnostic.shouldShowVoiceButtonCorrection
                        ? "onboarding.remote.voice_button_mistake.title"
                        : observedRemoteButtons.isEmpty
                            ? "onboarding.remote.button_waiting"
                            : "onboarding.remote.button_received"
                ),
                detail: physicalRemoteButtonStatusDetail,
                isComplete: !observedRemoteButtons.isEmpty,
                pendingColor: remoteInputDiagnostic.shouldShowVoiceButtonCorrection ? .orange : nil,
                compact: true
            )

            if let profile = settings.selectedRemoteProfile,
               selectedControlConnected,
               BridgeAppModel.canLearnHIDIdentity(model: profile.model, source: settings.onboardingControlSource) {
                Button(localization.text("remote.hid_binding.open")) { hidBindingProfile = profile }
                    .buttonStyle(.bordered)
                    .onAppear { learnSelectedHIDIdentity() }
                    .onChange(of: settings.selectedRemoteProfileID) { _, _ in learnSelectedHIDIdentity() }
            }

            if shouldShowSecureInputWarning {
                secureInputWarningCard
            }

            if !selectedControlConnected {
                openBluetoothSettingsButton
            }
        }
        .onAppear { model.selectOnboardingRemoteIfNeeded() }
        .onChange(of: model.onboardingRemoteProfiles.map(\.id)) { _, _ in
            model.selectOnboardingRemoteIfNeeded()
        }
    }

    private var physicalRemoteButtonStatusDetail: String {
        if usesG9N9NButtonTestWorkaround {
            return localization.text(observedRemoteButtons.isEmpty
                ? "onboarding.remote.g9n9n.button_waiting_detail"
                : "onboarding.remote.g9n9n.button_detail")
        }
        let instructionKey = remoteInputDiagnostic.shouldShowVoiceButtonCorrection
            ? "onboarding.remote.voice_button_mistake.detail"
            : observedRemoteButtons.isEmpty
                ? "onboarding.remote.button_waiting_detail"
                : "onboarding.remote.button_detail"
        return localization.text(instructionKey)
    }

    var shouldShowSecureInputWarning: Bool {
        OnboardingSecureInputPolicy.shouldShowWarning(
            step: settings.onboardingStep,
            source: settings.onboardingControlSource,
            remoteConnected: selectedControlConnected,
            remoteButtonObserved: settings.onboardingStep == .controls
                ? !testedControlButtons.isEmpty
                : !observedRemoteButtons.isEmpty,
            secureInputActive: secureInputActive,
            waitStartedAtUptime: secureInputWaitStartedAtUptime,
            nowUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    var secureInputWarningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 32, height: 32)
                    .background(Color.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: localization.text("onboarding.secure_input.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: localization.text("onboarding.secure_input.detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                onboardingActionButton(id: "secure-input.recheck") {
                    recheckSecureInput()
                } label: {
                    Text(verbatim: localization.text("onboarding.secure_input.recheck"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                Text(verbatim: localization.text("onboarding.secure_input.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private func controllerButtonStatusCard(waitingDetailKey: String) -> some View {
        statusCard(
            icon: observedRemoteButtons.isEmpty
                ? "button.programmable"
                : "checkmark.circle.fill",
            title: localization.text(
                observedRemoteButtons.isEmpty
                    ? "onboarding.remote.button_waiting"
                    : "onboarding.remote.button_received"
            ),
            detail: localization.text(
                observedRemoteButtons.isEmpty
                    ? waitingDetailKey
                    : "onboarding.remote.button_detail"
            ),
            isComplete: !observedRemoteButtons.isEmpty
        )
    }

    private var openBluetoothSettingsButton: some View {
        onboardingActionButton(id: "bluetooth.settings.open") {
            openBluetoothSettings()
        } label: {
            Text(verbatim: localization.text("onboarding.remote.open_bluetooth"))
        }
            .buttonStyle(.bordered)
    }
}
