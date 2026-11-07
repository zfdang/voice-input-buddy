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
    func apply(to button: NSStatusBarButton, description: String) {
        let resourceName = self == .streaming ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = self == .streaming ? "mic.fill" : "mic"
        // Named images are shared. Keep localized descriptions local to this status item.
        let image = (NSImage(named: NSImage.Name(resourceName))?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: description)
        // Preserve the supplied artwork colors.
        image?.isTemplate = false
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = description
        button.image = image
        button.title = image == nil ? description : ""
        button.appearsDisabled = self == .disconnected
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }
}
