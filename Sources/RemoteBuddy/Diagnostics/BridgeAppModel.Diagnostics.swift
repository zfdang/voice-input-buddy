import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    @MainActor func openLogFolder() {
        let logger = AppLogger.shared
        logger.write("LOGS opened_by_user")
        logger.flush()
        if FileManager.default.fileExists(atPath: logger.logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logger.logURL])
        } else {
            let localization = LocalizationStore(settings: settings)
            let alert = NSAlert()
            alert.messageText = localization.text("diagnostics.logs.open_failed")
            alert.informativeText = localization.text("diagnostics.logs.open_failed.detail")
            alert.runModal()
        }
    }

    func openProjectFolder() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        if candidate.path.contains(".app/Contents/MacOS") {
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(candidate)
    }

    func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension BridgeAppModel {
    func optionalDiagnosticBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private func optionalDiagnosticInt(_ value: Int?) -> String {
        value.map(String.init) ?? "unknown"
    }

    func elapsedMilliseconds(since uptime: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - uptime) * 1_000))
    }
}
