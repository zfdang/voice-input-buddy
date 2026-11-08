import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Diagnostic log retention")
struct DiagnosticLogRetentionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func mappedNativeRepeatSurvivesThirtySecondsAndEndsOnRelease() throws {
        var now: TimeInterval = 0
        let filter = KeyboardEventSuppressor(uptime: { now })
        filter.arm(nativeEvents: [.keyboard(keyCode: 38)], edge: .down)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: true))
        #expect(filter.handle(type: .keyDown, event: event))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        for time: TimeInterval in [10, 20, 31, 45, 65] {
            now = time
            #expect(filter.handle(type: .keyDown, event: event))
        }
        filter.arm(nativeEvents: [.keyboard(keyCode: 38)], edge: .up)
        #expect(filter.handle(type: .keyUp, event: event))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        #expect(!filter.handle(type: .keyDown, event: event))
    }

    @Test func oversizedRecordsReportOnceAndDoNotDisableLaterLogging() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        let url = root.appendingPathComponent("remotebuddy.app-test.log")
        let logger = AppLogger(logURL: url, maximumFileSize: 512,
                               reportFailure: { failures.append($0) })
        for _ in 0..<20 { logger.writeSynchronously(String(repeating: "x", count: 600), at: Date()) }
        #expect(failures == ["log_record_too_large"])
        logger.writeSynchronously("logging continues", at: Date())
        #expect(try String(contentsOf: url, encoding: .utf8).contains("logging continues"))
        #expect(try Data(contentsOf: url).count <= 512)
    }

    @Test func recordMustFitAlongsideHeaderAndLaterWritesStillWork() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        let url = root.appendingPathComponent("remotebuddy.app-test.log")
        let logger = AppLogger(logURL: url, maximumFileSize: 512,
                               reportFailure: { failures.append($0) })
        let date = Date(timeIntervalSince1970: 0)
        logger.writeSynchronously("x", at: date)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let headerBytes = lines[0].utf8.count + 1
        let recordPrefixBytes = lines[1].utf8.count // Remove x, add newline: same count.
        // This record fits by itself, but would exceed the file cap together with its header.
        logger.writeSynchronously(String(repeating: "z", count: 513 - headerBytes - recordPrefixBytes), at: date)
        #expect(failures == ["log_record_too_large"])
        logger.writeSynchronously("still available", at: date)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("still available"))
        #expect(!text.contains("zzz"))
        #expect(text.utf8.count <= 512)
    }

    @Test func sizeLimitRotatesAndRetainsBoundedPrivateLogsDuringSession() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("remotebuddy.app-test.log")
        let logger = AppLogger(logURL: url, maximumFileSize: 512, archiveCount: 2)
        for index in 0..<30 {
            logger.writeSynchronously("message-\(index) " + String(repeating: "x", count: 100), at: Date())
        }
        let logs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }
        #expect(logs.count == 3)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("message-29"))
        for file in logs {
            #expect(try Data(contentsOf: file).count <= 512)
            #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("Remote Buddy runtime log (UTF-8)\n"))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    @Test func textLogNeedsNoKeyAndPreservesUnicodeWithoutInjectedLines() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("remotebuddy.app-test.log")
        let logger = AppLogger(logURL: url)
        logger.write("设备连接正常\nnew line")
        logger.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("设备连接正常 new line"))
        #expect(text.contains("seq=0"))
        #expect(text.split(separator: "\n").count == 2)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
    }

    @Test func initialLogSymlinkNeverOverwritesTarget() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("user-data")
        try Data("untouched".utf8).write(to: target)
        let url = root.appendingPathComponent("remotebuddy.app-test.log")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let logger = AppLogger(logURL: url)
        logger.writeSynchronously("must not overwrite", at: Date())
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @Test func retentionKeepsNewestArchivesAndUnrelatedFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("remotebuddy.app-old.log")
        let recent = root.appendingPathComponent("remotebuddy.app-recent.log")
        let unrelated = root.appendingPathComponent("sayall.app-old.log")
        for url in [old, recent, unrelated] { try Data("archive".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: recent.path)
        let logger = AppLogger(logURL: root.appendingPathComponent("remotebuddy.app-current.log"),
                               archiveCount: 1)
        withExtendedLifetime(logger) {
            #expect(!FileManager.default.fileExists(atPath: old.path))
            #expect(FileManager.default.fileExists(atPath: recent.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }

    @Test func retentionSkipsActiveSessionsAndSymbolicLinks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activeURL = root.appendingPathComponent("remotebuddy.app-active.log")
        let active = AppLogger(logURL: activeURL)
        let target = root.appendingPathComponent("user-data")
        try Data("untouched".utf8).write(to: target)
        let link = root.appendingPathComponent("remotebuddy.app-link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let next = AppLogger(logURL: root.appendingPathComponent("remotebuddy.app-next.log"),
                             archiveCount: 0)
        let targetContents = try String(contentsOf: target, encoding: .utf8)
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        withExtendedLifetime((active, next)) {
            active.writeSynchronously("still active", at: Date())
            #expect(FileManager.default.fileExists(atPath: activeURL.path))
            #expect(targetContents == "untouched")
            #expect(linkDestination == target.path)
        }
    }
}

