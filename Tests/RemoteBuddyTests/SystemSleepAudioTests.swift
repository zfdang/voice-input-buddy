import Foundation
import Testing
@testable import RemoteBuddy

@Suite("System sleep audio teardown")
@MainActor
struct SystemSleepAudioTests {
    private final class MonitorToken {}

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
        customMappingEnabled: Bool = true,
        hasMatchingHIDServices: Bool = true,
        configureHIDProfile: Bool = true,
        attachReadyBridge: Bool = true,
        _ body: (BridgeAppModel, BluetoothRemoteBridge, () -> [DispatchWorkItem]) throws -> Void
    ) throws {
        let name = "sleep-lifecycle-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = customMappingEnabled

        let bridgeID = UUID()
        if configureHIDProfile {
            let mappings = RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
            let profile = RemoteDeviceProfile(
                model: .rc001,
                bluetoothIdentifier: bridgeID,
                hidFingerprint: "test-remote",
                mappings: mappings
            )
            settings.remoteDeviceProfiles = [profile]
            settings.selectedRemoteProfileID = profile.id
        }

        var hidMappings: [HIDUsageMapping] = []
        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                guard hasMatchingHIDServices else { return [] }
                return [
                    RemoteHIDMappingService(
                        registryID: 123,
                        locationID: 9,
                        readMappings: { hidMappings },
                        setMappings: { hidMappings = $0; return true }
                    )
                ]
            },
            recoveryDefaults: values,
            bootID: "sleep-test"
        )

        var tapEnabled = false
        let suppressor = KeyboardEventSuppressor(
            permissionsGranted: { true },
            tapOperations: .init(
                start: { tapEnabled = true; return true },
                stop: { tapEnabled = false },
                isEnabled: { tapEnabled }
            )
        )

        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            voiceFunctionMapper: mapper,
            hidEventSuppressor: suppressor,
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { [weak settings] in settings?.onboardingVoiceTool ?? .unselected },
            installMonitor: { _ in MonitorToken() },
            removeMonitor: { _ in }
        )

        var scheduledReconnects: [DispatchWorkItem] = []
        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridgeID,
            scheduleReconnect: { _, work in scheduledReconnects.append(work) }
        )
        if attachReadyBridge {
            model.connections.bridges[bridgeID] = bridge
            bridge.simulateReadyStateForTesting()
            model.connections.states[ObjectIdentifier(bridge)] = bridge.state
        }
        model.started = true
        defer {
            model.stopHIDMonitors()
            model.preferredInputSourceMonitor.stop()
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            bridge.stop()
            model.connections.bridges.values.forEach { $0.stop() }
            model.connections.discoveryBridge?.stop()
            model.connections.bridges.removeAll()
            model.connections.states.removeAll()
            model.connections.discoveryBridge = nil
            model.started = false
        }
        try body(model, bridge, { scheduledReconnects })
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
        #expect(!state.pendingSystemWakeRecovery)

        // Stray didWake without prior systemSleeping must not arm deferred recovery.
        let strayWakeChanged = state.apply(.systemDidWake)
        #expect(!strayWakeChanged)
        #expect(!state.pendingSystemWakeRecovery)

        state.apply(.screenDidSleep)
        #expect(!state.suspendsHIDMonitoring)

        state.apply(.systemWillSleep)
        #expect(state.suspendsHIDMonitoring)
        #expect(!state.pendingSystemWakeRecovery)

        state.apply(.sessionDidResignActive)
        #expect(state.suspendsHIDMonitoring)

        state.apply(.systemDidWake)
        #expect(state.suspendsHIDMonitoring)
        #expect(state.pendingSystemWakeRecovery)

        state.apply(.systemWillSleep)
        #expect(!state.pendingSystemWakeRecovery)

        state.apply(.sessionDidBecomeActive)
        #expect(state.suspendsHIDMonitoring)
        state.apply(.systemDidWake)
        #expect(!state.suspendsHIDMonitoring)
        let consumedWake = state.consumePendingSystemWakeRecovery()
        #expect(consumedWake)
        #expect(!state.pendingSystemWakeRecovery)
    }

    @Test func systemSleepReleasesHIDMonitoringBlocksRestartAndDiscoveryAndRestoresOnWake() throws {
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            model.applyHIDSettings()
            let configuredMonitor = try #require(model.hidMonitors["test-remote"])
            let discoveryMonitor = try #require(model.discoveryHIDMonitor)
            #expect(configuredMonitor.isMonitoring)
            #expect(discoveryMonitor.isMonitoring)
            #expect(model.hidEventSuppressor.isRunning)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(!model.hidMonitoringInterrupted)

            var monitorResets = 0
            configuredMonitor.onInputReset = { _ in monitorResets += 1 }
            var discoveryResets = 0
            discoveryMonitor.onInputReset = { _ in discoveryResets += 1 }
            model.activeRemoteButtons = [.right]

            model.scheduleHIDMappingRecoveryIfNeeded()
            #expect(model.hidMappingRecoveryWorkItem == nil) // matched services exist

            model.handleSystemAudioLifecycle(.systemWillSleep)

            #expect(monitorResets == 1)
            #expect(discoveryResets == 1)
            #expect(model.hidMonitors.isEmpty)
            #expect(model.discoveryHIDMonitor == nil)
            #expect(!model.hidEventSuppressor.isRunning)
            #expect(!model.preferredInputSourceMonitor.isMonitoring)
            #expect(model.activeRemoteButtons.isEmpty)
            #expect(model.hidMonitoringInterrupted)

            // Attempted HID start, discovery, or recovery scheduling during sleep must remain inert.
            model.startHIDMonitors(powerKeySuppressed: true)
            model.startHIDDiscoveryIfNeeded(allowBackOnly: true)
            model.scheduleHIDMappingRecoveryIfNeeded()
            #expect(model.hidMonitors.isEmpty)
            #expect(model.discoveryHIDMonitor == nil)
            #expect(!model.hidEventSuppressor.isRunning)
            #expect(!model.preferredInputSourceMonitor.isMonitoring)
            #expect(model.hidMappingRecoveryWorkItem == nil)

            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.hidMonitors["test-remote"]?.isMonitoring == true)
            #expect(model.discoveryHIDMonitor?.isMonitoring == true)
            #expect(model.hidEventSuppressor.isRunning)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReconnecting(bridge.state))
            #expect(scheduledReconnects().count == 1)
            configuredMonitor.onInputReset = nil
            discoveryMonitor.onInputReset = nil
        }
    }

    @Test func startHIDMonitorsGuardPreservesInterruptedDuringSleepWithoutMappingConfig() throws {
        try withReadyBridgeModel(
            customMappingEnabled: false,
            hasMatchingHIDServices: false,
            configureHIDProfile: false
        ) { model, _, _ in
            model.applyHIDSettings()
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(model.hidStatus.key == "button_mapping.status.system_managed")

            model.handleSystemAudioLifecycle(.systemWillSleep)
            #expect(model.hidMonitoringInterrupted)
            #expect(!model.preferredInputSourceMonitor.isMonitoring)

            // Calling startHIDMonitors directly while suspended (e.g. from voice configuration)
            // must not clear hidMonitoringInterrupted via the system_managed early exit.
            model.startHIDMonitors(powerKeySuppressed: false)
            #expect(model.hidMonitoringInterrupted)

            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(!model.hidMonitoringInterrupted)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
        }
    }

    @Test func bleReadyAcrossSleepReschedulesHIDMappingRecoveryOnWake() throws {
        try withReadyBridgeModel(
            customMappingEnabled: true,
            hasMatchingHIDServices: false
        ) { model, bridge, _ in
            model.applyHIDSettings()
            #expect(model.hidMappingRecoveryWorkItem != nil)

            // Session inactivity suspends HID and cancels pending recovery while keeping the ready bridge intact.
            model.handleSystemAudioLifecycle(.sessionDidResignActive)
            #expect(model.hidMappingRecoveryWorkItem == nil)
            #expect(model.hidMonitoringInterrupted)
            #expect(isReady(bridge.state))

            // On resume when the bridge remained .ready (no .ready transition callback),
            // applyHIDSettings() restores discovery/suppressor/input-source monitors and reschedules HID mapping recovery.
            // configuredMonitor stays stopped until recovery matches services and suppresses power key.
            model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
            #expect(model.discoveryHIDMonitor?.isMonitoring == true)
            #expect(model.hidEventSuppressor.isRunning)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(model.hidMonitoringInterrupted)
            #expect(model.hidMappingRecoveryWorkItem != nil)
            #expect(isReady(bridge.state))
        }
    }

    @Test func staggeredWakeRestoresHIDImmediatelyWhileDeferringBluetoothUntilScreenWake() throws {
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            // Typical macOS sequence: screen sleeps first, then system sleeps, then system wakes
            // while the display is still off. Real applyHIDSettings() restores HID immediately
            // while recoverBluetoothVoiceLink remains deferred until screenDidWake.
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(model.hidMonitoringInterrupted)

            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.isSuspended)
            #expect(!model.audio.suspensionState.suspendsHIDMonitoring)
            #expect(model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(model.hidMonitors["test-remote"]?.isMonitoring == true)
            #expect(model.discoveryHIDMonitor?.isMonitoring == true)
            #expect(model.hidEventSuppressor.isRunning)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(isReady(bridge.state))

            // A DarkWake returning to sleep suspends HID again and supersedes an unconsumed wake flag.
            model.handleSystemAudioLifecycle(.systemWillSleep)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(model.hidMonitoringInterrupted)
            #expect(model.hidMonitors.isEmpty)
            #expect(!model.hidEventSuppressor.isRunning)

            // Next wake clears hidMonitoringInterrupted immediately and runs real recoverVoiceLink on screenDidWake.
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(model.hidMonitors["test-remote"]?.isMonitoring == true)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(isReconnecting(bridge.state))
            #expect(scheduledReconnects().count == 1)
        }
    }

    @Test func screenWakeWithoutSystemSleepPreservesReadyBluetoothBridge() throws {
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            model.handleSystemAudioLifecycle(.screenDidSleep)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))
            #expect(scheduledReconnects().isEmpty)
        }
    }

    @Test func systemWakeRemainsDeferredUntilInactiveSessionBecomesActive() throws {
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            model.handleSystemAudioLifecycle(.sessionDidResignActive)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.suspendsHIDMonitoring)
            #expect(model.hidMonitoringInterrupted)
            #expect(model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(!model.hidMonitoringInterrupted)
            #expect(model.hidMonitors["test-remote"]?.isMonitoring == true)
            #expect(model.discoveryHIDMonitor?.isMonitoring == true)
            #expect(model.hidEventSuppressor.isRunning)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(isReconnecting(bridge.state))
            #expect(scheduledReconnects().count == 1)
        }
    }

    @Test func hidResumesWhenSleepAndSessionClearEvenWhileScreenStillSleeps() throws {
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
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
            #expect(model.hidMonitors["test-remote"]?.isMonitoring == true)
            #expect(model.discoveryHIDMonitor?.isMonitoring == true)
            #expect(model.hidEventSuppressor.isRunning)
            #expect(model.preferredInputSourceMonitor.isMonitoring)
            #expect(isReady(bridge.state))
            #expect(scheduledReconnects().isEmpty)

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.isSuspended)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(isReconnecting(bridge.state))
            #expect(scheduledReconnects().count == 1)
        }
    }

    @Test func startupPendingAndFinishAudioStartupConsumePendingSystemWakeRecovery() throws {
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            model.audio.startupPending = true
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(isReady(bridge.state))

            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(isReconnecting(bridge.state))
            #expect(scheduledReconnects().count == 1)
        }

        // Unready bridge during startupPending recovers via session_activated consistently with normal resume.
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            model.connections.states[ObjectIdentifier(bridge)] = .scanning
            model.audio.startupPending = true
            model.handleSystemAudioLifecycle(.sessionDidResignActive)
            model.handleSystemAudioLifecycle(.sessionDidBecomeActive)
            #expect(isReconnecting(bridge.state))
            #expect(scheduledReconnects().count == 1)
        }

        // With empty bridges/discoveryBridge during startupPending, systemDidWake immediately starts missing connections.
        try withReadyBridgeModel(attachReadyBridge: false) { model, _, _ in
            model.audio.startupPending = true
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(!model.connections.bridges.isEmpty)
            #expect(model.connections.discoveryBridge != nil)
        }

        // finishAudioStartup with empty bridges/discoveryBridge runs completeBluetoothResume and resumes Fn-tap when connected.
        try withReadyBridgeModel(attachReadyBridge: false) { model, _, _ in
            model.audio.startupPending = true
            model.audio.startupGeneration = 9
            model.hidMonitoringInterrupted = true
            model.isConnected = true
            model.voiceFnTapSession.setEnabled(true)
            model.voiceFnTapSession.suspend()
            #expect(model.voiceFnTapSession.isSuspended)

            model.finishAudioStartup(
                generation: 9,
                configurationGeneration: 0,
                configured: false,
                devices: []
            )
            #expect(!model.audio.startupPending)
            #expect(!model.hidMonitoringInterrupted)
            #expect(model.hidMonitors["test-remote"]?.isMonitoring == true)
            #expect(!model.voiceFnTapSession.isSuspended)
            #expect(!model.connections.bridges.isEmpty)
            #expect(model.connections.discoveryBridge != nil)
        }
    }

    @Test func fnTapVoiceResumesAfterWakeOrSessionResumeWhenBridgeRemainsReady() throws {
        try withReadyBridgeModel { model, bridge, _ in
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
        try withReadyBridgeModel { model, bridge, scheduledReconnects in
            model.handleSystemAudioLifecycle(.screenDidSleep)
            model.handleSystemAudioLifecycle(.systemWillSleep)
            model.handleSystemAudioLifecycle(.systemDidWake)
            #expect(model.audio.suspensionState.pendingSystemWakeRecovery)

            // Simulates shutdown/restart even if started is toggled directly before stop() or resume.
            model.started = false
            model.stop()
            #expect(!model.audio.suspensionState.pendingSystemWakeRecovery)
            #expect(!model.audio.suspensionState.isSuspended)

            model.started = true
            model.handleSystemAudioLifecycle(.screenDidWake)
            #expect(isReady(bridge.state))
            #expect(scheduledReconnects().isEmpty)
        }
    }
}
