import Foundation
import Testing
@testable import RemoteBuddy

@Suite("System sleep audio teardown")
@MainActor
struct SystemSleepAudioTests {
    @Test func actualSleepEndsActiveVoiceEvenDuringStartup() async throws {
        let name = "system-sleep-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values), initialAudioDevices: [])
        model.started = true
        defer { model.started = false }
        model.audio.startupPending = true
        model.voiceSession.isActive = true
        model.isStreaming = true
        model.isAudioOutputReady = true
        model.audio.output.registerPendingVoiceBuffer()
        model.handleSystemAudioLifecycle(.systemWillSleep)
        #expect(!model.voiceSession.isActive)
        #expect(!model.isStreaming)
        #expect(!model.isAudioOutputReady)
        model.audio.startupGeneration = 42
        var configurations = 0
        model.prepareAudioStartup(generation: 42, devices: [], configureOutput: { _, _ in configurations += 1 })
        #expect(configurations == 0)
        #expect(!model.audio.startupPending)
        // Wait for the real output queue without allocating an audio device.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { model.audio.output.stop(); continuation.resume() }
        }
        #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 0)
    }

    @Test func screenSleepPreservesActiveVoice() throws {
        let name = "screen-sleep-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values), initialAudioDevices: [])
        model.started = true
        defer { model.started = false }
        model.voiceSession.isActive = true
        model.isStreaming = true
        model.handleSystemAudioLifecycle(.screenDidSleep)
        #expect(model.voiceSession.isActive)
        #expect(model.isStreaming)
    }

    private func withReadyBridgeModel(
        customMappingEnabled: Bool = false,
        _ body: (BridgeAppModel, BluetoothRemoteBridge) throws -> Void
    ) throws {
        let name = "sleep-lifecycle-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = customMappingEnabled
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            voiceFunctionMapper: RemoteHIDKeyMapper(
                serviceProvider: { [] },
                recoveryDefaults: values
            ),
            hidEventSuppressor: KeyboardEventSuppressor(permissionsGranted: { false })
        )
        let bridgeID = UUID()
        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridgeID,
            scheduleReconnect: { _, _ in }
        )
        model.connections.bridges[bridgeID] = bridge
        bridge.simulateReadyStateForTesting()
        model.started = true
        defer {
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            bridge.stop()
            model.connections.bridges.removeAll()
            model.connections.discoveryBridge = nil
            model.started = false
        }
        try body(model, bridge)
    }

    private func isReady(_ state: BluetoothBridgeState) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private func isReconnecting(_ state: BluetoothBridgeState) -> Bool {
        if case .reconnecting = state { return true }
        return false
    }

    @Test func hidSuspensionTracksSleepAndSessionReasons() {
        var state = SystemAudioSuspensionState()
        #expect(!state.suspendsHIDMonitoring)

        state.apply(.screenDidSleep)
        #expect(!state.suspendsHIDMonitoring)

        state.apply(.systemWillSleep)
        #expect(state.suspendsHIDMonitoring)

        state.apply(.sessionDidResignActive)
        #expect(state.suspendsHIDMonitoring)

        state.apply(.systemDidWake)
        #expect(state.suspendsHIDMonitoring)

        state.apply(.sessionDidBecomeActive)
        #expect(!state.suspendsHIDMonitoring)
    }

    @Test func systemSleepReleasesHIDMonitoringBlocksRestartAndDiscoveryAndRestoresOnWake() throws {
        try withReadyBridgeModel(customMappingEnabled: true) { model, bridge in
            let makeSimulatedMonitor = {
                HIDRemoteMonitor(
                    settings: model.settings,
                    profileID: nil,
                    eventSuppressor: model.hidEventSuppressor,
                    ownsEventSuppressor: false,
                    runtimePermissions: { true },
                    actionPerformer: { _, _, _ in true },
                    diagnosticLogger: { _ in }
                )
            }
            let monitor = makeSimulatedMonitor()
            monitor.connectSimulatedDevice(fingerprint: "test-remote", profileID: UUID())
            var monitorResets = 0
            monitor.onInputReset = { _ in monitorResets += 1 }
            model.hidMonitors["test-remote"] = monitor

            let discoveryMonitor = makeSimulatedMonitor()
            discoveryMonitor.connectSimulatedDevice(fingerprint: "discovery-remote", profileID: nil)
            var discoveryResets = 0
            discoveryMonitor.onInputReset = { _ in discoveryResets += 1 }
            model.discoveryHIDMonitor = discoveryMonitor
            model.activeRemoteButtons = [.right]

            model.scheduleHIDMappingRecoveryIfNeeded()
            #expect(model.hidMappingRecoveryWorkItem != nil)

            model.handleSystemAudioLifecycle(.systemWillSleep)

            #expect(monitorResets == 1)
            #expect(discoveryResets == 1)
            #expect(model.hidMonitors.isEmpty)
            #expect(model.discoveryHIDMonitor == nil)
            #expect(model.activeRemoteButtons.isEmpty)
            #expect(model.hidMonitoringInterrupted)
            #expect(model.hidMappingRecoveryWorkItem == nil)

            // Attempted HID start, discovery, or recovery scheduling during sleep must remain inert.
            model.startHIDMonitors(powerKeySuppressed: false)
            model.startHIDDiscoveryIfNeeded(allowBackOnly: true)
            model.scheduleHIDMappingRecoveryIfNeeded()
            #expect(model.hidMonitors.isEmpty)
            #expect(model.discoveryHIDMonitor == nil)
            #expect(!model.hidEventSuppressor.isRunning)
            #expect(model.hidMappingRecoveryWorkItem == nil)

            // Switching to system-managed mode lets real applyHIDSettings() complete wake restoration
            // without creating live hardware HID handles.
            model.settings.customMappingEnabled = false
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(!model.hidMonitoringInterrupted)
            #expect(model.hidStatus.key == "button_mapping.status.system_managed")
            #expect(isReconnecting(bridge.state))
            monitor.onInputReset = nil
            discoveryMonitor.onInputReset = nil
        }
    }

    @Test func staggeredWakeRestoresHIDImmediatelyWhileDeferringBluetoothUntilScreenWake() throws {
        try withReadyBridgeModel { model, bridge in
            // Typical macOS sequence: screen sleeps first, then system sleeps, then system wakes
            // while the display is still off. Real applyHIDSettings() restores HID immediately
            // while recoverBluetoothVoiceLink remains deferred until screenDidWake.
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(model.hidMonitoringInterrupted)

            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.isSuspended)
            #expect(!model.audio.suspensionState.suspendsHIDMonitoring)
            #expect(model.audio.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReady(bridge.state))

            // A DarkWake returning to sleep suspends HID again and supersedes an unconsumed wake flag.
            model.handleSystemAudioLifecycle(.systemWillSleep)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(model.hidMonitoringInterrupted)

            // Next wake clears hidMonitoringInterrupted immediately and runs real recoverVoiceLink on screenDidWake.
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReconnecting(bridge.state))
        }
    }

    @Test func screenWakeWithoutSystemSleepPreservesReadyBluetoothBridge() throws {
        try withReadyBridgeModel { model, bridge in
            model.handleSystemAudioLifecycle(.screenDidSleep)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))
        }
    }

    @Test func systemWakeRemainsDeferredUntilInactiveSessionBecomesActive() throws {
        try withReadyBridgeModel { model, bridge in
            model.handleSystemAudioLifecycle(.sessionDidResignActive)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.suspendsHIDMonitoring)
            #expect(model.hidMonitoringInterrupted)
            #expect(model.audio.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReconnecting(bridge.state))
        }
    }

    @Test func hidResumesWhenSleepAndSessionClearEvenWhileScreenStillSleeps() throws {
        try withReadyBridgeModel { model, bridge in
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.sessionDidResignActive)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.suspendsHIDMonitoring)
            #expect(model.hidMonitoringInterrupted)
            #expect(isReady(bridge.state))

            // Clearing session inactivity while the screen is still asleep unblocks real applyHIDSettings()
            // immediately while Bluetooth recovery stays deferred until screenDidWake.
            model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
            #expect(!model.audio.suspensionState.suspendsHIDMonitoring)
            #expect(model.audio.suspensionState.isSuspended)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(isReconnecting(bridge.state))
        }
    }

    @Test func startupPendingAndFinishAudioStartupConsumePendingSystemWakeRecovery() throws {
        try withReadyBridgeModel { model, bridge in
            model.audio.startupPending = true
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(isReconnecting(bridge.state))
        }

        try withReadyBridgeModel { model, bridge in
            let discoveryBridge = BluetoothRemoteBridge(
                settings: model.settings,
                delegate: model,
                scheduleReconnect: { _, _ in }
            )
            model.connections.discoveryBridge = discoveryBridge
            defer { discoveryBridge.stop() }

            model.audio.startupPending = true
            model.audio.startupGeneration = 9
            model.audio.pendingSystemWakeRecovery = true
            model.hidMonitoringInterrupted = true

            model.finishAudioStartup(
                generation: 9,
                configurationGeneration: 0,
                configured: false,
                devices: []
            )
            #expect(!model.audio.startupPending)
            #expect(!model.hidMonitoringInterrupted)
            #expect(!model.audio.pendingSystemWakeRecovery)
            #expect(isReconnecting(bridge.state))
        }
    }

    @Test func fnTapVoiceResumesAfterWakeOrSessionResumeWhenBridgeRemainsReady() throws {
        try withReadyBridgeModel { model, bridge in
            model.voiceFnTapSession.setEnabled(true)
            model.voiceFnTapSession.resume()
            #expect(!model.voiceFnTapSession.isSuspended)

            // Ready transition while system is suspended must not un-suspend Fn-tap early.
            model.handleSystemAudioLifecycle(.sessionDidResignActive)
            #expect(model.voiceFnTapSession.isSuspended)
            #expect(!model.voiceFnTapSession.startVoice())
            model.bluetoothBridge(bridge, didChange: .ready("Test remote"))
            #expect(model.voiceFnTapSession.isSuspended)

            // Resuming when the bridge stayed .ready (no bridge state transition) must re-enable Fn-tap.
            model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
            #expect(!model.voiceFnTapSession.isSuspended)
            #expect(isReady(bridge.state))
        }
    }

    @Test func stopAndStoppedLifecycleClearPendingSystemWakeRecovery() throws {
        try withReadyBridgeModel { model, bridge in
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.pendingSystemWakeRecovery)

            // Simulates shutdown/restart even if started is toggled directly before stop() or resume.
            model.started = false
            model.stop()
            #expect(!model.audio.pendingSystemWakeRecovery)

            model.started = true
            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(isReady(bridge.state))
        }
    }
}
