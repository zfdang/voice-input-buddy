import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var voiceToolContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            onboardingTitle("onboarding.voice_tool.title")
            Text(verbatim: localization.text("onboarding.voice_tool.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if allRecognizedVoiceToolsUnavailable {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Text(verbatim: localization.text("onboarding.voice_tool.none_detected"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 8
            ) {
                ForEach(visibleVoiceTools) { tool in
                    voiceToolCard(for: tool)
                }
            }

            if settings.onboardingVoiceTool == .doubao && voiceToolAvailability[.doubao] == .notInstalled {
                HStack(spacing: 8) {
                    Text(verbatim: localization.text("onboarding.voice_tool.doubao.install_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    onboardingLink(id: "voice-tool.doubao.install", destination: AppLinks.doubaoInputMethod) {
                        Text(verbatim: localization.text("onboarding.voice_tool.doubao.install"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.onboardingVoiceTool == .bageshuo && voiceToolAvailability[.bageshuo] == .notInstalled {
                HStack(spacing: 8) {
                    Text(verbatim: localization.text("onboarding.voice_tool.bageshuo.install_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    onboardingLink(id: "voice-tool.bageshuo.install", destination: AppLinks.bageshuoWebsite) {
                        Text(verbatim: localization.text("onboarding.voice_tool.bageshuo.install"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if proposedPairingPlan?.fnTapModeEnabled == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: settings.onboardingVoiceTool == .macosDictation
                        ? localization.text("onboarding.voice_tool.dictation_fn_tap_explanation")
                        : localization.text("onboarding.voice_tool.fn_tap_banner"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            if settings.onboardingVoiceTool == .other || settings.onboardingVoiceTool == .voicecursor {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.badge.xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: localization.text("onboarding.voice_tool.other.setup_detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                }
            }

            if settings.onboardingControlSource.supportedGestureModes.count > 1 {
                gestureModeChoice
            }

        }
    }

    private var onboardingVoiceKeyControl: some View {
        let profile = VoiceToolAdapterProfile.profile(for: settings.onboardingVoiceTool)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(verbatim: localization.text("onboarding.voice_tool.binding.title"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                onboardingActionButton(id: "voice-binding.recommended") {
                    selectVoiceBindingPreference(.documentedDefault)
                } label: {
                    Label {
                        Text(verbatim: localization.text("onboarding.voice_tool.binding.recommended"))
                    } icon: {
                        Image(systemName: settings.onboardingVoiceBindingPreference == .documentedDefault
                            ? "checkmark.circle.fill"
                            : "circle")
                    }
                }
                .buttonStyle(.bordered)

                onboardingActionButton(id: "voice-binding.learn-current") {
                    selectVoiceBindingPreference(.learnCurrent)
                } label: {
                    Label {
                        Text(verbatim: localization.text("onboarding.voice_tool.binding.learn"))
                    } icon: {
                        Image(systemName: settings.onboardingVoiceBindingPreference == .learnCurrent
                            ? "checkmark.circle.fill"
                            : "circle")
                    }
                }
                .buttonStyle(.bordered)
            }

            Text(verbatim: localization.text(
                settings.onboardingVoiceBindingPreference == .learnCurrent
                    ? "onboarding.voice_tool.binding.learn_detail"
                    : "onboarding.voice_tool.binding.recommended_detail"
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if settings.onboardingVoiceBindingPreference == .documentedDefault {
                Text(defaultBindingSummary(profile: profile))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(profile.evidenceState == .verified ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
