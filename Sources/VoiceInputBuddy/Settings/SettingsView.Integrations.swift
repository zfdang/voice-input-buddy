import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var integrationPage: some View {
        settingsPage {
            PageHeader(title: localization.text("settings.integration.title"))
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text(localization.text("settings.integration.introduction"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localization.text("settings.integration.current")).font(.headline)
                        Text(localization.text(settings.onboardingVoiceTool.titleKey))
                            .font(.title3.weight(.medium))
                        Label(model.voiceShortcutStatus.text(using: localization), systemImage: "keyboard")
                        Label(model.integrationAudioDeviceStatus.text(using: localization), systemImage: "mic")
                        if model.audioStatus.key != "audio.output.none_selected",
                           model.audioStatus.key != "audio.output.current_format" {
                            Text(model.audioStatus.text(using: localization))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(localization.text("settings.integration.microphone_help"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(OnboardingVoiceToolVisibilityPolicy.tools) { tool in
                        integrationToolCard(tool)
                    }
                }
                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localization.text("settings.integration.shortcut_title")).font(.headline)
                        mappingVoiceKeyModeControl
                        if VoiceFunctionKeyTapApplicability.isApplicable(capabilities: model.selectedRemoteVoiceCapabilities) {
                            mappingVoiceFnTapControl
                        }
                        Text(localization.text("settings.integration.shortcut_help"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let warning = model.voiceKeyCompatibilityWarning {
                    voiceKeyCompatibilityWarningPanel(warning)
                }
            }
        }
        .onAppear {
            model.refreshVoiceKeyCompatibilityWarning()
            model.refreshAudioDevices()
        }
    }

    private func integrationToolCard(_ tool: OnboardingVoiceTool) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(localization.text(tool.titleKey))
                        .font(.headline)
                    Spacer()
                    if settings.onboardingVoiceTool == tool {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(localization.text(tool.detailKey))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(localization.text("settings.integration.configure")) {
                    SettingsPageBehavior.beginIntegrationSetup(tool: tool, settings: settings)
                }
                .compatibilityButtonStyle(.standard)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
