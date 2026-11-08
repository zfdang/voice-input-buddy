import Foundation
import Testing
@testable import RemoteBuddy

/// Drives the session controller into the production playback admission/chunking
/// boundary, with only hardware scheduling and keyboard injection replaced.
@Suite("Voice pipeline integration")
struct VoicePipelineIntegrationTests {
    private final class PlaybackSink {
        var pending = 0
        var preRoll = 0
        var played: [Int16] = []
        var rejected = 0

        func enqueue(_ samples: [Int16], isPreRoll: Bool) {
            guard VoicePlaybackQueueCapacity.admits(pending: pending, incoming: samples.count,
                pendingPreRoll: preRoll, isPreRoll: isPreRoll) else { rejected += 1; return }
            pending += samples.count
            if isPreRoll { preRoll += samples.count }
            for chunk in VoicePlaybackQueueCapacity.chunks(samples) { played.append(contentsOf: chunk) }
        }
    }

    @Test(arguments: [12_000, 32_000, 80_000])
    func bufferedSpeechTraversesSessionAndPlaybackBoundaryWithoutDroppingSamples(count: Int) {
        let clock = ControlledTestScheduler()
        let sink = PlaybackSink()
        var drainCompletion: (() -> Void)?
        var keys: [Bool] = []
        let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { keys.append($0); return true },
            enqueueAudio: { sink.enqueue($0, isPreRoll: false) },
            drainAudio: { _, done in drainCompletion = done },
            onFailure: { _ in Issue.record("Unexpected key failure") },
            enqueuePreRollAudio: { sink.enqueue($0, isPreRoll: true) },
            pendingPlaybackDuration: { Double(sink.pending) / 16_000 })
        session.setEnabled(true)
        #expect(session.startVoice())
        let samples = (0..<count).map { Int16($0 % 30_000) }
        #expect(session.receive(samples))
        #expect(sink.played.isEmpty)
        clock.advance(to: 270)
        #expect(sink.played == samples)
        #expect(sink.rejected == 0)
        #expect(session.receive([7, 8, 9]))
        #expect(sink.played == samples + [7, 8, 9])
        #expect(session.stopVoice())
        guard case .draining = session.phase else { Issue.record("Must wait for playback"); return }
        if count == 80_000 {
            clock.advance(to: 2_500)
            guard case .draining = session.phase else { Issue.record("Five seconds of audio was cut off"); return }
            #expect(keys == [true, false])
        }
        drainCompletion?()
        clock.runAll()
        #expect(session.phase == .idle)
        #expect(keys == [true, false, true, false])
    }

    @Test func stalePlaybackCompletionCannotStopTheNextSession() {
        let clock = ControlledTestScheduler()
        var completions: [() -> Void] = []
        var keys: [Bool] = []
        let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { keys.append($0); return true }, enqueueAudio: { _ in },
            drainAudio: { _, done in completions.append(done) },
            onFailure: { _ in Issue.record("Unexpected key failure") })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 270)
        #expect(session.stopVoice())
        completions[0]()
        clock.advance(to: 390)
        #expect(session.startVoice())
        clock.advance(to: 660)
        let currentPhase = session.phase
        completions[0]()
        clock.tasks.filter { $0.cancelled }.forEach { $0.fire(includingCancelled: true) }
        #expect(session.phase == currentPhase)
        #expect(keys == [true, false, true, false, true, false])
        #expect(session.stopVoice())
        completions[1]()
        clock.runAll()
        #expect(session.phase == .idle)
    }
}