@Suite("Keyboard event filtering")
struct KeyboardEventFilteringTests {
    @Test func freshPhysicalKeyDownClearsStaleHeldState() throws {
        let suppressor = KeyboardEventSuppressor()
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: true))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 38)], edge: .down)
        #expect(suppressor.handle(type: .keyDown, event: event))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(suppressor.handle(type: .keyDown, event: event))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        #expect(!suppressor.handle(type: .keyDown, event: event))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(!suppressor.handle(type: .keyDown, event: event))
    }

    @Test func injectedKeysDoNotConsumeRemoteSuppression() throws {
        // This checks event ownership, not expiry. AppKit event creation can take
        // longer than the 180 ms pending window on a busy build machine.
        let suppressor = KeyboardEventSuppressor(uptime: { 0 })
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: true))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 38)], edge: .down)
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        #expect(!suppressor.handle(type: .keyDown, event: event))
        let physical = try #require(CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 38, keyDown: true))
        #expect(physical.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker)
        #expect(suppressor.handle(type: .keyDown, event: physical))
    }
}

@Suite("Product deep links")
struct ProductDeepLinkTests {
    @Test func registeredSchemeMatchesParser() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = try #require(types.first?["CFBundleURLSchemes"] as? [String])
        let scheme = try #require(schemes.first)
        let url = try #require(URL(string: "\(scheme)://launch?source=external&status=ready"))
        let request = try #require(RemoteBuddyDeepLinkRequest.parse(url))
        #expect(request.source == "external")
        #expect(request.status == .ready)
    }

    @Test func rejectsOtherAppsAndAmbiguousParameters() throws {
        for value in ["sayall://launch", "voice-input-buddy://launch", "remote-buddy://launch?status=ready&status=failed",
                      "remote-buddy://launch#fragment", "remote-buddy://other"] {
            #expect(RemoteBuddyDeepLinkRequest.parse(try #require(URL(string: value))) == nil)
        }
    }
}

@Suite("Scheduled voice task lifetime")
@MainActor
struct ScheduledVoiceTaskLifetimeTests {
    private final class Probe {}

    @Test func cancellationHandleCanCrossQueuesWithoutExecutingScheduledWork() async {
        var queued: DispatchWorkItem?
        var calls = 0
        let task = ScheduledOperation.scheduled(after: 1, enqueue: { _, item in queued = item }) { calls += 1 }
        await Task.detached { task.cancel() }.value
        queued?.perform()
        #expect(calls == 0)
    }

    @Test func mainQueueCleanupFromBackgroundCancellationRunsExactlyOnceOnMain() async {
        var calls = 0
        await withCheckedContinuation { continuation in
            let task = ScheduledOperation.mainQueueCancellation {
                #expect(Thread.isMainThread)
                calls += 1
                continuation.resume()
            }
            DispatchQueue.global().async { task.cancel(); task.cancel() }
        }
        #expect(calls == 1)
    }

    @Test func completedTaskReleasesCapturedObjects() {
        var probe: Probe? = Probe()
        weak let observed = probe
        var calls = 0
        var queued: DispatchWorkItem?
        let task = ScheduledOperation.scheduled(after: 0, enqueue: { _, item in queued = item }) { [retained = probe!] in
            withExtendedLifetime(retained) { calls += 1 }
        }
        probe = nil
        queued?.perform()
        #expect(calls == 1)
        #expect(observed == nil)
        withExtendedLifetime(task) {}
    }

