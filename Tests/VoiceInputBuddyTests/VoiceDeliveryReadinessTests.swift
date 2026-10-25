import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Voice delivery after asynchronous configuration")
struct VoiceDeliveryReadinessTests {
    private func attempt() -> VoiceAudioDeliveryDiagnostic {
        var value = VoiceAudioDeliveryDiagnostic(generation: 1, route: .virtualAudioDirect,
            sessionEnded: true, receivedSamples: 22_560)
        value.outputAtObservation = VirtualAudioOutputDiagnosticSnapshot(
            selectedDeviceKind: .buddyMic, actualDeviceKind: .buddyMic,
            engineRunning: true, playerPlaying: true, boundToSelectedDevice: true,
            pendingBuffers: 4, pendingSamples: 960,
            counters: VirtualAudioPlaybackCounters(scheduledSamples: 22_560, playedSamples: 21_600))
        return value
    }

    @Test func coldStartWaitsForTailAndPassesWithoutReplacingHistoricalSnapshot() {
        var value = attempt()
        #expect(value.outputAtStart.selectedDeviceKind == .unavailable)
        #expect(value.result == .playbackPending)
        #expect(terminal(value, final: false) != .audioDeliveryFailed)
        value.outputAtObservation.pendingBuffers = 0
        value.outputAtObservation.pendingSamples = 0
        value.outputAtObservation.counters.playedSamples = 22_560
        #expect(value.result == .deliveredToSelectedDevice)
        #expect(terminal(value, final: false) == .passed)
        #expect(value.outputAtStart.selectedDeviceKind == .unavailable)
    }

    @Test(arguments: [false, true])
    func transientReadinessAndBindingWaitUntilDeadline(binding: Bool) {
        var value = attempt()
        if binding { value.outputAtObservation.boundToSelectedDevice = false }
        else { value.outputAtObservation.engineRunning = false }
        #expect(!value.result.isConfirmedFailure)
        #expect(terminal(value, final: false) != .audioDeliveryFailed)
        #expect(terminal(value, final: true) == .audioDeliveryFailed)
    }

    @Test func lostOrInterruptedAudioRemainsFailureAfterRecovery() {
        var value = attempt()
        value.enqueueFailures = 1
        #expect(terminal(value, final: false) == .audioDeliveryFailed)
        value.enqueueFailures = 0
        value.outputAtObservation.counters.interruptedSamples = 240
        #expect(terminal(value, final: false) == .audioDeliveryFailed)
    }

    @Test func incompleteAndPendingPlaybackCannotPassAtDeadline() {
        var value = attempt()
        #expect(terminal(value, final: true) == .audioDeliveryFailed)
        value.outputAtObservation.pendingSamples = 0
        #expect(value.result == .playbackIncomplete)
        #expect(terminal(value, final: true) == .audioDeliveryFailed)
    }

    @Test func completedDeliverySurvivesIdleTeardownUntilTranscriptArrives() {
        var value = attempt()
        value.outputAtObservation.pendingBuffers = 0
        value.outputAtObservation.pendingSamples = 0
        value.outputAtObservation.counters.playedSamples = value.receivedSamples
        let delivered = value.outputAtObservation
        #expect(value.result == .deliveredToSelectedDevice)
        value.observeOutput(VirtualAudioOutputDiagnosticSnapshot(counters: delivered.counters))
        #expect(value.outputAtObservation == delivered)
        #expect(terminal(value, final: true) == .passed)
    }

    @Test(arguments: ["pending", "interrupted", "wrong_route"])
    func idleTeardownCannotConvertUnverifiedDeliveryToSuccess(failure: String) {
        var value = attempt()
        if failure == "interrupted" { value.outputAtObservation.counters.interruptedSamples = 240 }
        if failure == "wrong_route" { value.outputAtObservation.boundToSelectedDevice = false }
        value.observeOutput(VirtualAudioOutputDiagnosticSnapshot(counters: value.outputAtObservation.counters))
        #expect(value.result != .deliveredToSelectedDevice)
        #expect(terminal(value, final: true) == .audioDeliveryFailed)
    }

    @Test @MainActor func completedModelSnapshotDoesNotLeakIntoTheNextVoiceSession() throws {
        let name = "completed-delivery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        var value = attempt()
        value.outputAtObservation.pendingBuffers = 0
        value.outputAtObservation.pendingSamples = 0
        value.outputAtObservation.counters.playedSamples = value.receivedSamples
        model.voiceSession.voiceAudioDeliveryDiagnostic = value
        model.preserveCompletedVoiceAudioDelivery()
        #expect(model.voiceAudioDeliveryDiagnosticSnapshot().result == .deliveredToSelectedDevice)
        model.beginVoiceSessionIfNeeded()
        #expect(model.voiceAudioDeliveryDiagnosticSnapshot().result == .receiving)
        #expect(model.voiceAudioDeliveryDiagnosticSnapshot().receivedSamples == 0)
    }

    private func terminal(_ value: VoiceAudioDeliveryDiagnostic, final: Bool) -> FirstUseVoiceAttemptResult {
        FirstUseVoiceAttemptPolicy.terminalResultAfterSession(manualInputObserved: false,
            samplesReceived: true, transcriptionAppeared: true, triggerReady: true,
            focusReadyAtDeadline: true, audioDeliveryResult: value.result, finalObservation: final)
    }
}
