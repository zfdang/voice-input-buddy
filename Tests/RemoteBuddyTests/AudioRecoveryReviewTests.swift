import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Audio recovery review regressions")
@MainActor
struct AudioRecoveryReviewTests {
    @Test func stoppedActiveOutputRequestsRecoveryWithoutTheDebounceGap() async throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.voiceSession.isActive = true
        defer { model.started = false }
        var delays: [TimeInterval] = []
        model.scheduleAudioRecovery(reason: "engine_configuration_change", schedule: { delay, _ in delays.append(delay) })
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(delays == [0])
    }

    @Test(arguments: ["hardware_change", "engine_configuration_change"])
    func healthySelectedOutputKeepsActiveAndQueuedSpeech(reason: String) throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        model.voiceSession.isActive = true
        model.audio.output.registerPendingVoiceBuffer()
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Test Mic")
        let healthy = VirtualAudioOutputDiagnosticSnapshot(engineRunning: true,
            playerPlaying: true, boundToSelectedDevice: true, pendingBuffers: 1, pendingSamples: 32_000)
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: reason, details: "properties=devices",
            devices: [device], outputSnapshot: healthy, configureOutput: { _ in reconfigurations += 1 })
        #expect(reconfigurations == 0)
        #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 1)
        #expect(model.voiceSession.isActive)
        // Cached health is not sufficient after the selected device disappears.
        model.completeAudioRecoveryDeviceRefresh(generation: 0, reason: reason, details: "properties=devices",
            devices: [], outputSnapshot: healthy, configureOutput: { _ in reconfigurations += 1 })
        #expect(reconfigurations == 1)
        model.completeAudioRecoveryDeviceRefresh(generation: 99, reason: reason, details: "",
            devices: [], configureOutput: { _ in reconfigurations += 1 })
        #expect(reconfigurations == 1)
    }

    @Test func unhealthyActiveEngineStillRecoversAndBoundIdleEngineDoesNotLoop() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(boundToSelectedDevice: true,
            configurationHealthy: false, hasActiveAudioSource: true, pendingVoiceBufferCount: 1))
        #expect(!AudioEngineConfigurationChangePolicy.needsRecovery(boundToSelectedDevice: true,
            configurationHealthy: false, hasActiveAudioSource: false, pendingVoiceBufferCount: 0))
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(boundToSelectedDevice: false,
            configurationHealthy: false, hasActiveAudioSource: false, pendingVoiceBufferCount: 0))
    }

    @Test func inaudibleVirtualDeviceTriggersRecoveryEvenWhenEngineAndPlayerAreRunning() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Remote Buddy Mic")
        let inaudible = VirtualAudioOutputDiagnosticSnapshot(
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            audibilityHealthy: false,
            pendingBuffers: 0,
            pendingSamples: 0
        )
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(
            generation: 0,
            reason: "hardware_change",
            details: "properties=device_mute",
            devices: [device],
            outputSnapshot: inaudible,
            configureOutput: { _ in reconfigurations += 1 }
        )
        #expect(reconfigurations == 1)
    }

    @Test func normalVolumeAdjustmentKeepsAudioOutputReadyAndDoesNotTriggerReconfiguration() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        model.isAudioOutputReady = true
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Test Mic")
        let healthy = VirtualAudioOutputDiagnosticSnapshot(
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            audibilityHealthy: true,
            pendingBuffers: 0,
            pendingSamples: 0
        )
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(
            generation: 0,
            reason: "hardware_change",
            details: "properties=device_volume",
            devices: [device],
            outputSnapshot: healthy,
            configureOutput: { _ in reconfigurations += 1 }
        )
        #expect(reconfigurations == 0)
        #expect(model.isAudioOutputReady)
    }

    @Test func healthyVolumeAfterPriorUnreadyRestoresAudioOutputReady() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        model.isAudioOutputReady = false
        let device = AudioDeviceInfo(id: 101, uid: model.settings.selectedAudioDeviceUID, name: "Test Mic")
        let healthy = VirtualAudioOutputDiagnosticSnapshot(
            engineRunning: true,
            playerPlaying: true,
            boundToSelectedDevice: true,
            audibilityHealthy: true,
            pendingBuffers: 0,
            pendingSamples: 0
        )
        var reconfigurations = 0
        model.completeAudioRecoveryDeviceRefresh(
            generation: 0,
            reason: "hardware_change",
            details: "properties=device_volume",
            devices: [device],
            outputSnapshot: healthy,
            configureOutput: { _ in reconfigurations += 1 }
        )
        #expect(reconfigurations == 0)
        #expect(model.isAudioOutputReady)
    }

    @Test func invalidationDuringQueryCannotRestoreStaleAudibility() async {
        let cache = AudibilityCache()
        let queryStarted = DispatchSemaphore(value: 0)
        let resumeQuery = DispatchSemaphore(value: 0)
        let firstResult = Task.detached {
            var calls = 0
            return cache.value(for: 101, at: 10) {
                calls += 1
                if calls == 1 {
                    queryStarted.signal()
                    resumeQuery.wait()
                    return false
                }
                return true
            }
        }
        #expect(queryStarted.wait(timeout: .now() + 5) == .success)
        cache.invalidate()
        let current = cache.value(for: 101, at: 10) { true }
        resumeQuery.signal()
        #expect(await firstResult.value)
        #expect(current)
        #expect(cache.value(for: 101, at: 10) { false })
    }

    @Test func audibilityCachePartitionsDevicesAndExpires() {
        let cache = AudibilityCache()
        #expect(cache.value(for: 101, at: 10) { true })
        #expect(cache.value(for: 101, at: 11) { false })
        #expect(!cache.value(for: 102, at: 11) { false })
        #expect(cache.value(for: 102, at: 13) { true })
    }
}
