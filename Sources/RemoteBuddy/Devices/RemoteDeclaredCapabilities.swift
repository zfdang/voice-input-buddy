import Foundation

/// Shared voice capability vocabulary for the public adapters and Siri UI.
struct RemoteDeclaredCapabilities: OptionSet, Equatable {
    let rawValue: Int

    static let controlEdges = RemoteDeclaredCapabilities(rawValue: 1 << 0)
    static let voiceStream = RemoteDeclaredCapabilities(rawValue: 1 << 1)
    static let touchSurface = RemoteDeclaredCapabilities(rawValue: 1 << 2)
    static let battery = RemoteDeclaredCapabilities(rawValue: 1 << 3)
    static let toggleVoiceGesture = RemoteDeclaredCapabilities(rawValue: 1 << 4)
}
