import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var bluetoothPermissionState: PermissionVisualState {
        bluetoothAuthorization == .allowedAlways ? .granted : .pending
    }

    func refreshPermissionStates() {
        bluetoothAuthorization = permissionOverrides?.bluetooth ?? CBManager.authorization
        inputMonitoringGranted = permissionOverrides?.inputMonitoring ?? HIDRemoteMonitor.isInputMonitoringGranted
        accessibilityGranted = permissionOverrides?.accessibility ?? KeyboardInjector.isAccessibilityTrusted
    }

    func setCustomMappingEnabled(_ enabled: Bool) {
        refreshPermissionStates()
        settings.customMappingEnabled = enabled
        guard MappingPermissionPolicy.requiresPrompt(
            enabled: enabled,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted
        ) else {
            isWaitingForMappingPermissions = false
            model.applyHIDSettings()
            return
        }
        isMappingPermissionAlertPresented = true
    }

    func resumeCustomMappingIfPermissionsGranted() {
        guard
            isWaitingForMappingPermissions,
            inputMonitoringGranted,
            accessibilityGranted
        else { return }
        isWaitingForMappingPermissions = false
        model.applyHIDSettings()
    }
}
