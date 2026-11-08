import Testing
@testable import RemoteBuddy

@Suite("Onboarding permission regression")
struct OnboardingPermissionRegressionTests {
    @Test(arguments: [OnboardingStep.remote, .controls, .audio, .voiceTest])
    func revokedPermissionOverridesLaterStepDiagnostics(step: OnboardingStep) {
        let capabilities = OnboardingCapabilities(bluetoothGranted: true,
            inputMonitoringGranted: true, accessibilityGranted: false,
            voiceSessionStarted: true, voiceSamplesReceived: true,
            voiceSessionEnded: true, transcriptionAppeared: true)
        let context = FirstUseDiagnosticContext(step: step, capabilities: capabilities, hasSelectedAudioUID: true)
        #expect(context.failureReason == .accessibilityPermissionDenied)
        #expect(!OnboardingFlowPolicy.canContinue(from: step, voiceTool: .other, capabilities: capabilities))
        #expect(OnboardingFlowPolicy.recoveryStep(from: step, voiceTool: .other,
            capabilities: capabilities, hasSelectedAudioUID: true) == .permissions)
    }
}
