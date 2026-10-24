import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    @ViewBuilder
    func voiceToolCard(for tool: OnboardingVoiceTool) -> some View {
        let isSelected = settings.onboardingVoiceTool == tool

        VStack(alignment: .leading, spacing: 0) {
            onboardingActionButton(id: "voice-tool.\(tool.rawValue)") {
                selectVoiceTool(tool)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: voiceToolIcon(tool))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.text(tool.titleKey))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(localization.text(tool.detailKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if voiceToolAvailability[tool] == .notInstalled {
                            Text(verbatim: localization.text("onboarding.voice_tool.status.not_installed"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .top)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .top)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.09)
                : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.65)
                        : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
    }

    func inputMethodGuide(for tool: OnboardingVoiceTool) -> some View {
        let steps = inputMethodGuideSteps(for: tool)
        let selectedIndex = selectedInputMethodGuideStep.flatMap { index in
            steps.indices.contains(index) ? index : nil
        }

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localization.text("onboarding.voice_tool.guide.title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(localization.text("onboarding.voice_tool.guide.detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tool.requiresFunctionKeySetup {
                inputSourceSwitchStatus(for: tool)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .top),
                    GridItem(.flexible(), alignment: .top),
                ],
                spacing: 8
            ) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    let isCompleted = completedInputMethodGuideSteps.contains(step.id)
                    onboardingActionButton(id: "input-guide.\(index)") {
                        selectedInputMethodGuideStep = index
                        completedInputMethodGuideSteps.insert(step.id)
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            Group {
                                if isCompleted {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                } else {
                                    Text("\(step.id)")
                                        .font(.system(size: 12, weight: .bold))
                                }
                            }
                                .frame(width: 22, height: 22)
                                .background(
                                    isCompleted
                                        ? Color.green
                                        : selectedIndex == index
                                        ? Color.accentColor
                                        : Color.primary.opacity(0.08),
                                    in: Circle()
                                )
                                .foregroundStyle(
                                    isCompleted || selectedIndex == index ? Color.white : Color.primary
                                )
                            Text(localization.text(step.titleKey))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxHeight: .infinity, alignment: .center)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 54)
                        .background(
                            selectedIndex == index
                                ? Color.accentColor.opacity(0.09)
                                : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    selectedIndex == index
                                        ? Color.accentColor.opacity(0.55)
                                        : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }

            if let selectedIndex {
                switch steps[selectedIndex].content {
                case let .screenshot(resourceName):
                    onboardingGuideScreenshot(resourceName: resourceName)
                case let .instruction(systemImage, detailKey):
                    onboardingGuideInstruction(systemImage: systemImage, detailKey: detailKey)
                case .systemFunctionKey:
                    systemFunctionKeyInstruction
                case .microphoneIntegration:
                    externalToolMicrophoneConfigurationCard
                }
            } else {
                Text(verbatim: localization.text("onboarding.voice_tool.guide.select_step"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func inputSourceSwitchStatus(for tool: OnboardingVoiceTool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: inputSourceSwitchResult == .selected ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(inputSourceSwitchResult == .selected ? Color.green : Color.accentColor)

            Text(inputSourceSwitchStatusText(for: tool))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if inputSourceSwitchResult == .unavailable || inputSourceSwitchResult == .failed {
                onboardingActionButton(id: "input-source.activate") {
                    activateSelectedInputMethod()
                } label: {
                    Text(verbatim: localization.text(
                        inputSourceSwitchResult == .failed
                            ? "onboarding.voice_tool.switch.retry"
                            : "onboarding.voice_tool.switch.select"
                    ))
                }
                .buttonStyle(.bordered)
            }

            if inputSourceSwitchResult == .notSelected {
                onboardingActionButton(id: "input-source.activate") {
                    activateSelectedInputMethod()
                } label: {
                    Text(verbatim: localization.text("onboarding.voice_tool.switch.select"))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    func onboardingGuideScreenshot(resourceName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = onboardingGuideImage(resourceName: resourceName) {
                onboardingGuidePreview(image: image)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    // Guide pictures are informational; clicks belong to the surrounding controls.
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
            } else {
                Text(verbatim: localization.text("onboarding.voice_tool.guide.image_missing"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            Group {
                Text(verbatim: localization.text(
                    "onboarding.voice_tool.guide.screenshot." +
                        resourceName.replacingOccurrences(of: "-", with: "_")
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if resourceName == "doubao-settings", let binding = proposedPairingPlan?.binding {
                Text(LocalizedMessage("onboarding.voice_tool.guide.match_shortcut",
                    arguments: [localization.text(binding.shortcut.localizationKey)]).text(using: localization))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func onboardingGuidePreview(image: NSImage) -> some View {
        GeometryReader { geometry in
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func onboardingGuideInstruction(
        systemImage: String,
        detailKey: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            Text(verbatim: localization.text(detailKey))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var systemFunctionKeyInstruction: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingGuideScreenshot(resourceName: "system-fn")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemFunctionKeyAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(systemFunctionKeyAvailable ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text(
                        systemFunctionKeyAvailable
                            ? "onboarding.voice_tool.system_fn.ready"
                            : "onboarding.voice_tool.system_fn.conflict"
                    ))
                    .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: localization.text("onboarding.voice_tool.system_fn.detail"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !systemFunctionKeyAvailable {
                    onboardingActionButton(id: "keyboard-settings.open") {
                        openKeyboardSettings()
                    } label: {
                        Text(verbatim: localization.text("onboarding.voice_tool.system_fn.open_settings"))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    func inputMethodGuideSteps(
        for tool: OnboardingVoiceTool
    ) -> [OnboardingInputMethodGuideStep] {
        let toolSteps: [OnboardingInputMethodGuideStep]
        switch tool {
        case .doubao:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.select_doubao",
                    content: .screenshot("doubao-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_doubao",
                    content: .screenshot("doubao-settings")
                ),
            ]
        case .weixin:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.select_weixin",
                    content: .screenshot("weixin-input-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_weixin",
                    content: .screenshot("weixin-input-settings")
                ),
            ]
        case .bageshuo:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_bageshuo",
                    content: .screenshot("bageshuo-menu")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_bageshuo",
                    content: .screenshot("bageshuo-settings")
                ),
            ]
        case .typeless:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_typeless",
                    content: .instruction(
                        systemImage: "waveform.badge.mic",
                        detailKey: "onboarding.voice_tool.guide.open_typeless.detail"
                    )
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_typeless",
                    content: .instruction(
                        systemImage: "hand.tap.fill",
                        detailKey: "onboarding.voice_tool.guide.configure_typeless.detail"
                    )
                ),
            ]
        case .voicecursor:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_voicecursor",
                    content: .instruction(systemImage: "mic.fill", detailKey: "onboarding.voice_tool.guide.open_voicecursor.detail")
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_other",
                    content: .screenshot("voicecursor-setting-fn")
                ),
            ]
        case .macosDictation:
            // Dictation needs 🌐 assigned to it, so the generic "release system Fn"
            // step does not apply.
            return [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.enable_dictation",
                    content: .instruction(
                        systemImage: "mic.fill",
                        detailKey: "onboarding.voice_tool.guide.enable_dictation.detail"
                    )
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_dictation",
                    content: .instruction(
                        systemImage: "globe",
                        detailKey: "onboarding.voice_tool.guide.configure_dictation.detail"
                    )
                ),
                OnboardingInputMethodGuideStep(
                    id: 3,
                    titleKey: "onboarding.voice_tool.guide.select_microphone",
                    content: .microphoneIntegration
                ),
                OnboardingInputMethodGuideStep(
                    id: 4,
                    titleKey: "onboarding.voice_tool.guide.release_wechat_fn",
                    content: .screenshot("weixin-app-shortcuts")
                ),
            ]
        case .other:
            toolSteps = [
                OnboardingInputMethodGuideStep(
                    id: 1,
                    titleKey: "onboarding.voice_tool.guide.open_other",
                    content: .instruction(
                        systemImage: "mic.fill",
                        detailKey: "onboarding.voice_tool.guide.open_other.detail"
                    )
                ),
                OnboardingInputMethodGuideStep(
                    id: 2,
                    titleKey: "onboarding.voice_tool.guide.configure_other",
                    content: .instruction(
                        systemImage: "globe",
                        detailKey: "onboarding.voice_tool.guide.configure_other.detail"
                    )
                ),
            ]
        case .unselected:
            return []
        }

        return toolSteps + [
            OnboardingInputMethodGuideStep(
                id: 3,
                titleKey: "onboarding.voice_tool.guide.select_microphone",
                content: .microphoneIntegration
            ),
            OnboardingInputMethodGuideStep(
                id: 4,
                titleKey: "onboarding.voice_tool.guide.release_system_fn",
                content: .systemFunctionKey
            ),
            OnboardingInputMethodGuideStep(
                id: 5,
                titleKey: "onboarding.voice_tool.guide.release_wechat_fn",
                content: .screenshot("weixin-app-shortcuts")
            ),
        ]
    }

    func defaultBindingSummary(profile: VoiceToolAdapterProfile) -> String {
        let descriptions = VoiceGestureMode.allCases.compactMap { mode -> String? in
            guard let shortcut = profile.defaultShortcutByMode[mode] else { return nil }
            return "\(localization.text("onboarding.gesture.\(mode.rawValue)")): " +
                localization.text(shortcut.localizationKey)
        }
        if descriptions.isEmpty {
            return localization.text("onboarding.voice_tool.binding.no_documented_default")
        }
        let evidence = localization.text(
            profile.evidenceState == .verified
                ? "onboarding.voice_tool.binding.evidence_verified"
                : "onboarding.voice_tool.binding.evidence_pending"
        )
        return descriptions.joined(separator: " · ") + " · " + evidence
    }

    private func onboardingGuideImage(resourceName: String) -> NSImage? {
        guard let url = VoiceInputBuddyResourceBundle.onboardingImageURL(
            named: resourceName, isDark: colorScheme == .dark,
            in: VoiceInputBuddyResourceBundle.mainOrDevelopment
        ) else {
            return nil
        }
        return OnboardingImageCache.image(at: url)
    }

    private func selectVoiceTool(_ tool: OnboardingVoiceTool) {
        settings.setOnboardingVoiceTool(tool)
        AppLogger.shared.write(
            "ONBOARDING VOICE_TOOL selected=\(tool.rawValue) binding_policy=function_key"
        )
        selectedInputMethodGuideStep = nil
        completedInputMethodGuideSteps.removeAll()
        refreshSelectedInputMethodStatus()
        refreshSystemFunctionKeyUsage()
        stageCurrentDocumentedPairingPlanIfPossible()
    }

    func selectVoiceBindingPreference(_ preference: OnboardingVoiceBindingPreference) {
        settings.setOnboardingVoiceBindingPreference(preference)
        stageCurrentDocumentedPairingPlanIfPossible()
    }

    func selectPreferredGesture(_ gesture: VoiceGestureMode) {
        settings.setOnboardingPreferredGesture(gesture)
    }

    func stageCurrentDocumentedPairingPlanIfPossible() {
        guard settings.onboardingVoiceBindingPreference == .documentedDefault,
              let plan = proposedPairingPlan else { return }
        settings.beginOnboardingVoiceTrial(plan)
        model.setVoiceKeyMode(plan.binding.shortcut)
        model.setVoiceFnTapModeEnabled(plan.fnTapModeEnabled)
    }
}
struct OnboardingInputMethodGuideStep: Identifiable {
    enum Content {
        case screenshot(String)
        case instruction(systemImage: String, detailKey: String)
        case systemFunctionKey
        case microphoneIntegration
    }

    let id: Int
    let titleKey: String
    let content: Content
}
