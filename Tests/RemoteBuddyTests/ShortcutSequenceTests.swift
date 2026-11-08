import AppKit
import Testing
@testable import RemoteBuddy

@Suite("Shortcut modifier ownership")
@MainActor
struct ShortcutSequenceTests {
    private struct Posted {
        let code: UInt16
        let type: CGEventType
        let flags: CGEventFlags
        let marker: Int64
        init(_ event: CGEvent) {
            code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            type = event.type
            flags = event.flags
            marker = event.getIntegerValueField(.eventSourceUserData)
        }
    }

    @Test func shortcutDoesNotFeedSyntheticOptionBackIntoHardwareState() {
        var hardware: CGEventFlags = []
        var session: CGEventFlags = []
        var posted: [Posted] = []
        let requested: CGEventFlags = [.maskAlternate, .maskCommand,
            CGEventFlags(rawValue: 0x0020), CGEventFlags(rawValue: 0x0008)]
        #expect(ShortcutEventSequence.send(keyCode: 123, modifiers: requested,
            hardwareFlags: { hardware }, eventPoster: { event in
                ShortcutEventSequence.post(event, eventPoster: { location, submitted in
                    // Model HID-stage state being visible to the next hardware read.
                    if location == .cghidEventTap { hardware = submitted.flags }
                    session = submitted.flags
                    posted.append(Posted(submitted))
                })
            }, logger: { _ in }))
        #expect(posted.map(\.code) == [58, 55, 123, 123, 55, 58])
        #expect(hardware.intersection([.maskAlternate, .maskCommand]).isEmpty)
        #expect(session.intersection([.maskAlternate, .maskCommand]).isEmpty)
    }

    @Test(arguments: [ButtonAction.commandReturn, .shiftReturn, .commandCopy, .commandPaste,
        .commandClose, .commandQuit, .commandCut, .commandSelectAll, .commandUndo,
        .commandRedo, .commandFind, .commandSave, .commandDelete, .showDesktop])
    func builtInShortcutsUseModifierEdgesAndPropagateSubmissionFailure(action: ButtonAction) {
        var posted: [Posted] = []
        #expect(KeyboardInjector.send(action, accessibilityTrusted: { true }, secureInputEnabled: { false },
            shortcutEventPoster: { posted.append(Posted($0)); return true }, shortcutHardwareFlags: { [] }))
        #expect(posted.first?.type == .flagsChanged)
        #expect(posted.last?.type == .flagsChanged)
        #expect(posted.last?.flags.isEmpty == true)
        #expect(posted.filter { $0.type == .keyDown }.count == 1)
        #expect(posted.filter { $0.type == .keyUp }.count == 1)
        #expect(!KeyboardInjector.send(action, accessibilityTrusted: { true }, secureInputEnabled: { false },
            shortcutEventPoster: { _ in false }, shortcutHardwareFlags: { [] }))
    }

    @Test func everyBuiltInShortcutUsesItsConfiguredKeyDespiteNativeHomeFn() {
        let shortcuts: [(ButtonAction, UInt16, CGEventFlags)] = [
            (.commandReturn, 36, .maskCommand), (.shiftReturn, 36, .maskShift),
            (.commandCopy, 8, .maskCommand), (.commandPaste, 9, .maskCommand),
            (.commandClose, 13, .maskCommand), (.commandQuit, 12, .maskCommand),
            (.commandCut, 7, .maskCommand), (.commandSelectAll, 0, .maskCommand),
            (.commandUndo, 6, .maskCommand), (.commandRedo, 6, [.maskCommand, .maskShift]),
            (.commandFind, 3, .maskCommand), (.commandSave, 1, .maskCommand),
            (.commandDelete, 51, .maskCommand), (.showDesktop, 103, .maskSecondaryFn),
        ]
        for (action, code, flags) in shortcuts {
            var posted: [Posted] = []
            #expect(KeyboardInjector.send(action, accessibilityTrusted: { true }, secureInputEnabled: { false },
                shortcutEventPoster: { posted.append(Posted($0)); return true },
                shortcutHardwareFlags: { CGEventFlags(rawValue: 0x800100) }))
            let keys = posted.filter { $0.type == .keyDown || $0.type == .keyUp }
            #expect(keys.count == 2)
            #expect(keys.allSatisfy { $0.code == code && $0.flags.intersection(
                [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn, .maskNumericPad]
            ) == flags })
            #expect(posted.last?.flags.contains(.maskSecondaryFn) == false)
        }
    }

    @Test func standaloneModifierRetriesFailedReleaseWithoutAnotherPress() {
        var downs: [Bool] = []
        let submitted = KeyboardInjector.send(.customShortcut, shortcut: StandaloneKeyboardModifier.leftCommand.shortcut,
            accessibilityTrusted: { true }, secureInputEnabled: { false }, keyStatePoster: { _, down, _ in
                downs.append(down)
                return downs.count != 2
            })
        #expect(submitted)
        #expect(downs == [true, false, false])
    }

    @Test func plainKeyUsesMarkedDownAndUpWithoutModifiers() {
        var posted: [Posted] = []
        #expect(ShortcutEventSequence.send(keyCode: 0, modifiers: [], hardwareFlags: { [] },
            eventPoster: { posted.append(Posted($0)); return true }, logger: { _ in }))
        #expect(posted.map(\.code) == [0, 0])
        #expect(posted.map(\.type) == [.keyDown, .keyUp])
        #expect(posted.allSatisfy { $0.flags.isEmpty && $0.marker == KeyboardInjector.syntheticEventMarker })
    }

    @Test func combinationReleasesOwnedModifiersInReverseOrder() {
        var posted: [Posted] = []
        #expect(ShortcutEventSequence.send(keyCode: 8, modifiers: [.maskCommand, .maskShift],
            hardwareFlags: { [] }, eventPoster: { posted.append(Posted($0)); return true }, logger: { _ in }))
        #expect(posted.map(\.code) == [56, 55, 8, 8, 55, 56])
        #expect(posted.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        #expect(posted[2].flags.contains([.maskCommand, .maskShift]))
        #expect(!posted[4].flags.contains(.maskCommand) && posted[4].flags.contains(.maskShift))
        #expect(posted[5].flags.isEmpty)
        #expect(posted.allSatisfy { $0.marker == KeyboardInjector.syntheticEventMarker })
    }

    @Test func physicallyHeldCommandIsNeverReleasedBySyntheticShortcut() {
        var posted: [Posted] = []
        #expect(ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { .maskCommand }, eventPoster: { posted.append(Posted($0)); return true }, logger: { _ in }))
        #expect(posted.map(\.code) == [8, 8])
        #expect(posted.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    @Test func rightCommandRequestPreservesPhysicallyHeldLeftCommand() {
        var posted: [Posted] = []
        let left = CGEventFlags(rawValue: 0x0008)
        let right = CGEventFlags(rawValue: 0x0010)
        #expect(ShortcutEventSequence.send(keyCode: 8, modifiers: [.maskCommand, right],
            hardwareFlags: { [.maskCommand, left] },
            eventPoster: { posted.append(Posted($0)); return true }, logger: { _ in }))
        #expect(posted.map(\.code) == [54, 8, 8, 54])
        #expect(posted[0].flags.contains([.maskCommand, left, right]))
        #expect(posted[3].flags.contains([.maskCommand, left]))
        #expect(!posted[3].flags.contains(right))
    }

    @Test func failedKeyDownStillAttemptsKeyUpAndModifierCleanup() {
        var posted: [Posted] = []
        #expect(!ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { [] }, eventPoster: { event in
                posted.append(Posted(event))
                return !(event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 8)
            }, logger: { _ in }))
        #expect(posted.map(\.code) == [55, 8, 8, 55])
        #expect(posted[2].type == .keyUp)
        #expect(posted.last?.flags.isEmpty == true)
    }

    @Test func failedModifierPressSkipsMainKeyButAttemptsRelease() {
        var posted: [Posted] = []
        #expect(!ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { [] }, eventPoster: { event in
                posted.append(Posted(event))
                return !event.flags.contains(.maskCommand)
            }, logger: { _ in }))
        #expect(posted.map(\.code) == [55, 55])
        #expect(posted.last?.flags.isEmpty == true)
    }

    @Test func physicalModifierPressedMidTransactionSurvivesCleanup() {
        var physical: CGEventFlags = []
        var posted: [Posted] = []
        #expect(ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { physical }, eventPoster: { event in
                posted.append(Posted(event))
                if event.type == .keyDown { physical = [.maskShift, CGEventFlags(rawValue: 0x0002)] }
                return true
            }, logger: { _ in }))
        #expect(posted.map(\.code) == [55, 8, 8, 55])
        #expect(posted.last?.flags.contains(.maskShift) == true)
        #expect(posted.last?.flags.contains(.maskCommand) == false)
    }
    @Test(arguments: [CGEventFlags.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn])
    func everyModifierFamilyIsPressedAndReleased(flag: CGEventFlags) {
        let keys: [CGEventFlags.RawValue: UInt16] = [CGEventFlags.maskControl.rawValue: 59,
            CGEventFlags.maskAlternate.rawValue: 58, CGEventFlags.maskShift.rawValue: 56,
            CGEventFlags.maskCommand.rawValue: 55, CGEventFlags.maskSecondaryFn.rawValue: 63]
        var posted: [Posted] = []
        #expect(ShortcutEventSequence.send(keyCode: 8, modifiers: flag, hardwareFlags: { [] },
            eventPoster: { posted.append(Posted($0)); return true }, logger: { _ in }))
        #expect(posted.count == 4)
        #expect(posted.first?.code == keys[flag.rawValue])
        #expect(posted.first?.type == .flagsChanged)
        #expect(posted[1].type == .keyDown && posted[2].type == .keyUp)
        #expect(posted[1].flags.contains(flag))
        #expect(posted.last?.code == keys[flag.rawValue])
        #expect(posted.last?.flags.isEmpty == true)
    }

    @Test func failedReleaseRetriesOnceButDoesNotReportSuccess() {
        var releases = 0
        var posted: [Posted] = []
        #expect(!ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { [] }, eventPoster: { event in
                posted.append(Posted(event))
                if event.type == .keyUp {
                    releases += 1
                    return releases > 1
                }
                return true
            }, logger: { _ in }))
        #expect(releases == 2)
        #expect(posted.map(\.code) == [55, 8, 8, 8, 55])
        #expect(posted.last?.flags.isEmpty == true)
    }

    @Test func repeatedReleaseFailureHasFiniteCleanupAndDiagnostic() {
        var posted: [Posted] = []
        var logs: [String] = []
        #expect(!ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { [] }, eventPoster: { event in
                posted.append(Posted(event))
                return event.type != .keyUp && !event.flags.isEmpty
            }, logger: { logs.append($0) }))
        #expect(posted.map(\.code) == [55, 8, 8, 8, 55, 55])
        #expect(logs.last?.contains("cleanup_failed=true") == true)
    }

    @Test @MainActor func recoveryDefersForPhysicalPressAndOnlyReleasesFailedModifier() {
        let clock = ControlledTestScheduler()
        var physical: CGEventFlags = []
        var posted: [Posted] = []
        var allowRelease = false
        #expect(!ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { physical }, eventPoster: { event in
                posted.append(Posted(event))
                return event.type != .flagsChanged || event.flags.contains(.maskCommand) || allowRelease
            }, logger: { _ in }, recoveryScheduler: clock.voiceSchedule))
        #expect(posted.map(\.code) == [55, 8, 8, 55, 55])
        physical = [.maskCommand, CGEventFlags(rawValue: 0x0008)]
        clock.runNext()
        #expect(posted.count == 5)
        physical = [.maskShift, CGEventFlags(rawValue: 0x0004)]
        allowRelease = true
        clock.runAll()
        #expect(posted.count == 6)
        #expect(posted.last?.type == .flagsChanged)
        #expect(posted.last?.code == 55)
        #expect(posted.last?.flags == physical)
        #expect(clock.activeCount == 0)
    }

    @Test @MainActor func permanentlyFailedCleanupStopsAfterEightAsyncAttempts() {
        let clock = ControlledTestScheduler()
        var releases = 0
        #expect(!ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
            hardwareFlags: { [] }, eventPoster: { event in
                if event.type == .flagsChanged && event.flags.isEmpty { releases += 1; return false }
                return true
            }, logger: { _ in }, recoveryScheduler: clock.voiceSchedule))
        clock.runAll()
        #expect(releases == 10)
        #expect(clock.activeCount == 0)
    }

}
