import CoreGraphics
import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Ordered voice input activation")
@MainActor
struct VoiceInputActivationTests {
    private func model() throws -> BridgeAppModel {
        let suite = "voice-activation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingVoiceTool(.weixin)
        settings.voiceKeyMode = .function
        return BridgeAppModel(settings: settings, initialAudioDevices: [])
    }

    private func beginInlineSession(_ monitor: PreferredInputSourceMonitor) -> Bool {
        var result = false
        monitor.beginVoiceSession { result = $0 }
        return result
    }

    @Test func firstFnWaitsForActivationAndLeavesSourceSelectedAfterStop() throws {
        let model = try model()
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        var source = "previous"
        var events: [String] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { _ in events.append("select"); return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { source = $0; events.append("restore"); return .selected },
            waitForInputSourceActivation: { requested, current, continuing, done in
                #expect(current() == "previous")
                source = requested
                events.append("activated")
                done(continuing())
            }, installMonitor: { _ in nil }, logger: { _ in })
        for _ in 0..<2 {
            let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
                keySetter: { mode, down in
                    #expect(mode == .function)
                    #expect(source == target)
                    events.append(down ? "fn_down" : "fn_up")
                    return true
                })
            #expect(started)
            let stopped = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                keySetter: { _, _ in events.append("fn_up"); return true })
            #expect(stopped)
            #expect(source == target)
            #expect(!model.voiceKeyLatch.isHeld)
            #expect(!model.preferredInputSourceMonitor.functionKeyIsPressedForDiagnostics)
        }
        #expect(events == ["select", "activated", "fn_down", "fn_up", "fn_down", "fn_up"])
    }

    @Test func cancelledActivationCannotSendFnDownOrBlockTheNextSession() throws {
        let model = try model()
        var source = "previous"
        var cancel = true
        var posted: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { _ in .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { target, _, continuing, done in
                source = target
                if cancel {
                    let stopped = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                        keySetter: { _, down in posted.append(down); return true })
                    #expect(stopped)

                }
                done(continuing())
            }, installMonitor: { _ in nil }, logger: { _ in })
        let cancelled = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true })
        #expect(!cancelled)
        #expect(posted.isEmpty)
        #expect(model.pendingVoiceKeyMode == nil)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(source == "previous")
        cancel = false
        let restarted = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true })
        #expect(restarted)
        #expect(posted == [true])
        let cleaned = model.releaseVoiceKeyIfNeeded(releaseKey: { _ in posted.append(false); return true })
        #expect(cleaned)
        #expect(posted == [true, false])
        #expect(source == OnboardingVoiceTool.weixin.preferredInputSourceID)
    }

    @Test func activationTimeoutRollsBackBeforePostingAnyKey() throws {
        let model = try model()
        var source = "previous"
        var posts = 0
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { _ in .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { _, _, _, done in done(false) }, installMonitor: { _ in nil }, logger: { _ in })
        let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in posts += 1; return true })
        #expect(!started)
        #expect(posts == 0)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(model.pendingVoiceKeyMode == nil)
        #expect(!model.voiceSession.commandAudio.isWaiting)
    }

    @Test func failedFnUpAndConfirmedCleanupBothRetainSourceForComposition() throws {
        let model = try model()
        var source = "previous"
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { tool in source = tool.preferredInputSourceID!; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) }, installMonitor: { _ in nil }, logger: { _ in })
        let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in true })
        #expect(started)
        let stopped = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in false })
        #expect(!stopped)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(source == OnboardingVoiceTool.weixin.preferredInputSourceID)
        let cleaned = model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true })
        #expect(cleaned)
        #expect(source == OnboardingVoiceTool.weixin.preferredInputSourceID)
    }

    @Test func alreadySelectedSourceAndUserChangesArePreserved() throws {
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        var source = target
        var restored: [String] = []
        let monitor = PreferredInputSourceMonitor(voiceTool: { .weixin },
            prepareInputSource: { _ in source = target; return .selected }, currentInputSourceID: { source },
            restoreInputSource: { restored.append($0); source = $0; return .selected },
            waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) }, installMonitor: { _ in nil }, logger: { _ in })
        #expect(beginInlineSession(monitor))
        monitor.endVoiceSession()
        #expect(restored.isEmpty)
        source = "previous"
        #expect(beginInlineSession(monitor))
        source = "user_selected"
        monitor.endVoiceSession()
        #expect(restored.isEmpty)
        #expect(source == "user_selected")
    }

    @Test func ordinaryKeyboardFnLeavesItsInputSourceSelected() throws {
        var source = "previous"
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        let monitor = PreferredInputSourceMonitor(voiceTool: { .weixin },
            prepareInputSource: { _ in source = target; return .selected }, currentInputSourceID: { source },
            restoreInputSource: { source = $0; return .selected }, installMonitor: { _ in nil }, logger: { _ in })
        monitor.handleFunctionKeyPressed(true)
        #expect(source == target)
        #expect(monitor.functionKeyIsPressedForDiagnostics)
        monitor.handleFunctionKeyPressed(false)
        #expect(source == target)
    }

    @Test func delayedResultRemainsAttachedAfterKeyUpAndMonitorStop() throws {
        let model = try model()
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        var source = "previous"
        var restores = 0
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { source = $0; restores += 1; return .selected },
            waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) },
            installMonitor: { _ in nil }, logger: { _ in })
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in true }))
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in true }))
        model.preferredInputSourceMonitor.stop()
        // A recognition result can arrive after both recording and monitoring
        // have ended. Its input method must still be the selected text client.
        #expect(source == target)
        #expect(restores == 0)
        #expect(!model.voiceKeyLatch.isHeld)
    }

    @Test func monitorStopDuringSubmittedVoiceRetainsSourceAndUserSelection() throws {
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        for userChanged in [false, true] {
            var source = "previous"
            var restores = 0
            let monitor = PreferredInputSourceMonitor(voiceTool: { .weixin },
                prepareInputSource: { _ in source = target; return .selected },
                currentInputSourceID: { source },
                restoreInputSource: { source = $0; restores += 1; return .selected },
                waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            monitor.markVoiceTriggerSubmitted()
            if userChanged { source = "user_selected" }
            monitor.stop()
            monitor.endVoiceSession()
            #expect(source == (userChanged ? "user_selected" : target))
            #expect(restores == 0)
        }
    }

    @Test func unsubmittedSessionRollsBackAndDoesNotAffectLaterSuccessfulSession() throws {
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        var source = "previous"
        var restored: [String] = []
        let monitor = PreferredInputSourceMonitor(voiceTool: { .weixin },
            prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { restored.append($0); source = $0; return .selected },
            waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) },
            installMonitor: { _ in nil }, logger: { _ in })
        #expect(beginInlineSession(monitor))
        monitor.endVoiceSession()
        #expect(source == "previous")
        #expect(restored == ["previous"])
        #expect(beginInlineSession(monitor))
        monitor.markVoiceTriggerSubmitted()
        monitor.endVoiceSession()
        #expect(source == target)
        #expect(restored == ["previous"])
    }

    @Test func standaloneToolsNeverSelectWaitForOrRestoreAnInputSource() {
        for tool in [OnboardingVoiceTool.voicecursor, .typeless, .bageshuo, .other] {
            #expect(tool.preferredInputSourceID == nil)
            var sourceOperations = 0
            let monitor = PreferredInputSourceMonitor(voiceTool: { tool },
                prepareInputSource: { _ in sourceOperations += 1; return .failed },
                currentInputSourceID: { sourceOperations += 1; return "previous" },
                restoreInputSource: { _ in sourceOperations += 1; return .failed },
                waitForInputSourceActivation: { _, _, _, done in sourceOperations += 1; done(false) },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            monitor.markVoiceTriggerSubmitted()
            monitor.endVoiceSession()
            monitor.handleFunctionKeyPressed(true)
            monitor.handleFunctionKeyPressed(false)
            monitor.stop()
            #expect(sourceOperations == 0)
        }
    }

    @Test func bothSystemInputMethodsRetainSelectionAfterSuccessfulTrigger() throws {
        for tool in [OnboardingVoiceTool.weixin, .doubao] {
            let target = try #require(tool.preferredInputSourceID)
            var source = "previous"
            var restored: [String] = []
            let monitor = PreferredInputSourceMonitor(voiceTool: { tool },
                prepareInputSource: { _ in source = target; return .selected },
                currentInputSourceID: { source },
                restoreInputSource: { restored.append($0); source = $0; return .selected },
                waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            monitor.markVoiceTriggerSubmitted()
            monitor.endVoiceSession()
            monitor.stop()
            #expect(source == target)
            #expect(restored.isEmpty)
        }
    }

    @Test func orderedEventsCannotAcquireAnExtraGlobalFnOwnerAndRemainSynthetic() throws {
        #expect(!PreferredInputSourceMonitor.shouldObserveFunctionEvent(marker: KeyboardInjector.orderedVoiceEventMarker))
        #expect(PreferredInputSourceMonitor.shouldObserveFunctionEvent(marker: 0))
        // Both software markers must stay outside the physical Fn observer.
        #expect(!PreferredInputSourceMonitor.shouldObserveFunctionEvent(marker: KeyboardInjector.syntheticEventMarker))
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.orderedVoiceEventMarker)
        #expect(KeyboardInjector.isSyntheticEvent(event))
        let ordinarySource = try #require(CGEventSource(stateID: .privateState))
        let ordinaryEvent = try #require(CGEvent(keyboardEventSource: ordinarySource, virtualKey: 63, keyDown: true))
        #expect(!KeyboardInjector.isSyntheticEvent(ordinaryEvent))
    }

    @Test func failedSourceSelectionOrFnDownNeverLeavesTheSourceOwned() throws {
        for selection in [OnboardingInputSourceSwitchResult.failed, .selected] {
            let model = try model()
            var source = "previous"
            var posts = 0
            model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
                voiceTool: { .weixin }, prepareInputSource: { tool in
                    if selection == .selected { source = tool.preferredInputSourceID! }
                    return selection
                }, currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
                waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) },
                installMonitor: { _ in nil }, logger: { _ in })
            let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
                keySetter: { _, _ in posts += 1; return false })
            #expect(!started)
            #expect(posts == (selection == .selected ? 1 : 0))
            #expect(source == "previous")
            #expect(!model.voiceKeyLatch.isHeld)
            #expect(model.pendingVoiceKeyMode == nil)
        }
    }

    @Test func orderedHardwareFnRequiresNeutralizationAndPostingPermission() {
        #expect(OrderedVoiceActivationPolicy.needsSoftwareFn(mode: .function, fnTapEnabled: false,
            preferredInputSourceID: "weixin"))
        #expect(!OrderedVoiceActivationPolicy.needsSoftwareFn(mode: .function, fnTapEnabled: true,
            preferredInputSourceID: "weixin"))
        #expect(!OrderedVoiceActivationPolicy.needsSoftwareFn(mode: .function, fnTapEnabled: false,
            preferredInputSourceID: nil))
        #expect(!BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: false,
            accessibilityGranted: true, requiresOrderedFn: true))
        #expect(!BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: true,
            accessibilityGranted: false, requiresOrderedFn: true))
        #expect(BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: true,
            accessibilityGranted: true, requiresOrderedFn: true))
        #expect(BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: false))
        #expect(VoiceKeySessionPreservationPolicy.shouldPreserveInputSourceSession(latchHeld: true,
            heldMode: .function, pendingMode: nil))
    }

    @Test func multipleVoiceOwnersReleaseKeysWithoutRestoringTheSource() throws {
        let model = try model()
        var source = "previous"
        var posts: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { tool in source = tool.preferredInputSourceID!; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) }, installMonitor: { _ in nil }, logger: { _ in })
        let setter: (VoiceKeyMode, Bool) -> Bool = { _, down in posts.append(down); return true }
        let first = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth, keySetter: setter)
        let second = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .chromecast, keySetter: setter)
        #expect(first && second)
        let firstStop = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth, keySetter: setter)
        #expect(firstStop)
        #expect(source == OnboardingVoiceTool.weixin.preferredInputSourceID)
        #expect(posts == [true])
        let secondStop = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .chromecast, keySetter: setter)
        #expect(secondStop)
        #expect(source == OnboardingVoiceTool.weixin.preferredInputSourceID)
        #expect(posts == [true, false])
    }
    @Test func toolChangesRemainPendingUntilBothRecordingAndKeyCleanupEnd() throws {
        let model = try model()
        model.started = true
        model.isStreaming = true
        model.pendingVoiceToolMappingRefresh = true
        var refreshes = 0
        model.flushPendingVoiceToolMappingRefresh(applyMappings: { refreshes += 1 })
        #expect(refreshes == 0)
        model.settings.setOnboardingVoiceTool(.typeless)
        _ = model.voiceKeyLatch.transition(streaming: true, owner: .bluetooth)
        model.isStreaming = false
        model.flushPendingVoiceToolMappingRefresh(applyMappings: { refreshes += 1 })
        #expect(refreshes == 0)
        #expect(model.pendingVoiceToolMappingRefresh)
        model.voiceKeyLatch.reset()
        model.isStreaming = true
        model.endVoiceSessionIfNeeded(flushAudio: false, applyPendingMappings: { refreshes += 1 })
        #expect(refreshes == 1)
        #expect(!model.requiresOrderedVoiceFn)
        #expect(!model.pendingVoiceToolMappingRefresh)
        model.flushPendingVoiceToolMappingRefresh(applyMappings: { refreshes += 1 })
        #expect(refreshes == 1)
        model.started = false
    }

    @Test func lateSelectionReceivesAFullSettlingIntervalWithoutBlocking() {
        var time: TimeInterval = 0
        var queued: (() -> Void)?
        var result: Bool?
        PreferredInputSourceMonitor.waitForActivation(
            target: "target", current: { time >= 0.49 ? "target" : "previous" }, shouldContinue: { true },
            now: { time }, schedule: { _, work in queued = work }, completion: { result = $0 })
        #expect(result == nil)
        while let check = queued {
            queued = nil
            time += 0.01
            check()
        }
        #expect(result == true)
        #expect(time >= 0.54 && time <= 0.550000001)
    }

    @Test func selectionAfterDeadlineAndCancelledActivationFailOnce() {
        for cancelled in [false, true] {
            var time: TimeInterval = 0
            var queued: (() -> Void)?
            var results: [Bool] = []
            PreferredInputSourceMonitor.waitForActivation(
                target: "target", current: { time >= 0.51 ? "target" : "previous" },
                shouldContinue: { !cancelled || time < 0.1 }, now: { time },
                schedule: { _, work in queued = work }, completion: { results.append($0) })
            while let check = queued {
                queued = nil
                time += 0.01
                check()
            }
            #expect(results == [false])
            #expect(time < (cancelled ? 0.12 : 0.51))
        }
    }

    @Test func cancelledDeferredActivationCannotPostOrMutateNewSession() throws {
        let model = try model()
        var source = "previous"
        var confirmations: [(Bool) -> Void] = []
        var posted: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { tool in source = tool.preferredInputSourceID!; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { _, _, _, done in confirmations.append(done) },
            installMonitor: { _ in nil }, logger: { _ in })
        let setter: (VoiceKeyMode, Bool) -> Bool = { _, down in posted.append(down); return true }
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        #expect(posted.isEmpty)
        #expect(model.voiceSession.commandAudio.isWaiting)
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        confirmations[0](true)
        #expect(posted.isEmpty)
        #expect(model.pendingVoiceKeyMode == .function)
        confirmations[1](true)
        #expect(posted == [true])
        #expect(model.heldVoiceKeyMode == .function)
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        #expect(posted == [true, false])
    }
}
