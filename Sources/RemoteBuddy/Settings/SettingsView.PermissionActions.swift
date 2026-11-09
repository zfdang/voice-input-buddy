import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        state: PermissionVisualState,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            HStack(spacing: 7) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 8, height: 8)
                Text(state.title(using: localization))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 132, alignment: .leading)
            Button(actionTitle, action: action)
                .compatibilityButtonStyle(.standard)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 180)
        }
        .padding(.vertical, 8)
    }

    private func openSettingsURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func performPermissionAction(
        _ action: SettingsPermissionAction,
        requestPermission: () -> Void
    ) {
        SettingsPageBehavior.perform(
            action,
            requestPermission: requestPermission,
            openSystemSettings: openSettingsURL
        )
    }

    func copySettingsDiagnosticSummary() {
        let appBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let logURL = AppLogger.shared.logURL
        let logExists = FileManager.default.fileExists(atPath: logURL.path)
        var logSizeBytes: Int64?
        if logExists,
           let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int64 {
            logSizeBytes = size
        }

        let connectedProfile = settings.remoteDeviceProfiles.first(where: { model.connectedRemoteProfileIDs.contains($0.id) }) ??
            settings.remoteDeviceProfiles.first(where: { $0.id == settings.selectedRemoteProfileID })
        let remoteModelDesc: String
        if let connectedProfile {
            let name = connectedProfile.customName.isEmpty ? localization.text(connectedProfile.displayNameFallbackKey) : connectedProfile.customName
            remoteModelDesc = "\(name) (\(connectedProfile.model.rawValue))"
        } else {
            remoteModelDesc = localization.text("common.value.none")
        }

        let virtualMicReady = BuddyMicrophoneDevicePolicy.device(in: model.audioDevices) != nil

        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: currentVersion,
            appBuild: appBuild,
            macosVersion: FirstUseDiagnosticSnapshot.systemVersion,
            architecture: FirstUseDiagnosticSnapshot.architecture,
            isRosetta: FirstUseDiagnosticSnapshot.runningUnderRosetta == "true",
            bluetoothGranted: bluetoothPermissionState == .granted,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            remoteConnected: model.isConnected,
            remoteModel: remoteModelDesc,
            virtualMicrophoneReady: virtualMicReady,
            audioOutputReady: model.isAudioOutputReady,
            voiceTool: settings.onboardingVoiceTool.rawValue,
            voiceKeyMode: settings.voiceKeyMode.rawValue,
            runtimeLogAvailable: logExists,
            runtimeLogPath: logURL.path,
            runtimeLogSizeBytes: logSizeBytes
        )
        SettingsPageBehavior.copyDiagnosticSummary(
            snapshot,
            writeToPasteboard: { summary in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(summary, forType: .string)
            },
            writeAuditLog: AppLogger.shared.write
        )
    }
}
