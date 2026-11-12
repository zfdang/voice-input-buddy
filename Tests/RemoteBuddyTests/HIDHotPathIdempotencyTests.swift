import Foundation
import Testing
@testable import RemoteBuddy

@Suite("HID hot-path idempotency")
@MainActor
struct HIDHotPathIdempotencyTests {
    private final class MonitorToken {}

    @MainActor
    private struct Harness {
        let suite: String
        let defaults: UserDefaults
        let settings: AppSettings
        let model: BridgeAppModel
        let bridgeID: UUID
        let bridge: BluetoothRemoteBridge
        let counters: Counters

        final class Counters {
            var setMappingsCount = 0
            var tapStartCount = 0
            var tapStopCount = 0
            var tapEnabled = false
            var hasMatchingHIDServices = true
            var hidMappings: [HIDUsageMapping] = []
            var permissionSnapshot = HIDPermissionSnapshot(
                inputMonitoringGranted: true,
                accessibilityGranted: true
            )
            var logs: [String] = []
        }

        func cleanup() {
            model.stopHIDMonitors()
            model.preferredInputSourceMonitor.stop()
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            bridge.stop()
            model.connections.bridges.values.forEach { $0.stop() }
            model.connections.discoveryBridge?.stop()
            model.connections.bridges.removeAll()
            model.connections.states.removeAll()
            model.started = false
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeHarness(
        customMappingEnabled: Bool = true,
        configureProfile: Bool = true,
        modelType: RemoteModel = .rc001,
        voiceKeyMode: VoiceKeyMode = .function,
        voiceTool: OnboardingVoiceTool = .unselected,
        hasMatchingHIDServices: Bool = true
    ) throws -> Harness {
        let suite = "hid-idempotency-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = customMappingEnabled
        settings.voiceKeyMode = voiceKeyMode
        settings.setOnboardingVoiceTool(voiceTool)

        let bridgeID = UUID()
        if configureProfile {
            let mappings = RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
            let profile = RemoteDeviceProfile(
                model: modelType,
                bluetoothIdentifier: bridgeID,
                hidFingerprint: "test-remote",
                mappings: mappings
            )
            settings.remoteDeviceProfiles = [profile]
            settings.selectedRemoteProfileID = profile.id
        }

        let counters = Harness.Counters()
        counters.hasMatchingHIDServices = hasMatchingHIDServices

        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                guard counters.hasMatchingHIDServices else { return [] }
                return [
                    RemoteHIDMappingService(
                        registryID: 123,
                        locationID: 9,
                        readMappings: { counters.hidMappings },
                        setMappings: {
                            counters.setMappingsCount += 1
                            counters.hidMappings = $0
                            return true
                        }
                    )
                ]
            },
            recoveryDefaults: defaults,
            bootID: "idempotency-test"
        )

