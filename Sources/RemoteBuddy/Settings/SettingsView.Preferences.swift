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
                let overview = overviewState
                HStack(spacing: 10) {
                    overviewCard(number: 1, titleKey: "settings.section.permissions", status: overview.permissionsSummary(using: localization), ready: overview.permissionsReady, section: .permissions)
                    overviewCard(number: 2, titleKey: "settings.overview.remote", status: remoteSummary, ready: overview.remoteReady, section: .connection)
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

            VStack(alignment: .leading, spacing: 20) {
                aboutSection(titleKey: "settings.general.display_group") {
                    VStack(spacing: 0) {
                        preferenceRow(symbol: "dock.rectangle", titleKey: "about.preferences.show_dock_icon", detailKey: "about.preferences.show_dock_icon_help") {
                            Toggle("", isOn: Binding(
                                get: { settings.showDockIcon },
                                set: { setDockIconVisible($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(localization.text("about.preferences.show_dock_icon"))
                            .toggleStyle(.switch)
                        }
                        Divider()
                        preferenceRow(symbol: "menubar.rectangle", titleKey: "about.preferences.show_status_bar_icon", detailKey: "about.preferences.show_status_bar_icon_help") {
                            Toggle("", isOn: Binding(
                                get: { settings.showStatusBarIcon },
                                set: { setStatusBarIconVisible($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(localization.text("about.preferences.show_status_bar_icon"))
                            .toggleStyle(.switch)
                        }
                        if appIconCatalog.options.count > 1 {
                            Divider()
                            appIconPreferenceRow
                        }
                    }
                }

                aboutSection(titleKey: "settings.general.launch_behavior") {
                    VStack(spacing: 0) {
                        preferenceRow(symbol: "power", titleKey: "about.preferences.launch_at_login", detailKey: "about.preferences.launch_at_login_help") {
                            Toggle("", isOn: Binding(
                                get: { loginItemService.isEnabled },
                                set: { loginItemService.setEnabled($0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel(localization.text("about.preferences.launch_at_login"))
                            .toggleStyle(.switch)
                        }
                        if loginItemService.requiresApproval {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(localization.text("about.preferences.launch_at_login_requires_approval"))
                                    .font(.caption).foregroundStyle(.orange)
                                Button(localization.text("about.preferences.launch_at_login_open_system_settings"), action: loginItemService.openLoginItemsSettings)
                                    .compatibilityButtonStyle(.standard)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 48)
                            .padding(.bottom, 10)
                        } else if loginItemService.didFailToUpdate {
                            Text(localization.text("about.preferences.launch_at_login_update_failed"))
                                .font(.caption).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 48)
                                .padding(.bottom, 10)
                        }
                        Divider()
                        preferenceRow(symbol: "macwindow", titleKey: "about.preferences.open_main_window_at_launch", detailKey: "settings.general.open_window_help") {
                            Toggle("", isOn: $settings.openMainWindowAtLaunch)
                                .labelsHidden()
                                .accessibilityLabel(localization.text("about.preferences.open_main_window_at_launch"))
                                .toggleStyle(.switch)
                        }
                    }
                }

                aboutSection(titleKey: "settings.general.language_group") {
                    preferenceRow(symbol: "globe", titleKey: "about.preferences.language", detailKey: "about.preferences.language_description") {
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
                }
            }

        }
    }

    private func preferenceRow<Control: View>(symbol: String, titleKey: String, detailKey: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(localization.text(titleKey)).font(.subheadline.weight(.semibold))
                Text(localization.text(detailKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    var overviewState: SettingsOverviewState {
        SettingsOverviewState(
            bluetoothGranted: bluetoothAuthorization == .allowedAlways,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            audioDevices: model.audioDevices, profiles: settings.remoteDeviceProfiles,
            connectedIDs: model.connectedRemoteProfileIDs,
            mappingEnabled: settings.customMappingEnabled, integrationTool: settings.onboardingVoiceTool,
            remoteName: remoteModelName
        )
    }

    private var remoteSummary: String {
        let names = overviewState.connectedRemoteNames
        return names.isEmpty ? localization.text("settings.overview.disconnected")
            : SettingsOverviewState.localizedList(names, locale: localization.locale)
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
            VStack(alignment: .leading, spacing: 20) {
                aboutHeroHeader

                aboutSection(titleKey: "about.info.title") {
                    VStack(spacing: 0) {
                        aboutInfoRow(title: localization.text("about.version.current"), value: currentVersion)
                        Divider()
                        aboutInfoRow(title: localization.text("about.info.build"), value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? localization.text("common.value.unknown"))
                        Divider()
                        aboutInfoRow(title: localization.text("about.info.architecture"), value: FirstUseDiagnosticSnapshot.architecture)
                    }
                }

                if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
                    aboutSection(titleKey: "about.info.updates") { softwareUpdateSection }
                }

                aboutSection(titleKey: "settings.diagnostics.title") { inlineDiagnosticsSection }

                if model.isRC003VoiceExtensionTestEnabled {
                    Text(localization.text("about.preferences.rc003_voice_extension_test"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                aboutSection(titleKey: "about.info.project") { settingsSupportSection }
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

                Text(localization.text("about.app.description"))
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
        .padding(.bottom, 4)
    }

    private func aboutSection<Content: View>(titleKey: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.text(titleKey)).font(.title3.weight(.semibold))
            GlassPanel { content().frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func aboutInfoRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .padding(.vertical, 8)
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
            .padding(.vertical, 2)
        }
    }

    private var settingsSupportSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localization.text("about.page.hero_description"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Divider()
            aboutLinkRow(titleKey: "about.support.website", symbol: "globe", label: "remote.zfdang.com", destination: localization.localizedWebsiteURL)
            Divider()
            aboutLinkRow(titleKey: "about.info.releases", symbol: "shippingbox", label: localization.text("about.info.open_releases"), destination: AppLinks.githubReleases)
            Divider()
            aboutLinkRow(titleKey: "about.support.github", symbol: "link", label: "github.com/zfdang/remote-buddy", destination: AppLinks.githubRepository)
            Divider()
            aboutLinkRow(titleKey: "about.support.feedback", symbol: "bubble.left.and.bubble.right", label: localization.text("about.support.feedback_action"), destination: AppLinks.feedback)
        }
    }

    private func aboutLinkRow(titleKey: String, symbol: String, label: String, destination: URL) -> some View {
        HStack(spacing: 10) {
            Label(localization.text(titleKey), systemImage: symbol)
            Spacer(minLength: 12)
            Link(label, destination: destination)
        }
        .padding(.vertical, 10)
    }
}
