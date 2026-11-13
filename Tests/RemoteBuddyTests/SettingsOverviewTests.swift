import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Settings overview")
struct SettingsOverviewTests {
    private func state(bluetooth: Bool = true, input: Bool = true, accessibility: Bool = true,
                       driver: Bool = true, profiles: [RemoteDeviceProfile] = [], ids: Set<UUID> = [],
                       mapping: Bool = false, tool: OnboardingVoiceTool = .unselected) -> SettingsOverviewState {
        SettingsOverviewState(bluetoothGranted: bluetooth, inputMonitoringGranted: input,
            accessibilityGranted: accessibility,
            audioDevices: driver ? [AudioDeviceInfo(id: 111, uid: BuddyMicrophoneDevicePolicy.deviceUID,
                name: BuddyMicrophoneDevicePolicy.deviceName)] : [],
            profiles: profiles, connectedIDs: ids, mappingEnabled: mapping,
            integrationTool: tool, remoteName: { $0.customName })
    }

    @Test func missingDriverPreventsReadyDespiteAllPermissions() {
        #expect(state().permissionsReady)
        #expect(state(driver: false).missingRequirementKeys == ["settings.driver.title"])
        #expect(!state(driver: false).permissionsReady)
        #expect(state(bluetooth: false, input: false, accessibility: false, driver: false)
            .missingRequirementKeys == ["permission.bluetooth.title", "permission.input_monitoring.title",
                "permission.accessibility.title", "settings.driver.title"])
    }

    @Test func connectedNamesExcludeDisconnectedAndUnregisteredDevices() {
        let first = RemoteDeviceProfile(customName: "Study", mappings: .init(buttonBindings: [:], buttonShortcuts: [:], secondaryButtonBindings: [:]))
        let second = RemoteDeviceProfile(customName: "Living room", mappings: .init(buttonBindings: [:], buttonShortcuts: [:], secondaryButtonBindings: [:]))
        #expect(!state(profiles: [first, second]).remoteReady)
        let snapshot = state(profiles: [first, second], ids: [second.id, UUID()])
        #expect(snapshot.remoteReady)
        #expect(snapshot.connectedRemoteNames == ["Living room"])
    }

    @Test func optionalConfigurationDoesNotBlockPrerequisites() {
        let snapshot = state()
        #expect(snapshot.permissionsReady)
        #expect(!snapshot.mappingEnabled)
        #expect(!snapshot.integrationReady)
        #expect(state(mapping: true, tool: .voiceBuddy).integrationReady)
    }

    @Test func changedPrerequisitesAreReflectedWithoutRestartingOnboarding() {
        let before = state(input: false, driver: false)
        let after = state()
        #expect(!before.permissionsReady)
        #expect(after.permissionsReady)
        #expect(after.missingRequirementKeys.isEmpty)
        #expect(!state(accessibility: false).permissionsReady)
    }

    @Test @MainActor func summariesNameMissingRequirementsAndReflectRepairs() throws {
        let suite = "overview.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))
        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.select(language)
            let summary = state(input: false, driver: false).permissionsSummary(using: localization)
            #expect(summary.contains(localization.text("permission.input_monitoring.title")))
            #expect(summary.contains(localization.text("settings.driver.title")))
            #expect(!summary.contains("%@"))
            #expect(state().permissionsSummary(using: localization) == localization.text("settings.overview.ready"))
        }
    }

    @Test func listsUseLocale() {
        let chinese = SettingsOverviewState.localizedList(["蓝牙", "辅助功能"], locale: Locale(identifier: "zh_CN"))
        #expect(!chinese.contains(", "))
        #expect(chinese.contains("蓝牙") && chinese.contains("辅助功能"))
    }
}
