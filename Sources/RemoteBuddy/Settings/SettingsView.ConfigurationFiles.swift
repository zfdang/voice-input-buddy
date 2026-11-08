import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func exportConfiguration() {
        configurationStatus = nil
        guard let url = ConfigurationFilePanel.exportURL(
            title: localization.text("configuration.export.panel_title"),
            prompt: localization.text("configuration.export.prompt")
        ) else { return }
        do {
            let data = try settings.exportedConfigurationData()
            try data.write(to: url, options: .atomic)
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.export.success"),
                tint: .green,
                systemImage: "checkmark.circle.fill"
            )
        } catch {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.export.write_failed"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    func importConfiguration() {
        configurationStatus = nil
        guard let url = ConfigurationFilePanel.importURL(
            title: localization.text("configuration.import.panel_title"),
            prompt: localization.text("configuration.import.prompt")
        ) else { return }
        settings.configurationImportNotice = nil
        do {
            try model.importConfiguration(from: ConfigurationFileReader.read(from: url))
            localization.select(settings.applicationLanguage)
            syncEntryPointVisibility()
            if settings.configurationImportNotice != nil {
                configurationStatus = ConfigurationStatus(
                    message: LocalizedMessage("configuration.import.partial"),
                    tint: .orange,
                    systemImage: "exclamationmark.triangle.fill"
                )
            } else {
                configurationStatus = ConfigurationStatus(
                    message: LocalizedMessage("configuration.import.success"),
                    tint: .green,
                    systemImage: "checkmark.circle.fill"
                )
            }
        } catch AppConfigurationError.unsupportedVersion {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.unsupported_version"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch AppConfigurationError.unsafeVoiceKeyChange {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.voice_key_busy"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        } catch {
            configurationStatus = ConfigurationStatus(
                message: LocalizedMessage("configuration.import.invalid_file"),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }
}
