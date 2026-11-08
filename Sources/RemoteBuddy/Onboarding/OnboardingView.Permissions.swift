import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingTitle("onboarding.permissions.title")
            Text(verbatim: localization.text("onboarding.permissions.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                if settings.onboardingControlMethod.requiresBluetoothPermission || settings.onboardingStep == .permissions {
                    permissionRow(
                        id: "permission.bluetooth",
                        icon: "antenna.radiowaves.left.and.right",
                        titleKey: "permission.bluetooth.title",
                        detailKey: "onboarding.permissions.bluetooth.detail",
                        granted: bluetoothAuthorization == .allowedAlways,
                        action: requestBluetoothPermission
                    )
                }
                if settings.onboardingControlMethod.requiresInputMonitoringPermission || settings.onboardingStep == .permissions {
                    permissionRow(
                        id: "permission.input-monitoring",
                        icon: "keyboard",
                        titleKey: "permission.input_monitoring.title",
                        detailKey: "onboarding.permissions.input.detail",
                        granted: inputMonitoringGranted,
                        action: requestInputMonitoringPermission
                    )
                }
                permissionRow(
                    id: "permission.accessibility",
                    icon: "hand.point.up.left",
                    titleKey: "permission.accessibility.title",
                    detailKey: "onboarding.permissions.accessibility.detail",
                    granted: accessibilityGranted,
                    action: requestAccessibilityPermission
                )
            }

        }
    }

    private var shortcutLearningCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localization.text("onboarding.shortcut_learning.title"))
                .font(.system(size: 14, weight: .semibold))
            Text(verbatim: localization.text("onboarding.shortcut_learning.detail"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if VoiceToolAdapterProfile.profile(
                for: settings.onboardingVoiceTool
            ).supportedModes.count > 1 {
                gestureModeChoice
            }

            if let binding = settings.stagedVoiceToolBinding,
               binding.source == .userLearned {
                Label(
                    LocalizedMessage(
                        "onboarding.shortcut_learning.captured",
                        arguments: [localization.text(binding.shortcut.localizationKey)]
                    ).text(using: localization),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
            } else {
                onboardingActionButton(id: "shortcut.start") {
                    shortcutCaptureErrorKey = nil
                    isCapturingVoiceShortcut = true
                } label: {
                    Text(verbatim: localization.text(
                        isCapturingVoiceShortcut
                            ? "onboarding.shortcut_learning.waiting"
                            : "onboarding.shortcut_learning.start"
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!accessibilityGranted || !inputMonitoringGranted)
            }

            if let shortcutCaptureErrorKey {
                Text(localization.text(shortcutCaptureErrorKey))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }

            if isCapturingVoiceShortcut {
                ShortcutCaptureView(
                    onCapture: handleLearnedShortcut,
                    onFailure: handleShortcutCaptureFailure
                )
                .frame(width: 1, height: 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }

    func refreshPermissionStates() {
        let bluetooth = permissionOverrides?.bluetooth ?? CBManager.authorization
        let input = permissionOverrides?.inputMonitoring ?? HIDRemoteMonitor.isInputMonitoringGranted
        let accessibility = permissionOverrides?.accessibility ?? KeyboardInjector.isAccessibilityTrusted
        if bluetoothAuthorization != bluetooth { bluetoothAuthorization = bluetooth }
        if inputMonitoringGranted != input { inputMonitoringGranted = input }
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
    }

    func refreshSecureInputState() {
        guard OnboardingSecureInputPolicy.shouldMonitor(
            step: settings.onboardingStep,
            source: settings.onboardingControlSource
        ) else {
            if secureInputActive != nil { secureInputActive = nil }
            if secureInputWaitStartedAtUptime != nil { secureInputWaitStartedAtUptime = nil }
            if lastLoggedSecureInputState != nil { lastLoggedSecureInputState = nil }
            return
        }

        let active = SecureInputMonitor.isEnabled()
        if secureInputActive != active { secureInputActive = active }
        if lastLoggedSecureInputState != active {
            AppLogger.shared.write(
                "ONBOARDING SECURE_INPUT phase=state_changed active=\(active)"
            )
            lastLoggedSecureInputState = active
        }

        let currentStepHasObservedButton = settings.onboardingStep == .controls
            ? !testedControlButtons.isEmpty
            : !observedRemoteButtons.isEmpty
        if selectedControlConnected && !currentStepHasObservedButton {
            if secureInputWaitStartedAtUptime == nil {
                secureInputWaitStartedAtUptime = ProcessInfo.processInfo.systemUptime
            }
        } else if secureInputWaitStartedAtUptime != nil {
            secureInputWaitStartedAtUptime = nil
        }
    }

    func recheckSecureInput() {
        AppLogger.shared.write("ONBOARDING SECURE_INPUT phase=recovery_requested")
        secureInputWaitStartedAtUptime = ProcessInfo.processInfo.systemUptime
        switch settings.onboardingControlSource {
        case .xiaomiRemote, .siriRemote:
            model.applyHIDSettings()
        case .chromecastRemote:
            prepareSelectedControlConnection()
        case .unselected:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            refreshSecureInputState()
            let buttonReceived = settings.onboardingStep == .controls
                ? !testedControlButtons.isEmpty
                : !observedRemoteButtons.isEmpty
            let result = buttonReceived
                ? "button_received"
                : (shouldShowSecureInputWarning ? "retry_required" : "unknown")
            AppLogger.shared.write(
                "ONBOARDING SECURE_INPUT phase=recovery_completed result=\(result)"
            )
        }
    }

    func requestBluetoothPermission() {
        guard interactionProbe == nil else { return }
        if bluetoothAuthorization == .allowedAlways {
            openBluetoothPrivacySettings()
            return
        }

        model.reconnect()
        if bluetoothAuthorization == .denied || bluetoothAuthorization == .restricted {
            openBluetoothPrivacySettings()
        }
    }

    func requestInputMonitoringPermission() {
        guard interactionProbe == nil else { return }
        model.requestInputMonitoringPermission()
    }

    func requestAccessibilityPermission() {
        guard interactionProbe == nil else { return }
        model.requestAccessibilityPermission()
    }

    private func openBluetoothPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        ) else { return }
        openOnboardingURL(url)
    }

    func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return
        }
        openOnboardingURL(url)
    }

    func openKeyboardSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        ) else { return }
        openOnboardingURL(url)
    }

    func openOnboardingURL(_ url: URL) {
        if let interactionProbe {
            interactionProbe.recordOpenedURL(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
