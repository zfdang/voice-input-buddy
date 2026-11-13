import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

struct HIDPermissionSnapshot: Equatable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    static var current: HIDPermissionSnapshot {
        HIDPermissionSnapshot(
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
    }
}

enum HIDPermissionRecoveryPolicy {
    static func shouldReapplySettings(
        started: Bool,
        customMappingEnabled: Bool,
        voiceKeyMode: VoiceKeyMode = .function,
        voiceFnTapModeEnabled: Bool = false,
        softwareVoiceKeyHeld: Bool = false,
        monitoringInterrupted: Bool = false,
        previous: HIDPermissionSnapshot?,
        current: HIDPermissionSnapshot
    ) -> Bool {
        guard started,
              (
                  customMappingEnabled ||
                      voiceKeyMode.requiresAccessibility ||
                      voiceFnTapModeEnabled ||
                      softwareVoiceKeyHeld || monitoringInterrupted
              ),
              let previous
        else { return false }
        return previous != current || (monitoringInterrupted &&
            current.inputMonitoringGranted && current.accessibilityGranted)
    }
}

enum HIDMappingRecoveryPolicy {
    static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    static func shouldPreserveFnTapPreferenceAfterMappingFailure(
        hasMatchingServices: Bool
    ) -> Bool {
        !hasMatchingServices
    }

    static func retryDelay(
        forAttempt attempt: Int,
        started: Bool,
        readyBridgeCount: Int,
        hasMatchingServices: Bool
    ) -> TimeInterval? {
        guard started,
              readyBridgeCount > 0,
              !hasMatchingServices,
              retryDelays.indices.contains(attempt)
        else { return nil }
        return retryDelays[attempt]
    }
}

enum BluetoothStatusKeys {
    static let permissionDenied = "bluetooth.status.permission_denied"
    static let off = "bluetooth.status.off"
    static let unsupported = "bluetooth.status.unsupported"
    static let unavailable = "bluetooth.status.unavailable"
}

enum HIDStatusKeys {
    static let notPermitted = "button_mapping.error.not_permitted"
    static let inputMonitoringRequired = "button_mapping.permission.input_monitoring_required"
    static let interrupted = "button_mapping.status.interrupted"
}

enum HIDFilterFailureState: Equatable {
    case none
    case tapCreateFailed
    case systemDisabled
}

enum RuntimePermissionIssue: Equatable {
    case permissionDesynced(signals: [String])
    case bluetoothPermissionDenied
    case inputMonitoringPermissionDenied
    case bluetoothUnavailable(statusKey: String)

    var isPermissionDesynced: Bool {
        if case .permissionDesynced = self { return true }
        return false
    }

    var preferredPrivacySettingsURLString: String {
        switch self {
        case let .permissionDesynced(signals):
            if signals == ["bluetooth_unauthorized"] {
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
            }
            if !signals.isEmpty, signals.allSatisfy({ $0.hasPrefix("hid_") }) {
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
            return "x-apple.systempreferences:com.apple.preference.security?Privacy"
        case .bluetoothPermissionDenied:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .inputMonitoringPermissionDenied:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .bluetoothUnavailable:
            return "x-apple.systempreferences:com.apple.BluetoothSettings"
        }
    }

    var diagnosticIdentifier: String {
        switch self {
        case let .permissionDesynced(signals):
            let joined = signals.joined(separator: ",")
            return joined.isEmpty ? "permission_desynced" : "permission_desynced(\(joined))"
        case .bluetoothPermissionDenied:
            return "bluetooth_permission_denied"
        case .inputMonitoringPermissionDenied:
            return "input_monitoring_permission_denied"
        case let .bluetoothUnavailable(statusKey):
            return "bluetooth_unavailable(\(statusKey))"
        }
    }
}

enum RuntimePermissionDiagnosisPolicy {
    static let unavailableBluetoothStatusKeys: Set<String> = [
        BluetoothStatusKeys.off,
        BluetoothStatusKeys.unsupported,
        BluetoothStatusKeys.unavailable
    ]

    static func diagnose(
        bluetoothGranted: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        connectionStatusKey: String,
        hidStatusKey: String,
        hidFilterFailure: HIDFilterFailureState = .none
    ) -> RuntimePermissionIssue? {
        let bleRuntimeDenied = connectionStatusKey == BluetoothStatusKeys.permissionDenied
        let hidNotPermitted = hidStatusKey == HIDStatusKeys.notPermitted
        let hidRuntimePermissionDenied = hidStatusKey == HIDStatusKeys.inputMonitoringRequired
        let hidFilterTapCreateFailed = hidFilterFailure == .tapCreateFailed
        let hidFilterSystemDisabled = hidFilterFailure == .systemDisabled || hidStatusKey == HIDStatusKeys.interrupted

        var desyncSignals: [String] = []
        if bleRuntimeDenied, bluetoothGranted {
            desyncSignals.append("bluetooth_unauthorized")
        }
        if hidNotPermitted, inputMonitoringGranted {
            desyncSignals.append("hid_open_not_permitted")
        }
        if hidFilterTapCreateFailed, inputMonitoringGranted, accessibilityGranted {
            desyncSignals.append("hid_filter_tap_create_failed")
        }
        if hidFilterSystemDisabled, inputMonitoringGranted, accessibilityGranted {
            desyncSignals.append("hid_filter_system_disabled")
        }
        if !desyncSignals.isEmpty {
            return .permissionDesynced(signals: desyncSignals)
        }

        if bleRuntimeDenied {
            return .bluetoothPermissionDenied
        }
        if hidNotPermitted || hidRuntimePermissionDenied {
            return .inputMonitoringPermissionDenied
        }
        if unavailableBluetoothStatusKeys.contains(connectionStatusKey) {
            return .bluetoothUnavailable(statusKey: connectionStatusKey)
        }
        return nil
    }
}
