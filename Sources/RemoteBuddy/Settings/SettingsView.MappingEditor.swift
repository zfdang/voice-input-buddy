import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    func mappingTriggerEditor(
        _ button: RemoteButton,
        trigger: ButtonTrigger
    ) -> some View {
        let configured = mappingConfiguration(for: button, trigger: trigger)
        let installedBundleIdentifiers = PresetApplication.installedBundleIdentifiers
        let actions = ButtonAction.pickerActions(
            installedBundleIdentifiers: installedBundleIdentifiers,
            current: configured.action,
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ).filter { $0 != .disabled && $0 != .repeatSingleClick }
        let isManagedPowerAction = button == .power &&
            trigger == .singleClick &&
            settings.experimentalContinuousRecordingEnabled
        return VStack(alignment: .leading, spacing: 16) {
            if trigger == .longPress {
                let isHoldRepeatSelected = configured.action == .repeatSingleClick
                Button {
                    setMappingAction(.repeatSingleClick, for: button, trigger: .longPress)
                    shortcutCaptureTarget = nil
                    applicationShortcutCaptureProfileID = nil
                } label: {
                    Label(localization.text("action.repeat_single_click"), systemImage:
                        isHoldRepeatSelected ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("button-mapping.hold-repeat")
                .accessibilityAddTraits(isHoldRepeatSelected ? .isSelected : [])
                Text(localization.text("button_mapping.hold_repeat.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            mappingActionFilterControl

            ForEach(ButtonActionCategory.allCases.filter(mappingActionFilter.includes)) { category in
                let groupedActions = actions.filter { $0.category == category }
                if !groupedActions.isEmpty {
                    mappingActionGroup(
                        category: category,
                        actions: groupedActions,
                        selectedAction: configured.action,
                        installedBundleIdentifiers: installedBundleIdentifiers,
                        isManagedPowerAction: isManagedPowerAction,
                        onSelect: { action in
                            setMappingAction(action, for: button, trigger: trigger)
                            shortcutCaptureTarget = nil
                            applicationShortcutCaptureProfileID = nil
                        }
                    )
                }
            }

            if configured.action == .customShortcut {
                inlineShortcutEditor(
                    button: button,
                    trigger: trigger,
                    configured: configured
                )
            }

            if configured.action == .openCustomApplication {
                customApplicationEditor(
                    button: button,
                    trigger: trigger,
                    configured: configured
                )
            }

            if trigger == .singleClick,
               configured.action != .disabled,
               !settings.allowsHoldRepeat(for: button) {
                mappingRapidPressControl(button: button)
            }

            if button == .power && trigger == .singleClick && settings.experimentalContinuousRecordingEnabled {
                Text(localization.text("button_mapping.continuous_recording_experiment.power_managed"))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if trigger == .doubleClick && configured.action != .disabled {
                Text(localization.text("button_mapping.double_click.effect"))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if trigger == .longPress && configured.action != .disabled && configured.action != .repeatSingleClick {
                Text(localization.text("button_mapping.long_press.effect"))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if trigger == .singleClick {
                Text(localization.text("button_mapping.single_click.help"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mappingActionFilterControl: some View {
        HStack(spacing: 8) {
            ForEach(MappingActionFilter.visibleCases) { filter in
                let isSelected = mappingActionFilter == filter
                Button {
                    guard mappingActionFilter != filter else { return }
                    mappingActionFilter = filter
                } label: {
                    Text(localization.text(filter.localizationKey))
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(
                            isSelected
                                ? Color(nsColor: .alternateSelectedControlTextColor)
                                : Color.secondary
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            isSelected ? Color.accentColor : Color.clear,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    isSelected ? Color.clear : Color.secondary.opacity(0.22),
                                    lineWidth: 1
                                )
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func mappingRapidPressControl(button: RemoteButton) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(localization.text("button_mapping.rapid_press"), isOn: Binding(
                get: { settings.allowsRapidPress(for: button) },
                set: { settings.setAllowsRapidPress($0, for: button) }
            ))
            .font(.system(size: 13, weight: .medium))
            .toggleStyle(.switch)
            Text(localization.text("button_mapping.rapid_press_hint_short"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .help(localization.text("button_mapping.rapid_press_help"))
    }

    @ViewBuilder
    private func mappingActionGroup(
        category: ButtonActionCategory,
        actions: [ButtonAction],
        selectedAction: ButtonAction,
        installedBundleIdentifiers: Set<String>,
        isManagedPowerAction: Bool,
        onSelect: @escaping (ButtonAction) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.text(category.localizationKey))
                .font(.system(size: 14, weight: .semibold))

            mappingActionGrid(
                actions: actions,
                selectedAction: selectedAction,
                installedBundleIdentifiers: installedBundleIdentifiers,
                isManagedPowerAction: isManagedPowerAction,
                onSelect: onSelect
            )
        }
    }

    private func mappingActionGrid(
        actions: [ButtonAction],
        selectedAction: ButtonAction,
        installedBundleIdentifiers: Set<String>,
        isManagedPowerAction: Bool,
        onSelect: @escaping (ButtonAction) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 148), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(actions) { action in
                    let unavailableApplication = action.presetApplication.map {
                        !installedBundleIdentifiers.contains($0.bundleIdentifier)
                    } ?? false
                    let unavailableExperiment = action == .toggleLongRecording &&
                        !settings.experimentalContinuousRecordingEnabled
                    Button {
                        onSelect(action)
                    } label: {
                        mappingActionLabel(
                            title: action.displayName(using: localization) +
                                (unavailableApplication
                                    ? localization.text("common.suffix.not_installed")
                                    : unavailableExperiment
                                        ? localization.text("common.suffix.experimental_disabled")
                                        : ""),
                            isSelected: selectedAction == action,
                            systemImage: selectedAction == action ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedAction == action ? .isSelected : [])
                    .disabled(isManagedPowerAction || unavailableApplication || unavailableExperiment)
                }
                if actions.contains(.openCommonPhrases) {
                    Button {
                        selectedSection = .commonPhrases
                    } label: {
                        mappingActionLabel(
                            title: localization.text("common_phrases.adjust"),
                            isSelected: false,
                            systemImage: "slider.horizontal.3"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("common-phrases-adjust")
                }
            }
        }
    }

    private func mappingActionLabel(title: String, isSelected: Bool, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func inlineShortcutEditor(
        button: RemoteButton,
        trigger: ButtonTrigger,
        configured: ConfiguredButtonAction
    ) -> some View {
        let target = ShortcutEditingTarget(button: button, trigger: trigger)
        let contextID = target.id
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.text("shortcut.editor.click_first_help"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if shortcutCaptureTarget == target {
                HStack(spacing: 10) {
                    Label(localization.text("shortcut.editor.recording_prompt"), systemImage: "keyboard.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    Button(localization.text("common.action.cancel")) {
                        shortcutCaptureTarget = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                ShortcutCaptureView(
                    onCapture: { shortcut in
                        setMappingShortcut(shortcut, for: button, trigger: trigger)
                        AppLogger.shared.write("SHORTCUT CAPTURE completed target=button")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .succeeded
                        )
                        shortcutCaptureTarget = nil
                    },
                    onFailure: { failure in
                        AppLogger.shared.write("SHORTCUT CAPTURE failed reason=\(failure)")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .failed(failure)
                        )
                        shortcutCaptureTarget = nil
                        if failure == .accessibilityPermissionRequired {
                            _ = KeyboardInjector.requestAccessibilityAccess()
                        }
                    }
                )
                .frame(height: 1)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Label {
                                Text(
                                configured.shortcut?.visualDisplayName(using: localization) ??
                                    localization.text("shortcut.editor.not_recorded")
                                )
                        } icon: {
                            Image(systemName: configured.shortcut == nil ? "keyboard" : "keyboard.badge.checkmark")
                                .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.green)
                        }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(configured.shortcut == nil ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        .help(configured.shortcut?.detailedDisplayName(using: localization) ?? "")

                        Button(localization.text(configured.shortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again")) {
                            applicationShortcutCaptureProfileID = nil
                            shortcutCaptureFeedback = nil
                            shortcutCaptureTarget = target
                        }
                        .compatibilityButtonStyle(.standard)

                        Button(localization.text("common.action.clear")) {
                            setMappingShortcut(nil, for: button, trigger: trigger)
                            shortcutCaptureFeedback = nil
                        }
                        .compatibilityButtonStyle(.standard)
                        .disabled(configured.shortcut == nil)
                    }

                    shortcutCaptureFeedbackView(contextID: contextID)

                    KeyboardShortcutPicker(
                        shortcut: configured.shortcut,
                        showsStandardKeyboardInitially: initialShortcutPickerShowsKeyboard,
                        onSelect: { shortcut in
                            setMappingShortcut(shortcut, for: button, trigger: trigger)
                            shortcutCaptureFeedback = nil
                        }
                    )
                    .id("mapping-shortcut-editor-\(contextID)")
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func customApplicationEditor(
        button: RemoteButton,
        trigger: ButtonTrigger,
        configured: ConfiguredButtonAction
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {

            Text(localization.text("custom_application.target"))
                .font(.system(size: 14, weight: .semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(settings.customApplicationProfiles) { profile in
                    profileSelectionButton(
                        profile,
                        selected: configured.applicationProfileID == profile.id
                    ) {
                        setMappingApplicationProfileID(profile.id, for: button, trigger: trigger)
                    }
                }

                Button {
                    chooseCustomApplication(for: button, trigger: trigger)
                } label: {
                    Label(localization.text("custom_application.add"), systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .compatibilityButtonStyle(.standard)
            }

            if let profile = settings.customApplicationProfile(id: configured.applicationProfileID) {
                Divider()

                Text(localization.text("custom_application.focus_strategy"))
                    .font(.system(size: 14, weight: .semibold))

                HStack(spacing: 8) {
                    ForEach(CustomApplicationFocusStrategy.allCases) { strategy in
                        Button {
                            var updated = profile
                            updated.focusStrategy = strategy
                            settings.updateCustomApplicationProfile(updated)
                            applicationShortcutCaptureProfileID = nil
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: profile.focusStrategy == strategy ? "checkmark.circle.fill" : "circle")
                                Text(strategy.displayName(using: localization))
                                    .lineLimit(1)
                            }
                            .font(.system(size: 13, weight: profile.focusStrategy == strategy ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(profile.focusStrategy == strategy ? Color.accentColor : Color.primary)
                        .background(
                            profile.focusStrategy == strategy
                                ? Color.accentColor.opacity(0.12)
                                : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    profile.focusStrategy == strategy
                                        ? Color.accentColor.opacity(0.5)
                                        : Color.secondary.opacity(0.16)
                                )
                        }
                    }
                }

                if profile.focusStrategy == .keyboardShortcut {
                    inlineApplicationShortcutEditor(profile)
                }

                if profile.focusStrategy == .recordedAccessibility {
                    accessibilityLearningEditor(profile)
                }

                HStack {
                    Spacer()
                    Button(localization.text("custom_application.test")) {
                        _ = KeyboardInjector.send(
                            .openCustomApplication,
                            applicationProfile: profile
                        )
                    }
                    .compatibilityButtonStyle(.prominent)
                }
            } else {
                Text(localization.text("custom_application.not_configured"))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func profileSelectionButton(
        _ profile: CustomApplicationProfile,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : "app")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(profile.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func inlineApplicationShortcutEditor(_ profile: CustomApplicationProfile) -> some View {
        let contextID = "application-\(profile.id.uuidString)"
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.text("custom_application.shortcut.editor_instructions"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if applicationShortcutCaptureProfileID == profile.id {
                HStack(spacing: 10) {
                    Label(localization.text("shortcut.editor.recording_prompt"), systemImage: "keyboard.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    Button(localization.text("common.action.cancel")) {
                        applicationShortcutCaptureProfileID = nil
                    }
                    .compatibilityButtonStyle(.standard)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

                ShortcutCaptureView(
                    onCapture: { shortcut in
                        guard var updated = settings.customApplicationProfile(id: profile.id) else { return }
                        updated.focusShortcut = shortcut
                        settings.updateCustomApplicationProfile(updated)
                        AppLogger.shared.write("SHORTCUT CAPTURE completed target=application_focus")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .succeeded
                        )
                        applicationShortcutCaptureProfileID = nil
                    },
                    onFailure: { failure in
                        AppLogger.shared.write("SHORTCUT CAPTURE failed reason=\(failure)")
                        shortcutCaptureFeedback = ShortcutCaptureFeedback(
                            contextID: contextID,
                            result: .failed(failure)
                        )
                        applicationShortcutCaptureProfileID = nil
                        if failure == .accessibilityPermissionRequired {
                            _ = KeyboardInjector.requestAccessibilityAccess()
                        }
                    }
                )
                .frame(height: 1)
            } else {
                HStack(spacing: 10) {
                    Label {
                        Text(
                            profile.focusShortcut?.displayName(using: localization) ??
                                localization.text("shortcut.editor.not_recorded")
                        )
                    } icon: {
                        Image(systemName: profile.focusShortcut == nil ? "keyboard" : "keyboard.badge.checkmark")
                            .foregroundStyle(profile.focusShortcut == nil ? Color.secondary : Color.green)
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(profile.focusShortcut == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                    Button(localization.text(profile.focusShortcut == nil ? "shortcut.action.record" : "shortcut.action.record_again")) {
                        shortcutCaptureTarget = nil
                        shortcutCaptureFeedback = nil
                        applicationShortcutCaptureProfileID = profile.id
                    }
                    .compatibilityButtonStyle(.prominent)

                    Button(localization.text("common.action.clear")) {
                        var updated = profile
                        updated.focusShortcut = nil
                        settings.updateCustomApplicationProfile(updated)
                        shortcutCaptureFeedback = nil
                    }
                    .compatibilityButtonStyle(.standard)
                    .disabled(profile.focusShortcut == nil)
                }

                shortcutCaptureFeedbackView(contextID: contextID)
            }
        }
    }
}
