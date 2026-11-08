import CoreGraphics
import Testing
@testable import RemoteBuddy

@Suite("App switcher navigation modifiers")
struct AppSwitcherModifierTests {
    @Test(arguments: [UInt64(0x800100), 0xA00100])
    func nativeHomeFnDoesNotContaminateSwitcherOrCleanup(rawFlags: UInt64) throws {
        var events: [CGEvent] = []
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, flags in
            guard let event = KeyboardInjector.makeMappedKeyEvent(
                code: code, isDown: down, flags: flags,
                hardwareFlags: { CGEventFlags(rawValue: rawFlags) }
            ) else { return false }
            events.append(event)
            return true
        })
        #expect(session.trigger())
        #expect(session.trigger())
        #expect(session.moveSelection(left: true))
        #expect(session.cancel())
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } ==
            [55, 48, 48, 48, 48, 123, 123, 53, 53, 55])
        for event in events {
            #expect(!event.flags.contains(.maskSecondaryFn))
            #expect(!event.flags.contains(.maskNumericPad))
            #expect(KeyboardInjector.isSyntheticEvent(event))
        }
        #expect(events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(events.last?.flags.contains(.maskCommand) == false)
    }

    @Test(arguments: [CGEventFlags.maskShift, .maskControl, .maskAlternate, .maskCommand])
    func physicalModifiersRemainHeldOnCommandRelease(modifier: CGEventFlags) throws {
        let event = try #require(KeyboardInjector.makeMappedKeyEvent(
            code: 55, isDown: false, flags: [],
            hardwareFlags: { CGEventFlags(rawValue: 0x800100).union(modifier) }
        ))
        #expect(event.flags.contains(modifier))
        #expect(!event.flags.contains(.maskSecondaryFn))
    }

    @Test func voiceKeyPathStillPreservesFn() throws {
        let event = try #require(KeyboardInjector.makeMarkedKeyEvent(
            code: 63, isDown: true, flags: .maskSecondaryFn,
            marker: KeyboardInjector.orderedVoiceEventMarker,
            hardwareFlags: { [] }
        ))
        #expect(event.flags.contains(.maskSecondaryFn))
    }

    @Test(arguments: [CGKeyCode(36), 48, 51, 53, 55, 123, 124, 125, 126])
    func remappedPlainAndModifierKeysKeepTheirConfiguredCodes(code: CGKeyCode) throws {
        for down in [true, false] {
            let event = try #require(KeyboardInjector.makeMappedKeyEvent(
                code: code, isDown: down, flags: [],
                hardwareFlags: { CGEventFlags(rawValue: 0x800100) }
            ))
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(code))
            #expect(!event.flags.contains(.maskSecondaryFn))
            #expect(!event.flags.contains(.maskNumericPad))
        }
    }

    @Test(arguments: [UInt64(0x800100), 0xA00100])
    func shortcutTransactionAddsFnOnlyWhenExplicitlyConfigured(rawFlags: UInt64) {
        for configuredFn in [false, true] {
            var events: [CGEvent] = []
            let requested: CGEventFlags = configuredFn ? [.maskCommand, .maskSecondaryFn] : .maskCommand
            #expect(ShortcutEventSequence.send(keyCode: 36, modifiers: requested,
                hardwareFlags: { CGEventFlags(rawValue: rawFlags) },
                eventPoster: { events.append($0); return true }, logger: { _ in }))
            let keyEvents = events.filter { $0.type == .keyDown || $0.type == .keyUp }
            #expect(keyEvents.count == 2)
            #expect(keyEvents.allSatisfy {
                $0.getIntegerValueField(.keyboardEventKeycode) == 36 &&
                    $0.flags.contains(.maskCommand) &&
                    $0.flags.contains(.maskSecondaryFn) == configuredFn &&
                    !$0.flags.contains(.maskNumericPad)
            })
            #expect(events.last?.flags.contains(.maskSecondaryFn) == false)
        }
    }

    @Test func standaloneConfiguredFnRemainsPresentAndIsReleased() throws {
        let down = try #require(KeyboardInjector.makeMappedKeyEvent(
            code: 63, isDown: true, flags: .maskSecondaryFn,
            hardwareFlags: { CGEventFlags(rawValue: 0x800100) }
        ))
        let up = try #require(KeyboardInjector.makeMappedKeyEvent(
            code: 63, isDown: false, flags: [],
            hardwareFlags: { CGEventFlags(rawValue: 0x800100) }
        ))
        #expect(down.flags.contains(.maskSecondaryFn))
        #expect(!up.flags.contains(.maskSecondaryFn))
    }
}
