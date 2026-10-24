import Testing
@testable import VoiceInputBuddy

@Suite("macOS Dictation tool")
struct MacOSDictationToolTests {
    private func session(
        clock: ControlledTestScheduler,
        edges: @escaping (Bool) -> Void,
        samples: @escaping ([Int16]) -> Void = { _ in }
    ) -> VoiceFnTapSessionController {
        let session = VoiceFnTapSessionController(startTapCount: { 2 }, schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { edges($0); return true }, enqueueAudio: samples,
            drainAudio: { _, done in done() }, onFailure: { _ in Issue.record("Unexpected failure") })
        session.setEnabled(true)
        return session
    }

    @Test func doublePressStartsAndOnePressStops() {
        let clock = ControlledTestScheduler()
        var edges: [Bool] = []
        var samples: [[Int16]] = []
        let session = session(clock: clock, edges: { edges.append($0) }, samples: { samples.append($0) })
        #expect(session.startVoice())
        #expect(session.receive([1, 2]))
        clock.advance(to: 270)
        #expect(edges == [true, false])
        #expect(session.phase != .idle)
        #expect(samples.isEmpty)
        clock.advance(to: 540)
        #expect(edges == [true, false, true, false])
        #expect(samples == [[1, 2]])
        #expect(session.stopVoice())
        clock.runAll()
        #expect(edges == [true, false, true, false, true, false])
        #expect(session.phase == .idle)
    }

    @Test func releaseBetweenStartTapsFinishesTheSequenceThenStops() {
        let clock = ControlledTestScheduler()
        var edges: [Bool] = []
        let session = session(clock: clock, edges: { edges.append($0) })
        #expect(session.startVoice())
        clock.advance(to: 300)
        #expect(edges == [true, false])
        // A lone press would pair with the next session's first press.
        #expect(session.stopVoice())
        #expect(session.phase != .idle)
        clock.runAll()
        #expect(edges == [true, false, true, false, true, false])
        #expect(session.phase == .idle)
    }

    @Test func dictationUsesFnTapConversionWithAToggleBinding() throws {
        #expect(OnboardingVoiceTool.macosDictation.functionKeyStartTapCount == 2)
        #expect(OnboardingVoiceTool.other.functionKeyStartTapCount == 1)
        #expect(!OnboardingVoiceTool.macosDictation.supportsHoldVoiceRecording)
        #expect(!OnboardingVoiceTool.macosDictation.requiresFunctionKeySetup)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .macosDictation, controlSource: .chromecastRemote
        ))
        #expect(plan.binding.shortcut == .function)
        #expect(plan.binding.gestureMode == .toggle)
        #expect(plan.fnTapModeEnabled)
    }
}
