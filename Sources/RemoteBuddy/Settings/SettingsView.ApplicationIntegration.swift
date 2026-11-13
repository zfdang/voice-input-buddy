import SwiftUI

extension SettingsView {
    var applicationIntegrationPage: some View {
        settingsPage {
            PageHeader(title: localization.text("application_integration.title"))
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text(localization.text("application_integration.introduction"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(localization.text("application_integration.supported")).font(.headline)
                    Spacer()
                    Button(localization.text("application_integration.enable_all")) {
                        settings.setAllApplicationIntegrations(enabled: true)
                    }
                    .disabled(ApplicationIntegration.allCases.allSatisfy(settings.isApplicationIntegrationEnabled))
                    Button(localization.text("application_integration.disable_all")) {
                        settings.setAllApplicationIntegrations(enabled: false)
                    }
                    .disabled(settings.enabledApplicationIntegrations.isEmpty)
                }
                ForEach(ApplicationIntegration.allCases) { application in
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                let name = application == .weChat ? localization.text("application.wechat") : application.title
                                Text(name).font(.headline)
                                Spacer()
                                Toggle(name, isOn: Binding(
                                    get: { settings.isApplicationIntegrationEnabled(application) },
                                    set: { settings.setApplicationIntegration(application, enabled: $0) }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .accessibilityLabel(name)
                            }
                            Text(localization.text(application.detailKey))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Label(localization.text("application_integration.accessibility_help"), systemImage: "accessibility")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
