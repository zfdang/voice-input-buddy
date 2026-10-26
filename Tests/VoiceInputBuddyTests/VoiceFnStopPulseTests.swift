import Testing
@testable import VoiceInputBuddy

@Suite("Voice presses during stop pulses")
struct VoiceFnStopPulseTests {
    @Test(arguments: [1, 2], [false, true])
    func queuedPressWaitsForReleaseAndPreservesItsAudio(startTaps: Int, quickRelease: Bool) {
        let clock = ControlledTestScheduler()
        var edges: [Bool] = []
        var audio: [[Int16]] = []
        let session = VoiceFnTapSessionController(startTapCount: { startTaps },
            maximumPreRollSampleCount: 4, schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { edges.append($0); return true },
            enqueueAudio: { audio.append($0) }, drainAudio: { _, done in done() },
            onFailure: { _ in Issue.record("Unexpected key failure") })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 500)
        #expect(session.stopVoice())
        guard case .stopping = session.phase else { Issue.record("Expected stop pulse"); return }
        let priorEdges = edges
        #expect(session.startVoice())
        #expect(session.receive([1, 2, 3]))
        #expect(session.receive([4, 5, 6]))
        if quickRelease { #expect(session.stopVoice()) }
        clock.advance(to: 619)
        #expect(edges == priorEdges)
        #expect(audio.isEmpty)
        clock.runAll()
        #expect(audio == [[3, 4, 5, 6]])
        if !quickRelease {
            guard case .active = session.phase else { Issue.record("Queued press was lost"); return }
            #expect(session.stopVoice())
            clock.runAll()
        }
        #expect(session.phase == .idle)
        #expect(edges == Array(repeating: [true, false], count: 2 * (startTaps + 1)).flatMap { $0 })
    }

    @Test func failedOldStopReleaseCannotStartQueuedVoice() {
        let clock = ControlledTestScheduler()
        var allowRelease = true
        var downs = 0
        var audio: [[Int16]] = []
        let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { down in
                if down { downs += 1 }
                return down || allowRelease
            }, enqueueAudio: { audio.append($0) }, drainAudio: { _, done in done() }, onFailure: { _ in })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 500)
        #expect(session.stopVoice())
        #expect(session.startVoice())
        #expect(session.receive([7, 8]))
        allowRelease = false
        clock.advance(to: 620)
        #expect(downs == 2)
        #expect(audio.isEmpty)
        #expect(session.requiresCleanupBeforeMapping)
        allowRelease = true
        clock.runAll()
        #expect(downs == 2)
        #expect(!session.requiresCleanupBeforeMapping)
    }
}
