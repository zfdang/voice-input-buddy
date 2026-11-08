import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    static func shouldRecoverHIDAfterCompletedUpdate(
        completedUpdate: Bool,
        customMappingEnabled: Bool
    ) -> Bool {
        completedUpdate && customMappingEnabled
    }

    nonisolated static func shouldReapplyHIDSettings(
        previousState: BluetoothBridgeState?,
        currentState: BluetoothBridgeState
    ) -> Bool {
        guard case .ready = currentState else { return false }
        guard let previousState else { return true }
        if case .ready = previousState { return false }
        return true
    }

    nonisolated static func canStartBluetoothVoice(
        mode: VoiceKeyMode,
        voiceFnTapModeEnabled: Bool = false,
        isVoiceKeyNeutralized: Bool,
        hasHardwareVoiceKey: Bool = true,
        accessibilityGranted: Bool = false,
        requiresOrderedFn: Bool = false
    ) -> Bool {
        if !hasHardwareVoiceKey { return accessibilityGranted }
        if requiresOrderedFn { return accessibilityGranted && isVoiceKeyNeutralized }
        return (mode == .function && !voiceFnTapModeEnabled) || isVoiceKeyNeutralized
    }

    nonisolated static func canFallbackVoiceKeyMode(
        isStreaming: Bool,
        allowVoiceKeyModeFallback: Bool
    ) -> Bool {
        !isStreaming && allowVoiceKeyModeFallback
    }

    nonisolated static func voiceKeyCompatibilityWarning(
        remoteConnected: Bool,
        usesPrivateAdapter: Bool,
        customMappingEnabled: Bool,
        hidStatusKey: String,
        voiceShortcutStatusKey: String,
        karabinerRunning: Bool
    ) -> VoiceKeyCompatibilityWarning? {
        guard remoteConnected, !usesPrivateAdapter, customMappingEnabled else { return nil }

        let isExclusiveAccess = hidStatusKey == "button_mapping.error.exclusive_access" ||
            hidStatusKey == "button_mapping.error.exclusive_access.karabiner"
        if isExclusiveAccess {
            return hidStatusKey == "button_mapping.error.exclusive_access.karabiner" && karabinerRunning
                ? .karabiner
                : .otherInputTool
        }

        let isVoiceKeyMappingUnavailable = voiceShortcutStatusKey == "voice_button.status.waiting" ||
            hidStatusKey == "button_mapping.status.disconnected" ||
            hidStatusKey == "button_mapping.status.waiting_for_device"
        return isVoiceKeyMappingUnavailable && karabinerRunning ? .karabiner : nil
    }

    @discardableResult
    static func importConfiguration(
        from data: Data,
        into settings: AppSettings,
        isStreaming: Bool,
        releaseVoiceKey: () -> Bool
    ) throws -> Bool {
        let importedVoiceKeyConfiguration = try settings.voiceKeyConfigurationState(in: data)
        let changesVoiceKeyConfiguration =
            importedVoiceKeyConfiguration != settings.voiceKeyConfigurationState
        guard !isStreaming else { throw AppConfigurationError.unsafeVoiceKeyChange }
        if changesVoiceKeyConfiguration {
            guard releaseVoiceKey() else {
                throw AppConfigurationError.unsafeVoiceKeyChange
            }
        }
        try settings.importConfiguration(from: data)
        return changesVoiceKeyConfiguration
    }

    func recoverHIDAfterCompletedUpdate(delay: TimeInterval = 2) {
        guard started, settings.customMappingEnabled else { return }
        completedUpdateHIDRecoveryWorkItem?.cancel()
        stopHIDMonitors()
        AppLogger.shared.write("HID UPDATE RECOVERY scheduled delay_ms=\(Int(delay * 1_000))")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.settings.customMappingEnabled else { return }
            self.completedUpdateHIDRecoveryWorkItem = nil
            self.applyHIDSettings()
            AppLogger.shared.write("HID UPDATE RECOVERY applied")
        }
        completedUpdateHIDRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func refreshHIDAfterPermissionChange() {
        let current = HIDPermissionSnapshot.current
        // Permission polling can stop before the saved snapshot changes. Recover a deferred
        // key-up whenever permission is available and the voice session has already ended.
        if current.accessibilityGranted, !isStreaming, voiceKeyLatch.isHeld {
            _ = releaseVoiceKeyIfNeeded()
        }
        if current.accessibilityGranted { voiceFnTapSession.retryCleanupAfterPermissionRecovery() }
        guard HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: started,
            customMappingEnabled: settings.customMappingEnabled,
            voiceKeyMode: settings.voiceKeyMode,
            voiceFnTapModeEnabled: settings.voiceFnTapModeEnabled,
            softwareVoiceKeyHeld: voiceKeyLatch.isHeld,
            monitoringInterrupted: hidMonitoringInterrupted,
            previous: appliedHIDPermissionSnapshot,
            current: current
        ) else { return }
        let previous = appliedHIDPermissionSnapshot
        AppLogger.shared.write(
            "HID PERMISSIONS changed " +
                "input=\(previous?.inputMonitoringGranted ?? false)->\(current.inputMonitoringGranted) " +
                "accessibility=\(previous?.accessibilityGranted ?? false)->\(current.accessibilityGranted) " +
                "recovery=apply_settings"
        )

        applyHIDSettings()
    }

    func reconnect() {
        guard started else { return }
        if connections.bridges.isEmpty && connections.discoveryBridge == nil {
            AppLogger.shared.write("BLE RECONNECT starting_missing_bridges")
            startBluetoothConnections()
            return
        }
        if let selectedBluetoothBridge {
            selectedBluetoothBridge.reconnectNow()
        } else {
            connections.bridges.values.forEach { $0.reconnectNow() }
            connections.discoveryBridge?.reconnectNow()
        }
    }

    func recheckRemoteInput() {
        guard started, !isStreaming else { return }
        AppLogger.shared.write("HID USER_RECHECK requested")
        applyHIDSettings()
        refreshVoiceKeyCompatibilityWarning()
    }

    func refreshVoiceKeyCompatibilityWarning() {
        let warning = Self.voiceKeyCompatibilityWarning(
            remoteConnected: isConnected,
            usesPrivateAdapter: settings.selectedRemoteProfile?.model.usesPrivateAdapter == true,
            customMappingEnabled: settings.customMappingEnabled,
            hidStatusKey: hidStatus.key,
            voiceShortcutStatusKey: voiceShortcutStatus.key,
            karabinerRunning: HIDRemoteMonitor.isKarabinerElementsRunning()
        )
        guard warning != voiceKeyCompatibilityWarning else { return }
        voiceKeyCompatibilityWarning = warning
        let reason: String
        switch warning {
        case .karabiner: reason = "karabiner"
        case .otherInputTool: reason = "other_input_tool"
        case nil: reason = "none"
        }
        AppLogger.shared.write(
            "HID VOICE_KEY_COMPATIBILITY state=\(warning == nil ? "clear" : "warning") reason=\(reason)"
        )
    }

    func recoverBluetoothVoiceLink(reason: String) {
        let targets: [BluetoothRemoteBridge]
        if let selectedBluetoothBridge {
            targets = [selectedBluetoothBridge]
        } else {
            targets = Array(connections.bridges.values)
        }
        AppLogger.shared.write(
            "BLE RECOVERY phase=begin trigger=\(reason) target_bridges=\(targets.count) " +
                "configured_bridges=\(connections.bridges.count) " +
                "discovery=\(connections.discoveryBridge != nil) " +
                "ready_bridges=\(readyBluetoothBridgeCount)"
        )
        if targets.isEmpty, connections.discoveryBridge == nil {
            startBluetoothConnections()
            AppLogger.shared.write(
                "BLE RECOVERY phase=begin trigger=\(reason) cause=started_missing_bridges"
            )
            return
        }
        targets.forEach { $0.recoverVoiceLink(reason: reason) }
        connections.discoveryBridge?.recoverVoiceLink(reason: reason)
    }

    func setBluetoothSystemSuspended(_ suspended: Bool, reason: String) {
        connections.bridges.values.forEach {
            $0.setSystemSuspended(suspended, reason: reason)
        }
        connections.discoveryBridge?.setSystemSuspended(suspended, reason: reason)
    }

    func resumeBluetoothConnectionCyclesIfNeeded(reason: String) {
        connections.bridges.values.forEach {
            $0.resumeConnectionCycleIfNeeded(reason: reason)
        }
        connections.discoveryBridge?.resumeConnectionCycleIfNeeded(reason: reason)
    }

    func refreshRemoteDiscovery() {
        guard started else { return }
        if connections.discoveryBridge == nil {
            startBluetoothDiscoveryIfNeeded()
        } else {
            connections.discoveryBridge?.reconnectNow()
        }
        AppLogger.shared.write("BLE DISCOVERY refreshed_from_foreground")
    }
}
