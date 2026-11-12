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
            currentServicesVoiceKeyNeutralized: false,
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
            currentServicesVoiceKeyNeutralized: true,
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
            currentServicesVoiceKeyNeutralized: false,
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
            currentServicesVoiceKeyNeutralized: true,
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
            currentServicesVoiceKeyNeutralized: true,
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
            currentServicesVoiceKeyNeutralized: false,
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
            currentServicesVoiceKeyNeutralized: false,
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
            currentServicesVoiceKeyNeutralized: false,
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
            currentServicesVoiceKeyNeutralized: true,
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

    @Test func voiceStartRevalidatesWhenSecondXiaomiHIDServiceAppearsLater() throws {
        let suite = "hid-two-remotes-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.voiceKeyMode = .function
        settings.setOnboardingVoiceTool(.weixin)

        let bridge1ID = UUID()
        let bridge2ID = UUID()
        let mappings = RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let profile1 = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: bridge1ID,
            hidFingerprint: "remote-1",
            mappings: mappings
        )
        let profile2 = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: bridge2ID,
            hidFingerprint: "remote-2",
            mappings: mappings
        )
        settings.remoteDeviceProfiles = [profile1, profile2]
        settings.selectedRemoteProfileID = profile1.id

        var hasService2 = false
        var mappings1: [HIDUsageMapping] = []
        var mappings2: [HIDUsageMapping] = []
        var writeCount = 0

        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                var result = [RemoteHIDMappingService(
                    registryID: 101,
                    locationID: 9,
                    readMappings: { mappings1 },
                    setMappings: {
                        writeCount += 1
                        mappings1 = $0
                        return true
                    }
                )]
                if hasService2 {
                    result.append(RemoteHIDMappingService(
                        registryID: 202,
                        locationID: 10,
                        readMappings: { mappings2 },
                        setMappings: {
                            writeCount += 1
                            mappings2 = $0
                            return true
                        }
                    ))
                }
                return result
            },
            recoveryDefaults: defaults,
            bootID: "two-remotes-test"
        )

        var tapEnabled = false
        var tapStarts = 0
        let suppressor = KeyboardEventSuppressor(
            permissionsGranted: { true },
            tapOperations: .init(
                start: { tapStarts += 1; tapEnabled = true; return true },
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
            voiceTool: { .weixin },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { "test.input.source" },
            restoreInputSource: { _ in .selected },
            waitForInputSourceActivation: { _, _, _, done in done(false) },
            installMonitor: { _ in MonitorToken() },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        let bridge1 = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridge1ID,
            scheduleReconnect: { _, _ in }
        )
        let bridge2 = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridge2ID,
            scheduleReconnect: { _, _ in }
        )
        model.connections.bridges[bridge1ID] = bridge1
        model.connections.bridges[bridge2ID] = bridge2
        bridge1.simulateReadyStateForTesting()
        model.started = true
        defer {
            model.stopHIDMonitors()
            model.preferredInputSourceMonitor.stop()
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            bridge1.stop()
            bridge2.stop()
            model.connections.bridges.removeAll()
            model.connections.states.removeAll()
            model.started = false
            defaults.removePersistentDomain(forName: suite)
        }

        // Only remote 1's HID service is present when bridge 2 becomes Bluetooth-ready.
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(mappings1.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(mappings2.isEmpty)

        bridge2.simulateReadyStateForTesting()
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(mappings2.isEmpty)

        // Remote 2's HID service appears after Bluetooth readiness reported success for remote 1.
        hasService2 = true
        model.bluetoothBridgeDidStartVoice(bridge2)
        _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: bridge2ID)
        model.voiceSession.stopRequested = false
        model.voiceSession.end()

        #expect(mappings2.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(mappings2.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey))
        #expect(model.hidAllowedLocationIDs == Set([9, 10]))

        // Subsequent voice press on remote 2 reuses the healthy neutralized set without extra writes.
        let writesAfterCatchup = writeCount
        let tapStartsAfterCatchup = tapStarts
        let monitor2AfterCatchup = try #require(model.hidMonitors["remote-2"])
        model.bluetoothBridgeDidStartVoice(bridge2)
        _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: bridge2ID)
        model.voiceSession.stopRequested = false
        model.voiceSession.end()

        #expect(writeCount == writesAfterCatchup)
        #expect(tapStarts == tapStartsAfterCatchup)
        #expect(model.hidMonitors["remote-2"] === monitor2AfterCatchup)
    }

    @Test func voiceStartDetectsDisconnectedServiceAndReusedOrResetRegistryID() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .function,
            voiceTool: .weixin,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // Simulate disconnect dropping the HID service, then reconnecting with cleared mappings.
        counters.hasMatchingHIDServices = false
        model.bluetoothBridge(harness.bridge, didChange: .reconnecting)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        counters.hasMatchingHIDServices = true
        counters.hidMappings = []
        let writesBeforeReconnectVoice = counters.setMappingsCount
        model.bluetoothBridgeDidStartVoice(harness.bridge)
        _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: harness.bridgeID)
        model.voiceSession.stopRequested = false
        model.voiceSession.end()

        #expect(counters.setMappingsCount == writesBeforeReconnectVoice + 1)
        #expect(counters.hidMappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
    }

    @Test func hidDeviceConnectedSchedulesMappingRefreshForUnmappedService() async throws {
        let suite = "hid-connect-refresh-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.voiceKeyMode = .leftCommand

        let bridgeID = UUID()
        let mappings = RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let profile = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: bridgeID,
            hidFingerprint: "remote-1",
            mappings: mappings
        )
        settings.remoteDeviceProfiles = [profile]
        settings.selectedRemoteProfileID = profile.id

        var hasService2 = false
        var mappings1: [HIDUsageMapping] = []
        var mappings2: [HIDUsageMapping] = []
        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                var result = [RemoteHIDMappingService(
                    registryID: 101,
                    locationID: 9,
                    readMappings: { mappings1 },
                    setMappings: { mappings1 = $0; return true }
                )]
                if hasService2 {
                    result.append(RemoteHIDMappingService(
                        registryID: 202,
                        locationID: 10,
                        readMappings: { mappings2 },
                        setMappings: { mappings2 = $0; return true }
                    ))
                }
                return result
            },
            recoveryDefaults: defaults,
            bootID: "hid-connect-refresh-test"
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
            voiceTool: { .unselected },
            installMonitor: { _ in MonitorToken() },
            removeMonitor: { _ in },
            logger: { _ in }
        )
        model.started = true
        defer {
            model.stopHIDMonitors()
            model.preferredInputSourceMonitor.stop()
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            model.started = false
            defaults.removePersistentDomain(forName: suite)
        }

        model.applyHIDSettings()
        #expect(mappings1.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(mappings2.isEmpty)

        hasService2 = true
        let monitor = try #require(model.hidMonitors["remote-1"])
        monitor.onDeviceConnected?(profile.id, "remote-1")

        // Drain the main-queue dispatch queued by onDeviceConnected.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(mappings2.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(mappings2.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey))
        #expect(model.hidAllowedLocationIDs == Set([9, 10]))
    }
}