    @Test func cancellationReleasesCapturedObjectsBeforeDeadline() {
        var probe: Probe? = Probe()
        weak let observed = probe
        var calls = 0
        var queued: DispatchWorkItem?
        let task = ScheduledOperation.scheduled(after: 0.05, enqueue: { _, item in queued = item }) { [retained = probe!] in
            withExtendedLifetime(retained) { calls += 1 }
        }
        probe = nil
        task.cancel()
        task.cancel()
        #expect(observed == nil)
        queued?.perform()
        #expect(calls == 0)
        #expect(observed == nil)
    }
}

@Suite("Portable device mappings")
@MainActor
struct PortableDeviceMappingTests {
    private func settings(_ suites: inout [String]) throws -> AppSettings {
        let suite = "mapping-review-" + UUID().uuidString
        suites.append(suite)
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppSettings(defaults: defaults)
    }

    @Test func importedSelectedDeviceBindingsWorkOnAnotherMac() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        let source = try settings(&suites)
        let sourceID = source.registerBluetoothRemote(identifier: UUID())
        source.selectRemoteProfile(sourceID)
        source.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: sourceID)
        let destination = try settings(&suites)
        let destinationID = destination.registerBluetoothRemote(identifier: UUID())
        destination.selectRemoteProfile(destinationID)
        try destination.importConfiguration(from: source.exportedConfigurationData())
        #expect(destination.configuredBaseAction(for: .ok, trigger: .singleClick,
                                                 profileID: destinationID).action == .commandCopy)
        #expect(destination.configurationImportNotice == nil)
    }

    @Test func importBeforePairingKeepsSelectedDeviceOverride() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        let source = try settings(&suites)
        source.setBaseBinding(.init(action: .escape, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: nil)
        let sourceID = source.registerBluetoothRemote(identifier: UUID())
        source.selectRemoteProfile(sourceID)
        source.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: sourceID)
        let destination = try settings(&suites)
        try destination.importConfiguration(from: source.exportedConfigurationData())
        let destinationID = destination.registerBluetoothRemote(identifier: UUID())
        destination.selectRemoteProfile(destinationID)
        #expect(destination.configuredBaseAction(for: .ok, trigger: .singleClick,
                                                 profileID: destinationID).action == .commandCopy)
    }

    @Test func missingExportSelectionReportsUnknownDeviceScope() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        let source = try settings(&suites)
        let sourceID = source.registerBluetoothRemote(identifier: UUID())
        source.selectRemoteProfile(sourceID)
        source.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: sourceID)
        var payload = try #require(JSONSerialization.jsonObject(with: source.exportedConfigurationData()) as? [String: Any])
        payload.removeValue(forKey: "selectedMappingProfileID")
        let destination = try settings(&suites)
        try destination.importConfiguration(from: JSONSerialization.data(withJSONObject: payload))
        #expect(destination.configuredBaseAction(for: .ok, trigger: .singleClick).action == .returnKey)
        #expect(destination.configurationImportNotice?.rejectedEntryStorageKeys == ["unifiedBaseBindings"])
    }

    @Test func unrelatedUnknownDeviceScopesAreReported() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        let source = try settings(&suites)
        let first = source.registerBluetoothRemote(identifier: UUID())
        let second = source.registerBluetoothRemote(identifier: UUID())
        source.selectRemoteProfile(first)
        source.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: first)
        source.setBaseBinding(.init(action: .escape, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: second)
        let destination = try settings(&suites)
        try destination.importConfiguration(from: source.exportedConfigurationData())
        #expect(destination.configuredBaseAction(for: .ok, trigger: .singleClick).action == .commandCopy)
        #expect(destination.configurationImportNotice?.rejectedEntryStorageKeys == ["unifiedBaseBindings"])
    }

    @Test func sameMacRoundTripPreservesDeviceScopes() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        let source = try settings(&suites)
        let first = source.registerBluetoothRemote(identifier: UUID())
        let second = source.registerBluetoothRemote(identifier: UUID())
        source.selectRemoteProfile(first)
        source.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: first)
        source.setBaseBinding(.init(action: .escape, shortcut: nil),
                              for: .ok, trigger: .singleClick, profileID: second)
        try source.importConfiguration(from: source.exportedConfigurationData())
        #expect(source.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: first).action == .commandCopy)
        #expect(source.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: second).action == .escape)
    }
}
