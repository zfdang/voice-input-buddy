import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Review input boundaries")
struct ReviewInputBoundaryTests {
    @Test func inheritedOutputPipeCannotOutliveDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = BoundedCommandRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 1.5 & printf done"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.2)
    }

    @Test func drainsOutputLargerThanPipeCapacity() {
        let result = BoundedCommandRunner.run(executableURL: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=65536", "count=8"], timeout: 3)
        #expect(!result.timedOut)
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput == Data(repeating: 0, count: 524_288))
    }

    @Test func oversizedCommandOutputIsRejected() {
        let result = BoundedCommandRunner.run(executableURL: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=65536", "count=32"], timeout: 3)
        #expect(!result.timedOut)
        #expect(result.terminationStatus == -1)
        #expect(result.standardOutput.isEmpty)
    }

    @Test func runningProcessIsStoppedAtDeadline() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = BoundedCommandRunner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["3"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1.2)
    }

    @Test func phraseFileReadEnforcesLimitBeforeDecoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 32, count: CommonPhraseStore.maximumImportBytes + 1).write(to: url)
        #expect(throws: AppConfigurationError.self) { try CommonPhraseStore.readImport(from: url) }
        let archive = CommonPhraseArchive(entries: [CommonPhrase(id: "test", text: "测试",
            label: "测试")], bindings: ["ok": "test"])
        try JSONEncoder().encode(archive).write(to: url)
        #expect(try CommonPhraseStore.readImport(from: url) == archive)
        try Data(repeating: 0, count: 12).write(to: url)
        #expect(throws: Error.self) { try CommonPhraseStore.readImport(from: url) }
    }

    @Test func boundedReaderAcceptsExactLimitAndRejectsOneExtraByte() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 128).write(to: url)
        #expect(try ConfigurationFileReader.read(from: url, maximumBytes: 128).count == 128)
        #expect(throws: AppConfigurationError.self) { try ConfigurationFileReader.read(from: url, maximumBytes: 127) }
    }

    @Test @MainActor func duplicateApplicationIDsRejectImportWithoutChangingSettings() throws {
        let name = "review-input-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let profile = CustomApplicationProfile(displayName: "First", bundleIdentifier: "review.first",
            applicationPath: "/Applications/First.app")
        _ = settings.addCustomApplicationProfile(profile)
        settings.buttonApplicationProfileIDs[.left] = profile.id
        let original = try settings.exportedConfigurationData()
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var profiles = try #require(object["customApplicationProfiles"] as? [[String: Any]])
        var duplicate = try #require(profiles.first)
        duplicate["displayName"] = "Second"
        duplicate["bundleIdentifier"] = "review.second"
        profiles.append(duplicate)
        object["customApplicationProfiles"] = profiles
        object["gainDB"] = 23
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: AppConfigurationError.self) { try settings.importConfiguration(from: invalid) }
        #expect(try settings.exportedConfigurationData() == original)
        profiles[1] = profiles[0]
        object["customApplicationProfiles"] = profiles
        #expect(throws: AppConfigurationError.self) {
            try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try settings.exportedConfigurationData() == original)
        // A unique ID must still be accepted, including an app absent from this Mac.
        profiles[1]["id"] = UUID().uuidString
        object["customApplicationProfiles"] = profiles
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.customApplicationProfiles.count == 2)
        #expect(settings.gainDB == 23)
        #expect(settings.applicationProfileID(for: .left) == profile.id)
        #expect(settings.customApplicationProfile(id: settings.applicationProfileID(for: .left))?.bundleIdentifier == "review.first")
    }

    @Test @MainActor func danglingApplicationReferencesAreReportedAndValidReferencesSurvive() throws {
        let name = "review-references-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let profile = CustomApplicationProfile(displayName: "Editor", bundleIdentifier: "example.editor",
            applicationPath: "/Applications/Editor.app")
        _ = settings.addCustomApplicationProfile(profile)
        var object = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        object["buttonApplicationProfileIDs"] = ["left": profile.id.uuidString, "right": UUID().uuidString]
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.buttonApplicationProfileIDs[.left] == profile.id)
        #expect(settings.buttonApplicationProfileIDs[.right] == nil)
        #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains("buttonApplicationProfileIDs") == true)
        // An explicit empty profile list replaces local profiles; it is not a union.
        object["customApplicationProfiles"] = []
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.buttonApplicationProfileIDs.isEmpty)
    }

    @Test @MainActor func corruptGainCannotReachIntegerFormatting() throws {
        let name = "review-gain-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for (value, expected) in [(Double.nan, 10.0), (.infinity, 10), (-20, 0), (30, 24), (12, 12)] {
            defaults.set(value, forKey: "gainDB")
            #expect(AppSettings(defaults: defaults).gainDB == expected)
        }
    }

    @Test @MainActor func directGainAssignmentNormalizesBeforePublishingOrPersisting() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        for (value, expected) in [(Double.nan, 10.0), (.infinity, 10), (-1, 0), (99, 24)] {
            settings.gainDB = value
            #expect(settings.gainDB == expected)
            #expect(defaults.double(forKey: "gainDB") == expected)
            #expect(Int(settings.gainDB) == Int(expected))
        }
    }

    @Test @MainActor func backupBindingsCannotReintroduceDanglingApplications() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var object = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        object["continuousRecordingPowerBindingBackup"] = ["action": "openCustomApplication", "applicationProfileID": UUID().uuidString]
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains("continuousRecordingPowerBindingBackup") == true)
        #expect(settings.applicationProfileID(for: .power) == nil)
    }

    @Test @MainActor func failedImportClearsThePreviousFilteringNotice() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var object = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        object["buttonApplicationProfileIDs"] = ["left": UUID().uuidString]
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.configurationImportNotice != nil)
        #expect(throws: Error.self) { try settings.importConfiguration(from: Data("invalid".utf8)) }
        #expect(settings.configurationImportNotice == nil)
    }

    #if DEBUG
    @Test func developmentFeedRequiresExplicitTestModeAndPreviewOptIn() {
        let environment = ["VOICE_INPUT_BUDDY_UI_TEST_MODE": "1",
            "VOICE_INPUT_BUDDY_UI_TEST_FEED_URL": "http://127.0.0.1:8765/appcast-arm64.xml",
            "VOICE_INPUT_BUDDY_UI_TEST_VERSION": "v26-10-13.099"]
        #expect(UpdateFeedResolver.testInjectedFeed(environment: environment,
            assetName: "appcast-arm64.xml", includePreRelease: true) != nil)
        #expect(UpdateFeedResolver.testInjectedFeed(environment: environment,
            assetName: "appcast-arm64.xml", includePreRelease: false) == nil)
        #expect(UpdateFeedResolver.testInjectedFeed(environment: [:],
            assetName: "appcast-arm64.xml", includePreRelease: true) == nil)
    }
    #endif
}