        let suppressor = KeyboardEventSuppressor(
            permissionsGranted: { counters.permissionSnapshot.accessibilityGranted },
            tapOperations: .init(
                start: {
                    counters.tapStartCount += 1
                    counters.tapEnabled = true
                    return true
                },
                stop: {
                    if counters.tapEnabled {
                        counters.tapStopCount += 1
                    }
                    counters.tapEnabled = false
                },
                isEnabled: { counters.tapEnabled }
            )
        )

        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            voiceFunctionMapper: mapper,
            hidEventSuppressor: suppressor,
            permissionSnapshotProvider: { counters.permissionSnapshot }
        )
        // Cancel any ordered-Fn voice key wait synchronously so tests never post OS key events.
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { [weak settings] in settings?.onboardingVoiceTool ?? .unselected },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { "test.input.source" },
            restoreInputSource: { _ in .selected },
            waitForInputSourceActivation: { _, _, _, done in done(false) },
            installMonitor: { _ in MonitorToken() },
            removeMonitor: { _ in },
            logger: { _ in }
        )
        model.voiceFnTapSession = VoiceFnTapSessionController(
            setFunctionKeyPressed: { _ in true },
            enqueueAudio: { _ in },
            drainAudio: { _, completion in completion() },
            onFailure: { _ in },
            logger: { counters.logs.append($0) }
        )

        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridgeID,
            scheduleReconnect: { _, _ in }
        )
        if configureProfile {
            model.connections.bridges[bridgeID] = bridge
            bridge.simulateReadyStateForTesting()
            model.connections.states[ObjectIdentifier(bridge)] = bridge.state
        }
        model.started = true

        return Harness(
            suite: suite,
            defaults: defaults,
            settings: settings,
            model: model,
            bridgeID: bridgeID,
            bridge: bridge,
            counters: counters
        )
    }

    @Test func shouldReapplyHIDSettingsBeforeVoiceStartTruthTable() {
        let granted = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
        let deniedAccessibility = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: false)

        // Plain Fn hold-to-talk never needs pre-voice reapplication.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            isVoiceKeyNeutralized: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: true,
            appliedPermissionSnapshot: deniedAccessibility,
            currentPermissionSnapshot: granted
        ))

        // Steady-state ordered-Fn (e.g. Weixin) skips reapplication when neutralized and healthy.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            isVoiceKeyNeutralized: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))

        // Missing neutralization on hardware remote, interrupted monitoring, or permission changes trigger recovery.
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            isVoiceKeyNeutralized: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            isVoiceKeyNeutralized: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            isVoiceKeyNeutralized: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: deniedAccessibility,
            currentPermissionSnapshot: granted
        ))

        // Chromecast remote (no hardware voice key) does not flap when no Xiaomi HID service is neutralized.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .leftCommand,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: false,
            isVoiceKeyNeutralized: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))

        // Fn-tap mode requires session activation only when Accessibility is granted and session is disabled.
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: true,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: false,
            isVoiceKeyNeutralized: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: true,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: false,
            isVoiceKeyNeutralized: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: deniedAccessibility,
            currentPermissionSnapshot: deniedAccessibility
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            mode: .function,
            fnTapModeEnabled: true,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            isVoiceKeyNeutralized: true,
            fnTapSessionEnabled: true,
            monitoringInterrupted: false,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
    }

    @Test func voiceStartSkipsHIDTeardownWhenOrderedFnAlreadyNeutralizedAndRecoversWhenNeeded() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .function,
            voiceTool: .weixin,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let model = harness.model
        let bridge = harness.bridge
        let counters = harness.counters

        // Bridge becoming .ready in makeHarness already ran applyHIDSettings() once.
        #expect(model.requiresOrderedVoiceFn)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(counters.tapStartCount == 1)
        #expect(counters.tapStopCount == 0)
        #expect(counters.setMappingsCount == 1)
        let initialMonitor = try #require(model.hidMonitors["test-remote"])
        let initialDiscovery = try #require(model.discoveryHIDMonitor)

        for _ in 0..<3 {
            model.bluetoothBridgeDidStartVoice(bridge)
            _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: harness.bridgeID)
            model.voiceSession.stopRequested = false
            model.voiceSession.end()
        }

        #expect(counters.tapStartCount == 1)
        #expect(counters.tapStopCount == 0)
        #expect(counters.setMappingsCount == 1)
        #expect(model.hidMonitors["test-remote"] === initialMonitor)
        #expect(model.discoveryHIDMonitor === initialDiscovery)

        // When monitoring was interrupted, voice start triggers HID recovery.
        model.hidMonitoringInterrupted = true
        model.bluetoothBridgeDidStartVoice(bridge)
        _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: harness.bridgeID)
        model.voiceSession.stopRequested = false
        model.voiceSession.end()

        #expect(!model.hidMonitoringInterrupted)
        #expect(counters.tapStopCount == 1)
        #expect(counters.tapStartCount == 2)
        #expect(model.hidMonitors["test-remote"] !== initialMonitor)
    }

    @Test func voiceStartReappliesSettingsWhenServiceWasNotYetNeutralized() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .leftCommand,
            voiceTool: .unselected,
            hasMatchingHIDServices: false
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        model.applyHIDSettings()
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(counters.setMappingsCount == 0)

        counters.hasMatchingHIDServices = true
        model.bluetoothBridgeDidStartVoice(harness.bridge)
        _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: harness.bridgeID)
        model.voiceSession.stopRequested = false
        model.voiceSession.end()

        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(counters.setMappingsCount == 1)
    }

    @Test func applyHIDSettingsReusesHealthyMonitorsUnlessConfigChangesOrRecheckForced() throws {
        let harness = try makeHarness(customMappingEnabled: true)
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        model.applyHIDSettings()
        let firstMonitor = try #require(model.hidMonitors["test-remote"])
        let firstDiscovery = try #require(model.discoveryHIDMonitor)
        #expect(counters.tapStartCount == 1)
        #expect(counters.tapStopCount == 0)

        // Unchanged config and healthy monitors skip teardown/recreation.
        model.applyHIDSettings()
        #expect(model.hidMonitors["test-remote"] === firstMonitor)
        #expect(model.discoveryHIDMonitor === firstDiscovery)
        #expect(counters.tapStartCount == 1)
        #expect(counters.tapStopCount == 0)

        // Explicit user recheck forces a full rebuild.
        model.recheckRemoteInput()
        let recheckedMonitor = try #require(model.hidMonitors["test-remote"])
        #expect(recheckedMonitor !== firstMonitor)
        #expect(counters.tapStopCount == 1)
        #expect(counters.tapStartCount == 2)

        // Turning off custom mapping (falling back to back-only mode) tears down event tap and rebuilds monitors.
        harness.settings.customMappingEnabled = false
        model.applyHIDSettings()
        let backOnlyMonitor = try #require(model.hidMonitors["test-remote"])
        #expect(backOnlyMonitor !== recheckedMonitor)
        #expect(!counters.tapEnabled)
        #expect(counters.tapStopCount == 2)

        // Re-running with unchanged back-only config also stays idempotent.
        model.applyHIDSettings()
        #expect(model.hidMonitors["test-remote"] === backOnlyMonitor)
        #expect(counters.tapStartCount == 2)

        // External monitor stop invalidates reuse so the next applyHIDSettings recovers it.
        backOnlyMonitor.stop()
        model.applyHIDSettings()
        #expect(model.hidMonitors["test-remote"] !== backOnlyMonitor)
    }

    @Test func startHIDMonitorsPreservesInterruptedFlagDuringSleepBeforeDisabledEarlyReturn() throws {
        let harness = try makeHarness(
            customMappingEnabled: false,
            configureProfile: false
        )
        defer { harness.cleanup() }
        let model = harness.model

        model.handleSystemAudioLifecycle(.systemWillSleep)
        #expect(model.audio.suspensionState.suspendsHIDMonitoring)
        #expect(model.hidMonitoringInterrupted)

        model.startHIDMonitors(powerKeySuppressed: false)
        #expect(model.hidMonitoringInterrupted)
        #expect(model.appliedHIDMonitoringConfiguration == nil)
    }

    @Test func registerBluetoothBridgeLogsCompletionOnlyForNewAttachmentOrTelemetry() throws {
        let harness = try makeHarness(configureProfile: false)
        defer { harness.cleanup() }
        let model = harness.model
        let bridge = harness.bridge

        var messages: [String] = []
        let profileID = try #require(
            model.registerBluetoothBridgeIfNeeded(bridge) { messages.append($0) }
        )
        #expect(messages == [
            "REMOTE PROFILE phase=completed result=persisted reason=verified_remote_path created=true"
        ])

        // Re-registering an already-attached bridge with no pending telemetry does not spam logs.
        messages.removeAll()
        let repeatedID = model.registerBluetoothBridgeIfNeeded(bridge) { messages.append($0) }
        #expect(repeatedID == profileID)
        #expect(messages.isEmpty)

        // Pending telemetry triggers a completion log when flushed.
        model.pendingRemoteBatteryLevels[harness.bridgeID] = 85
        let telemetryID = model.registerBluetoothBridgeIfNeeded(bridge) { messages.append($0) }
        #expect(telemetryID == profileID)
        #expect(messages == [
            "REMOTE PROFILE phase=completed result=persisted reason=verified_remote_path created=false"
        ])
    }
}
