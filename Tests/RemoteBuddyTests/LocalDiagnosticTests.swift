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

    @Test func settingsDiagnosticSnapshotContainsComprehensiveRedactedInfo() {
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.2.3",
            appBuild: "42",
            macosVersion: "15.3.1",
            architecture: "arm64",
            isRosetta: false,
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false,
            remoteConnected: true,
            remoteModel: "小米蓝牙遥控器 (xiaomi)",
            virtualMicrophoneReady: true,
            audioOutputReady: true,
            voiceTool: "wechat",
            voiceKeyMode: "press_and_hold",
            runtimeLogAvailable: true,
            runtimeLogPath: "/tmp/test.log",
            runtimeLogSizeBytes: 2048,
            generatedAt: Date(timeIntervalSince1970: 1700000000)
        )

        let summary = snapshot.summary
        #expect(summary.contains("1.2.3 (Build 42)"))
        #expect(summary.contains("15.3.1 (arm64)"))
        #expect(summary.contains("蓝牙 / Bluetooth: 已授权 (Granted)"))
        #expect(summary.contains("辅助功能 / Accessibility: 未授权 (Denied)"))
        #expect(summary.contains("遥控器连接 / Remote Connected: 已连接 (Yes) [小米蓝牙遥控器 (xiaomi)]"))
        #expect(summary.contains("虚拟麦克风驱动 / Virtual Mic Driver: 已就绪 (Ready)"))
        #expect(summary.contains("语音工具 / Voice Tool: wechat"))
        #expect(summary.contains("按键模式 / Voice Key Mode: press_and_hold"))
        #expect(summary.contains("日志文件状态 / Log Available: 存在"))
        #expect(summary.contains("永不上传"))
        #expect(summary.contains("app_version: \"1.2.3\""))

        var writtenSummary: String?
        var writtenAudit: String?
        SettingsPageBehavior.copyDiagnosticSummary(
            snapshot,
            writeToPasteboard: { writtenSummary = $0 },
            writeAuditLog: { writtenAudit = $0 }
        )
        #expect(writtenSummary == summary)
        #expect(writtenAudit?.contains("SETTINGS DIAGNOSTICS copied") == true)
        #expect(writtenAudit?.contains("bluetooth=true") == true)
        #expect(writtenAudit?.contains("accessibility=false") == true)
    }

    @Test func settingsDiagnosticSnapshotRedactsHomeDirectoryInLogPath() {
        let fakeHome = "/Users/secret_user_42"
        let fullPath = "\(fakeHome)/Library/Logs/RemoteBuddy/remotebuddy.log"
        let sanitized = SettingsDiagnosticSnapshot.sanitizePath(fullPath, homeDirectory: fakeHome)
        #expect(sanitized == "~/Library/Logs/RemoteBuddy/remotebuddy.log")
        #expect(SettingsDiagnosticSnapshot.sanitizePath(fakeHome, homeDirectory: fakeHome) == "~")
        #expect(SettingsDiagnosticSnapshot.sanitizePath("/tmp/safe.log", homeDirectory: fakeHome) == "/tmp/safe.log")

        let actualHome = NSHomeDirectory()
        let realUserLogPath = "\(actualHome)/Library/Logs/RemoteBuddy/remotebuddy.log"
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.0.0",
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            runtimeLogAvailable: true,
            runtimeLogPath: realUserLogPath
        )

        #expect(!snapshot.runtimeLogPath.contains(actualHome))
        #expect(snapshot.runtimeLogPath == "~/Library/Logs/RemoteBuddy/remotebuddy.log")
        #expect(!snapshot.summary.contains(actualHome))
        #expect(snapshot.summary.contains("~/Library/Logs/RemoteBuddy/remotebuddy.log"))
    }

    @Test func diagnosticRedactorPreservesFactoryNamesAndMasksCustomNamesDeterministically() {
        // Factory names preserved
        #expect(DiagnosticRedactor.redactedDeviceName("Siri Remote") == "Siri Remote")
        #expect(DiagnosticRedactor.redactedDeviceName("MI RC") == "MI RC")
        #expect(DiagnosticRedactor.redactedDeviceName("Apple TV Remote") == "Apple TV Remote")
        #expect(DiagnosticRedactor.redactedDeviceName("MacBook Pro Speakers") == "MacBook Pro Speakers")

        // Personalized names with factory fragments must NOT bypass redaction
        let personalized1 = DiagnosticRedactor.redactedDeviceName("Living Room Siri Remote")
        #expect(personalized1.hasPrefix("device_"))
        #expect(!personalized1.contains("Siri Remote"))

        let personalized2 = DiagnosticRedactor.redactedDeviceName("Bob's MI RC")
        #expect(personalized2.hasPrefix("device_"))
        #expect(!personalized2.contains("MI RC"))

        // Pure custom names are redacted to deterministic SHA256 hex
        let customA1 = DiagnosticRedactor.redactedDeviceName("My Bedroom Remote")
        let customA2 = DiagnosticRedactor.redactedDeviceName("My Bedroom Remote")
        #expect(customA1 == customA2)
        #expect(customA1.hasPrefix("device_"))
        #expect(customA1.count == 15) // "device_" (7) + 8 hex chars (prefix 4 bytes) = 15

        // Empty/whitespace/nil
        #expect(DiagnosticRedactor.redactedDeviceName(nil) == "unknown")
        #expect(DiagnosticRedactor.redactedDeviceName("") == "unknown")
        #expect(DiagnosticRedactor.redactedDeviceName("   ") == "unknown")
    }

}
