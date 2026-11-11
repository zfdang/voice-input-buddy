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

    @Test func systemSleepReleasesHIDMonitoringBlocksRestartAndRestoresOnWake() throws {
        let name = "sleep-hid-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.started = true
        defer {
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            model.started = false
        }

        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: nil,
            eventSuppressor: model.hidEventSuppressor,
            ownsEventSuppressor: false,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "test-remote", profileID: UUID())
        var resets = 0
        monitor.onInputReset = { _ in resets += 1 }
        model.hidMonitors["test-remote"] = monitor
        model.discoveryHIDMonitor = monitor
        model.activeRemoteButtons = [.right]

        let bridgeID = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: bridgeID)
        model.connections.bridges[bridgeID] = bridge
        model.connections.states[ObjectIdentifier(bridge)] = .ready("Test remote")
        model.scheduleHIDMappingRecoveryIfNeeded()
        #expect(model.hidMappingRecoveryWorkItem != nil)

        var hidRestores = 0
        var btRecoveries: [String] = []
        model.handleSystemAudioLifecycle(
            .systemWillSleep,
            applyHID: { hidRestores += 1 },
            recoverBluetooth: { btRecoveries.append($0) }
        )

        #expect(resets == 2)
        #expect(model.hidMonitors.isEmpty)
        #expect(model.discoveryHIDMonitor == nil)
        #expect(model.activeRemoteButtons.isEmpty)
        #expect(model.hidMonitoringInterrupted)
        #expect(model.hidMappingRecoveryWorkItem == nil)

        // Attempted HID start or recovery scheduling during sleep must remain inert.
        model.startHIDMonitors(powerKeySuppressed: false)
        model.scheduleHIDMappingRecoveryIfNeeded()
        #expect(model.hidMonitors.isEmpty)
        #expect(!model.hidEventSuppressor.isRunning)
        #expect(model.hidMappingRecoveryWorkItem == nil)
        #expect(hidRestores == 0)

        model.handleSystemAudioLifecycle(
            .systemDidWake,
            applyHID: { hidRestores += 1 },
            recoverBluetooth: { btRecoveries.append($0) }
        )
        #expect(hidRestores == 1)
        #expect(btRecoveries == ["system_wake"])
        monitor.onInputReset = nil
    }

    @Test func staggeredWakePreservesPendingSystemWakeBluetoothAndHIDRecovery() throws {
        let name = "staggered-wake-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.started = true
        defer { model.started = false }

        var hidRestores = 0
        var btRecoveries: [String] = []
        let send = { (event: SystemAudioLifecycleEvent) in
            model.handleSystemAudioLifecycle(
                event,
                applyHID: { hidRestores += 1; model.hidMonitoringInterrupted = false },
                recoverBluetooth: { btRecoveries.append($0) }
            )
        }

        // Typical macOS sequence: screen sleeps first, then system sleeps, then system wakes
        // (or DarkWakes) before screen wakes.
        send(.screenDidSleep)
        send(.systemWillSleep)
        #expect(!model.audio.pendingSystemWakeRecovery)
        #expect(model.hidMonitoringInterrupted)

        send(.systemDidWake)
        #expect(model.audio.suspensionState.isSuspended)
        #expect(model.audio.pendingSystemWakeRecovery)
        #expect(hidRestores == 0)
        #expect(btRecoveries.isEmpty)

        // A DarkWake returning to sleep supersedes an unconsumed wake flag.
        send(.systemWillSleep)
        #expect(!model.audio.pendingSystemWakeRecovery)

        // Next wake sequence completes once screenDidWake clears the last suspension reason.
        send(.systemDidWake)
        #expect(model.audio.pendingSystemWakeRecovery)
        #expect(btRecoveries.isEmpty)

        send(.screenDidWake)
        #expect(!model.audio.suspensionState.isSuspended)
        #expect(!model.audio.pendingSystemWakeRecovery)
        #expect(!model.hidMonitoringInterrupted)
        #expect(hidRestores == 1)
        #expect(btRecoveries == ["system_wake"])
    }

    @Test func systemWakeRemainsDeferredUntilInactiveSessionBecomesActive() throws {
        let name = "session-deferred-wake-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.started = true
        defer { model.started = false }

        var hidRestores = 0
        var btRecoveries: [String] = []
        let send = { (event: SystemAudioLifecycleEvent) in
            model.handleSystemAudioLifecycle(
                event,
                applyHID: { hidRestores += 1; model.hidMonitoringInterrupted = false },
                recoverBluetooth: { btRecoveries.append($0) }
            )
        }

        send(.sessionDidResignActive)
        send(.systemWillSleep)
        send(.systemDidWake)
        #expect(model.audio.suspensionState.suspendsHIDMonitoring)
        #expect(model.audio.pendingSystemWakeRecovery)
        #expect(hidRestores == 0)
        #expect(btRecoveries.isEmpty)

        send(.sessionDidBecomeActive)
        #expect(!model.audio.suspensionState.isSuspended)
        #expect(!model.audio.pendingSystemWakeRecovery)
        #expect(hidRestores == 1)
        #expect(btRecoveries == ["system_wake"])
    }
}
