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

enum RuntimePermissionIssue: Equatable {
    case permissionDesynced(signals: [String])
    case bluetoothPermissionDenied
    case inputMonitoringPermissionDenied
    case bluetoothUnavailable(statusKey: String)

    var isPermissionDesynced: Bool {
        if case .permissionDesynced = self { return true }
        return false
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
        "bluetooth.status.off",
        "bluetooth.status.unsupported",
        "bluetooth.status.unavailable",
        "bluetooth.status.resetting"
    ]

    static func diagnose(
        bluetoothGranted: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        connectionStatusKey: String,
        hidStatusKey: String,
        hidFilterStartFailed: Bool
    ) -> RuntimePermissionIssue? {
        let bleRuntimeDenied = connectionStatusKey == "bluetooth.status.permission_denied"
        let hidNotPermitted = hidStatusKey == "button_mapping.error.not_permitted"
        let hidRuntimePermissionDenied = hidStatusKey == "button_mapping.permission.input_monitoring_required"

        var desyncSignals: [String] = []
        if bleRuntimeDenied, bluetoothGranted {
            desyncSignals.append("bluetooth_unauthorized")
        }
        if hidNotPermitted, inputMonitoringGranted {
            desyncSignals.append("hid_open_not_permitted")
        }
        if hidFilterStartFailed, inputMonitoringGranted, accessibilityGranted {
            desyncSignals.append("hid_filter_start_failed")
        }
        if !desyncSignals.isEmpty {
            return .permissionDesynced(signals: desyncSignals)
        }

        if bleRuntimeDenied || !bluetoothGranted {
            return .bluetoothPermissionDenied
        }
        if hidNotPermitted || hidRuntimePermissionDenied || !inputMonitoringGranted {
            return .inputMonitoringPermissionDenied
        }
        if unavailableBluetoothStatusKeys.contains(connectionStatusKey) {
            return .bluetoothUnavailable(statusKey: connectionStatusKey)
        }
        return nil
    }
}
