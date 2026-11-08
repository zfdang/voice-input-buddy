import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    private var connectionBadge: String {
        localization.text(model.isConnected ? "common.status.connected" : "common.status.connecting")
    }

    func copyRepositoryLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        isRepositoryLinkCopied = pasteboard.writeObjects([
            AppLinks.githubRepository.absoluteString as NSString
        ])
    }

    var connectionTint: Color {
        model.isConnected ? .green : .orange
    }

    private var voiceTriggerBadge: String {
        localization.text(model.isVoiceTriggerEnabled ? "common.status.enabled" : "common.status.preparing")
    }
}
