import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Voice tool configuration transfer")
@MainActor
struct VoiceToolConfigurationTransferTests {
    @Test(arguments: [OnboardingVoiceTool.macosDictation, .typeless, .other])
    func restoresTheToolAndItsStartSequence(tool: OnboardingVoiceTool) throws {
        let sourceName = "voice-tool-export-" + UUID().uuidString
        let targetName = "voice-tool-import-" + UUID().uuidString
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            targetDefaults.removePersistentDomain(forName: targetName)
        }
        let source = AppSettings(defaults: sourceDefaults)
        source.setOnboardingVoiceTool(tool)
        source.voiceKeyMode = .function
        source.voiceFnTapModeEnabled = true
        let target = AppSettings(defaults: targetDefaults)
        target.setOnboardingVoiceTool(tool == .macosDictation ? .other : .macosDictation)
        try target.importConfiguration(from: source.exportedConfigurationData())
        #expect(target.onboardingVoiceTool == tool)
        #expect(target.voiceKeyConfigurationState == source.voiceKeyConfigurationState)
        let reloaded = AppSettings(defaults: targetDefaults)
        #expect(reloaded.onboardingVoiceTool == tool)
        #expect(reloaded.onboardingVoiceTool.functionKeyStartTapCount == tool.functionKeyStartTapCount)

