import Combine
import Foundation

/// Resolves the resource bundle used by the running app and by the SwiftPM
/// screenshot executable. Release apps always win; the repository fallback is
/// only considered when the executable has no localized resources (the normal
/// `swift run` layout).
enum RemoteBuddyResourceBundle {
    static func onboardingImageURL(named name: String, isDark: Bool, in bundle: Bundle) -> URL? {
        let appearances = isDark ? ["dark", "light"] : ["light"]
        for appearance in appearances {
            for format in ["jpg", "jpeg", "png"] {
                if let url = bundle.url(forResource: "\(name)-\(appearance)",
                                        withExtension: format, subdirectory: "Onboarding") {
                    return url
                }
            }
        }
        return nil
    }

    static var mainOrDevelopment: Bundle {
        if hasLocalizedResources(in: .main) {
            return .main
        }

        for candidate in candidates {
            if let bundle = Bundle(path: candidate.path), hasLocalizedResources(in: bundle) {
                return bundle
            }
        }
        return .main
    }

    private static var candidates: [URL] {
        var urls: [URL] = []
#if DEBUG
        if let explicitPath = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_RESOURCE_ROOT"
        ], !explicitPath.isEmpty {
            urls.append(URL(fileURLWithPath: explicitPath, isDirectory: true))
        }

#endif
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        urls.append(currentDirectory.appendingPathComponent("Resources", isDirectory: true))

#if DEBUG
        // Resolve from the package marker instead of assuming a source directory depth.
        // Keep absolute source paths out of Release binaries.
        if let resources = developmentResourceRoot(from: URL(fileURLWithPath: #filePath)) {
            urls.append(resources)
        }
#endif
        return urls.reduce(into: []) { result, url in
            guard !result.contains(url) else { return }
            result.append(url)
        }
    }

#if DEBUG
    static func developmentResourceRoot(from sourceFile: URL) -> URL? {
        var directory = sourceFile.deletingLastPathComponent().standardizedFileURL
        while true {
            let resources = directory.appendingPathComponent("Resources", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: resources.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return resources
            }
            guard directory.path != "/", !directory.path.isEmpty else { return nil }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }
#endif

    private static func hasLocalizedResources(in bundle: Bundle) -> Bool {
        bundle.path(forResource: "en", ofType: "lproj") != nil ||
            bundle.path(forResource: "zh-Hans", ofType: "lproj") != nil
    }
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var nativeDisplayName: String {
        guard self != .system else { return rawValue }
        let nativeLocale = Locale(identifier: rawValue)
        return nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
    }
}

struct LocalizedMessage: Equatable {
    let key: String
    let arguments: [String]

    init(_ key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }

    @MainActor func text(using localization: LocalizationStore) -> String {
        let template = localization.text(key)
        guard !arguments.isEmpty else { return template }
        return String(
            format: template,
            locale: localization.locale,
            arguments: arguments
        )
    }
}

@MainActor
final class LocalizationStore: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published private(set) var locale: Locale

    private let settings: AppSettings
    private let resourceBundle: Bundle
    private var localeObserver: NSObjectProtocol?

    init(settings: AppSettings, resourceBundle: Bundle = RemoteBuddyResourceBundle.mainOrDevelopment) {
        self.settings = settings
        self.resourceBundle = resourceBundle
        language = settings.applicationLanguage
        locale = LocalizationSnapshot.resolvedLocale(
            for: settings.applicationLanguage,
            resourceBundle: resourceBundle
        )
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.language == .system else { return }
                self.locale = LocalizationSnapshot.resolvedLocale(
                    for: .system, resourceBundle: self.resourceBundle
                )
            }
        }
    }

    isolated deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    func select(_ language: AppLanguage) {
        guard self.language != language else { return }
        settings.applicationLanguage = language
        self.language = language
        locale = LocalizationSnapshot.resolvedLocale(for: language, resourceBundle: resourceBundle)
    }

    var snapshot: LocalizationSnapshot {
        LocalizationSnapshot(locale: locale, resourceBundle: resourceBundle)
    }

    func text(_ key: String) -> String { snapshot.text(key) }
    func localizedURL(forResource name: String, withExtension extension: String) -> URL? {
        snapshot.localizedURL(forResource: name, withExtension: `extension`)
    }
    var localizedWebsiteURL: URL { snapshot.localizedWebsiteURL }
}

/// An immutable lookup for non-UI consumers; it never observes or mutates preferences.
struct LocalizationSnapshot {
    let locale: Locale
    let resourceBundle: Bundle

    init(locale: Locale, resourceBundle: Bundle) {
        self.locale = locale
        self.resourceBundle = resourceBundle
    }

    init(language: AppLanguage, resourceBundle: Bundle = RemoteBuddyResourceBundle.mainOrDevelopment) {
        self.init(locale: LocalizationSnapshot.resolvedLocale(for: language, resourceBundle: resourceBundle),
                  resourceBundle: resourceBundle)
    }

    func text(_ key: String) -> String {
        if let localizedBundle = bundle(for: locale.identifier) {
            let value = localizedBundle.localizedString(
                forKey: key,
                value: nil,
                table: "Localizable"
            )
            if value != key {
                return value
            }
        }

        if locale.identifier != AppLanguage.english.rawValue,
           let englishBundle = bundle(for: AppLanguage.english.rawValue) {
            return englishBundle.localizedString(
                forKey: key,
                value: key,
                table: "Localizable"
            )
        }

        return key
    }

    func localizedURL(forResource name: String, withExtension extension: String) -> URL? {
        if let localizedURL = resourceBundle.url(
            forResource: name,
            withExtension: `extension`,
            subdirectory: nil,
            localization: locale.identifier
        ) {
            return localizedURL
        }

        guard locale.identifier != AppLanguage.english.rawValue else { return nil }
        return resourceBundle.url(
            forResource: name,
            withExtension: `extension`,
            subdirectory: nil,
            localization: AppLanguage.english.rawValue
        )
    }

    var localizedWebsiteURL: URL {
        AppLinks.website(for: locale)
    }

    private func bundle(for localizationIdentifier: String) -> Bundle? {
        guard let path = resourceBundle.path(
            forResource: localizationIdentifier,
            ofType: "lproj"
        ) else {
            return nil
        }
        return Bundle(path: path)
    }

    static func resolvedLocale(
        for language: AppLanguage,
        resourceBundle: Bundle
    ) -> Locale {
        switch language {
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        case .system:
            let supportedLocalizations = resourceBundle.localizations.filter { $0 != "Base" }
            let preferredLocalization = Bundle.preferredLocalizations(
                from: supportedLocalizations,
                forPreferences: Locale.preferredLanguages
            ).first ?? AppLanguage.english.rawValue
            return Locale(identifier: preferredLocalization)
        }
    }
}
