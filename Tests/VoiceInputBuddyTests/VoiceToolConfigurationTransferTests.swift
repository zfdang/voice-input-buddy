import Foundation
import Testing
@testable import VoiceInputBuddy

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
}
