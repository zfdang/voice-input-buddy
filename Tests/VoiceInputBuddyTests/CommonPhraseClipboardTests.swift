import AppKit
import Testing
@testable import VoiceInputBuddy

@Suite("Common phrase clipboard fallback")
@MainActor
struct CommonPhraseClipboardTests {
    @Test func defaultPasteRoutesShortcutDiagnosticsThroughInjectedLogger() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var logs: [String] = []
        var posted = 0
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] },
            logger: { logs.append($0) }, readClipboard: { $0() },
            accessibilityTrusted: { true }, secureInputEnabled: { false },
            pasteEventPoster: { _ in posted += 1; return true })
        writer.paste("private phrase", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        #expect(posted == 4)
        #expect(logs.contains { $0.contains("SHORTCUT SEQUENCE") && $0.contains("phase=completed") })
        #expect(logs.allSatisfy { !$0.contains("private phrase") })
    }

    @Test func defaultPasteUsesInjectedModifierDiagnosticsAtFinalSubmission() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var observations = 0
        var logs: [String] = []
        let writer = CommonPhraseClipboardPaste(board: board,
            modifierFlags: { observations += 1; return observations == 1 ? [] : .maskShift },
            modifierDiagnostics: { "fixture_modifier=true" }, logger: { logs.append($0) },
            readClipboard: { $0() }, accessibilityTrusted: { true }, secureInputEnabled: { false },
            pasteEventPoster: { _ in Issue.record("Held modifier must prevent paste"); return false })
        writer.paste("private phrase", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == "paste_failed") }
        #expect(logs.contains { $0.contains("fixture_modifier=true") })
        #expect(board.string(forType: .string) == "original")
    }

    @Test func persistentModifierFailureRecordsStateWithoutReadingClipboardOrPhraseText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        let clock = ControlledTestScheduler()
        var logs: [String] = []
        var observations = 0, reads = 0, posts = 0
        var result: String?
        let writer = CommonPhraseClipboardPaste(board: board,
            modifierFlags: { CGEventFlags(rawValue: 0xA00100) },
            modifierDiagnostics: {
                observations += 1
                return "observed_fn_key_down=true observed_navigation_keys=none"
            }, logger: { logs.append($0) },
            uptime: { Double(clock.now) / 1_000 }, readClipboard: { reads += 1; $0() },
            schedule: clock.voiceSchedule, postPaste: { posts += 1; return true })
        writer.paste("private phrase", validate: { $0(nil) }, canSubmit: { true }) { result = $0 }
        clock.advance(to: 600)
        #expect(result == "paste_failed")
        #expect(reads == 0 && posts == 0)
        #expect(board.string(forType: .string) == "original clipboard")
        #expect(logs.count == 2 && observations == 2)
        #expect(logs.first?.contains("waiting reason=modifiers_held flags=10486016") == true)
        #expect(logs.last?.contains("rejected reason=modifiers_held_after_wait") == true)
        #expect(logs.allSatisfy { $0.contains("observed_fn_key_down=true") && !$0.contains("private phrase") })
    }

    @Test func modifierRecoveryRecordsReleaseAndSuccessfulPastesDoNotSampleDiagnostics() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clock = ControlledTestScheduler()
        var held = true
        var logs: [String] = []
        var observations = 0, posts = 0, completions = 0
        let writer = CommonPhraseClipboardPaste(board: board,
            modifierFlags: { held ? .maskControl : [] },
            modifierDiagnostics: { observations += 1; return "observed_fn_key_down=false" },
            logger: { logs.append($0) }, uptime: { Double(clock.now) / 1_000 },
            readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: { posts += 1; return true })
        writer.paste("first", validate: { $0(nil) }, canSubmit: { true }) {
            #expect($0 == nil); completions += 1
        }
        held = false
        clock.advance(to: 50)
        #expect(completions == 1 && posts == 1 && observations == 2)
        #expect(logs.last?.contains("modifiers_released flags=0") == true)
        writer.paste("second", validate: { $0(nil) }, canSubmit: { true }) {
            #expect($0 == nil); completions += 1
        }
        #expect(completions == 2 && posts == 2 && observations == 2)
    }

    @Test func failedSecondPasteKeepsTheOriginalManualRestorePoint() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var accepted = true
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] },
            readClipboard: { $0() }, postPaste: { accepted })
        writer.paste("first", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        accepted = false
        writer.paste("second", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == "paste_failed") }
        #expect(board.string(forType: .string) == "first")
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
    }

    @Test func phrasePasteboardItemContainsStandardPrivacyMarkers() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("secret original", forType: .string)
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] },
            readClipboard: { $0() }, postPaste: { true })
        writer.paste("confidential phrase", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }

        #expect(board.string(forType: .string) == "confidential phrase")
        let types = board.types ?? []
        #expect(types.contains(CommonPhraseClipboardPaste.transientType))
        #expect(types.contains(CommonPhraseClipboardPaste.autoGeneratedType))
        #expect(types.contains(CommonPhraseClipboardPaste.concealedType))

        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "secret original")
        #expect(!(board.types ?? []).contains(CommonPhraseClipboardPaste.transientType))
    }

    @Test func delayedReceiverNeverSeesAnAutomaticallyRestoredOldClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old private content", forType: .string)
        let clock = ControlledTestScheduler()
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] },
            readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: { true })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        clock.advance(to: 5_000)
        #expect(board.string(forType: .string) == "phrase")
        #expect(writer.canRestoreClipboard)
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "old private content")
    }

    @Test func failedSubmissionRollsBackImmediatelyWithoutADeadline() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        var failure: String?
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] },
            readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: { false })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) { failure = $0 }
        #expect(failure == "paste_failed")
        #expect(board.string(forType: .string) == "original")
        #expect(clock.activeCount == 0)
    }

    @Test func postedPasteKeyDownStillCountsWhenKeyUpCreationFails() {
        let submitted = CommonPhraseClipboardPaste.submitPasteShortcut(hardwareFlags: { [] },
            eventPoster: { $0.type != .keyUp })
        #expect(submitted)
    }

    @Test func staleHIDFnAfterSuppressedNavigationDoesNotBlockOrModifyPaste() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        // Runtime failure: HID flags=0xA00100 and Fn=true, session flags=0x100.
        let effective = KeyboardHardwareModifierPolicy.normalized(CGEventFlags(rawValue: 0xA00100),
            fnKeyDown: true, combinedFlags: CGEventFlags(rawValue: 0x100), combinedFnKeyDown: false)
        var types: [CGEventType] = []
        var results: [String?] = []
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { effective },
            uptime: { Double(clock.now) / 1_000 }, readClipboard: { $0() }, schedule: clock.voiceSchedule,
            accessibilityTrusted: { true }, secureInputEnabled: { false }, pasteEventPoster: { event in
                #expect(!event.flags.contains(.maskSecondaryFn))
                types.append(event.type)
                return true
            })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) { results.append($0) }
        clock.runAll()
        #expect(results.count == 1 && results[0] == nil)
        #expect(types == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(board.string(forType: .string) == "phrase")
    }

    @Test(arguments: [CGEventFlags.maskControl, .maskAlternate, .maskShift])
    func removingStaleNavigationFnNeverRemovesOtherHeldModifiers(modifier: CGEventFlags) {
        let effective = KeyboardHardwareModifierPolicy.normalized(
            CGEventFlags(rawValue: 0xA00100).union(modifier), fnKeyDown: true,
            combinedFlags: modifier, combinedFnKeyDown: false)
        #expect(effective.contains(modifier))
        #expect(!effective.contains(.maskSecondaryFn))
        #expect(!CommonPhraseClipboardPaste.permitsPasteShortcut(flags: effective))
    }

    @Test(arguments: [false, true], [false, true])
    func sessionEvidenceOfRealFnStillBlocksPasteDespiteNavigationDecoration(hidDown: Bool, keyState: Bool) {
        let effective = KeyboardHardwareModifierPolicy.normalized(CGEventFlags(rawValue: 0xA00100),
            fnKeyDown: hidDown, combinedFlags: keyState ? [] : .maskSecondaryFn,
            combinedFnKeyDown: keyState)
        #expect(effective.contains(.maskSecondaryFn))
        #expect(!CommonPhraseClipboardPaste.permitsPasteShortcut(flags: effective))
    }

    @Test func externalKeyboardFnWithoutNavigationDecorationIsNeverRemoved() {
        let flags = KeyboardHardwareModifierPolicy.normalized(.maskSecondaryFn,
            fnKeyDown: false, combinedFlags: [], combinedFnKeyDown: false)
        #expect(KeyboardHardwareModifierPolicy.normalized([], fnKeyDown: true,
            combinedFlags: [], combinedFnKeyDown: false).contains(.maskSecondaryFn))
        #expect(flags.contains(.maskSecondaryFn))
        #expect(!CommonPhraseClipboardPaste.permitsPasteShortcut(flags: flags))
    }

    @Test func navigationReleaseRaceWaitsBeforeReadingOrReplacingClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        // Exact effective flag value observed during the failed remote-left selections.
        var flags = CGEventFlags(rawValue: 0xA00100)
        var reads = 0, posts = 0, completions = 0
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { flags },
            uptime: { Double(clock.now) / 1_000 }, readClipboard: { reads += 1; $0() },
            schedule: clock.voiceSchedule, postPaste: { posts += 1; return true })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) {
            #expect($0 == nil); completions += 1
        }
        clock.advance(to: 150)
        #expect(reads == 0 && posts == 0 && completions == 0)
        #expect(board.string(forType: .string) == "original")
        flags = [] // Native navigation key-up clears the transient HID state.
        clock.advance(to: 175)
        #expect(reads == 1 && posts == 1)
        #expect(board.string(forType: .string) == "phrase")
        clock.runAll()
        #expect(completions == 1)
        #expect(board.string(forType: .string) == "phrase")
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
    }

    @Test(arguments: [CGEventFlags.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift])
    func trulyHeldModifierTimesOutWithoutTouchingClipboardAndAllowsRetry(held: CGEventFlags) {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        var flags = held
        var reads = 0, posts = 0
        var results: [String?] = []
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { flags },
            uptime: { Double(clock.now) / 1_000 }, readClipboard: { reads += 1; $0() },
            schedule: clock.voiceSchedule, postPaste: { posts += 1; return true })
        writer.paste("blocked", validate: { $0(nil) }, canSubmit: { true }) { results.append($0) }
        clock.advance(to: 500)
        #expect(results == ["paste_failed"])
        #expect(reads == 0 && posts == 0)
        #expect(board.string(forType: .string) == "original")
        flags = []
        writer.paste("retry", validate: { $0(nil) }, canSubmit: { true }) { results.append($0) }
        clock.runAll()
        #expect(reads == 1 && posts == 1)
        #expect(results.count == 2 && results[1] == nil)
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
    }

    @Test func changedTargetDuringModifierWaitCancelsBeforeClipboardAccess() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        var current = true
        var result: String?
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { .maskSecondaryFn },
            uptime: { Double(clock.now) / 1_000 },
            readClipboard: { _ in Issue.record("Changed target must not trigger clipboard IPC") },
            schedule: clock.voiceSchedule, postPaste: { Issue.record("Changed target must not receive paste"); return true })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { current }) { result = $0 }
        current = false
        clock.runAll()
        #expect(result == "target_changed")
        #expect(board.string(forType: .string) == "original")
    }

    @Test func consecutivePhrasesDoNotLeaveTabsBeforeTheNextInsertion() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        let clock = ControlledTestScheduler()
        var editor = "已有文本："
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() },
            schedule: clock.voiceSchedule, postPaste: {
                editor += board.string(forType: .string) ?? ""
                return true
            })
        for body in ["第一条\t", "\t 第二条 \t"] {
            let phrase = CommonPhrase(id: "user-test", text: body,
                label: "标签")
            writer.paste(phrase.insertionText, validate: { $0(nil) }, canSubmit: { true }) {
                #expect($0 == nil)
            }
            clock.runAll()
        }
        #expect(writer.restorePreviousClipboard())
        #expect(editor == "已有文本：第一条第二条")
        #expect(board.string(forType: .string) == "original clipboard")
    }

    @Test func navigationFnFlagDoesNotBlockOrModifyPaste() {
        let flags = KeyboardHardwareModifierPolicy.normalized([.maskSecondaryFn, .maskNumericPad],
            fnKeyDown: false, combinedFlags: [], combinedFnKeyDown: false)
        #expect(!flags.contains(.maskSecondaryFn))
        #expect(flags.contains(.maskNumericPad))
        #expect(CommonPhraseClipboardPaste.permitsPasteShortcut(flags: flags))
    }

    @Test func physicallyHeldModifiersStillBlockPaste() {
        let fn = KeyboardHardwareModifierPolicy.normalized([], fnKeyDown: true,
            combinedFlags: .maskSecondaryFn, combinedFnKeyDown: true)
        #expect(!CommonPhraseClipboardPaste.permitsPasteShortcut(flags: fn))
        for modifier: CGEventFlags in [.maskControl, .maskAlternate, .maskShift] {
            let flags = KeyboardHardwareModifierPolicy.normalized([modifier, .maskSecondaryFn],
                fnKeyDown: false, combinedFlags: [], combinedFnKeyDown: false)
            #expect(!CommonPhraseClipboardPaste.permitsPasteShortcut(flags: flags))
        }
        #expect(CommonPhraseClipboardPaste.permitsPasteShortcut(flags: .maskCommand))
    }

    @Test func restoresEveryItemAndFormatAfterPaste() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("com.example.binary")
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([0, 1, 255]), forType: type)
        second.setString("second item", forType: .string)
        board.writeObjects([first, second])
        let originalTypes = board.pasteboardItems?.first?.types
        let clock = ControlledTestScheduler()
        var posts = 0
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: {
            posts += 1
            #expect(board.string(forType: .string) == "phrase")
            return true
        })
        var completed = false
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) {
            #expect($0 == nil); completed = true
        }
        #expect(posts == 1 && completed)
        #expect(board.string(forType: .string) == "phrase")
        clock.runAll()
        #expect(completed)
        #expect(writer.restorePreviousClipboard())
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.types == originalTypes)
        #expect(board.pasteboardItems?.first?.string(forType: .string) == "original")
        #expect(board.pasteboardItems?.first?.data(forType: type) == Data([0, 1, 255]))
        #expect(board.pasteboardItems?.last?.string(forType: .string) == "second item")
    }

    @Test func aNewUserCopyIsNeverRestoredOver() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: { true })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        board.clearContents()
        board.setString("new user copy", forType: .string)
        let count = board.changeCount
        clock.runAll()
        #expect(!writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "new user copy")
        #expect(board.changeCount == count)
    }

    @Test(arguments: [false, true])
    func validationFailureNeverPostsAndPreservesClipboard(secondCheck: Bool) {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() }, postPaste: {
            Issue.record("Invalid target must not receive paste"); return true
        })
        var calls = 0
        var failure: String?
        writer.paste("phrase", validate: { done in
            calls += 1
            done(calls == 1 && secondCheck ? nil : "target_changed")
        }, canSubmit: { true }) { failure = $0 }
        #expect(failure == "target_changed")
        #expect(board.string(forType: .string) == "original")
    }

    @Test func changedClipboardDuringRevalidationCancelsTheKeyEvent() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var validations: [(String?) -> Void] = []
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() }, postPaste: {
            Issue.record("Must not paste someone else's new clipboard"); return true
        })
        var result: String?
        writer.paste("phrase", validate: { validations.append($0) }, canSubmit: { true }) { result = $0 }
        try #require(validations.count == 1)
        validations[0](nil)
        try #require(validations.count == 2)
        board.clearContents()
        board.setString("new copy", forType: .string)
        validations[1](nil)
        #expect(result == "paste_failed")
        #expect(board.string(forType: .string) == "new copy")
    }

    @Test(arguments: [false, true])
    func submissionDoesNotScheduleRestorationAfterOwnerRelease(submitted: Bool) {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let clock = ControlledTestScheduler()
        var writer: CommonPhraseClipboardPaste? = .init(board: board, modifierFlags: { [] }, readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: { submitted })
        var completed = false
        writer?.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) {
            #expect($0 == (submitted ? nil : "paste_failed")); completed = true
        }
        writer = nil
        clock.runAll()
        #expect(completed)
        #expect(board.string(forType: .string) == (submitted ? "phrase" : nil))
    }

    @Test func successiveSubmissionsKeepOneOriginalClipboardForManualRestore() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        var posts = 0
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() }, schedule: clock.voiceSchedule, postPaste: { posts += 1; return true })
        writer.paste("blocked", validate: { $0(nil) }, canSubmit: { false }) { #expect($0 == "target_changed") }
        #expect(posts == 0)
        #expect(board.string(forType: .string) == "original")
        writer.paste("first", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        writer.paste("second", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        #expect(posts == 2)
        clock.runAll()
        #expect(board.string(forType: .string) == "second")
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
    }

    @Test func anOversizedSnapshotLeavesTheOriginalClipboardUntouched() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("com.example.large")
        let original = Data(repeating: 7, count: 32 * 1_024 * 1_024 + 1)
        board.setData(original, forType: type)
        let count = board.changeCount
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { $0() }, postPaste: {
            Issue.record("Must not paste without a complete snapshot"); return true
        })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == "clipboard_write_failed") }
        #expect(board.changeCount == count)
        #expect(board.data(forType: type) == original)
    }

    @Test func aStuckSnapshotAllowsRetryAndCannotCancelANewerSnapshot() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let clock = ControlledTestScheduler()
        var reads: [() -> Void] = []
        var completions = 0
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, readClipboard: { reads.append($0) },
            schedule: clock.voiceSchedule, postPaste: { true })
        writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) {
            #expect($0 == "clipboard_write_failed"); completions += 1
        }
        #expect(board.string(forType: .string) == "original")
        clock.runAll()
        #expect(completions == 1)
        writer.paste("retry", validate: { $0(nil) }, canSubmit: { true }) { #expect($0 == nil) }
        #expect(reads.count == 2)
        let read = try #require(reads.first)
        read()
        #expect(completions == 1)
        #expect(board.string(forType: .string) == "original")
        reads[1]()
        #expect(board.string(forType: .string) == "retry")
        clock.runAll()
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
    }

    @Test func backgroundSnapshotReturnsToMainBeforePostingAndRestoring() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] },
            readClipboard: { work in DispatchQueue.global().async { work() } }, schedule: { delay, action in
            if delay < 1 { DispatchQueue.main.async { action() } }
            return ScheduledOperation(cancellation: {})
        }, postPaste: { #expect(Thread.isMainThread); return true })
        let result: String? = await withCheckedContinuation { continuation in
            writer.paste("phrase", validate: { #expect(Thread.isMainThread); $0(nil) }, canSubmit: { true }) {
                #expect(Thread.isMainThread)
                continuation.resume(returning: $0)
            }
        }
        #expect(result == nil)
        #expect(board.string(forType: .string) == "phrase")
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
    }

    @Test func productionHelperRoundTripsMultipleClipboardFormats() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let binaryType = NSPasteboard.PasteboardType("example.helper-test")
        board.setString("original", forType: .string)
        board.setData(Data([0, 1, 255]), forType: binaryType)
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/VoiceInputBuddy")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let writer = CommonPhraseClipboardPaste(board: board, modifierFlags: { [] }, snapshotExecutableURL: executable,
            schedule: { delay, action in
                if delay < 1 { DispatchQueue.main.async { action() } }
                return ScheduledOperation(cancellation: {})
            }, postPaste: { board.string(forType: .string) == "phrase" })
        let result: String? = await withCheckedContinuation { continuation in
            writer.paste("phrase", validate: { $0(nil) }, canSubmit: { true }) {
                continuation.resume(returning: $0)
            }
        }
        #expect(result == nil)
        #expect(board.string(forType: .string) == "phrase")
        #expect(writer.restorePreviousClipboard())
        #expect(board.string(forType: .string) == "original")
        #expect(board.data(forType: binaryType) == Data([0, 1, 255]))
    }

    @Test func browserAndTerminalRoutesPreferNativePaste() {
        for terminal in ["com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty", "com.mitchellh.ghostty",
                         "app.getmoshi.desktop"] {
            #expect(CommonPhraseInserter.prefersPaste(bundleIdentifier: terminal, electron: false, webContent: false))
        }
        #expect(CommonPhraseInserter.prefersPaste(bundleIdentifier: "com.google.Chrome", electron: false, webContent: false))
        #expect(CommonPhraseInserter.prefersPaste(bundleIdentifier: "com.apple.Safari", electron: false, webContent: false))
        #expect(CommonPhraseInserter.prefersPaste(bundleIdentifier: "example.editor", electron: true, webContent: false))
        #expect(CommonPhraseInserter.prefersPaste(bundleIdentifier: "example.browser", electron: false, webContent: true))
        #expect(!CommonPhraseInserter.prefersPaste(bundleIdentifier: "example.native", electron: false, webContent: false))
    }
}
