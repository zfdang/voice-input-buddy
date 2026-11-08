import Testing
@testable import RemoteBuddy

@Suite("Fn quick release")
struct VoiceFnQuickReleaseTests {
    @Test func releaseBeforeStartDelayCancelsBothPulsesAndStaleCallbacks() {
        let clock = ControlledTestScheduler()
        var edges: [Bool] = []
        var samples: [[Int16]] = []
        let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { edges.append($0); return true }, enqueueAudio: { samples.append($0) },
            drainAudio: { _, done in done() }, onFailure: { _ in Issue.record("Unexpected failure") })
        session.setEnabled(true)
        #expect(session.startVoice())
        #expect(session.receive([1, 2]))
        #expect(session.stopVoice())
        #expect(session.phase == .idle)
        clock.tasks.forEach { $0.fire(includingCancelled: true) }
        #expect(edges.isEmpty)
        #expect(samples.isEmpty)
        #expect(session.startVoice())
        clock.advance(to: 150)
        #expect(edges == [true])
        clock.advance(to: 270)
        #expect(edges == [true, false])
        #expect(session.stopVoice())
        clock.runAll()
        #expect(session.phase == .idle)
    }
}
