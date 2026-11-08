import CoreAudio
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Runtime ownership")
@MainActor
struct RuntimeOwnershipTests {
    @Test func endingVoiceDiscardsPendingStartsAndCommandAudio() {
        let session = VoiceSessionRuntime()
        let identifier = UUID()
        let operation = session.pendingStart.begin(for: identifier)
        session.begin(deviceIdentifier: identifier)
        session.commandAudio.begin()
        let buffered = session.commandAudio.appendIfWaiting([1, 2, 3])
        #expect(buffered)
        session.stopRequested = true
        session.end()
        #expect(!session.isActive)
        #expect(session.activeDeviceIdentifier == nil)
        #expect(!session.stopRequested)
        #expect(!session.pendingStart.matches(identifier: identifier, operationID: operation))
        let remaining = session.commandAudio.drain()
        #expect(remaining.isEmpty)
        session.begin(deviceIdentifier: UUID())
        #expect(session.pendingStart.drain().isEmpty)
    }

    @Test func invalidationCancelsRecoveryAndInvalidatesEveryCompletionToken() {
        let runtime = AudioRuntime()
        let work = DispatchWorkItem {}
        runtime.recoveryWorkItem = work
        runtime.startupPending = true
        runtime.pendingVirtualAudioRelease = (0, "test")
        runtime.recoveryCoalescingState.recordEvent(reason: "hardware_change")
        runtime.invalidatePendingWork()
        #expect(work.isCancelled)
        #expect(runtime.recoveryWorkItem == nil)
        #expect(!runtime.startupPending)
        #expect(runtime.configurationGeneration == 1)
        #expect(runtime.startupGeneration == 1)
        #expect(runtime.deviceRefreshGeneration == 1)
        #expect(runtime.recoveryGeneration == 1)
        #expect(runtime.virtualAudioReleaseGeneration == 1)
        #expect(runtime.pendingVirtualAudioRelease == nil)
        #expect(runtime.recoveryCoalescingState.consumePendingEvents().count == 0)
    }

    @Test func releasingAudioOwnerCancelsPendingRecovery() {
        let work = DispatchWorkItem {}
        var runtime: AudioRuntime? = AudioRuntime()
        runtime?.recoveryWorkItem = work
        runtime = nil
        #expect(work.isCancelled)
    }
}
