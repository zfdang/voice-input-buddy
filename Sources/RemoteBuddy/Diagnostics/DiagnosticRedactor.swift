import CryptoKit
import Foundation

enum DiagnosticRedactor {
    /// Per-process salt keeps redactions correlated within one session while preventing offline dictionary lookups across logs.
    private static let sessionSalt = UUID().uuidString

    private static let knownFactoryNames: Set<String> = [
        "mi rc", "siri remote", "apple tv remote", "apple remote",
        "chromecast remote", "google tv remote",
        "macbook pro speakers", "macbook air speakers", "imac speakers",
        "mac mini speakers", "mac studio speakers", "mac pro speakers",
        "built-in output", "built-in microphone", "external headphones",
        "display audio", "buddy microphone"
    ]

    /// Normalizes and redacts peripheral and device names before they enter logs or public diagnostic reports.
    /// Known factory model names are retained; any personalized or arbitrary names are masked.
    static func redactedDeviceName(_ rawName: String?) -> String {
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "unknown"
        }
        let lower = name.lowercased()
        if knownFactoryNames.contains(lower) ||
            RemoteModel.allCases.contains(where: { RemoteDeviceNamePolicy.isFactoryName(name, model: $0) }) {
            return name
        }
        let digest = SHA256.hash(data: Data("\(sessionSalt):\(name)".utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "device_\(hex)"
    }
}
