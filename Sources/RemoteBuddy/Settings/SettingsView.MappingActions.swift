import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    @ViewBuilder
    func shortcutCaptureFeedbackView(contextID: String) -> some View {
        if shortcutCaptureFeedback?.contextID == contextID,
           let result = shortcutCaptureFeedback?.result {
            switch result {
            case .succeeded:
                Label(localization.text("shortcut.editor.success"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            case .failed(.accessibilityPermissionRequired):
                Label(localization.text("shortcut.editor.permission_required"), systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(.eventTapUnavailable):
                Label(localization.text("shortcut.editor.capture_unavailable"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    func accessibilityLearningEditor(_ profile: CustomApplicationProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.text("custom_application.accessibility.learn_help"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(localization.text("custom_application.accessibility.learn")) {
                    recordCustomApplicationInput(profileID: profile.id)
                }
                .compatibilityButtonStyle(.prominent)
                .disabled(customApplicationLearningStates[profile.id] == .recording)

                Button(localization.text("custom_application.accessibility.test")) {
                    KeyboardInjector.testCustomApplicationInput(profile) { success in
                        DispatchQueue.main.async {
                            if success { settings.markPortableApplicationVerified(profile.id) }
                            customApplicationLearningStates[profile.id] = success ? .succeeded : .failed
                        }
                    }
                }
                .compatibilityButtonStyle(.standard)
                .disabled(profile.accessibilityTarget == nil)
                Text(
                    settings.portablePendingApplications.contains(profile.id.uuidString)
                        ? localization.text("custom_application.accessibility.needs_verification")
                        : profile.accessibilityTarget == nil
                        ? localization.text("custom_application.accessibility.not_recorded")
                        : localization.text("custom_application.accessibility.recorded")
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(profile.accessibilityTarget == nil ? Color.orange : Color.green)
            }

            if let learningState = customApplicationLearningStates[profile.id] {
                Label(
                    localization.text(learningState.messageKey),
                    systemImage: learningState.systemImage
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(learningState.tint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func chooseCustomApplication(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        let panel = NSOpenPanel()
        panel.title = localization.text("custom_application.picker.title")
        panel.prompt = localization.text("common.action.choose")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !bundleIdentifier.isEmpty
        else { return }

        let existing = settings.customApplicationProfiles.first {
            $0.bundleIdentifier == bundleIdentifier
        }
        let profileID: UUID
        if let existing {
            var updated = existing
            updated.applicationPath = url.path
            settings.updateCustomApplicationProfile(updated)
            profileID = existing.id
        } else {
            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            profileID = settings.addCustomApplicationProfile(
                CustomApplicationProfile(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    applicationPath: url.path
                )
            )
        }
        setMappingApplicationProfileID(profileID, for: button, trigger: trigger)
    }

    private func recordCustomApplicationInput(profileID: UUID) {
        guard KeyboardInjector.isAccessibilityTrusted else {
            model.requestAccessibilityPermission()
            return
        }
        guard let profile = settings.customApplicationProfile(id: profileID) else { return }
        customApplicationLearningStates[profileID] = .recording
        let savedURL = URL(fileURLWithPath: profile.applicationPath)
        let applicationURL = Bundle(url: savedURL)?.bundleIdentifier == profile.bundleIdentifier
            ? savedURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleIdentifier)
        guard let applicationURL else {
            customApplicationLearningStates[profileID] = .applicationMissing
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
            guard error == nil else {
                DispatchQueue.main.async {
                    customApplicationLearningStates[profileID] = .openFailed
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                KeyboardInjector.captureFocusedAccessibilityTargetAsync(
                    bundleIdentifier: profile.bundleIdentifier
                ) { target in
                    if let target, var updated = settings.customApplicationProfile(id: profileID) {
                        updated.accessibilityTarget = target
                        updated.focusStrategy = .recordedAccessibility
                        settings.updateCustomApplicationProfile(updated)
                        settings.markPortableApplicationVerified(updated.id)
                    }
                    customApplicationLearningStates[profileID] = target == nil ? .failed : .succeeded
                    NSApp.activate()
                }
            }
        }
    }

    func mappingActionSummary(for button: RemoteButton, trigger: ButtonTrigger,
                                      configuredAction: ConfiguredButtonAction? = nil) -> String {
        let configured = configuredAction ?? mappingConfiguration(for: button, trigger: trigger)
        guard configured.action != .disabled else {
            return localization.text("button_mapping.action.not_set")
        }
        if configured.action == .customShortcut, let shortcut = configured.shortcut {
            return shortcut.visualDisplayName(using: localization)
        }
        if configured.action == .openCustomApplication {
            return settings.customApplicationProfile(id: configured.applicationProfileID)?.displayName
                ?? localization.text("custom_application.not_configured")
        }
        switch configured.action {
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .deleteBackward: return "⌫"
        case .volumeUp: return localization.text("action.system_volume_up_short")
        case .volumeDown: return localization.text("action.system_volume_down_short")
        case .volumeMute: return "Mute"
        default: break
        }
        return configured.action.displayName(using: localization)
    }

    private func buttonProfileSystemImage(for action: ButtonAction) -> String {
        if action.presetApplication != nil { return "app" }
        switch action {
        case .openCommonPhrases: return "text.quote"
        case .focusInput: return "scope"
        case .showDesktop: return "macwindow"
        case .appSwitcher: return "command"
        case .volumeUp, .volumeDown, .volumeMute: return "speaker.wave.2"
        case .playPause, .previousCommandLeft, .nextCommandRight: return "play.circle"
        case .toggleLongRecording: return "record.circle"
        default: return "keyboard"
        }
    }
}
