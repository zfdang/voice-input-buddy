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
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: currentVersion,
            bluetoothGranted: bluetoothPermissionState == .granted,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            runtimeLogAvailable: FileManager.default.fileExists(atPath: AppLogger.shared.logURL.path)
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
