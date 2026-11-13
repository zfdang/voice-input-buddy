import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var generalPage: some View {
        settingsPage(contentPadding: 28) {
            PageHeader(title: localization.text("settings.section.general"))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text(localization.text("settings.overview.title"))
                    .font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    overviewCard(number: 1, titleKey: "settings.overview.permissions", status: permissionsSummary, ready: permissionsReady, section: .permissions)
                    overviewCard(number: 2, titleKey: "settings.overview.remote", status: remoteSummary, ready: !connectedOverviewRemotes.isEmpty, section: .connection)
                    overviewCard(number: 3, titleKey: "settings.overview.mapping", status: localization.text(settings.customMappingEnabled ? "common.status.enabled" : "settings.overview.optional"), ready: settings.customMappingEnabled, optional: true, section: .mapping)
                    overviewCard(number: 4, titleKey: "settings.overview.integration", status: localization.text(settings.onboardingVoiceTool == .unselected ? "settings.overview.not_configured" : settings.onboardingVoiceTool.titleKey), ready: settings.onboardingVoiceTool != .unselected, section: .integration)
                }
            }
            .padding(.bottom, 16)

            GlassPanel {
                HStack(spacing: 18) {
                    Image(systemName: "wand.and.stars").font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(localization.text("about.preferences.restart_onboarding")).font(.headline)
                        Text(localization.text("about.preferences.restart_onboarding_help"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(localization.text("about.preferences.restart_onboarding_action")) {
                        settings.restartOnboarding()
                    }
                    .compatibilityButtonStyle(.prominent)
                    .controlSize(.large)
                }
            }
            .padding(.bottom, 16)

            CompatibilityGlassContainer(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localization.text("settings.general.title"))
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        VStack(spacing: 0) {
                            HStack(spacing: 14) {
                                Image(systemName: "dock.rectangle")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localization.text("about.preferences.show_dock_icon"))
                                        .font(.subheadline.weight(.semibold))
                                    Text(localization.text("about.preferences.show_dock_icon_help"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { settings.showDockIcon },
                                    set: { setDockIconVisible($0) }
                                ))
                                .labelsHidden()
                                .accessibilityLabel(localization.text("about.preferences.show_dock_icon"))
                                .toggleStyle(.switch)
                            }
                            .padding(.vertical, 8)

                            Divider()

                            if appIconCatalog.options.count > 1 {
                                appIconPreferenceRow
                                Divider()
                            }

                            HStack(spacing: 14) {
                                Image(systemName: "menubar.rectangle")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localization.text("about.preferences.show_status_bar_icon"))
                                        .font(.subheadline.weight(.semibold))
                                    Text(localization.text("about.preferences.show_status_bar_icon_help"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { settings.showStatusBarIcon },
                                    set: { setStatusBarIconVisible($0) }
                                ))
                                .labelsHidden()
                                .accessibilityLabel(localization.text("about.preferences.show_status_bar_icon"))
                                .toggleStyle(.switch)
                            }
                            .padding(.vertical, 8)

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "power")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(localization.text("settings.general.launch_behavior"))
                                        .font(.subheadline.weight(.semibold))
                                    Text(localization.text("settings.general.launch_behavior_help"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                HStack(spacing: 10) {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(localization.text("about.preferences.launch_at_login"))
                                            .font(.system(size: 12, weight: .medium))
                                        Toggle("", isOn: Binding(
                                            get: { loginItemService.isEnabled },
                                            set: { loginItemService.setEnabled($0) }
                                        ))
                                        .labelsHidden()
                                        .accessibilityLabel(localization.text("about.preferences.launch_at_login"))
                                        .toggleStyle(.switch)
                                    }

                                    Divider()
                                        .frame(height: 34)

                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(localization.text("about.preferences.open_main_window_at_launch"))
                                            .font(.system(size: 12, weight: .medium))
                                        Toggle("", isOn: $settings.openMainWindowAtLaunch)
                                            .labelsHidden()
                                            .accessibilityLabel(localization.text("about.preferences.open_main_window_at_launch"))
                                            .toggleStyle(.switch)
                                    }
                                }
                            }
                            .padding(.vertical, 8)

                            if loginItemService.requiresApproval {
                                Text(localization.text("about.preferences.launch_at_login_requires_approval"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.bottom, 8)
                                Button(
                                    localization.text("about.preferences.launch_at_login_open_system_settings"),
                                    action: loginItemService.openLoginItemsSettings
                                )
                                .compatibilityButtonStyle(.standard)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            } else if loginItemService.didFailToUpdate {
                                Text(localization.text("about.preferences.launch_at_login_update_failed"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .padding(.bottom, 8)
                            }

                            Divider()

                            HStack(spacing: 14) {
                                Image(systemName: "globe")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(localization.text("about.preferences.language"))
                                        .font(.subheadline.weight(.semibold))
                                    Text(localization.text("about.preferences.language_description"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 20)
                                Picker(localization.text("about.preferences.language"), selection: Binding(
                                    get: { localization.language },
                                    set: { localization.select($0) }
                                )) {
                                    ForEach(AppLanguage.allCases) { language in
                                        Text(languageTitle(language)).tag(language)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 300)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var permissionsReady: Bool {
        bluetoothAuthorization == .allowedAlways && inputMonitoringGranted && accessibilityGranted
    }

    private var permissionsSummary: String {
        if permissionsReady { return localization.text("settings.overview.granted") }
        var missing: [String] = []
        if bluetoothAuthorization != .allowedAlways { missing.append(localization.text("permission.bluetooth.title")) }
        if !inputMonitoringGranted { missing.append(localization.text("permission.input_monitoring.title")) }
        if !accessibilityGranted { missing.append(localization.text("permission.accessibility.title")) }
        return String(format: localization.text("settings.overview.missing_permissions"), missing.joined(separator: ", "))
    }

    private var connectedOverviewRemotes: [RemoteDeviceProfile] {
        settings.remoteDeviceProfiles.filter { model.isRemoteConnected($0.id) }
    }

    private var remoteSummary: String {
        let names = connectedOverviewRemotes.map { remoteModelName($0) }
        guard !names.isEmpty else { return localization.text("settings.overview.disconnected") }
        return names.joined(separator: ", ")
    }

    private func overviewCard(number: Int, titleKey: String, status: String, ready: Bool, optional: Bool = false, section: SettingsSection) -> some View {
        let tint: Color = ready ? .green : (optional ? .secondary : .orange)
        return Button {
            selectedSection = section
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.12), in: Circle())
                    Spacer(minLength: 0)
                    Image(systemName: ready ? "checkmark.circle.fill" : (optional ? "circle" : "exclamationmark.circle.fill"))
                        .foregroundStyle(tint)
                }
                Text(localization.text(titleKey))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.3), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var aboutPage: some View {
        settingsPage(contentPadding: 28) {
            PageHeader(title: localization.text("settings.section.about"))
        } content: {
            CompatibilityGlassContainer(spacing: 0) {
                VStack(spacing: 0) {
                    aboutHeroHeader

                    softwareUpdateSection

                    inlineDiagnosticsSection

                    if model.isRC003VoiceExtensionTestEnabled {
                        Text(localization.text("about.preferences.rc003_voice_extension_test"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Divider() }
                    }

                    settingsSupportSection
                }
            }
        }
        .onAppear {
            guard !SettingsVisualRenderingPolicy.isScreenshotHarness else { return }
            guard UpdateCheckPolicy(
                checksForPreReleaseUpdates: settings.checksForPreReleaseUpdates
            ).refreshesAboutInformationOnAppear else { return }
            refreshUpdateInformation()
        }
    }

    private var aboutHeroHeader: some View {
        VStack(spacing: 12) {
            Image(nsImage: appIconCatalog.image(
                for: settings.appIconIdentifier
            ))
            .resizable()
            .frame(width: 80, height: 80)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

            VStack(spacing: 6) {
                Text(localization.text("app.name"))
                    .font(.system(size: 22, weight: .bold))

                Text(localization.text("settings.application.tagline"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    Text(localization.text("about.version.current"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(currentVersion)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                    if case .available = updateInformation.state {
                        StatusPill(
                            text: localization.text("about.version.available"),
                            tint: .green
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var softwareUpdateSection: some View {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(localization.text("about.version.title"))
                            .font(.subheadline.weight(.semibold))
                        Text(localization.text("about.version.check_prerelease_help_short"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Toggle(
                        localization.text("about.version.check_prerelease"),
                        isOn: $settings.checksForPreReleaseUpdates
                    )
                    .toggleStyle(.switch)
                    .font(.system(size: 12))

                    Button(action: checkForUpdates) {
                        Label(
                            localization.text("menu.check_for_updates"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .compatibilityButtonStyle(.standard)
                    .fixedSize(horizontal: true, vertical: false)
                }

                updateInformationContent

                if case let .available(update) = updateInformation.state {
                    HStack {
                        Spacer()
                        Button(action: checkForUpdates) {
                            Text(String(
                                format: localization.text("about.version.update_to"),
                                locale: localization.locale,
                                arguments: [update.displayVersion]
                            ))
                        }
                        .compatibilityButtonStyle(.prominent)
                    }
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var settingsSupportSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.text("about.support.feedback"))
                    .font(.subheadline.weight(.semibold))
                Text(localization.text("about.support.feedback_description"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Link(destination: localization.localizedWebsiteURL) {
                Label(localization.text("about.support.website"), systemImage: "globe")
            }
            .compatibilityButtonStyle(.standard)
            Link(destination: AppLinks.githubRepository) {
                Label(localization.text("about.support.github"), systemImage: "link")
            }
            .compatibilityButtonStyle(.standard)
            Link(destination: AppLinks.feedback) {
                Label(localization.text("about.support.feedback_action"), systemImage: "arrow.up.right")
            }
            .compatibilityButtonStyle(.standard)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }
}
