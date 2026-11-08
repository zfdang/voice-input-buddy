import AppKit
import Testing
@testable import RemoteBuddy

@Suite("Application shortcut resolution")
struct ApplicationShortcutResolverTests {
    @Test func commandQAndWRequestWindowClose() {
        for char in ["q", "Q", "w", "W"] {
            #expect(
                ApplicationShortcutResolver.resolve(
                    modifierFlags: .command,
                    charactersIgnoringModifiers: char
                ) == .closeWindow
            )
        }
    }

    @Test func plainKeysPassThrough() {
        for char in ["q", "w", "a", "c", "v"] {
            #expect(
                ApplicationShortcutResolver.resolve(
                    modifierFlags: [],
                    charactersIgnoringModifiers: char
                ) == .passThrough
            )
        }
    }

    @Test func otherCommandShortcutsPassThrough() {
        for char in ["a", "c", "v", "z", "h", "m"] {
            #expect(
                ApplicationShortcutResolver.resolve(
                    modifierFlags: .command,
                    charactersIgnoringModifiers: char
                ) == .passThrough
            )
        }
    }

    @Test func compoundModifiersPassThrough() {
        let compoundModifiers: [NSEvent.ModifierFlags] = [
            [.command, .shift],
            [.command, .option],
            [.command, .control],
            [.command, .shift, .option],
        ]
        for modifiers in compoundModifiers {
            #expect(
                ApplicationShortcutResolver.resolve(
                    modifierFlags: modifiers,
                    charactersIgnoringModifiers: "q"
                ) == .passThrough
            )
            #expect(
                ApplicationShortcutResolver.resolve(
                    modifierFlags: modifiers,
                    charactersIgnoringModifiers: "w"
                ) == .passThrough
            )
        }
    }

    @Test func nilCharactersPassThrough() {
        #expect(
            ApplicationShortcutResolver.resolve(
                modifierFlags: .command,
                charactersIgnoringModifiers: nil
            ) == .passThrough
        )
    }
}
