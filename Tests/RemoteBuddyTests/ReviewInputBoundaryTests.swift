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

    @Test @MainActor func powerMappingRemainsFreelyEditableAndResettable() throws {
        let name = "power-mapping-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        settings.setAction(.commandReturn, for: .power, trigger: .singleClick)
        #expect(settings.action(for: .power) == .commandReturn)

        settings.setAction(.escape, for: .power, trigger: .singleClick)
        #expect(settings.action(for: .power) == .escape)

        settings.resetBindings()
        #expect(settings.action(for: .power) == AppSettings.defaultBindings[.power])
        #expect(settings.action(for: .power) != .toggleLongRecording)
    }

    #if DEBUG
    @Test func developmentFeedRequiresExplicitTestModeAndPreviewOptIn() {
        let environment = ["REMOTE_BUDDY_UI_TEST_MODE": "1",
            "REMOTE_BUDDY_UI_TEST_FEED_URL": "http://127.0.0.1:8765/appcast-arm64.xml",
            "REMOTE_BUDDY_UI_TEST_VERSION": "v26-10-13.099"]
        #expect(UpdateFeedResolver.testInjectedFeed(environment: environment,
            assetName: "appcast-arm64.xml", includePreRelease: true) != nil)
        #expect(UpdateFeedResolver.testInjectedFeed(environment: environment,
            assetName: "appcast-arm64.xml", includePreRelease: false) == nil)
        #expect(UpdateFeedResolver.testInjectedFeed(environment: [:],
            assetName: "appcast-arm64.xml", includePreRelease: true) == nil)
    }
    #endif
}
