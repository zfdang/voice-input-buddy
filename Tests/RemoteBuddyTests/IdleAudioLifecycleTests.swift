import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Idle audio releases the sleep blocker")
@MainActor
struct IdleAudioLifecycleTests {
    private func withModel(_ body: (BridgeAppModel, BluetoothRemoteBridge) async throws -> Void) async throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values), initialAudioDevices: [])
        let identifier = UUID()
        let bridge = BluetoothRemoteBridge(settings: model.settings, delegate: model, targetIdentifier: identifier)
        model.connections.bridges[identifier] = bridge
        model.connections.states[ObjectIdentifier(bridge)] = .ready("Test remote")
        defer { model.started = false }
        try await body(model, bridge)
    }

    @Test func connectedRemoteAndWakeDoNotRequireAnAudioEngine() async throws {
        try await withModel { model, _ in
            #expect(model.readyBluetoothBridgeCount == 1)
            #expect(!model.shouldKeepVirtualAudioActive)
            model.started = true
            let generation = model.audio.configurationGeneration
            model.resumeVirtualAudioOutputIfNeeded(reason: "system_screen_did_wake")
            #expect(model.audio.configurationGeneration == generation)
            #expect(!model.audio.output.hasAllocatedOutputResources)
            model.voiceSession.pendingStart.begin(for: UUID())
            #expect(model.shouldKeepVirtualAudioActive)
            model.voiceSession.pendingStart.cancel()
            model.audio.testToneStartupPending = true
            #expect(model.shouldKeepVirtualAudioActive)
            model.cancelTestToneIfNeeded(statusMessage: LocalizedMessage("audio.test_tone.cancelled_device_changed"),
                logReason: "test")
            #expect(!model.shouldKeepVirtualAudioActive)
        }
    }

    @Test func startupValidationSchedulesReleaseEvenWithAConnectedRemote() async throws {
        try await withModel { model, _ in
            model.started = true
            model.audio.startupPending = true
            model.audio.output.registerPendingVoiceBuffer()
            model.finishAudioStartup(generation: 0, configurationGeneration: 0, configured: true, devices: [])
            #expect(!model.audio.startupPending)
            #expect(model.audio.pendingVirtualAudioRelease?.reason == "startup_complete")
            #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 1)
            model.cancelVirtualAudioReleaseIfPending(trigger: "test_cleanup")
        }
    }

    @Test func idleReleaseKeepsTheVerifiedOutputForOnboarding() async throws {
        try await withModel { model, _ in
            model.started = true
            model.isAudioOutputReady = true
            #expect(model.isAudioOutputVerified)
            model.releaseVirtualAudioOutputIfUnused(reason: "test_idle")
            #expect(!model.isAudioOutputReady)
            #expect(model.isAudioOutputVerified)
            model.finishAudioStartup(generation: 0, configurationGeneration: model.audio.configurationGeneration,
                configured: false, devices: [])
            #expect(!model.isAudioOutputVerified)
            // An earlier idle release can stop the engine before a successful result arrives.
            model.finishAudioStartup(generation: 0, configurationGeneration: model.audio.configurationGeneration,
                configured: true, devices: [])
            #expect(!model.isAudioOutputReady)
            #expect(model.isAudioOutputVerified)
            model.cancelVirtualAudioReleaseIfPending(trigger: "test_cleanup")
        }
    }

    @Test(arguments: [false, true])
    func remoteStopDrainsTailAndNewVoicePreventsTeardown(restart: Bool) async throws {
        try await withModel { model, bridge in
            model.voiceSession.begin(deviceIdentifier: try #require(bridge.deviceIdentifier))
            model.isStreaming = true
            model.audio.output.registerPendingVoiceBuffer()
            model.bluetoothBridgeDidStopVoice(bridge)
            #expect(!model.voiceSession.isActive)
            #expect(!model.isStreaming)
            #expect(model.audio.pendingVirtualAudioRelease != nil)
            #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 1)
            if restart {
                model.voiceSession.isActive = true
                model.cancelVirtualAudioReleaseIfPending(trigger: "bluetooth_voice_start")
            }
            try await Task.sleep(for: .milliseconds(850))
            #expect(model.audio.pendingVirtualAudioRelease == nil)
            // The bounded drain releases an abandoned tail, but a fresh session
            // cancels that timer and retains the queued audio.
            #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == (restart ? 1 : 0))
        }
    }

    @Test func fnTapBufferedSpeechKeepsAudioUntilTheSessionFinishes() async throws {
        try await withModel { model, _ in
            let clock = ControlledTestScheduler()
            var drained: (() -> Void)?
            model.voiceFnTapSession = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
                setFunctionKeyPressed: { _ in true }, enqueueAudio: { _ in },
                drainAudio: { _, done in drained = done }, onFailure: { _ in Issue.record("Unexpected failure") })
            model.voiceFnTapSession.setEnabled(true)
            #expect(model.voiceFnTapSession.startVoice())
            #expect(model.voiceFnTapSession.receive([1, 2, 3]))
            #expect(model.shouldKeepVirtualAudioActive)
            clock.advance(to: 270)
            #expect(model.voiceFnTapSession.stopVoice())
            #expect(model.shouldKeepVirtualAudioActive)
            drained?()
            clock.runAll()
            #expect(!model.shouldKeepVirtualAudioActive)
        }
    }
}
