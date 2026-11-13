import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth held dictation tail") @MainActor
struct BluetoothVoiceHoldStopTests {
    private func makeModel(_ defaults: UserDefaults) -> BridgeAppModel {
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        _ = model.voiceKeyLatch.transition(streaming: true, owner: .bluetooth)
        model.heldVoiceKeyMode = .function
        model.isStreaming = true
        return model
    }

    @Test func remoteStopPreservesHeldKeyAndQueuedTail() throws {
        let suite = "hold-tail-remote-stop-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults)
        let identifier = UUID()
        let bridge = BluetoothRemoteBridge(settings: model.settings, delegate: model,
            targetIdentifier: identifier)
        model.voiceSession.begin(deviceIdentifier: identifier)
        model.audio.output.registerPendingVoiceBuffer()
        model.bluetoothBridgeDidStopVoice(bridge)
        #expect(!model.voiceSession.isActive)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(model.isStreaming)
        #expect(model.voiceSession.pendingKeyRelease?.deviceIdentifier == identifier)
        #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 1)
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        // A repeated stop is harmless while the first one still owns the tail.
        let id = model.voiceSession.pendingKeyRelease?.id
        model.bluetoothBridgeDidStopVoice(bridge)
        #expect(model.voiceSession.pendingKeyRelease?.id == id)
        #expect(model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true }))
        model.audio.output.endSession()
        model.endVoiceSessionIfNeeded(flushAudio: false)
    }

    @Test(arguments: [VirtualAudioDrainOutcome.normal, .forced])
    func releasesKeyOnlyAfterPlaybackCompletes(outcome: VirtualAudioDrainOutcome) throws {
        let suite = "hold-tail-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults)
        var completion: ((VirtualAudioDrainOutcome) -> Void)?
        var releases = 0
        model.finishBluetoothVoicePlayback(deviceIdentifier: UUID(), handledByFnTapMode: false,
            drainAudio: { delay, done in
                #expect(delay >= 0.75)
                completion = done
            }, releaseKey: {
                releases += 1
                #expect(model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true }))
            })
        #expect(releases == 0)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(model.isStreaming)
        #expect(model.isVoiceConfigurationBusy)
        #expect(model.shouldKeepVirtualAudioActive)
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        #expect(!model.canAcceptNewVoiceSession(from: .chromecast))
        let finish = try #require(completion)
        finish(outcome)
        #expect(releases == 1)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(!model.isStreaming)
        #expect(model.voiceSession.pendingKeyRelease == nil)
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
        completion?(.normal)
        #expect(releases == 1)
    }

    @Test func emptyPlaybackQueueDoesNotAddAStopDelay() throws {
        let suite = "hold-tail-empty-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults)
        var releases = 0
        model.finishBluetoothVoicePlayback(deviceIdentifier: UUID(), handledByFnTapMode: false,
            releaseKey: {
                releases += 1
                #expect(model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true }))
            })
        #expect(releases == 1)
        #expect(!model.isStreaming)
        #expect(model.voiceSession.pendingKeyRelease == nil)
    }

    @Test func forcedCleanupInvalidatesCompletionBeforeNextSession() throws {
        let suite = "hold-tail-cancel-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults)
        var completion: ((VirtualAudioDrainOutcome) -> Void)?
        model.finishBluetoothVoicePlayback(deviceIdentifier: UUID(), handledByFnTapMode: false,
            drainAudio: { _, done in completion = done },
            releaseKey: { Issue.record("Stale drain released the next session") })
        #expect(model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true }))
        #expect(model.voiceSession.pendingKeyRelease == nil)
        model.endVoiceSessionIfNeeded(flushAudio: false)
        _ = model.voiceKeyLatch.transition(streaming: true, owner: .bluetooth)
        model.heldVoiceKeyMode = .function
        model.isStreaming = true
        let finish = try #require(completion)
        finish(.forced)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(model.isStreaming)
        #expect(model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true }))
    }

    @Test func fnTapKeepsItsExistingDrainOwner() throws {
        let suite = "hold-tail-fn-tap-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(defaults)
        var releases = 0
        model.finishBluetoothVoicePlayback(deviceIdentifier: UUID(), handledByFnTapMode: true,
            drainAudio: { _, _ in Issue.record("Fn-tap must own its own drain") },
            releaseKey: {
                releases += 1
                #expect(model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true }))
            })
        #expect(releases == 1)
        #expect(model.voiceSession.pendingKeyRelease == nil)
        #expect(!model.isStreaming)
    }
}