        let clock = ControlledTestScheduler()
        var edges: [Bool] = []
        let session = VoiceFnTapSessionController(
            startTapCount: { reloaded.onboardingVoiceTool.functionKeyStartTapCount },
            schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { edges.append($0); return true },
            enqueueAudio: { _ in }, drainAudio: { _, done in done() },
            onFailure: { _ in Issue.record("Unexpected key failure") }
        )
        session.setEnabled(reloaded.voiceFnTapModeEnabled)
        #expect(session.startVoice())
        clock.runAll()
        #expect(edges == Array(repeating: [true, false], count: tool.functionKeyStartTapCount).flatMap { $0 })
        #expect(session.stopVoice())
        clock.runAll()
        #expect(edges.count == (tool.functionKeyStartTapCount + 1) * 2)
    }

    @Test func aToolOnlyImportMustReleaseThePreviousVoiceKeyBeforeApplying() throws {
        let name = "voice-tool-import-safety-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceKeyMode = .function
        settings.voiceFnTapModeEnabled = true
        settings.setOnboardingVoiceTool(.macosDictation)
        let data = try settings.exportedConfigurationData()
        settings.setOnboardingVoiceTool(.typeless)
        #expect(throws: AppConfigurationError.unsafeVoiceKeyChange) {
            try BridgeAppModel.importConfiguration(from: data, into: settings,
                isStreaming: false, releaseVoiceKey: { false })
        }
        #expect(settings.onboardingVoiceTool == .typeless)
        var releases = 0
        let changed = try BridgeAppModel.importConfiguration(from: data, into: settings,
            isStreaming: false, releaseVoiceKey: { releases += 1; return true })
        #expect(changed)
        #expect(releases == 1)
        #expect(settings.onboardingVoiceTool == .macosDictation)
    }

    @Test func chromecastVoiceModeRoundTripsAcrossExportAndImport() throws {
        let sourceName = "chromecast-export-" + UUID().uuidString
        let targetName = "chromecast-import-" + UUID().uuidString
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            targetDefaults.removePersistentDomain(forName: targetName)
        }
        let source = AppSettings(defaults: sourceDefaults)
        source.chromecastVoiceMode = .hold
        let target = AppSettings(defaults: targetDefaults)
        target.chromecastVoiceMode = .toggle
        let data = try source.exportedConfigurationData()
        try target.importConfiguration(from: data)
        #expect(target.chromecastVoiceMode == .hold)
    }

    @Test func importRollbackRestoresCompleteAffectedState() throws {
        let name = "import-rollback-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        // Set up initial state with unique values across categories
        settings.gainDB = 6.0
        settings.chromecastVoiceMode = .hold
        settings.applicationLanguage = .simplifiedChinese
        settings.showDockIcon = false
        settings.openMainWindowAtLaunch = false
        settings.voiceKeyMode = .leftOption
        settings.setOnboardingVoiceTool(.macosDictation)

        let initialAppProfile = CustomApplicationProfile(
            id: UUID(),
            displayName: "Finder Initial",
            bundleIdentifier: "com.apple.finder",
            applicationPath: "/System/Library/CoreServices/Finder.app",
            focusStrategy: .none
        )
        settings.customApplicationProfiles = [initialAppProfile]

        settings.setBaseBinding(
            ConfiguredButtonAction(action: .playPause, shortcut: nil),
            for: .ok,
            trigger: .singleClick,
            profileID: settings.selectedRemoteProfileID
        )
        let initialAction = settings.configuredBaseAction(for: .ok, trigger: .singleClick).action
        #expect(initialAction == .playPause)

        let otherDefaults = try #require(UserDefaults(suiteName: name + "-other"))
        defer { otherDefaults.removePersistentDomain(forName: name + "-other") }
        let otherSettings = AppSettings(defaults: otherDefaults)

        otherSettings.gainDB = 18.0
        otherSettings.chromecastVoiceMode = .toggle
        otherSettings.applicationLanguage = .english
        otherSettings.showDockIcon = true
        otherSettings.openMainWindowAtLaunch = true
        otherSettings.voiceKeyMode = .rightCommand
        otherSettings.setOnboardingVoiceTool(.weixin)

        let importedAppProfile = CustomApplicationProfile(
            id: UUID(),
            displayName: "Finder Imported",
            bundleIdentifier: "com.apple.finder",
            applicationPath: "/System/Library/CoreServices/Finder.app",
            focusStrategy: .none
        )
        otherSettings.customApplicationProfiles = [importedAppProfile]

        otherSettings.setBaseBinding(
            ConfiguredButtonAction(action: .showDesktop, shortcut: nil),
            for: .ok,
            trigger: .singleClick,
            profileID: otherSettings.selectedRemoteProfileID
        )
        let otherData = try otherSettings.exportedConfigurationData()

        // Clean import succeeds
        try settings.importConfiguration(from: otherData)
        #expect(settings.configurationImportNotice == nil)
        #expect(settings.lastImportRollbackSnapshot != nil)
        #expect(settings.configuredBaseAction(for: .ok, trigger: .singleClick).action == .showDesktop)
        #expect(settings.gainDB == 18.0)
        #expect(settings.chromecastVoiceMode == .toggle)
        #expect(settings.applicationLanguage == .english)
        #expect(settings.showDockIcon == true)
        #expect(settings.openMainWindowAtLaunch == true)
        #expect(settings.voiceKeyMode == .rightCommand)
        #expect(settings.onboardingVoiceTool == .weixin)
        #expect(settings.customApplicationProfiles.map(\.displayName) == ["Finder Imported"])

        // Rollback restores complete state
        #expect(settings.rollbackLastImport())
        #expect(settings.lastImportRollbackSnapshot == nil)
        #expect(settings.configuredBaseAction(for: .ok, trigger: .singleClick).action == .playPause)
        #expect(settings.gainDB == 6.0)
        #expect(settings.chromecastVoiceMode == .hold)
        #expect(settings.applicationLanguage == .simplifiedChinese)
        #expect(settings.showDockIcon == false)
        #expect(settings.openMainWindowAtLaunch == false)
        #expect(settings.voiceKeyMode == .leftOption)
        #expect(settings.onboardingVoiceTool == .macosDictation)
        #expect(settings.customApplicationProfiles.map(\.displayName) == ["Finder Initial"])

        // Second rollback returns false
        #expect(!settings.rollbackLastImport())
    }
}
