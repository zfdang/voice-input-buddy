import Testing
@testable import RemoteBuddy

@Suite("Onboarding physical transcript input")
struct OnboardingTranscriptInputTests {
    @Test func unknownAndSyntheticEventsCannotClaimPhysicalInput() {
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: nil, sourceStateID: nil, sourceUnixProcessID: nil))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10, sourceStateID: 0, sourceUnixProcessID: 12))
        #expect(!OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10, sourceStateID: 1, sourceUnixProcessID: 12))
        #expect(OnboardingTranscriptInputPolicy.isConfirmedPhysicalKeyboardInput(
            eventTypeRawValue: 10, sourceStateID: 1, sourceUnixProcessID: 0))
    }

    @Test func manualPasteIsRejectedButSyntheticDictationPasteRemainsAllowed() {
        #expect(OnboardingTranscriptInputPolicy.isManualPaste(eventTypeRawValue: nil,
            sourceStateID: nil, sourceUnixProcessID: nil))
        #expect(OnboardingTranscriptInputPolicy.isManualPaste(eventTypeRawValue: 10,
            sourceStateID: 1, sourceUnixProcessID: 0))
        #expect(!OnboardingTranscriptInputPolicy.isManualPaste(eventTypeRawValue: 10,
            sourceStateID: 0, sourceUnixProcessID: 123))
    }

    @Test func remoteConfirmKeysDoNotCountAsManualTyping() {
        for code: UInt16 in [36, 76] {
            #expect(!OnboardingTranscriptInputPolicy.canEditText(keyCode: code,
                characters: "\r", commandHeld: false))
        }
    }

    @Test func typingAndIMEKeysCountButNavigationAndCopyDoNot() {
        #expect(OnboardingTranscriptInputPolicy.canEditText(keyCode: 0, characters: "a", commandHeld: false))
        #expect(OnboardingTranscriptInputPolicy.canEditText(keyCode: 49, characters: " ", commandHeld: false))
        #expect(OnboardingTranscriptInputPolicy.canEditText(keyCode: 51, characters: nil, commandHeld: false))
        #expect(!OnboardingTranscriptInputPolicy.canEditText(keyCode: 123, characters: "\u{F702}", commandHeld: false))
        #expect(!OnboardingTranscriptInputPolicy.canEditText(keyCode: 8, characters: "c", commandHeld: true))
    }
}
