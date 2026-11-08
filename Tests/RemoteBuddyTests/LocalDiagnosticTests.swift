import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Local structured diagnostics")
struct LocalDiagnosticTests {
    @Test func structuredEventsAreWrittenToTheLocalLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("runtime.log")
        let logger = AppLogger(logURL: log, reportFailure: { _ in })
        let event = try #require(PublicDiagnosticEvent(component: "settings", action: "load",
            phase: "completed", result: "loaded", reason: "remote_profiles", source: "app"))
        logger.record(event)
        logger.flush()
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains(event.canonicalLine))
        #expect(PublicDiagnosticEvent.parse(event.canonicalLine) == event)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files == [".remotebuddy-diagnostic-log.lock", "runtime.log"])
    }

    @Test func disabledLoggingDoesNotCreateAnEventFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("runtime.log")
        let logger = AppLogger(logURL: log, reportFailure: { _ in }, isEnabled: false)
        let event = try #require(PublicDiagnosticEvent(component: "settings", action: "load",
            phase: "completed", result: "loaded", reason: "remote_profiles", source: "app"))
        logger.record(event)
        logger.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func writesStayOnOwnedSessionDescriptorWhenThePathIsReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("runtime.log")
        let owned = directory.appendingPathComponent("owned.log")
        let unrelated = directory.appendingPathComponent("user-data")
        let logger = AppLogger(logURL: log, reportFailure: { _ in })
        try FileManager.default.moveItem(at: log, to: owned)
        try Data("untouched".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: unrelated)
        logger.writeSynchronously("owned session", at: Date())
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "untouched")
        #expect(try String(contentsOf: owned, encoding: .utf8).contains("owned session"))
    }

}
