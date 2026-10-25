import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Resumable onboarding") @MainActor
struct OnboardingPauseTests {
    @Test(arguments: [VoiceKeyMode.function, .leftCommand])
    func resumingDictationVoiceTestRestoresTheTrialAndRetainsCancellation(mode: VoiceKeyMode) throws {
        let name = "resume-dictation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = mode
        settings.voiceFnTapModeEnabled = false
        settings.setOnboardingControlSource(.xiaomiRemote)
        settings.setOnboardingVoiceTool(.macosDictation)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .macosDictation, controlSource: .xiaomiRemote
        ))
        settings.beginOnboardingVoiceTrial(plan)
        settings.setOnboardingStep(.voiceTest)
        for _ in 0..<2 {
            let resumed = AppSettings(defaults: defaults)
            #expect(resumed.onboardingStep == .voiceTest)
            #expect(resumed.voiceKeyMode == .function)
            #expect(resumed.voiceFnTapModeEnabled)
            #expect(resumed.stagedVoiceToolBinding == plan.binding)
            #expect(resumed.verifiedVoiceToolBinding == nil)
        }
        let cancelled = AppSettings(defaults: defaults)
        cancelled.discardOnboardingVoiceTrial()
        #expect(cancelled.voiceKeyMode == mode)
        #expect(!cancelled.voiceFnTapModeEnabled)
        #expect(cancelled.stagedVoiceToolBinding == nil)
    }

    @Test func leavingVoiceTestingStillRollsBackAnInterruptedTrial() throws {
        let name = "rollback-dictation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .leftCommand
        settings.voiceFnTapModeEnabled = false
        settings.setOnboardingControlSource(.xiaomiRemote)
        settings.setOnboardingVoiceTool(.macosDictation)
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .macosDictation, controlSource: .xiaomiRemote
        ))
        settings.beginOnboardingVoiceTrial(plan)
        settings.setOnboardingStep(.voiceTool)
        let resumed = AppSettings(defaults: defaults)
        #expect(resumed.voiceKeyMode == .leftCommand)
        #expect(!resumed.voiceFnTapModeEnabled)
        #expect(resumed.stagedVoiceToolBinding == nil)
    }

    @Test(arguments: [OnboardingStep.audio, .permissions, .voiceTest])
    func pausePreservesStepAcrossRelaunchWithoutCompletingValidation(step: OnboardingStep) throws {
        let name = "pause-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingStep(step)
        let model = BridgeAppModel(settings: settings)
        var closes = 0
        let view = OnboardingView(model: model, onPauseSetup: { closes += 1 })
        model.isStreaming = true
        view.pauseIncompleteSetup()
        #expect(closes == 0)
        model.isStreaming = false
        view.pauseIncompleteSetup()
        #expect(closes == 1)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.onboardingStep == step)
        #expect(!restored.isOnboardingComplete)
        #expect(restored.verifiedVoiceToolBinding == nil)
    }
}
