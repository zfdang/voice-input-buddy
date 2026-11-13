import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var sidebar: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: SettingsPageBehavior.sidebarTopDragHeight)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Image(nsImage: appIconCatalog.image(for: settings.appIconIdentifier))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                Text(verbatim: localization.text("app.name"))
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)

            Divider()
                .padding(.horizontal, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(visibleSections) { section in
                        sidebarButton(section)
                    }
                }
                .padding(.top, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var visibleSections: [SettingsSection] {
        SettingsPageBehavior.sidebarSections()

    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        let isSelected = (selectedSection == .commonPhrases ? .mapping : selectedSection) == section
        return Button {
            selectSection(section)
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 21, weight: .semibold))
                    if SettingsPageBehavior.showsUpdateBadge(
                        for: section,
                        hasUnseenUpdate: updateInformation.hasUnseenUpdate
                    ) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(x: 4, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                Text(localization.text(section.titleKey))
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(
            SettingsPageBehavior.showsUpdateBadge(
                for: section,
                hasUnseenUpdate: updateInformation.hasUnseenUpdate
            ) ? Text(localization.text("settings.update_badge.accessibility_value")) : Text("")
        )
    }

    func selectSection(_ section: SettingsSection) {
        selectedSection = section
        if SettingsPageBehavior.marksUpdateAsSeen(whenSelecting: section) {
            updateInformation.markAvailableUpdateSeen()
        }
    }

    @ViewBuilder
    var selectedPage: some View {
        switch SettingsPageBehavior.visibleSection(for: selectedSection) {
        case .connection:
            connectionPage
        case .integration:
            integrationPage
        case .mapping:
            if let device = settings.selectedRemoteProfile,
               device.model.isAppleSiriRemote {
                settingsPage {
                    PageHeader(title: localization.text("button_mapping.page.title"))
                } content: {
                    Text(localization.text("button_mapping.unsupported_device"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                mappingPage
            }
        case .commonPhrases:
            CommonPhraseSettingsView(store: model.commonPhraseStore) {
                selectSection(.mapping)
            }
        case .permissions:
            permissionsPage
        case .general:
            generalPage
        case .about:
            aboutPage
        }
    }

    func settingsPage<Header: View, Content: View>(
        contentPadding: CGFloat = 22,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .padding(contentPadding)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .compatibilityScrollEdgeEffect()
        }
    }
}
