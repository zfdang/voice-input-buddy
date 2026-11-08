import AppKit
import Foundation

struct AppIconIdentifier: RawRepresentable, Hashable, Identifiable, Codable {
    static let standard = AppIconIdentifier(rawValue: "standard")

    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AppIconOption: Identifiable {
    let id: AppIconIdentifier
    let titleKey: String
    let image: NSImage
}

struct AppIconCatalog {
    let options: [AppIconOption]

    init(standardImage: NSImage, additionalOptions: [AppIconOption] = []) {
        options = [
            AppIconOption(
                id: .standard,
                titleKey: "about.preferences.app_icon_standard",
                image: standardImage
            ),
        ] + additionalOptions.filter { $0.id != .standard }
    }

    @MainActor
    static func live(
        resourceBundle: Bundle = RemoteBuddyResourceBundle.mainOrDevelopment
    ) -> AppIconCatalog {
        let standardImage = image(
            named: "standard",
            extension: "png",
            subdirectory: "AppIcons",
            in: resourceBundle
        ) ?? NSApplication.shared.applicationIconImage ?? NSImage(
            size: NSSize(width: 512, height: 512)
        )
        return AppIconCatalog(standardImage: standardImage)
    }

    func resolvedIdentifier(for requestedIdentifier: AppIconIdentifier) -> AppIconIdentifier {
        if options.contains(where: { $0.id == requestedIdentifier }) {
            return requestedIdentifier
        }
        return .standard
    }

    func image(for requestedIdentifier: AppIconIdentifier) -> NSImage {
        option(for: requestedIdentifier).image
    }

    private func option(for requestedIdentifier: AppIconIdentifier) -> AppIconOption {
        let identifier = resolvedIdentifier(for: requestedIdentifier)
        return options.first { $0.id == identifier } ?? options[0]
    }

    private static func image(
        named resourceName: String,
        extension resourceExtension: String,
        subdirectory: String? = nil,
        in bundle: Bundle
    ) -> NSImage? {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: subdirectory
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

@MainActor
final class AppIconController {
    let catalog: AppIconCatalog

    private let applyImage: (NSImage) -> Void
    private var operationID: UInt = 0

    init() {
        catalog = .live()
        applyImage = { image in
            // Native AppKit and SwiftUI alerts read this named image, not the Dock override.
            // Keep the bundle's opaque ICNS separate from the selected rounded runtime logo.
            NSImage(named: NSImage.applicationIconName)?.setName(nil)
            image.setName(NSImage.applicationIconName)
            NSApplication.shared.applicationIconImage = image
        }
    }

    init(
        catalog: AppIconCatalog,
        applyImage: @escaping (NSImage) -> Void
    ) {
        self.catalog = catalog
        self.applyImage = applyImage
    }

    @discardableResult
    func apply(
        _ requestedIdentifier: AppIconIdentifier,
        source: String
    ) -> AppIconIdentifier {
        operationID &+= 1
        let currentOperationID = operationID
        let appliedIdentifier = catalog.resolvedIdentifier(for: requestedIdentifier)
        let requestedLogIdentifier = appliedIdentifier == requestedIdentifier
            ? appliedIdentifier.rawValue
            : "unavailable"
        AppLogger.shared.write(
            "APP_ICON CHANGE operation_id=\(currentOperationID) phase=requested " +
                "source=\(source) requested=\(requestedLogIdentifier)"
        )

        applyImage(catalog.image(for: appliedIdentifier))
        let result = appliedIdentifier == requestedIdentifier ? "applied" : "fallback"
        let reason = appliedIdentifier == requestedIdentifier
            ? "selection_available"
            : "resource_unavailable"
        AppLogger.shared.write(
            "APP_ICON CHANGE operation_id=\(currentOperationID) phase=completed " +
                "result=\(result) reason=\(reason) applied=\(appliedIdentifier.rawValue)"
        )
        return appliedIdentifier
    }
}
