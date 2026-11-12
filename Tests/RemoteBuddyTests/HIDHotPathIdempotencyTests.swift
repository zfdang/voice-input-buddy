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
        let secondaryBridgeID: UUID?
        let secondaryBridge: BluetoothRemoteBridge?
        let counters: Counters

        final class Counters {
            var serviceProviderCallCount = 0
            var setMappingsCount = 0
            var orderedFnWaitCount = 0
            var tapStartCount = 0
            var tapStopCount = 0
            var tapEnabled = false
            var hasMatchingHIDServices = true
            var allowWrites = true
            var primaryRegistryID: UInt64? = 123
            var primaryLocationID: UInt32 = 9
            var hidMappings: [HIDUsageMapping] = []
            var recordedWrites: [(registryID: UInt64?, mappings: [HIDUsageMapping])] = []
            var secondaryService: (
                enabled: Bool,
                registryID: UInt64?,
                locationID: UInt32,
                mappings: [HIDUsageMapping]
            ) = (false, 202, 10, [])
            var permissionSnapshot = HIDPermissionSnapshot(
                inputMonitoringGranted: true,
                accessibilityGranted: true
            )
            var logs: [String] = []
        }

        func startAndVerifyVoice(on targetBridge: BluetoothRemoteBridge? = nil, id: UUID? = nil) {
            let orderedFnBefore = counters.orderedFnWaitCount
            model.bluetoothBridgeDidStartVoice(targetBridge ?? bridge)
            if model.requiresOrderedVoiceFn {
                #expect(counters.orderedFnWaitCount == orderedFnBefore + 1)
            } else {
                #expect(model.voiceSession.isActive)
            }
            endVoiceSession(for: id)
        }

        func endVoiceSession(for id: UUID? = nil) {
            _ = model.voiceSession.pendingStart.cancel(ifOwnedBy: id ?? bridgeID)
            model.voiceSession.stopRequested = false
            model.voiceSession.end()
        }

        func cleanup(expectNoFnTapLogs: Bool = true) {
            if expectNoFnTapLogs {
                #expect(counters.logs.isEmpty)
            }
            model.stopHIDMonitors()
            model.preferredInputSourceMonitor.stop()
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            bridge.stop()
            secondaryBridge?.stop()
            model.connections.bridges.values.forEach { $0.stop() }
            model.connections.discoveryBridge?.stop()
            model.connections.bridges.removeAll()
            model.connections.states.removeAll()
            model.started = false
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static var defaultMappings: RemoteDeviceMappings {
        RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
    }

    private static func makeStubPreferredInputSourceMonitor(
        settings: AppSettings,
        counters: Harness.Counters
    ) -> PreferredInputSourceMonitor {
        PreferredInputSourceMonitor(
            voiceTool: { [weak settings] in settings?.onboardingVoiceTool ?? .unselected },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { "test.input.source" },
            restoreInputSource: { _ in .selected },
            waitForInputSourceActivation: { _, _, _, done in
                counters.orderedFnWaitCount += 1
                done(false)
            },
            installMonitor: { _ in MonitorToken() },
            removeMonitor: { _ in },
            logger: { _ in }
        )
    }

    private func makeHarness(
        customMappingEnabled: Bool = true,
        configureProfile: Bool = true,
        configureSecondProfile: Bool = false,
        modelType: RemoteModel = .rc001,
        voiceKeyMode: VoiceKeyMode = .function,
        voiceTool: OnboardingVoiceTool = .unselected,
        voiceFnTapModeEnabled: Bool = false,
        hasMatchingHIDServices: Bool = true,
        secondaryServiceEnabled: Bool = false
    ) throws -> Harness {
        let suite = "hid-idempotency-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = customMappingEnabled
        settings.voiceKeyMode = voiceKeyMode
        settings.setOnboardingVoiceTool(voiceTool)
        settings.voiceFnTapModeEnabled = voiceFnTapModeEnabled

        let bridgeID = UUID()
        let secondaryBridgeID: UUID? = configureSecondProfile ? UUID() : nil
        if configureProfile {
            var profiles = [
                RemoteDeviceProfile(
                    model: modelType,
                    bluetoothIdentifier: bridgeID,
                    hidFingerprint: "test-remote",
                    mappings: Self.defaultMappings
                )
            ]
            if let secondaryBridgeID {
                profiles.append(
                    RemoteDeviceProfile(
                        model: modelType,
                        bluetoothIdentifier: secondaryBridgeID,
                        hidFingerprint: "remote-2",
                        mappings: Self.defaultMappings
                    )
                )
            }
            settings.remoteDeviceProfiles = profiles
            settings.selectedRemoteProfileID = profiles[0].id
        }

        let counters = Harness.Counters()
        counters.hasMatchingHIDServices = hasMatchingHIDServices
        counters.secondaryService.enabled = secondaryServiceEnabled

        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                counters.serviceProviderCallCount += 1
                var services: [RemoteHIDMappingService] = []
                if counters.hasMatchingHIDServices {
                    let regID = counters.primaryRegistryID
                    services.append(
                        RemoteHIDMappingService(
                            registryID: regID,
                            locationID: counters.primaryLocationID,
                            readMappings: { counters.hidMappings },
                            setMappings: {
                                guard counters.allowWrites else { return false }
                                counters.setMappingsCount += 1
                                counters.recordedWrites.append((registryID: regID, mappings: $0))
                                counters.hidMappings = $0
                                return true
                            }
                        )
                    )
                }
                if counters.secondaryService.enabled {
                    let regID = counters.secondaryService.registryID
                    services.append(
                        RemoteHIDMappingService(
                            registryID: regID,
                            locationID: counters.secondaryService.locationID,
                            readMappings: { counters.secondaryService.mappings },
                            setMappings: {
                                guard counters.allowWrites else { return false }
                                counters.setMappingsCount += 1
                                counters.recordedWrites.append((registryID: regID, mappings: $0))
                                counters.secondaryService.mappings = $0
                                return true
                            }
                        )
                    )
                }
                return services
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
        model.preferredInputSourceMonitor = Self.makeStubPreferredInputSourceMonitor(
            settings: settings,
            counters: counters
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
        var secondaryBridge: BluetoothRemoteBridge?
        if let secondaryBridgeID {
            let second = BluetoothRemoteBridge(
                settings: settings,
                delegate: model,
                targetIdentifier: secondaryBridgeID,
                scheduleReconnect: { _, _ in }
            )
            model.connections.bridges[secondaryBridgeID] = second
            secondaryBridge = second
        }
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
            secondaryBridgeID: secondaryBridgeID,
            secondaryBridge: secondaryBridge,
            counters: counters
        )
    }

    @Test func shouldReapplyHIDSettingsBeforeVoiceStartTruthTable() {
        let granted = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
        let deniedAccessibility = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: false)

        // Plain Fn hold-to-talk without custom mapping never needs pre-voice reapplication.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: false,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: false,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: true,
            monitoringConfigurationApplied: false,
            appliedPermissionSnapshot: deniedAccessibility,
            currentPermissionSnapshot: granted
        ))

        // Plain Fn with customMappingEnabled skips when power-key suppression matches live services or no HID services exist, and recovers when services mismatch.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: false,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))

        // Steady-state ordered-Fn (e.g. Weixin) skips reapplication when neutralized and healthy.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: true,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))

        // Missing neutralization, service mismatch, interrupted monitoring, missing config, or permission changes trigger recovery.
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: true,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: true,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: true,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: true,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: false,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: false,
            requiresOrderedFn: true,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: true,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: deniedAccessibility,
            currentPermissionSnapshot: granted
        ))

        // Chromecast remote (no hardware voice key) does not flap when no Xiaomi HID service exists.
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .leftCommand,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: false,
            hasMatchingHIDServices: false,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))

        // Hardware-key remote (.leftCommand) forces reapplication when neutralization is missing even before HID services appear.
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .leftCommand,
            fnTapModeEnabled: false,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: false,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))

        // Fn-tap mode requires session activation only when Accessibility is granted and session is disabled.
        #expect(BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: true,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: false,
            hasMatchingHIDServices: false,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: granted,
            currentPermissionSnapshot: granted
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: true,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: false,
            hasMatchingHIDServices: false,
            isVoiceKeyNeutralized: false,
            currentServicesMatchDesiredMapping: false,
            fnTapSessionEnabled: false,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
            appliedPermissionSnapshot: deniedAccessibility,
            currentPermissionSnapshot: deniedAccessibility
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettingsBeforeVoiceStart(
            customMappingEnabled: true,
            mode: .function,
            fnTapModeEnabled: true,
            requiresOrderedFn: false,
            hasHardwareVoiceKey: true,
            hasMatchingHIDServices: true,
            isVoiceKeyNeutralized: true,
            currentServicesMatchDesiredMapping: true,
            fnTapSessionEnabled: true,
            monitoringInterrupted: false,
            monitoringConfigurationApplied: true,
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
            harness.startAndVerifyVoice(on: bridge)
        }

        #expect(counters.tapStartCount == 1)
        #expect(counters.tapStopCount == 0)
        #expect(counters.setMappingsCount == 1)
        #expect(model.hidMonitors["test-remote"] === initialMonitor)
        #expect(model.discoveryHIDMonitor === initialDiscovery)

        // When monitoring was interrupted, voice start triggers HID recovery.
        model.hidMonitoringInterrupted = true
        harness.startAndVerifyVoice(on: bridge)

        #expect(!model.hidMonitoringInterrupted)
        #expect(counters.tapStopCount == 1)
        #expect(counters.tapStartCount == 2)
        #expect(model.hidMonitors["test-remote"] !== initialMonitor)
    }

    @Test func voiceStartRecoversWhenAppliedMonitoringConfigurationIsMissing() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .function,
            voiceTool: .weixin,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        let initialMonitor = try #require(model.hidMonitors["test-remote"])
        #expect(!model.hidMonitoringInterrupted)
        #expect(model.appliedHIDMonitoringConfiguration != nil)

        // Simulate unhealthy monitor start leaving appliedHIDMonitoringConfiguration nil without setting interrupted.
        model.appliedHIDMonitoringConfiguration = nil
        harness.startAndVerifyVoice()

        #expect(model.appliedHIDMonitoringConfiguration != nil)
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
        harness.startAndVerifyVoice()

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

        // Allowed location set change invalidates monitor config and forces rebuild.
        counters.secondaryService.enabled = true
        model.applyHIDSettings()
        let multiLocationMonitor = try #require(model.hidMonitors["test-remote"])
        #expect(multiLocationMonitor !== recheckedMonitor)
        #expect(counters.tapStopCount == 2)
        #expect(counters.tapStartCount == 3)

        // Binding a compatible non-standard HID identity changes config and forces rebuild.
        let profileID = try #require(harness.settings.selectedRemoteProfileID)
        let bound = harness.settings.bindCompatibleHID(
            RemoteHIDBinding(
                identity: RemoteHIDIdentity(vendorID: 0x1234, productID: 0x5678),
                fingerprint: "bound-fp"
            ),
            to: profileID
        )
        #expect(bound)
        model.applyHIDSettings()
        let reboundMonitor = try #require(model.hidMonitors["bound-fp"])
        #expect(reboundMonitor !== multiLocationMonitor)
        #expect(counters.tapStopCount == 3)
        #expect(counters.tapStartCount == 4)

        // External suppressor stop invalidates suppressorHealthy and forces rebuild.
        model.hidEventSuppressor.stop()
        model.applyHIDSettings()
        let afterSuppressorRecovery = try #require(model.hidMonitors["bound-fp"])
        #expect(afterSuppressorRecovery !== reboundMonitor)
        #expect(counters.tapStopCount == 4)
        #expect(counters.tapStartCount == 5)

        // Turning off custom mapping (falling back to back-only mode) tears down event tap and rebuilds monitors.
        harness.settings.customMappingEnabled = false
        model.applyHIDSettings()
        let backOnlyMonitor = try #require(model.hidMonitors["bound-fp"])
        let backOnlyDiscovery = try #require(model.discoveryHIDMonitor)
        #expect(backOnlyMonitor !== afterSuppressorRecovery)
        #expect(!counters.tapEnabled)
        #expect(counters.tapStopCount == 5)

        // Re-running with unchanged back-only config stays idempotent.
        model.applyHIDSettings()
        #expect(model.hidMonitors["bound-fp"] === backOnlyMonitor)
        #expect(model.discoveryHIDMonitor === backOnlyDiscovery)
        #expect(counters.tapStartCount == 5)

        // External target or discovery monitor stop invalidates reuse so next applyHIDSettings recovers.
        backOnlyMonitor.stop()
        model.applyHIDSettings()
        let recoveredBackOnlyMonitor = try #require(model.hidMonitors["bound-fp"])
        #expect(recoveredBackOnlyMonitor !== backOnlyMonitor)

        let recoveredDiscovery = try #require(model.discoveryHIDMonitor)
        recoveredDiscovery.stop()
        model.applyHIDSettings()
        #expect(model.discoveryHIDMonitor !== recoveredDiscovery)

        // Removing the remote device clears applied monitoring config and stops monitors.
        #expect(model.removeRemoteDevice(profileID))
        #expect(model.appliedHIDMonitoringConfiguration == nil)
        #expect(model.hidMonitors["bound-fp"] == nil)

        model.applyHIDSettings()
        #expect(model.appliedHIDMonitoringConfiguration != nil)
        #expect(model.hidMonitors.isEmpty)
        #expect(model.discoveryHIDMonitor == nil)
        #expect(counters.logs.isEmpty)
    }

    @Test func startHIDMonitorsAndSystemAudioLifecyclePreserveSleepReasonsAndFlags() throws {
        let harness = try makeHarness(
            customMappingEnabled: false,
            configureProfile: false
        )
        defer { harness.cleanup() }
        let model = harness.model

        #expect(SystemAudioLifecycleEvent.systemWillSleep.rawValue == "system_will_sleep")
        #expect(SystemAudioLifecycleEvent.systemDidWake.rawValue == "system_did_wake")

        model.handleSystemAudioLifecycle(.systemWillSleep)
        #expect(model.audio.suspensionState.suspendsHIDMonitoring)
        #expect(model.hidMonitoringInterrupted)

        model.startHIDMonitors(powerKeySuppressed: false)
        #expect(model.hidMonitoringInterrupted)
        #expect(model.appliedHIDMonitoringConfiguration == nil)

        model.handleSystemAudioLifecycle(.systemDidWake)
        #expect(!model.audio.suspensionState.suspendsHIDMonitoring)
        #expect(!model.hidMonitoringInterrupted)
    }

    @Test func registerBluetoothBridgeHandlesRejectionsPromotionAndPendingTelemetry() throws {
        let harness = try makeHarness(configureProfile: false)
        defer { harness.cleanup() }
        let model = harness.model
        let bridge = harness.bridge

        // Bridge without deviceIdentifier logs missing_identifier rejection.
        let unattached = BluetoothRemoteBridge(
            settings: harness.settings,
            delegate: model,
            targetIdentifier: nil,
            scheduleReconnect: { _, _ in }
        )
        defer { unattached.stop() }
        var rejectedMessages: [String] = []
        #expect(model.registerBluetoothBridgeIfNeeded(unattached) { rejectedMessages.append($0) } == nil)
        #expect(rejectedMessages == [
            "REMOTE PROFILE phase=completed result=rejected reason=missing_identifier"
        ])

        // Verifying mismatched identity fails cleanly.
        #expect(!bridge.bindVerifiedIdentity(UUID()))

        // Forgotten Bluetooth identifiers are ignored without persisting.
        let forgottenID = UUID()
        let forgottenProfileID = harness.settings.registerBluetoothRemote(identifier: forgottenID, model: .rc001)
        #expect(harness.settings.removeRemoteProfile(forgottenProfileID))
        #expect(harness.settings.forgottenBluetoothIdentifiers.contains(forgottenID))
        let forgottenBridge = BluetoothRemoteBridge(
            settings: harness.settings,
            delegate: model,
            targetIdentifier: forgottenID,
            scheduleReconnect: { _, _ in }
        )
        defer { forgottenBridge.stop() }
        var forgottenMessages: [String] = []
        #expect(model.registerBluetoothBridgeIfNeeded(forgottenBridge) { forgottenMessages.append($0) } == nil)
        #expect(forgottenMessages.isEmpty)

        // New registration persists and logs created=true.
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

        // Pending battery, power state, and model telemetry all flush and trigger created=false log.
        model.pendingRemoteBatteryLevels[harness.bridgeID] = 85
        model.pendingRemotePowerStates[harness.bridgeID] = .onBattery
        model.pendingRemoteModels[harness.bridgeID] = .rc003
        let telemetryID = model.registerBluetoothBridgeIfNeeded(bridge) { messages.append($0) }
        #expect(telemetryID == profileID)
        #expect(model.remoteBatteryLevels[profileID] == 85)
        #expect(model.remotePowerStates[profileID] == .onBattery)
        #expect(harness.settings.remoteDeviceProfiles.first(where: { $0.id == profileID })?.model == .rc003)
        #expect(messages == [
            "REMOTE PROFILE phase=completed result=persisted reason=verified_remote_path created=false"
        ])

        // Discovery bridge promotion attaches into bridges and logs created=true for newly discovered peer.
        let promotedID = UUID()
        let discovery = BluetoothRemoteBridge(
            settings: harness.settings,
            delegate: model,
            targetIdentifier: nil,
            scheduleReconnect: { _, _ in }
        )
        model.connections.discoveryBridge = discovery
        #expect(discovery.bindVerifiedIdentity(promotedID))
        messages.removeAll()
        let newProfileID = try #require(
            model.registerBluetoothBridgeIfNeeded(discovery) { messages.append($0) }
        )
        #expect(newProfileID != profileID)
        #expect(model.connections.bridges[promotedID] === discovery)
        #expect(model.connections.discoveryBridge !== discovery)
        #expect(messages == [
            "REMOTE PROFILE phase=completed result=persisted reason=verified_remote_path created=true"
        ])
    }

    @Test func voiceStartRevalidatesWhenSecondXiaomiHIDServiceAppearsLater() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            configureProfile: true,
            configureSecondProfile: true,
            modelType: .rc003,
            voiceKeyMode: .function,
            voiceTool: .weixin,
            hasMatchingHIDServices: true,
            secondaryServiceEnabled: false
        )
        defer { harness.cleanup() }
        let model = harness.model
        let bridge2 = try #require(harness.secondaryBridge)
        let bridge2ID = try #require(harness.secondaryBridgeID)
        let counters = harness.counters

        // Only remote 1's HID service is present when bridge 2 becomes Bluetooth-ready.
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(counters.hidMappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))

        bridge2.simulateReadyStateForTesting()
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // Pre-populate service 2 with stale non-neutral mapping to avoid asserting on empty defaults.
        counters.secondaryService.mappings = [RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey]
        counters.secondaryService.enabled = true

        // Verify explicit live validation invalidates isVoiceKeyNeutralized (true -> false) on unmapped service 2.
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: harness.settings.customMappingEnabled,
            expectedVoiceKeyNeutralization: model.shouldNeutralizeNativeVoiceKey
        ))
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // Restore cached-neutralization flag before voice start to also verify voiceStart's internal invalidation + catchup.
        counters.secondaryService.enabled = false
        model.applyHIDSettings()
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)

        counters.secondaryService.enabled = true
        counters.secondaryService.mappings = [RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey]
        counters.recordedWrites.removeAll()
        let writesBeforeVoice = counters.setMappingsCount
        harness.startAndVerifyVoice(on: bridge2, id: bridge2ID)

        #expect(counters.setMappingsCount == writesBeforeVoice + 2)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        let secondaryWrite = try #require(counters.recordedWrites.last(where: { $0.registryID == 202 }))
        #expect(secondaryWrite.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(secondaryWrite.mappings.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey))
        #expect(model.hidAllowedLocationIDs == Set([9, 10]))

        // Subsequent voice press on remote 2 reuses the healthy neutralized set without extra writes.
        let writesAfterCatchup = counters.setMappingsCount
        let tapStartsAfterCatchup = counters.tapStartCount
        let monitor2AfterCatchup = try #require(model.hidMonitors["remote-2"])
        harness.startAndVerifyVoice(on: bridge2, id: bridge2ID)

        #expect(counters.setMappingsCount == writesAfterCatchup)
        #expect(counters.tapStartCount == tapStartsAfterCatchup)
        #expect(model.hidMonitors["remote-2"] === monitor2AfterCatchup)
    }

    @Test func refreshValidityDetectsNewRegistryIDResetMappingsNilRegistryIDAndPowerMismatch() throws {
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

        // 1. Different registryID after reconnect invalidates neutralization even with leftover power-only mapping.
        counters.primaryRegistryID = 456
        counters.hidMappings = [RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey]
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: true
        ))
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        let writesBeforeNewID = counters.setMappingsCount
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeNewID + 1)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // 2. Reused registryID (456) whose OS mappings were reset forces reapply on voice start.
        counters.hidMappings = []
        counters.recordedWrites.removeAll()
        let writesBeforeReset = counters.setMappingsCount
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeReset + 1)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(counters.recordedWrites.last?.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey) == true)

        // 3. nil registryID cannot be verified as already applied and rolls back when neutralization is required.
        counters.primaryRegistryID = nil
        #expect(model.voiceFunctionMapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: true
        ))
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(!model.voiceFunctionMapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        counters.primaryRegistryID = 789
        model.applyHIDSettings()
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // 4. Power-key suppression mismatch (customMappingEnabled turned off) invalidates live validity.
        harness.settings.customMappingEnabled = false
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: harness.settings.customMappingEnabled,
            expectedVoiceKeyNeutralization: model.shouldNeutralizeNativeVoiceKey
        ))
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        counters.recordedWrites.removeAll()
        let writesBeforePowerToggle = counters.setMappingsCount
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforePowerToggle + 1)
        #expect(counters.recordedWrites.last?.mappings.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey) == false)
        #expect(counters.recordedWrites.last?.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey) == true)
    }

    @Test func transientEmptyServicesAndFailedVoiceStartWritePreserveFnTapMode() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .function,
            voiceTool: .unselected,
            voiceFnTapModeEnabled: true,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        #expect(harness.settings.voiceFnTapModeEnabled)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // HID service disappearance resets all applied flags so hardware remotes wait for re-neutralization,
        // without discarding the user's Fn-tap preference.
        counters.hasMatchingHIDServices = false
        let writesBeforeJitter = counters.setMappingsCount
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: true
        ))
        #expect(!model.voiceFunctionMapper.isApplied)
        #expect(!model.voiceFunctionMapper.isPowerKeySuppressed)
        #expect(model.voiceFunctionMapper.powerSuppressedLocationIDs == nil)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(harness.settings.voiceFnTapModeEnabled)
        #expect(counters.setMappingsCount == writesBeforeJitter)

        // While the hardware remote's HID service is still absent, Bluetooth voice start is rejected
        // yet the Fn-tap preference remains intact across the disconnect.
        model.bluetoothBridgeDidStartVoice(harness.bridge)
        #expect(!model.voiceSession.isActive)
        harness.endVoiceSession()
        #expect(harness.settings.voiceFnTapModeEnabled)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // Returning service sees cleared appliedConfiguration and reapplies once; subsequent voice press reuses it.
        counters.hasMatchingHIDServices = true
        counters.hidMappings = []
        counters.recordedWrites.removeAll()
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeJitter + 1)
        #expect(counters.recordedWrites.last?.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey) == true)
        #expect(harness.settings.voiceFnTapModeEnabled)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeJitter + 1)

        // If a returning service fails to write during voice start (`allowVoiceKeyModeFallback: false`),
        // Fn-tap mode preference is still preserved rather than flipped to false.
        counters.primaryRegistryID = 456
        counters.hidMappings = []
        counters.allowWrites = false
        model.bluetoothBridgeDidStartVoice(harness.bridge)
        #expect(!model.voiceSession.isActive)
        harness.endVoiceSession()
        #expect(harness.settings.voiceFnTapModeEnabled)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
    }

    @Test func refreshValidityDiscriminatesUnneutralizedEmptyServicesAndResetsAllStateOnDivergence() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .leftCommand,
            voiceTool: .unselected,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let mapper = harness.model.voiceFunctionMapper
        let counters = harness.counters

        // Switch to power-suppression-only apply so isVoiceKeyNeutralized == false while services stay non-empty.
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(!mapper.isVoiceKeyNeutralized)
        #expect(mapper.isPowerKeySuppressed)
        #expect(mapper.powerSuppressedLocationIDs == Set([9]))

        // Discriminating case: empty services + isVoiceKeyNeutralized == false when neutralization is expected
        // MUST return false and clear all applied flags (old code returned services.isEmpty == true).
        counters.hasMatchingHIDServices = false
        #expect(!mapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: true
        ))
        #expect(!mapper.hasMatchingServices)
        #expect(!mapper.isApplied)
        #expect(!mapper.isPowerKeySuppressed)
        #expect(mapper.powerSuppressedLocationIDs == nil)
        #expect(!mapper.isVoiceKeyNeutralized)

        // Divergence (.needsReapply) without voice neutralization also resets power-key suppression flags.
        counters.hasMatchingHIDServices = true
        counters.hidMappings = []
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(mapper.isApplied)
        #expect(mapper.isPowerKeySuppressed)
        #expect(mapper.powerSuppressedLocationIDs == Set([9]))

        counters.hidMappings = []
        #expect(!mapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: false
        ))
        #expect(!mapper.isApplied)
        #expect(!mapper.isPowerKeySuppressed)
        #expect(mapper.powerSuppressedLocationIDs == nil)
        #expect(!mapper.isVoiceKeyNeutralized)
    }

    @Test func hardwareRemoteRejectsBluetoothVoiceBeforeReconnectedHIDServiceAppearsWhilePreservingPreference() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .leftCommand,
            voiceTool: .unselected,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(harness.settings.voiceKeyMode == .leftCommand)

        // Simulate disconnect where HID service disappears before Bluetooth voice starts on reconnect.
        counters.hasMatchingHIDServices = false
        model.bluetoothBridgeDidStartVoice(harness.bridge)
        #expect(!model.voiceSession.isActive)
        #expect(!model.voiceFunctionMapper.isApplied)
        #expect(!model.voiceFunctionMapper.isPowerKeySuppressed)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(harness.settings.voiceKeyMode == .leftCommand)
        harness.endVoiceSession()

        // Once the reconnected HID service arrives, voice start re-neutralizes it once and reuses on repeat.
        counters.hasMatchingHIDServices = true
        counters.hidMappings = []
        counters.recordedWrites.removeAll()
        let writesBeforeReconnect = counters.setMappingsCount
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeReconnect + 1)
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(counters.recordedWrites.last?.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey) == true)
        #expect(harness.settings.voiceKeyMode == .leftCommand)
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeReconnect + 1)
    }

    @Test func pruneAppliedServicesShrinksIntersectionSoReturningServiceMustReapply() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .leftCommand,
            voiceTool: .unselected,
            hasMatchingHIDServices: true,
            secondaryServiceEnabled: true
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        #expect(!model.voiceFunctionMapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(model.voiceFunctionMapper.powerSuppressedLocationIDs == Set([9, 10]))

        // Drop primary (123, location 9) while keeping secondary (202, location 10), then prune.
        counters.hasMatchingHIDServices = false
        model.voiceFunctionMapper.pruneAppliedServices()
        #expect(!model.voiceFunctionMapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(model.voiceFunctionMapper.powerSuppressedLocationIDs == Set([10]))

        // Dropping the last remaining service clears all applied state (`needsReapply` is false until a service returns).
        counters.secondaryService.enabled = false
        model.voiceFunctionMapper.pruneAppliedServices()
        #expect(!model.voiceFunctionMapper.hasMatchingServices)
        #expect(!model.voiceFunctionMapper.isApplied)
        #expect(!model.voiceFunctionMapper.isPowerKeySuppressed)
        #expect(model.voiceFunctionMapper.powerSuppressedLocationIDs == nil)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: true
        ))

        // Reconnecting the pruned primary service (123) forces reapplication.
        counters.secondaryService.enabled = true
        counters.hasMatchingHIDServices = true
        counters.hidMappings = []
        #expect(model.voiceFunctionMapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(!model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: true
        ))
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)

        // When appliedConfiguration is nil (e.g. duplicate registryID), pruneAppliedServices still clears stale flags.
        counters.secondaryService.registryID = counters.primaryRegistryID
        #expect(model.voiceFunctionMapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(model.voiceFunctionMapper.isVoiceKeyNeutralized)
        model.voiceFunctionMapper.pruneAppliedServices()
        #expect(!model.voiceFunctionMapper.isApplied)
        #expect(!model.voiceFunctionMapper.isPowerKeySuppressed)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
    }

    @Test func pureFunctionModeRevalidatesPowerSuppressionOnlyWhenCustomMappingEnabled() throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .function,
            voiceTool: .unselected,
            hasMatchingHIDServices: true,
            secondaryServiceEnabled: false
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        #expect(!model.shouldNeutralizeNativeVoiceKey)
        #expect(!model.voiceFunctionMapper.isVoiceKeyNeutralized)
        #expect(model.voiceFunctionMapper.isPowerKeySuppressed)
        let initialWrites = counters.setMappingsCount

        // Steady state with customMappingEnabled skips teardown and extra writes.
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == initialWrites)

        // Late second service without power-key suppression is caught and patched on voice start.
        counters.secondaryService.enabled = true
        counters.secondaryService.mappings = []
        counters.recordedWrites.removeAll()
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == initialWrites + 2)
        let secondaryWrite = try #require(counters.recordedWrites.last(where: { $0.registryID == 202 }))
        #expect(secondaryWrite.mappings.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey))
        #expect(model.hidAllowedLocationIDs == Set([9, 10]))

        // Turning off customMappingEnabled skips live service probing during voice start altogether.
        harness.settings.customMappingEnabled = false
        model.applyHIDSettings()
        let probesBeforeDisabledVoice = counters.serviceProviderCallCount
        let writesBeforeDisabledVoice = counters.setMappingsCount
        harness.startAndVerifyVoice()
        #expect(counters.serviceProviderCallCount == probesBeforeDisabledVoice)
        #expect(counters.setMappingsCount == writesBeforeDisabledVoice)
    }

    @Test func partialMappingOptionsDuplicateRegistryIDAndNilRegistryIDWithoutNeutralization() throws {
        let harness = try makeHarness(
            customMappingEnabled: false,
            voiceKeyMode: .leftCommand,
            voiceTool: .unselected,
            hasMatchingHIDServices: true
        )
        defer { harness.cleanup() }
        let mapper = harness.model.voiceFunctionMapper
        let counters = harness.counters

        // 1. suppressPowerKey: false + neutralizeVoiceKey: true applies and validates cleanly.
        #expect(mapper.isVoiceKeyNeutralized)
        #expect(!mapper.isPowerKeySuppressed)
        #expect(!mapper.needsReapply(suppressPowerKey: false, neutralizeVoiceKey: true))

        // 2. suppressPowerKey: true + neutralizeVoiceKey: false leaves voice key unneutralized and suppresses power.
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(!mapper.isVoiceKeyNeutralized)
        #expect(mapper.isPowerKeySuppressed)
        #expect(!mapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(mapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: false
        ))

        // 3. Duplicate registryID across two services leaves appliedConfiguration nil -> every consecutive voice start reapplies.
        counters.secondaryService.enabled = true
        counters.secondaryService.registryID = counters.primaryRegistryID
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(mapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(!mapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: false
        ))

        harness.settings.customMappingEnabled = true
        harness.settings.voiceKeyMode = .function
        harness.model.applyHIDSettings()
        let writesBeforeConsecutiveDuplicateVoice = counters.setMappingsCount
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeConsecutiveDuplicateVoice + 2)
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeConsecutiveDuplicateVoice + 4)

        // Restoring distinct registryIDs restores steady-state reuse across consecutive voice starts.
        counters.secondaryService.registryID = 202
        harness.model.applyHIDSettings()
        let writesBeforeUniqueReuse = counters.setMappingsCount
        harness.startAndVerifyVoice()
        harness.startAndVerifyVoice()
        #expect(counters.setMappingsCount == writesBeforeUniqueReuse)

        // 4. nil registryID without voice neutralization skips unidentifiable service without caching appliedConfiguration.
        counters.secondaryService.enabled = false
        counters.primaryRegistryID = nil
        #expect(!mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(mapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: false))
    }

    @Test func candidateAvailableAndConnectedRefreshCoalescesDefersFlushesAndCancelsStaleWork() async throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .leftCommand,
            voiceTool: .unselected,
            hasMatchingHIDServices: true,
            secondaryServiceEnabled: false
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters

        #expect(counters.hidMappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))

        let monitor = try #require(model.hidMonitors["test-remote"])
        let profileID = try #require(harness.settings.selectedRemoteProfileID)

        // During an active voice session, candidate callbacks defer instead of dropping the refresh,
        // wait out flush attempts while active, and apply on endVoiceSessionIfNeeded.
        model.beginVoiceSessionIfNeeded()
        #expect(model.isStreaming)
        counters.secondaryService.enabled = true
        counters.secondaryService.mappings = [RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey]
        let writesDuringActiveVoice = counters.setMappingsCount

        monitor.onCandidateAvailable?()
        #expect(model.pendingHIDServiceMappingRefresh)
        model.flushPendingHIDServiceMappingRefreshIfNeeded()
        #expect(model.pendingHIDServiceMappingRefresh)
        #expect(counters.setMappingsCount == writesDuringActiveVoice)

        model.endVoiceSessionIfNeeded(flushAudio: false)
        #expect(!model.pendingHIDServiceMappingRefresh)
        #expect(counters.secondaryService.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(model.hidAllowedLocationIDs == Set([9, 10]))

        // Coalesces multiple rapid triggers while idle into a single async refresh pass (1 needsReapply + 1 apply).
        counters.secondaryService.mappings = []
        let callsBeforeRefresh = counters.serviceProviderCallCount
        let writesBeforeRefresh = counters.setMappingsCount
        monitor.onCandidateAvailable?()
        monitor.onCandidateAvailable?()
        monitor.onDeviceConnected?(profileID, "test-remote")
        #expect(model.pendingHIDServiceMappingRefresh)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(!model.pendingHIDServiceMappingRefresh)
        #expect(counters.secondaryService.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))
        #expect(counters.secondaryService.mappings.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey))
        #expect(counters.serviceProviderCallCount == callsBeforeRefresh + 2)
        #expect(counters.setMappingsCount == writesBeforeRefresh + 2)

        // Sleeping retains deferred refresh flag and flushes once wake clears suspension.
        counters.secondaryService.mappings = []
        model.handleSystemAudioLifecycle(.systemWillSleep)
        monitor.onCandidateAvailable?()
        #expect(model.pendingHIDServiceMappingRefresh)
        model.handleSystemAudioLifecycle(.systemDidWake)
        #expect(!model.pendingHIDServiceMappingRefresh)
        #expect(counters.secondaryService.mappings.contains(RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey))

        // stop() generation bump invalidates queued async closures even if started and pendingHIDServiceMappingRefresh
        // are re-armed before the stale main-queue closure runs.
        counters.secondaryService.mappings = []
        monitor.onCandidateAvailable?()
        #expect(model.pendingHIDServiceMappingRefresh)
        model.stop()
        #expect(!model.pendingHIDServiceMappingRefresh)
        let writesAfterStop = counters.setMappingsCount
        model.started = true
        model.pendingHIDServiceMappingRefresh = true
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(counters.setMappingsCount == writesAfterStop)
        #expect(model.pendingHIDServiceMappingRefresh)
        #expect(counters.secondaryService.mappings.isEmpty)
        model.pendingHIDServiceMappingRefresh = false

        // prepareForTermination() blocks further queueing.
        model.prepareForTermination()
        monitor.onCandidateAvailable?()
        #expect(!model.pendingHIDServiceMappingRefresh)
    }

    @Test func dualPendingFlagsCoalesceAndEmptyServiceRefreshSchedulesRecovery() async throws {
        let harness = try makeHarness(
            customMappingEnabled: true,
            voiceKeyMode: .function,
            voiceTool: .unselected,
            hasMatchingHIDServices: true,
            secondaryServiceEnabled: false
        )
        defer { harness.cleanup() }
        let model = harness.model
        let counters = harness.counters
        let monitor = try #require(model.hidMonitors["test-remote"])

        // 1. Both pendingVoiceToolMappingRefresh and pendingHIDServiceMappingRefresh set while streaming
        // coalesce into a single applyHIDSettings() pass on endVoiceSessionIfNeeded.
        model.beginVoiceSessionIfNeeded()
        counters.secondaryService.enabled = true
        counters.secondaryService.mappings = []
        let writesBeforeVoiceEnd = counters.setMappingsCount
        let probesBeforeVoiceEnd = counters.serviceProviderCallCount
        model.voiceToolDidChange()
        monitor.onCandidateAvailable?()
        #expect(model.pendingVoiceToolMappingRefresh)
        #expect(model.pendingHIDServiceMappingRefresh)
        #expect(counters.setMappingsCount == writesBeforeVoiceEnd)

        model.endVoiceSessionIfNeeded(flushAudio: false)
        #expect(!model.pendingVoiceToolMappingRefresh)
        #expect(!model.pendingHIDServiceMappingRefresh)
        #expect(counters.serviceProviderCallCount == probesBeforeVoiceEnd + 1)
        #expect(counters.setMappingsCount == writesBeforeVoiceEnd + 2)
        #expect(counters.secondaryService.mappings.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey))

        // 2. When flush sees .noServices while custom mapping is enabled, it schedules active recovery instead of dropping silently.
        counters.hasMatchingHIDServices = false
        counters.secondaryService.enabled = false
        model.cancelHIDMappingRecovery(reason: "reset_before_no_services_flush")
        #expect(model.hidMappingRecoveryWorkItem == nil)
        monitor.onCandidateAvailable?()
        #expect(model.pendingHIDServiceMappingRefresh)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!model.pendingHIDServiceMappingRefresh)
        #expect(model.hidMappingRecoveryWorkItem != nil)
        #expect(model.hidMappingRecoveryAttempt == 1)
        model.cancelHIDMappingRecovery(reason: "test_step")

        // 3. Pure .function + customMappingEnabled with empty HID services skips immediate applyHIDSettings
        // on voice start yet still schedules active HID mapping recovery for non-Chromecast profiles.
        #expect(model.voiceFunctionMapper.refreshAppliedMappingsValidity(
            expectedPowerKeySuppression: true,
            expectedVoiceKeyNeutralization: false
        ) == false)
        harness.startAndVerifyVoice()
        #expect(model.hidMappingRecoveryWorkItem != nil)
        #expect(model.hidMappingRecoveryAttempt == 1)
    }
}
