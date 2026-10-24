import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var voiceTestContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            onboardingTitle("onboarding.voice_test.title")
            Text(verbatim: localization.text("onboarding.voice_test.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Color.accentColor)
                Text(voiceGestureInstruction)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            if proposedPairingPlan?.fnTapModeEnabled == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    Text(verbatim: localization.text("onboarding.voice_test.fn_tap_explanation"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            ZStack(alignment: .topLeading) {
                OnboardingTranscriptEditor(
                    text: $transcript,
                    focusRequest: transcriptFocusRequest,
                    isActive: settings.onboardingStep == .voiceTest,
                    commitRequest: transcriptCommitRequest,
                    onManualInput: {
                        guard settings.onboardingStep == .voiceTest else { return }
                        manualTranscriptInputObserved = true
                        AppLogger.shared.write("ONBOARDING TRANSCRIPT manual_keyboard_input=true")
                        finishVoiceAttempt(result: .manualInput)
                    },
                    onTextStateChanged: captureVoiceTranscriptCandidate
                ) { snapshot in
                    updateTranscriptFocus(snapshot)
                }
                .onAppear {
                    requestTranscriptFocus()
                }
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            transcriptFirstResponder
                                ? Color.accentColor
                                : Color.primary.opacity(0.12),
                            lineWidth: transcriptFirstResponder ? 1.5 : 1
                        )
                }

                if transcript.isEmpty {
                    Text(verbatim: localization.text("onboarding.voice_test.placeholder"))
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 84, maxHeight: 92)

            HStack(spacing: 12) {
                Image(systemName: voiceSamplesReceived ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 24))
                    .foregroundStyle(voiceSamplesReceived ? Color.accentColor : Color.secondary)
                Text(voiceTestStatusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            onboardingGainCard
        }
    }

    private var onboardingGainCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(verbatim: localization.text("onboarding.voice_test.gain.title"))
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Color.accentColor)
            }

            Text(verbatim: localization.text("onboarding.voice_test.gain.detail"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Text(verbatim: localization.text("audio.gain.title"))
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { settings.gainDB },
                        set: { settings.gainDB = min(24, max(0, $0)) }
                    ),
                    in: 0...24,
                    step: 1,
                    onEditingChanged: logOnboardingGainEditing
                )
                .accessibilityIdentifier("onboarding.voice-test.gain")
                Text("\(Int(settings.gainDB)) dB")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 54, alignment: .trailing)
            }

        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        }
        .onAppear {
            interactionProbe?.registerAction("voice-test.gain.set-12") {
                settings.gainDB = 12
            }
        }
    }

    private func logOnboardingGainEditing(_ isEditing: Bool) {
        AppLogger.shared.write(
            "ONBOARDING GAIN editing=\(isEditing) value_db=\(Int(settings.gainDB))"
        )
    }

    var externalToolMicrophoneConfigurationCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(localization.text("onboarding.voice_test.microphone_confirmation.title"),
                  systemImage: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(LocalizedMessage(
                "onboarding.voice_tool.guide.microphone_detail",
                arguments: [
                    localization.text(settings.onboardingVoiceTool.titleKey),
                    selectedAudioDevice?.name ?? localization.text("onboarding.audio.select_required"),
                ]
            ).text(using: localization))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let runtimeStatus = selectedVoiceToolRuntimeStatusText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selectedVoiceToolRuntimeReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(selectedVoiceToolRuntimeReady ? Color.green : Color.red)
                    Text(runtimeStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedVoiceToolRuntimeReady ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !selectedVoiceToolRuntimeReady {
                        onboardingActionButton(id: "voice-tool.reopen") {
                            openSelectedVoiceTool()
                        } label: {
                            Text(verbatim: localization.text("onboarding.voice_tool.runtime.reopen"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if settings.onboardingVoiceTool == .weixin {
                onboardingGuideScreenshot(
                    resourceName: "weixin-input-microphone"
                )
            } else if settings.onboardingVoiceTool == .doubao {
                onboardingGuideScreenshot(
                    resourceName: "doubao-input-microphone"
                )
            } else if settings.onboardingVoiceTool == .bageshuo {
                onboardingGuideScreenshot(
                    resourceName: "bageshuo-input-microphone"
                )
            } else if settings.onboardingVoiceTool == .voicecursor {
                onboardingGuideScreenshot(resourceName: "voicecursor-setting-mic")
            } else if settings.onboardingVoiceTool == .macosDictation {
                Text(verbatim: localization.text("onboarding.voice_tool.guide.dictation_microphone"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
        }
    }
}
