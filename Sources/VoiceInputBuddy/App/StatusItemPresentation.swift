import AppKit
import Combine

/// Presentation only: a connection is not proof that audio or input permissions are ready.
enum StatusItemPresentation: String, Equatable {
    case disconnected
    case connected
    case streaming

    var descriptionKey: String { "status_item.state.\(rawValue)" }

    static func resolve(physicalConnected: Bool, isStreaming: Bool) -> Self {
        isStreaming ? .streaming : (physicalConnected ? .connected : .disconnected)
    }

    static func publisher(physicalConnected: AnyPublisher<Bool, Never>,
                          isStreaming: AnyPublisher<Bool, Never>) -> AnyPublisher<Self, Never> {
        physicalConnected.combineLatest(isStreaming)
            .map { resolve(physicalConnected: $0, isStreaming: $1) }
            .removeDuplicates().eraseToAnyPublisher()
    }

    @MainActor
    func apply(to button: NSStatusBarButton, description: String,
               loadImage: (NSImage.Name) -> NSImage? = { NSImage(named: $0) }) {
        let resourceName = self == .streaming ? "StatusIconActive" : "StatusIconTemplate"
        let fallbackSymbol = self == .streaming ? "mic.fill" : "mic"
        // Named images are shared. Keep localized descriptions local to this status item.
        let artwork = loadImage(NSImage.Name(resourceName))?.copy() as? NSImage
        let image = artwork ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: description)
        // The recording artwork is full color; system symbols and the idle icon use tinting.
        image?.isTemplate = self != .streaming || artwork == nil
        image?.size = NSSize(width: 20, height: 20)
        image?.accessibilityDescription = description
        button.image = image
        button.title = image == nil ? description : ""
        button.appearsDisabled = self == .disconnected
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }
}
