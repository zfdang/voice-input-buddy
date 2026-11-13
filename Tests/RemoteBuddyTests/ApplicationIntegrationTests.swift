import AppKit
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Application integrations")
@MainActor
struct ApplicationIntegrationTests {
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "app-integration.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }

    @Test func switchesPersistIndependentlyAndSupportBulkChanges() throws {
        try withSettings { settings, defaults in
            #expect(settings.enabledApplicationIntegrations.isEmpty)
            settings.setApplicationIntegration(.chatGPT, enabled: true)
            #expect(AppSettings(defaults: defaults).isApplicationIntegrationEnabled(.chatGPT))
            #expect(!settings.isApplicationIntegrationEnabled(.weChat))
            settings.setAllApplicationIntegrations(enabled: true)
            settings.setApplicationIntegration(.weChat, enabled: false)
            let restored = AppSettings(defaults: defaults)
            #expect(restored.enabledApplicationIntegrations.count == 2)
            #expect(!restored.isApplicationIntegrationEnabled(.weChat))
            settings.setAllApplicationIntegrations(enabled: false)
            #expect(AppSettings(defaults: defaults).enabledApplicationIntegrations.isEmpty)
        }
    }

    @Test func activationAloneNeverFocusesAndVoiceStartUsesOnlyEnabledForegroundApp() throws {
        try withSettings { settings, _ in
            let notifications = NotificationCenter()
            var current: (bundleIdentifier: String?, pid: pid_t)? = ("com.openai.codex", 42)
            var calls: [ApplicationIntegration] = []
            let controller = ApplicationIntegrationController(settings: settings, notifications: notifications,
                frontmost: { current }, focus: { app, pid, _ in
                    #expect(pid == 42)
                    calls.append(app)
                    return ScheduledOperation {}
                })
            settings.setAllApplicationIntegrations(enabled: true)
            controller.start()
            defer { controller.stop() }
            notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            #expect(calls.isEmpty)
            _ = controller.prepareForVoiceInput { _ in }
            #expect(calls == [.chatGPT])
            settings.setApplicationIntegration(.chatGPT, enabled: false)
            _ = controller.prepareForVoiceInput { _ in }
            current = ("com.apple.TextEdit", 42)
            _ = controller.prepareForVoiceInput { _ in }
            current = nil
            _ = controller.prepareForVoiceInput { _ in }
            #expect(calls == [.chatGPT])
        }
    }

