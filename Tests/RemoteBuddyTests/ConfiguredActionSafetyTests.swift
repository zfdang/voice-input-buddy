import Testing
@testable import RemoteBuddy

@Suite("Configured action secure input")
struct ConfiguredActionSafetyTests {
    @Test(arguments: [ButtonAction.commandPaste, .commandCopy, .commandCut, .returnKey, .customShortcut])
    func sensitiveActionsAreRejectedBeforeSubmittingEvents(action: ButtonAction) {
        #expect(!KeyboardInjector.send(action, accessibilityTrusted: { true }, secureInputEnabled: { true },
            keyPoster: { _, _ in Issue.record("Blocked action posted an event") },
            shortcutEventPoster: { _ in Issue.record("Blocked shortcut posted an event"); return false }))
    }

    @Test func ordinaryNavigationAndMediaRemainAvailableAndPolicyIsReadAtSubmission() {
        var secure = false
        var keys = 0
        let send = { KeyboardInjector.send(.commandPaste, accessibilityTrusted: { true },
            secureInputEnabled: { secure }, shortcutEventPoster: { event in
                if event.type == .keyDown { keys += 1 }; return true
            }, shortcutHardwareFlags: { [] }) }
        #expect(send())
        secure = true
        #expect(!send())
        #expect(keys == 1)
        #expect(KeyboardInjector.send(.arrowLeft, accessibilityTrusted: { true }, secureInputEnabled: { true },
            keyPoster: { _, _ in keys += 1 }))
        var media = 0
        #expect(KeyboardInjector.send(.volumeUp, accessibilityTrusted: { true }, secureInputEnabled: { true },
            systemKeyPoster: { _ in media += 1 }))
        #expect(keys == 2)
        #expect(media == 1)
    }
}
