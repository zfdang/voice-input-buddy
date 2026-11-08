import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var inlinePermissionsSection: some View {
        let bluetoothAction = SettingsPageBehavior.permissionAction(
            for: .bluetooth,
            isGranted: bluetoothPermissionState == .granted
        )
        let inputMonitoringAction = SettingsPageBehavior.permissionAction(
            for: .inputMonitoring,
            isGranted: inputMonitoringGranted
        )
        let accessibilityAction = SettingsPageBehavior.permissionAction(
            for: .accessibility,
            isGranted: accessibilityGranted
        )

        return VStack(alignment: .leading, spacing: 0) {
            Text(localization.text("settings.permissions.title"))
                .font(.title3.weight(.semibold))

            permissionRow(
                symbol: "antenna.radiowaves.left.and.right",
                title: localization.text("permission.bluetooth.title"),
                detail: localization.text("permission.bluetooth.description"),
                state: bluetoothPermissionState,
                actionTitle: localization.text("permission.bluetooth.open_settings")
            ) {
                performPermissionAction(bluetoothAction) {}
            }

            Divider().padding(.leading, 48)

            permissionRow(
                symbol: "keyboard",
                title: localization.text("permission.input_monitoring.title"),
                detail: localization.text("permission.input_monitoring.description"),
                state: inputMonitoringGranted ? .granted : .pending,
                actionTitle: localization.text(inputMonitoringAction.titleKey)
            ) {
                performPermissionAction(inputMonitoringAction) {
                    model.requestInputMonitoringPermission()
                }
            }

            Divider().padding(.leading, 48)

            permissionRow(
                symbol: "accessibility",
                title: localization.text("permission.accessibility.title"),
                detail: localization.text("permission.accessibility.description"),
                state: accessibilityGranted ? .granted : .pending,
                actionTitle: localization.text(accessibilityAction.titleKey)
            ) {
                performPermissionAction(accessibilityAction) {
                    model.requestAccessibilityPermission()
                }
            }

            if settings.isOnboardingComplete,
               !inputMonitoringGranted || !accessibilityGranted {
                Divider().padding(.leading, 48)
                Label(localization.text("permissions.upgrade_identity_help"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 9)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    var inlineDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.text("settings.diagnostics.title"))
                .font(.title3.weight(.semibold))
            Text(localization.text("diagnostics.logs.privacy"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.text("diagnostics.logs.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(localization.text("diagnostics.logs.last_entry"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button(localization.text("diagnostics.logs.show_in_finder")) { model.openLogFolder() }
                        .compatibilityButtonStyle(.standard)
                    Button(localization.text("diagnostics.logs.copy_summary")) { copySettingsDiagnosticSummary() }
                        .compatibilityButtonStyle(.standard)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    var appIconPreferenceRow: some View {
        let selectedIdentifier = appIconCatalog.resolvedIdentifier(
            for: settings.appIconIdentifier
        )

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "app.badge")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.text("about.preferences.app_icon"))
                    .font(.subheadline.weight(.semibold))
                Text(localization.text("about.preferences.app_icon_help"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                ForEach(appIconCatalog.options) { option in
                    Button {
                        settings.appIconIdentifier = option.id
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(nsImage: option.image)
                                .resizable()
                                .frame(width: 38, height: 38)
                            if selectedIdentifier == option.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .background(Circle().fill(.background))
                            }
                        }
                        .padding(7)
                        .background(
                            selectedIdentifier == option.id
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    selectedIdentifier == option.id
                                        ? Color.accentColor.opacity(0.55)
                                        : Color.secondary.opacity(0.18),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(localization.text(option.titleKey)))
                    .accessibilityAddTraits(
                        selectedIdentifier == option.id ? .isSelected : []
                    )
                }
            }
        }
        .padding(.vertical, 8)
    }
}