    @Test func switchingAppsCancelsPendingFocusWithoutStartingAnother() throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            let notifications = NotificationCenter()
            var calls = 0
            var cancelled = 0
            let controller = ApplicationIntegrationController(settings: settings, notifications: notifications,
                frontmost: { (ApplicationIntegration.chatGPT.bundleIdentifier, 10) }, focus: { _, _, _ in
                    calls += 1
                    return ScheduledOperation.mainQueueCancellation { cancelled += 1 }
                })
            controller.start()
            _ = controller.prepareForVoiceInput { _ in }
            notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            #expect(calls == 1)
            #expect(cancelled == 1)
            _ = controller.prepareForVoiceInput { _ in }
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(cancelled == 2)
            _ = controller.prepareForVoiceInput { _ in }
            controller.stop()
            #expect(cancelled == 3)
            _ = controller.prepareForVoiceInput { _ in }
            #expect(calls == 3)
        }
    }

    @Test(arguments: [VoiceKeyMode.function, .leftCommand])
    func voiceTriggerWaitsForFocusAndThenInputSource(mode: VoiceKeyMode) throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            settings.voiceKeyMode = mode
            let model = BridgeAppModel(settings: settings)
            var focusDone: ((Bool) -> Void)?
            var events: [String] = []
            let controller = ApplicationIntegrationController(settings: settings, notifications: NotificationCenter(),
                frontmost: { (ApplicationIntegration.weChat.bundleIdentifier, 42) }, focus: { _, _, done in
                    events.append("focus_requested")
                    focusDone = done
                    return ScheduledOperation {}
                })
            model.applicationIntegrationController = controller
            var source = "previous"
            model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
                voiceTool: { .weixin }, prepareInputSource: { _ in events.append("select_source"); return .selected },
                currentInputSourceID: { source }, restoreInputSource: { _ in .selected },
                waitForInputSourceActivation: { target, _, _, done in
                    source = target
                    events.append("source_ready")
                    done(true)
                }, installMonitor: { _ in nil }, logger: { _ in })
            controller.start()
            defer { controller.stop() }
            #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: false, owner: .bluetooth,
                keySetter: { _, down in events.append(down ? "voice_down" : "voice_up"); return true }))
            #expect(events == ["focus_requested"])
            let buffered = model.voiceSession.commandAudio.appendIfWaiting([1, 2, 3])
            #expect(buffered)
            events.append("focus_confirmed")
            let finishFocus = try #require(focusDone)
            finishFocus(true)
            #expect(events == ["focus_requested", "focus_confirmed", "select_source", "source_ready", "voice_down"])
            #expect(model.voiceSession.commandAudio.drain() == [1, 2, 3])
            #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                keySetter: { _, down in events.append(down ? "voice_down" : "voice_up"); return true }))
            #expect(events.last == "voice_up")
        }
    }

    @Test(arguments: [false, true])
    func releaseOrAppChangeDuringFocusCannotTriggerVoice(switchApp: Bool) throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            settings.voiceKeyMode = .leftCommand
            let model = BridgeAppModel(settings: settings)
            let notifications = NotificationCenter()
            var focusDone: ((Bool) -> Void)?
            var edges: [Bool] = []
            var completed: [Bool] = []
            let controller = ApplicationIntegrationController(settings: settings, notifications: notifications,
                frontmost: { (ApplicationIntegration.weChat.bundleIdentifier, 42) }, focus: { _, _, done in
                    focusDone = done
                    return ScheduledOperation {}
                })
            model.applicationIntegrationController = controller
            controller.start()
            defer { controller.stop() }
            #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
                keySetter: { _, down in edges.append(down); return true }, completion: { completed.append($0) }))
            if switchApp { notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil) }
            else {
                #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                    keySetter: { _, down in edges.append(down); return true }))
            }
            let finishFocus = try #require(focusDone)
            finishFocus(true)
            #expect(edges.isEmpty)
            #expect(completed == [false])
            #expect(!model.voiceKeyLatch.isHeld)
            #expect(!model.voiceKeyActivationInProgress)
            #expect(!model.voiceSession.commandAudio.isWaiting)
        }
    }

    @Test(arguments: [false, true])
    func unsuccessfulOptionalFocusStillStartsHoldVoiceAndFnTap(tapMode: Bool) throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            settings.voiceKeyMode = .function
            settings.voiceFnTapModeEnabled = tapMode
            let model = BridgeAppModel(settings: settings)
            var done: ((Bool) -> Void)?
            var edges: [Bool] = []
            var results: [Bool] = []
            var states: [ApplicationIntegrationPreparationState] = []
            let controller = ApplicationIntegrationController(settings: settings, notifications: NotificationCenter(),
                frontmost: { (ApplicationIntegration.weChat.bundleIdentifier, 42) }, focus: { _, _, callback in
                    done = callback
                    return ScheduledOperation {}
                }, onStateChange: { states.append($0) })
            model.applicationIntegrationController = controller
            controller.start()
            defer { controller.stop() }
            model.voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(snapshot: {
                VoiceInputDestinationSnapshot(bundleIdentifier: ApplicationIntegration.weChat.bundleIdentifier,
                    role: "AXTextArea", subrole: "", enabled: true, editable: true, protectedContent: false,
                    semanticText: "chat_input_field")
            })
            let clock = ControlledTestScheduler()
            let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
                destinationReadiness: { model.prepareIntegratedVoiceInputDestination(completion: $0, schedule: clock.voiceSchedule) },
                setFunctionKeyPressed: { edges.append($0); return true }, enqueueAudio: { _ in },
                drainAudio: { _, callback in callback() }, onFailure: { _ in })
            if tapMode {
                session.setEnabled(true)
                #expect(session.startVoice())
            } else {
                #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
                    keySetter: { _, down in edges.append(down); return true }, completion: { results.append($0) }))
            }
            let finish = try #require(done)
            finish(false)
            finish(true) // A late success must not undo a failure.
            clock.runAll()
            #expect(states == [.waiting, .unavailable])
            if tapMode { #expect(edges == [true, false]) }
            else {
                #expect(edges == [true])
                #expect(results == [true])
                #expect(model.voiceKeyLatch.isHeld)
                #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                    keySetter: { _, down in edges.append(down); return true }))
            }
            session.shutdown()
        }
    }

    @Test func optionalFocusTimeoutContinuesExactlyOnceAndIgnoresLateSuccess() throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            let clock = ControlledTestScheduler()
            var focusDone: ((Bool) -> Void)?
            var results: [VoiceInputDestinationWaitResult] = []
            let controller = ApplicationIntegrationController(settings: settings, notifications: NotificationCenter(),
                frontmost: { (ApplicationIntegration.weChat.bundleIdentifier, 42) }, focus: { _, _, done in
                    focusDone = done
                    return ScheduledOperation {}
                }, schedule: clock.voiceSchedule)
            controller.start()
            defer { controller.stop() }
            _ = controller.prepareForVoiceInput { results.append($0) }
            clock.advance(to: 3000)
            let finishFocus = try #require(focusDone)
            finishFocus(true)
            #expect(results == [.ready])
        }
    }

    @Test(arguments: [false, true])
    func fnTapWaitsForFocusAndRetainsEarlyAudioUnlessReleased(released: Bool) throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            settings.voiceFnTapModeEnabled = true
            let model = BridgeAppModel(settings: settings)
            let clock = ControlledTestScheduler()
            var focusDone: ((Bool) -> Void)?
            var edges: [Bool] = []
            var audio: [[Int16]] = []
            let controller = ApplicationIntegrationController(settings: settings, notifications: NotificationCenter(),
                frontmost: { (ApplicationIntegration.weChat.bundleIdentifier, 42) }, focus: { _, _, done in
                    focusDone = done
                    return ScheduledOperation {}
                }, schedule: clock.voiceSchedule)
            model.applicationIntegrationController = controller
            model.voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(snapshot: {
                VoiceInputDestinationSnapshot(bundleIdentifier: ApplicationIntegration.weChat.bundleIdentifier,
                    role: "AXTextArea", subrole: "", enabled: true, editable: true, protectedContent: false,
                    semanticText: "chat_input_field")
            })
            let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
                destinationReadiness: { model.prepareIntegratedVoiceInputDestination(completion: $0, schedule: clock.voiceSchedule) },
                setFunctionKeyPressed: { edges.append($0); return true }, enqueueAudio: { audio.append($0) },
                drainAudio: { _, done in done() }, onFailure: { _ in Issue.record("Unexpected failure") })
            controller.start()
            defer { session.shutdown(); controller.stop() }
            session.setEnabled(true)
            #expect(session.startVoice())
            #expect(session.receive([1, 2, 3]))
            #expect(edges.isEmpty && audio.isEmpty)
            if released { #expect(session.stopVoice()) }
            let finishFocus = try #require(focusDone)
            finishFocus(true)
            clock.advance(to: 120)
            #expect(edges == (released ? [] : [true, false]))
            #expect(audio == (released ? [] : [[1, 2, 3]]))
            #expect(!model.requiresOrderedVoiceFn)
        }
    }

    @Test func focusAndDestinationShareOneDeadlineWithinAudioCapacity() {
        let clock = ControlledTestScheduler()
        let sequence = VoiceInputPreparationSequence(schedule: clock.voiceSchedule)
        var focusDone: ((VoiceInputDestinationWaitResult) -> Void)?
        var destinationDone: ((VoiceInputDestinationWaitResult) -> Void)?
        var results: [VoiceInputDestinationWaitResult] = []
        var cancelledDestination = false
        let wait = sequence.start(stages: [
            { focusDone = $0; return .waiting(ScheduledOperation {}) },
            { destinationDone = $0; return .waiting(.mainQueueCancellation { cancelledDestination = true }) },
        ], completion: { results.append($0) })
        clock.advance(to: 3500)
        focusDone?(.ready)
        clock.advance(to: 4000)
        #expect(results == [.cancelled(.timedOut)])
        #expect(cancelledDestination)
        destinationDone?(.ready)
        if case let .waiting(operation) = wait { operation.cancel() }
        #expect(results.count == 1)
        #expect(Int(VoiceInputPreparationSequence.maximumWait * 16_000) < VoicePlaybackQueueCapacity.maximumPreRollSamples)
    }

    @Test func cancellingPreparationIsSilentAndDiscardsAllLateCallbacks() {
        let clock = ControlledTestScheduler()
        let sequence = VoiceInputPreparationSequence(schedule: clock.voiceSchedule)
        var done: ((VoiceInputDestinationWaitResult) -> Void)?
        let wait = sequence.start(stages: [{ done = $0; return .waiting(ScheduledOperation {}) }],
            completion: { _ in Issue.record("Owning session cancellation must be silent") })
        if case let .waiting(operation) = wait { operation.cancel() }
        done?(.ready)
        clock.runAll()
    }

    @Test func integrationWaitUsesBoundedPreRollAndRestoresNormalCapacityNextSession() {
        var buffer = CommandVoiceActivationAudioBuffer(maximumSampleCount: 4)
        buffer.begin(maximumSampleCount: 12)
        let bufferedDuringFocus = buffer.appendIfWaiting(Array(1...10))
        #expect(bufferedDuringFocus)
        #expect(buffer.drain() == Array(1...10))
        buffer.begin()
        let bufferedNormally = buffer.appendIfWaiting(Array(1...10))
        #expect(bufferedNormally)
        #expect(buffer.drain() == [7, 8, 9, 10])
    }

    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private func candidate(_ label: String = "", role: String = "AXTextArea", identifier: String = "", context: String = "",
                           protected: Bool = false, enabled: Bool = true,
                           frame: CGRect = CGRect(x: 350, y: 620, width: 600, height: 140)) -> KeyboardInjector.AccessibilityTextCandidate {
        .init(role: role, protectedContent: protected, identifier: identifier, title: "", description: "",
              help: "", placeholder: label, context: context, frame: frame, enabled: enabled)
    }

    @Test func antigravityClickFallbackOnlyTargetsTheVerifiedVisibleMessageInput() {
        let field = candidate("Message input")
        let point = KeyboardInjector.integratedComposerClickPoint(field, integration: .antigravity, windowFrame: window)
        #expect(point == CGPoint(x: 374, y: 636))
        for app in [ApplicationIntegration.weChat, .chatGPT] {
            #expect(KeyboardInjector.integratedComposerClickPoint(field, integration: app, windowFrame: window) == nil)
        }
        for field in [candidate("Search messages"), candidate("Message input", protected: true),
                      candidate("composer"), candidate("Message input", enabled: false),
                      candidate("Message input", frame: CGRect(x: 1200, y: 600, width: 600, height: 100))] {
            #expect(KeyboardInjector.integratedComposerClickPoint(field, integration: .antigravity, windowFrame: window) == nil)
        }
    }

    @Test func antigravityClickWaitsForRealFocusAndStopsWhenCancelled() {
        for cancelled in [false, true] {
            var clicks = 0
            var waits = 0
            var queries = 0
            let result = KeyboardInjector.clickIntegratedComposer(candidate("Message input"),
                integration: .antigravity, windowFrame: window,
                canContinue: { !cancelled || waits == 0 }, hitTest: { _ in true },
                postClick: { _ in clicks += 1; return true },
                isFocused: { queries += 1; return waits >= 2 }, pause: { waits += 1 })
            #expect(clicks == 1)
            #expect(result == !cancelled)
            #expect(waits == (cancelled ? 1 : 2))
            #expect(queries == (cancelled ? 1 : 3))
        }
        let result = KeyboardInjector.clickIntegratedComposer(candidate("Message input"),
            integration: .antigravity, windowFrame: window, canContinue: { false }, hitTest: { _ in true },
            postClick: { _ in Issue.record("Cancelled work must not click"); return true },
            isFocused: { Issue.record("Cancelled work must not query focus"); return true }, pause: {})
        #expect(!result)
    }

    @Test func occludedOrUnverifiedComposerNeverReceivesSyntheticClick() {
        for hit in [Int?.none, 7, 8] {
            let result = KeyboardInjector.clickIntegratedComposer(candidate("Message input"), integration: .antigravity,
                windowFrame: window, canContinue: { true }, hitTest: { _ in
                    KeyboardInjector.accessibilityAncestorChainContains(hit: hit, target: 1,
                        equal: ==, parent: { $0 == 8 ? 7 : nil })
                }, postClick: { _ in Issue.record("Occluded input must not be clicked"); return true },
                isFocused: { false }, pause: {})
            #expect(!result)
        }
        #expect(KeyboardInjector.accessibilityAncestorChainContains(hit: 3, target: 1,
            equal: ==, parent: { [3: 2, 2: 1][$0] }))
        #expect(KeyboardInjector.accessibilityAncestorChainContains(hit: 1, target: 1, equal: ==, parent: { _ in nil }))
        #expect(!KeyboardInjector.accessibilityAncestorChainContains(hit: 3, target: 1,
            equal: ==, parent: { [3: 2, 2: 3][$0] }))
    }

    @Test func composerDiscoveryOnlyReadsMetadataAndCannotReadOrWriteMessageText() {
        var reads: [String] = []
        let field = KeyboardInjector.accessibilityTextMetadata(role: "AXTextArea", frame: window,
            context: "conversation", selectedContext: false, read: { key in
                reads.append(key)
                if key == "AXValue" || key == "AXSelectedText" { Issue.record("Message content must not be queried") }
                return ["AXIdentifier": "chat_input_field", "AXEnabled": true][key]
            })
        #expect(field.identifier == "chat_input_field")
        #expect(KeyboardInjector.integratedComposerScore(field, integration: .weChat, windowFrame: window) != nil)
        #expect(!reads.contains("AXValue") && !reads.contains("AXSelectedText"))
        #expect(Set(reads) == ["AXSubrole", "AXProtectedContent", "AXIdentifier", "AXTitle", "AXDescription",
                               "AXHelp", "AXPlaceholderValue", "AXEnabled", "AXFocused"])
    }

    @Test func injectedCandidatePipelineOnlyFocusesTheUniqueComposerAndNeverSubmitsText() {
        let nodes = [(element: "search", snapshot: candidate("Search messages")),
                     (element: "editor", snapshot: candidate("code editor")),
                     (element: "composer", snapshot: candidate("Message input"))]
        var actions: [String] = []
        let focused = KeyboardInjector.focusIntegratedCandidates(nodes, integration: .antigravity,
            windowFrame: window, canContinue: { true }, focus: { actions.append("focus:\($0)"); return true },
            click: { _, _ in Issue.record("Direct focus must not click"); return false })
        #expect(focused && actions == ["focus:composer"])
        for current in [false, true] {
            actions.removeAll()
            let ambiguous = nodes + [(element: "other_composer", snapshot: candidate("Message input"))]
            let result = KeyboardInjector.focusIntegratedCandidates(ambiguous, integration: .antigravity,
                windowFrame: window, canContinue: { current },
                focus: { actions.append("focus:\($0)"); return true },
                click: { _, _ in actions.append("click"); return true })
            #expect(!result && actions.isEmpty)
        }
        actions.removeAll()
        let clicked = KeyboardInjector.focusIntegratedCandidates(nodes, integration: .antigravity,
            windowFrame: window, canContinue: { true }, focus: { actions.append("focus:\($0)"); return false },
            click: { element, snapshot in
                actions.append("click:\(element)")
                return KeyboardInjector.clickIntegratedComposer(snapshot, integration: .antigravity, windowFrame: window,
                    canContinue: { true }, hitTest: { _ in true }, postClick: { _ in true }, isFocused: { true }, pause: {})
            })
        #expect(clicked && actions == ["focus:composer", "click:composer"])
    }

    @Test func appSpecificComposersAreRecognized() {
        #expect(KeyboardInjector.integratedComposerScore(candidate("输入消息", identifier: "chat_input_field"),
            integration: .weChat, windowFrame: window) == 400)
        #expect(KeyboardInjector.integratedComposerScore(candidate("Message input"),
            integration: .antigravity, windowFrame: window) == 400)
        #expect(KeyboardInjector.integratedComposerScore(candidate("Work with ChatGPT"),
            integration: .chatGPT, windowFrame: window) != nil)
        #expect(KeyboardInjector.integratedComposerScore(candidate("Do anything"),
            integration: .chatGPT, windowFrame: window) != nil)
        #expect(ApplicationIntegration.chatGPT.bundleIdentifier == "com.openai.codex")
        #expect(ApplicationIntegration.matching("com.google.antigravity-ide") == nil)
        #expect(ApplicationIntegration.matching("com.openai.codex") == .chatGPT)
        #expect(ApplicationIntegration.matching("com.openai.chat") == .chatGPT)
    }

    @Test func searchCodeSecureAndUnlabeledGenericEditorsAreNotComposers() {
        for app in ApplicationIntegration.allCases {
            for field in [candidate("Search messages"), candidate("API key composer"),
                          candidate("composer", protected: true), candidate("composer", enabled: false),
                          candidate("composer", context: "monaco code editor"),
                          candidate("composer", role: "AXSecureTextField"),
                          candidate("composer", frame: CGRect(x: 2000, y: 620, width: 600, height: 100))] {
                #expect(KeyboardInjector.integratedComposerScore(field, integration: app, windowFrame: window) == nil)
            }
            if app != .weChat {
                #expect(KeyboardInjector.integratedComposerScore(candidate(context: "Chat message composer"),
                    integration: app, windowFrame: window) == nil)
            }
        }
    }

    @Test func weChatRequiresVerifiedIdentifierRatherThanGeometryOrLabelGuessing() {
        #expect(KeyboardInjector.integratedComposerScore(candidate(), integration: .weChat, windowFrame: window) == nil)
        #expect(KeyboardInjector.integratedComposerScore(candidate("message"), integration: .weChat, windowFrame: window) == nil)
        #expect(KeyboardInjector.integratedComposerScore(candidate("Search", identifier: "chat_input_field"),
            integration: .weChat, windowFrame: window) == nil)
    }

    @Test func appIntegrationIsImmediatelyBeforeAboutAndHasLocalizedDescriptions() throws {
        let sections = SettingsPageBehavior.sidebarSections()
        #expect(sections.suffix(2) == [.applicationIntegration, .about])
        try withSettings { settings, _ in
            let localization = LocalizationStore(settings: settings)
            for language in [AppLanguage.english, .simplifiedChinese] {
                localization.select(language)
                for key in ["application_integration.title", "application_integration.introduction"] +
                    ApplicationIntegration.allCases.map(\.detailKey) {
                    #expect(localization.text(key) != key)
                }
            }
        }
    }
}
