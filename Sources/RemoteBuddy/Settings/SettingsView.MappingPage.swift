import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func mappingConfiguration(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction {
        settings.configuredBaseAction(for: button, trigger: trigger)
    }

    private func saveMappingBinding(_ configured: ConfiguredButtonAction, button: RemoteButton, trigger: ButtonTrigger) {
        settings.setBaseBinding(configured, for: button, trigger: trigger, profileID: settings.selectedRemoteProfileID)
    }

    func setMappingAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.action = action
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    func setMappingShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.shortcut = shortcut
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    func setMappingApplicationProfileID(_ id: UUID?, for button: RemoteButton, trigger: ButtonTrigger) {
        var configured = mappingConfiguration(for: button, trigger: trigger)
        configured.applicationProfileID = id
        saveMappingBinding(configured, button: button, trigger: trigger)
    }

    private var mappingPageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                PageHeader(title: localization.text("button_mapping.page.title"))
                mappingHeaderToggle
            }
            Text(localization.text(settings.selectedRemoteProfile?.model.isChromecastRemote == true
                ? "button_mapping.google.subtitle" : "button_mapping.page.subtitle"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var mappingPage: some View {
        hardwareMappingPage {
            if settings.selectedRemoteProfile?.model.isChromecastRemote == true {
                googleChordInformation
                Text(localization.text("google.remote.ir_controls"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RemoteMappingCanvas(
                selectedButton: $selectedRemoteButton,
                activeButtons: model.activeRemoteButtons,
                voiceActive: model.isStreaming,
                actionSummary: { button, trigger in mappingActionSummary(for: button, trigger: trigger) },
                onEdit: { button, trigger in
                    selectedRemoteButton = button
                    mappingActionFilter = .all
                    mappingEditingTarget = ShortcutEditingTarget(
                        button: button,
                        trigger: trigger
                    )
                },
                onVoiceSettings: { selectedSection = .integration },
                remoteModel: settings.selectedRemoteProfile?.model ?? .unknown
            )
            .onReceive(model.$activeRemoteButtons) { buttons in
                selectedRemoteButton = MappingSelectionPolicy.selection(
                    current: selectedRemoteButton,
                    activeButtons: buttons,
                    isLocked: isMappingSelectionLocked
                )
            }
        }
    }

    private var googleChordInformation: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                Label(localization.text("button_mapping.google.enter.title"), systemImage: "return")
                    .font(.system(size: 15, weight: .semibold))
                Text(localization.text("button_mapping.google.enter.detail"))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Text(localization.text("button_mapping.google.enter.limit"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("button-mapping.google-enter-info")
    }

    private func hardwareMappingPage<HardwareCanvas: View>(
        @ViewBuilder hardwareCanvas: @escaping () -> HardwareCanvas
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                mappingPageHeader
                    .fixedSize(horizontal: true, vertical: false)
                mappingDevicePicker
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollViewReader { proxy in
                Group {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            Color.clear
                                .frame(height: 0)
                                .id("mapping-page-top")
                            configurationImportBanner
                            corruptedSettingsBanner

                            hardwareCanvas()

                            if let target = mappingEditingTarget {
                                mappingEditorPanel(target)
                                    .id("mapping-action-editor")
                            }

                            mappingFooter()
                            Color.clear.frame(height: 1).id("mapping-page-bottom")
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .id(settings.selectedRemoteProfileID)
                    .compatibilityScrollEdgeEffect()
                }
                .onChange(of: settings.selectedRemoteProfileID) { _, _ in
                    // 编辑器属于上一只遥控器；切换设备后不得把旧编辑区带到新页面。
                    mappingEditingTarget = nil
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                    DispatchQueue.main.async {
                        proxy.scrollTo("mapping-page-top", anchor: .top)
                    }
                }
                .onAppear {
                    guard mappingEditingTarget != nil else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("mapping-action-editor", anchor: .top)
                    }
                }
                .onChange(of: mappingEditingTarget?.id) { _, targetID in
                    guard targetID != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("mapping-action-editor", anchor: .top)
                        }
                    }
                }
            }
        }
    }

    /// Inline on purpose: an import that quietly dropped an entry must leave a trace the user
    /// can still read afterwards, and the repository's interface rules keep page-level notices
    /// flat inside the page rather than behind a sheet. Renders nothing when the last import
    /// adopted everything, so a clean import keeps the page's layout.
    @ViewBuilder
    private var configurationImportBanner: some View {
        if let notice = settings.configurationImportNotice {
            let rejected = ConfigurationImportNoticeText.rejectedSummary(
                for: notice.rejectedEntryStorageKeys,
                localize: localization.text
            )
            let missing = ConfigurationImportNoticeText.missingApplicationSummary(
                for: notice.applicationsMissingOnThisMac,
                localize: localization.text
            )
            GlassPanel {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localization.text(ConfigurationImportNoticeText.titleKey))
                            .font(.system(size: 12, weight: .semibold))
                        if let rejected {
                            Text(rejected)
                                .font(.system(size: 12))
                        }
                        if let missing {
                            Text(missing)
                                .font(.system(size: 12))
                        }
                        Text(localization.text(ConfigurationImportNoticeText.nextStepKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Inline on purpose: a sheet or alert here would be dismissed once and never seen again,
    /// and the repository's interface rules keep page-level notices flat inside the page.
    /// Renders nothing at all when no key failed to decode, so a healthy launch keeps its layout.
    @ViewBuilder
    private var corruptedSettingsBanner: some View {
        if let summary = CorruptedSettingsNotice.summary(
            for: settings.corruptedSettingKeys,
            localize: localization.text
        ) {
            GlassPanel {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localization.text(CorruptedSettingsNotice.titleKey))
                            .font(.system(size: 12, weight: .semibold))
                        Text(summary)
                            .font(.system(size: 12))
                        Text(localization.text(CorruptedSettingsNotice.recoveryKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(localization.text(CorruptedSettingsNotice.nextStepKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var mappingHeaderToggle: some View {
        Toggle(localization.text("button_mapping.toggle.enabled"), isOn: Binding(
            get: { settings.customMappingEnabled },
            set: { setCustomMappingEnabled($0) }
        ))
        .font(.system(size: 14, weight: .medium))
        .toggleStyle(.switch)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func mappingEditorPanel(_ target: ShortcutEditingTarget) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(target.button.displayName(using: localization))
                        .font(.system(size: 18, weight: .semibold))
                    Text(target.trigger.displayName(using: localization))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Spacer()
                    Button {
                        saveMappingBinding(.disabled, button: target.button, trigger: target.trigger)
                        shortcutCaptureTarget = nil
                        applicationShortcutCaptureProfileID = nil
                    } label: {
                        Label(localization.text("button_mapping.action.clear"), systemImage:
                            mappingConfiguration(for: target.button, trigger: target.trigger).action == .disabled
                                ? "checkmark.circle.fill" : "circle")
                    }
                    .compatibilityButtonStyle(.standard)
                    .help(localization.text("button_mapping.action.not_set_help"))
                    .disabled(
                        target.button == .power &&
                            target.trigger == .singleClick &&
                            settings.experimentalContinuousRecordingEnabled
                    )
                    Button(localization.text("button_mapping.editor.confirm")) {
                        mappingEditingTarget = nil
                        shortcutCaptureTarget = nil
                        applicationShortcutCaptureProfileID = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }

                if mappingConfiguration(for: target.button, trigger: target.trigger).action == .disabled {
                    Text(localization.text("button_mapping.action.not_set_help"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                mappingTriggerEditor(target.button, trigger: target.trigger)
            }
        }
    }

    private func mappingFooter() -> some View {
        // 能力一律取自「链路自报优先、型号默认兜底」的判定结果（见 RemoteVoiceCapabilities）。
        return GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                mappingHIDStatus
                Divider()
                mappingSelectionLockControl
                Divider()
                HStack {
                    Spacer(minLength: 0)
                    mappingRestoreDefaultsButton
                }
            }
        }
    }

    private var mappingHIDStatus: some View {
        Label(
            model.hidStatus.text(using: localization),
            systemImage: "keyboard"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private var mappingSelectionLockControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(localization.text("button_mapping.selection_lock"), isOn: $isMappingSelectionLocked)
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
            Text(localization.text("button_mapping.selection_lock_hint_short"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .help(localization.text("button_mapping.selection_lock_help"))
    }

    var mappingVoiceKeyModeControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localization.text("connection.voice_key_mode.title"))
                .font(.system(size: 12, weight: .medium))
            Picker(localization.text("connection.voice_key_mode.title"), selection: Binding(
                get: { settings.voiceKeyMode },
                set: { model.setVoiceKeyMode($0) }
            )) {
                ForEach(VoiceKeyMode.allCases) { mode in
                    Text(localization.text(mode.localizationKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .tint(Color.accentColor)
            Text(localization.text("connection.voice_key_mode.help"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if settings.voiceKeyMode != .function {
                Text(localization.text("connection.voice_key_mode.unverified_detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(localization.text("connection.voice_key_mode.help"))
    }

    var mappingVoiceFnTapControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(localization.text("connection.voice_fn_tap.enabled"), isOn: Binding(
                get: { settings.voiceFnTapModeEnabled },
                set: { model.setVoiceFnTapModeEnabled($0) }
            ))
            .font(.system(size: 12, weight: .medium))
            .toggleStyle(.switch)
            Text(localization.text("connection.voice_fn_tap.hint_short"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(localization.text("connection.voice_fn_tap.hint"))
        .opacity(settings.voiceKeyMode == .function ? 1 : 0.55)
        .disabled(settings.voiceKeyMode != .function)
    }

    private var mappingRestoreDefaultsButton: some View {
        Button(localization.text("common.action.restore_defaults")) {
            settings.resetBindings()
            selectedRemoteButton = .ok
        }
        .compatibilityButtonStyle(.standard)
    }

    private var mappingDevicePicker: some View {
        let profiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles,
            modelName: remoteModelName,
            systemName: { model.systemDeviceName(for: $0) }
        )
        return Picker(localization.text("remote.device.selector"), selection: Binding<UUID?>(
            get: { settings.selectedRemoteProfileID },
            set: { if let id = $0 { model.selectRemoteProfile(id) } }
        )) {
            if profiles.isEmpty || settings.selectedRemoteProfileID == nil {
                Text(localization.text("remote.device.select_placeholder")).tag(Optional<UUID>.none)
            }
            ForEach(profiles) { profile in
                Text(remoteModelName(profile)).tag(Optional(profile.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 310)
        .disabled(profiles.isEmpty)
    }
}
