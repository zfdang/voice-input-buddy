import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Configuration import session boundaries") @MainActor
struct ConfigurationImportSessionTests {
    @Test func unchangedShortcutStillRejectsImportDuringRecording() throws {
        let suite = "import-session-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let data = try settings.exportedConfigurationData()
        settings.gainDB = 19
        #expect(throws: AppConfigurationError.self) {
            try BridgeAppModel.importConfiguration(from: data, into: settings, isStreaming: true,
                releaseVoiceKey: { Issue.record("Import must not release an active key"); return true })
        }
        #expect(settings.gainDB == 19)
        #expect(try !BridgeAppModel.importConfiguration(from: data, into: settings, isStreaming: false,
            releaseVoiceKey: { Issue.record("Unchanged mode must not post a key"); return true }))
        #expect(settings.gainDB == 10)
    }

    @Test(arguments: ["audio_start", "activation", "recording"])
    func pendingSessionsRejectBeforeMutatingSettingsOrAudio(phase: String) throws {
        let suite = "import-session-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let payload = try settings.exportedConfigurationData()
        settings.gainDB = 21
        let model = BridgeAppModel(settings: settings)
        switch phase {
        case "audio_start": model.voiceSession.pendingStart.begin(for: UUID())
        case "activation": model.voiceKeyActivationInProgress = true
        default: model.voiceSession.isActive = true
        }
        #expect(model.isVoiceConfigurationBusy)
        #expect(throws: AppConfigurationError.self) { try model.importConfiguration(from: payload) }
        #expect(settings.gainDB == 21)
        #expect(model.audio.configurationGeneration == 0)
    }
}
