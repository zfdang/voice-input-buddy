import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Default localization resource lookup") @MainActor
struct LocalizationResourceDefaultTests {
    @Test func bareExecutableUsesResourcesAndLanguageChangesKeepOldSnapshotsStable() throws {
        let name = "locale-default-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))
        let key = SettingsSection.permissions.titleKey
        store.select(.english)
        let english = store.text(key)
        let snapshot = store.snapshot
        store.select(.simplifiedChinese)
        let chinese = store.text(key)
        #expect(english != key)
        #expect(chinese != key)
        #expect(english != chinese)
        #expect(snapshot.text(key) == english)
        #expect(LocalizationSnapshot(language: .english).text(key) == english)
    }

    @Test func rc003VoiceExtensionTestResolvesInBothLanguages() throws {
        let name = "locale-rc003-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))
        let key = "about.preferences.rc003_voice_extension_test"
        store.select(.english)
        let english = store.text(key)
        store.select(.simplifiedChinese)
        let chinese = store.text(key)
        #expect(english == "Test extended voice feature")
        #expect(chinese == "测试长时间语音功能")
    }

    @Test func statusItemShowMenuResolvesInBothLanguages() throws {
        let name = "locale-status-menu-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))
        let key = "status_item.accessibility.show_menu"
        store.select(.english)
        let english = store.text(key)
        store.select(.simplifiedChinese)
        let chinese = store.text(key)
        #expect(english == "Show Menu")
        #expect(chinese == "显示菜单")
    }

    @Test func helpAndSupportResolvesInBothLanguages() throws {
        let name = "locale-help-support-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))
        let key = "menu.help_and_support"
        store.select(.english)
        let english = store.text(key)
        store.select(.simplifiedChinese)
        let chinese = store.text(key)
        #expect(english == "Help & Support")
        #expect(chinese == "帮助与支持")
    }

    @Test func websiteURLResolvesPerLocale() throws {
        let name = "locale-website-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))
        store.select(.english)
        #expect(store.snapshot.localizedWebsiteURL == URL(string: "https://remote.zfdang.com/index.en.html")!)
        store.select(.simplifiedChinese)
        #expect(store.snapshot.localizedWebsiteURL == URL(string: "https://remote.zfdang.com/")!)
        #expect(AppLinks.website(for: Locale(identifier: "en_US")) == AppLinks.englishWebsite)
        #expect(AppLinks.website(for: Locale(identifier: "zh_CN")) == AppLinks.chineseWebsite)
    }

    @Test func statusItemActionResolverDecisionRules() {
        #expect(StatusItemActionResolver.shouldShowMenu(eventType: .rightMouseUp, modifierFlags: []))
        #expect(StatusItemActionResolver.shouldShowMenu(eventType: .rightMouseUp, modifierFlags: .control))
        #expect(StatusItemActionResolver.shouldShowMenu(eventType: .leftMouseUp, modifierFlags: .control))
        #expect(StatusItemActionResolver.shouldShowMenu(eventType: .leftMouseUp, modifierFlags: [.control, .shift]))
        #expect(!StatusItemActionResolver.shouldShowMenu(eventType: .leftMouseUp, modifierFlags: []))
        #expect(!StatusItemActionResolver.shouldShowMenu(eventType: .leftMouseUp, modifierFlags: .shift))
        #expect(!StatusItemActionResolver.shouldShowMenu(eventType: .leftMouseUp, modifierFlags: .command))
        #expect(!StatusItemActionResolver.shouldShowMenu(eventType: .leftMouseUp, modifierFlags: .option))
        #expect(!StatusItemActionResolver.shouldShowMenu(eventType: nil, modifierFlags: nil))
    }
}
