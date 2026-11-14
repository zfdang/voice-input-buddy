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

    /// Reapplies HID settings before starting Bluetooth voice only when live-validated
    /// neutralization or listener state is incomplete, interrupted, or permissions changed.
    nonisolated static func shouldReapplyHIDSettingsBeforeVoiceStart(
        customMappingEnabled: Bool,
        mode: VoiceKeyMode,
        fnTapModeEnabled: Bool,
        requiresOrderedFn: Bool,
        hasHardwareVoiceKey: Bool,
        hasMatchingHIDServices: Bool,
        isVoiceKeyNeutralized: Bool,
        currentServicesMatchDesiredMapping: Bool,
        fnTapSessionEnabled: Bool,
        monitoringInterrupted: Bool,
        monitoringConfigurationApplied: Bool,
        appliedPermissionSnapshot: HIDPermissionSnapshot?,
        currentPermissionSnapshot: HIDPermissionSnapshot
    ) -> Bool {
        let needsNeutralization = mode != .function || fnTapModeEnabled || requiresOrderedFn
        guard customMappingEnabled || needsNeutralization else { return false }
        if monitoringInterrupted || !monitoringConfigurationApplied { return true }
        if appliedPermissionSnapshot != currentPermissionSnapshot { return true }
        if !currentServicesMatchDesiredMapping,
           hasMatchingHIDServices || (hasHardwareVoiceKey && needsNeutralization) {
            return true
        }
        if hasHardwareVoiceKey, needsNeutralization, !isVoiceKeyNeutralized { return true }
        if fnTapModeEnabled, !requiresOrderedFn, !fnTapSessionEnabled,
           currentPermissionSnapshot.accessibilityGranted {
            return true
        }
        return false
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
        ) else {
            refreshRuntimePermissionDiagnosis(trigger: "permission_poll")
            return
        }
        let previous = appliedHIDPermissionSnapshot
        AppLogger.shared.write(
            "HID PERMISSIONS changed " +
                "input=\(previous?.inputMonitoringGranted ?? false)->\(current.inputMonitoringGranted) " +
                "accessibility=\(previous?.accessibilityGranted ?? false)->\(current.accessibilityGranted) " +
                "recovery=apply_settings"
        )

        applyHIDSettings()
        refreshRuntimePermissionDiagnosis(trigger: "permission_poll_reapplied")
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
        guard started else { return }
        guard !isStreaming else {
            refreshRuntimePermissionDiagnosis(trigger: "user_recheck_streaming")
            return
        }
        AppLogger.shared.write("HID USER_RECHECK requested")
        applyHIDSettings(forceRestartMonitors: true)
        refreshVoiceKeyCompatibilityWarning()
        refreshRuntimePermissionDiagnosis(trigger: "user_recheck")
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
        if settings.allowsForgottenRemoteDuringActiveControlSetup,
           let discovery = connections.discoveryBridge {
            connections.discoveryBridge = nil
            discovery.stop()
            connections.states.removeValue(forKey: ObjectIdentifier(discovery))
            startBluetoothDiscoveryIfNeeded()
        } else if connections.discoveryBridge == nil {
            startBluetoothDiscoveryIfNeeded()
        } else {
            connections.discoveryBridge?.reconnectNow()
        }
        AppLogger.shared.write("BLE DISCOVERY refreshed_from_foreground")
    }

    func refreshRuntimePermissionDiagnosis(
        trigger: String = "state_change",
        bluetoothGranted: Bool = CBManager.authorization == .allowedAlways
    ) {
        let permissions = permissionSnapshotProvider()
        let nextIssue = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: bluetoothGranted,
            inputMonitoringGranted: permissions.inputMonitoringGranted,
            accessibilityGranted: permissions.accessibilityGranted,
            connectionStatusKey: connectionStatus.key,
            hidStatusKey: hidStatus.key,
            hidFilterFailure: hidFilterFailureState
        )
        let changed = runtimePermissionIssue != nextIssue
        if changed {
            runtimePermissionIssue = nextIssue
            runtimePermissionIssueUpdatedAt = nextIssue == nil ? nil : Date()
            runtimePermissionDiagnosisTrigger = nextIssue == nil ? nil : trigger
        } else if nextIssue != nil {
            runtimePermissionDiagnosisTrigger = trigger
        }
        let nextKey = nextIssue?.diagnosticIdentifier
        if nextKey != lastLoggedRuntimePermissionIssueKey {
            lastLoggedRuntimePermissionIssueKey = nextKey
            if let nextIssue {
                AppLogger.shared.write(
                    "RUNTIME PERMISSION ISSUE detected trigger=\(trigger) " +
                        "issue=\(nextIssue.diagnosticIdentifier) " +
                        "bt_auth=\(bluetoothGranted) " +
                        "input_monitoring=\(permissions.inputMonitoringGranted) " +
                        "accessibility=\(permissions.accessibilityGranted) " +
                        "connection_status=\(connectionStatus.key) " +
                        "hid_status=\(hidStatus.key) " +
                        "hid_filter_failure=\(hidFilterFailureState)"
                )
            } else {
                AppLogger.shared.write("RUNTIME PERMISSION ISSUE cleared trigger=\(trigger)")
            }
        }
    }

    var canRelaunchApplication: Bool {
        Self.canRelaunchAppBundle(Bundle.main.bundleURL)
    }

    nonisolated static func canRelaunchAppBundle(_ bundleURL: URL) -> Bool {
        bundleURL.pathExtension.lowercased() == "app" &&
            FileManager.default.fileExists(atPath: bundleURL.path)
    }

    @discardableResult
    func relaunchApplication(
        bundleURL: URL = Bundle.main.bundleURL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        launchProcess: ((_ executablePath: String, _ arguments: [String]) throws -> Void)? = nil,
        terminateHandler: (() -> Void)? = nil
    ) -> Bool {
        guard !isTerminating else {
            AppLogger.shared.write("APP RELAUNCH skipped reason=already_terminating")
            return false
        }
        let sanitizedBundlePath = SettingsDiagnosticSnapshot.sanitizePath(bundleURL.path)
        guard Self.canRelaunchAppBundle(bundleURL) else {
            AppLogger.shared.write("APP RELAUNCH skipped reason=not_app_bundle path=\(sanitizedBundlePath)")
            return false
        }
        let issueLabel = runtimePermissionIssue?.diagnosticIdentifier ?? "none"
        AppLogger.shared.write("APP RELAUNCH requested pid=\(pid) bundle=\(sanitizedBundlePath) issue=\(issueLabel)")
        let executablePath = "/bin/sh"
        let arguments = [
            "-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 250 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open \"$2\"",
            "_",
            String(pid),
            bundleURL.path
        ]
        do {
            if let launchProcess {
                try launchProcess(executablePath, arguments)
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                try process.run()
            }
        } catch {
            AppLogger.shared.write("APP RELAUNCH failed \(AppLogger.errorFields(error))")
            return false
        }
        if let terminateHandler {
            terminateHandler()
        } else {
            NSApp.terminate(nil)
        }
        return true
    }
}
