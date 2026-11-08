import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    @ViewBuilder
    var updateInformationContent: some View {
        switch updateInformation.state {
        case .idle:
            Text(localization.text("about.version.information_title"))
                .font(.headline)
            Text(localization.text("about.version.information_idle"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .checking:
            Text(localization.text("about.version.information_title"))
                .font(.headline)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(localization.text("about.version.checking"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            Label(localization.text("about.version.up_to_date"), systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(localization.text("about.version.up_to_date_description"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .unavailable:
            Label(localization.text("about.version.information_unavailable"), systemImage: "wifi.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(localization.text("about.version.information_unavailable_description"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case let .available(update):
            Text(String(
                format: localization.text("about.version.release_notes_title"),
                locale: localization.locale,
                arguments: [update.displayVersion]
            ))
            .font(.headline)

            if update.releaseNotes.isEmpty {
                Text(localization.text("about.version.release_notes_unavailable"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(update.releaseNotes.enumerated()), id: \.offset) { index, note in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(note)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "BuddyReleaseVersion") as? String) ??
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ??
            localization.text("common.value.unknown")
    }

    func languageTitle(_ language: AppLanguage) -> String {
        language == .system ? localization.text("language.system") : language.nativeDisplayName
    }

}
