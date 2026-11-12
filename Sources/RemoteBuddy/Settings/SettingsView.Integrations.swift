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
                HStack(alignment: .center, spacing: 12) {
                    Text(localization.text("settings.integration.select_tool"))
                        .font(.headline)
                    Spacer()
                    Button(localization.text("settings.integration.configure")) {
                        if let tool = integrationToolSelection {
                            SettingsPageBehavior.beginIntegrationSetup(tool: tool, settings: settings)
                        }
                    }
                    .compatibilityButtonStyle(.prominent)
                    .controlSize(.large)
                    .disabled(integrationToolSelection == nil)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(OnboardingVoiceToolVisibilityPolicy.tools) { tool in
                        integrationToolCard(tool)
                    }
                }
                if integrationToolSelection == .voiceBuddy {
                    GlassPanel {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(localization.text("onboarding.voice_tool.voice_buddy.intro"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Link(destination: AppLinks.voiceBuddyWebsite(for: localization.locale)) {
                                    Text(localization.text("onboarding.voice_tool.voice_buddy.website"))
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }
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
            integrationToolSelection = OnboardingVoiceToolVisibilityPolicy.tools.contains(settings.onboardingVoiceTool)
                ? settings.onboardingVoiceTool : nil
            model.refreshVoiceKeyCompatibilityWarning()
            model.refreshAudioDevices()
        }
    }

    private func integrationToolCard(_ tool: OnboardingVoiceTool) -> some View {
        let selected = integrationToolSelection == tool
        return Button {
            integrationToolSelection = tool
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(localization.text(tool.titleKey))
                        .font(.headline)
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text(localization.text(tool.detailKey))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
