import Foundation

enum RemoteBuddyDeepLinkStatus: String, CaseIterable {
    case received
    case configured
    case partial
    case ready
    case failed
}

struct RemoteBuddyDeepLinkRequest: Equatable {
    let source: String?
    let status: RemoteBuddyDeepLinkStatus?
    let reason: String?

    var mayActivateSettings: Bool { source != nil }

    static func parse(_ url: URL) -> Self? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "remote-buddy" || components.scheme?.lowercased() == "voice-input-buddy",
              components.host?.lowercased() == "launch",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }

        let items = Dictionary(
            grouping: components.queryItems ?? [],
            by: \.name
        )
        guard items.values.allSatisfy({ $0.count == 1 }) else { return nil }

        let source = items["source"]?.first?.value.flatMap(normalizedSource)
        let status = items["status"]?.first?.value
            .flatMap(RemoteBuddyDeepLinkStatus.init(rawValue:))
        let reason = items["reason"]?.first?.value.flatMap(normalizedReason)
        return Self(source: source, status: status, reason: reason)
    }

    private static func normalizedSource(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.")
        guard value.lowercased().unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value.lowercased()
    }

    private static func normalizedReason(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.")
        guard value.lowercased().unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value.lowercased()
    }
}

extension Notification.Name {
    static let remoteBuddyDeepLinkReceived = Notification.Name("remotebuddy.deepLink.received")
}
