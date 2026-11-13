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
                frontmost: { current }, focus: { app, pid in
                    #expect(pid == 42)
                    calls.append(app)
                    return ScheduledOperation {}
                })
            settings.setAllApplicationIntegrations(enabled: true)
            controller.start()
            defer { controller.stop() }
            notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            #expect(calls.isEmpty)
            controller.voiceInputStarted()
            #expect(calls == [.chatGPT])
            settings.setApplicationIntegration(.chatGPT, enabled: false)
            controller.voiceInputStarted()
            current = ("com.apple.TextEdit", 42)
            controller.voiceInputStarted()
            current = nil
            controller.voiceInputStarted()
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
                frontmost: { (ApplicationIntegration.chatGPT.bundleIdentifier, 10) }, focus: { _, _ in
                    calls += 1
                    return ScheduledOperation.mainQueueCancellation { cancelled += 1 }
                })
            controller.start()
            controller.voiceInputStarted()
            notifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            #expect(calls == 1)
            #expect(cancelled == 1)
            controller.voiceInputStarted()
            notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
            #expect(cancelled == 2)
            controller.voiceInputStarted()
            controller.stop()
            #expect(cancelled == 3)
            controller.voiceInputStarted()
            #expect(calls == 3)
        }
    }

    @Test(arguments: [VoiceKeyMode.function, .leftCommand])
    func acceptedVoiceKeyStartsIntegrationAndReleaseCancelsIt(mode: VoiceKeyMode) throws {
        try withSettings { settings, _ in
            settings.setAllApplicationIntegrations(enabled: true)
            settings.voiceKeyMode = mode
            var calls = 0
            var cancelled = 0
            let model = BridgeAppModel(settings: settings)
            let controller = ApplicationIntegrationController(settings: settings, notifications: NotificationCenter(),
                frontmost: { (ApplicationIntegration.antigravity.bundleIdentifier, 42) }, focus: { app, _ in
                    #expect(app == .antigravity)
                    calls += 1
                    return ScheduledOperation.mainQueueCancellation { cancelled += 1 }
                })
            model.applicationIntegrationController = controller
            controller.start()
            defer { controller.stop() }
            #expect(calls == 0)
            #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: false, owner: .bluetooth,
                                            keySetter: { _, _ in true }))
            #expect(calls == 1)
            #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: false, owner: .bluetooth,
                                            keySetter: { _, _ in true }))
            #expect(cancelled == 1)
        }
    }

    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private func candidate(_ label: String = "", role: String = "AXTextArea", identifier: String = "", context: String = "",
                           protected: Bool = false, enabled: Bool = true,
                           frame: CGRect = CGRect(x: 350, y: 620, width: 600, height: 140)) -> KeyboardInjector.AccessibilityTextCandidate {
        .init(role: role, protectedContent: protected, identifier: identifier, title: "", description: "",
              help: "", placeholder: label, context: context, frame: frame, enabled: enabled)
    }

    @Test func appSpecificComposersAreRecognized() {
        #expect(KeyboardInjector.integratedComposerScore(candidate("输入消息", identifier: "chat_input_field"),
            integration: .weChat, windowFrame: window) == 400)
        #expect(KeyboardInjector.integratedComposerScore(candidate("Message input"),
            integration: .antigravity, windowFrame: window) == 400)
        #expect(KeyboardInjector.integratedComposerScore(candidate("Work with ChatGPT"),
            integration: .chatGPT, windowFrame: window) != nil)
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
