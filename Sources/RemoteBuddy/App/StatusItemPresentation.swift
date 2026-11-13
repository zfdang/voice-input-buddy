import AppKit
import Combine

/// Presentation only: a connection is not proof that audio or input permissions are ready.
enum StatusItemPresentation: String, Equatable {
    case disconnected
    case connected
    case preparing
    case streaming

    var descriptionKey: String { "status_item.state.\(rawValue)" }

    static func resolve(physicalConnected: Bool, isStreaming: Bool, isPreparing: Bool = false) -> Self {
        isStreaming ? .streaming : (isPreparing ? .preparing : (physicalConnected ? .connected : .disconnected))
    }

    static func publisher(physicalConnected: AnyPublisher<Bool, Never>,
                          isStreaming: AnyPublisher<Bool, Never>,
                          isPreparing: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher()) -> AnyPublisher<Self, Never> {
        physicalConnected.combineLatest(isStreaming, isPreparing)
            .map { resolve(physicalConnected: $0, isStreaming: $1, isPreparing: $2) }
            .removeDuplicates().eraseToAnyPublisher()
    }

    @MainActor
    func apply(to button: NSStatusBarButton, description: String) {
        let active = self == .streaming || self == .preparing
        let resourceName = active ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = active ? "mic.fill" : "mic"
        // Named images are shared. Keep localized descriptions local to this status item.
        let image = (NSImage(named: NSImage.Name(resourceName))?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: description)
        // Let macOS tint the monochrome artwork for light and dark menu bars.
        image?.isTemplate = true
        image?.size = NSSize(width: 22, height: 22)
        image?.accessibilityDescription = description
        button.image = image
        button.title = image == nil ? description : ""
        button.appearsDisabled = self == .disconnected
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }
}
