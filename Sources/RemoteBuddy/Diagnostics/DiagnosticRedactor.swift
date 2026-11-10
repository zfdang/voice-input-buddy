import Foundation

enum DiagnosticRedactor {
    /// Normalizes and redacts peripheral and device names before they enter logs or public diagnostic reports.
    /// Known factory model names are retained; any personalized or arbitrary names are masked.
    static func redactedDeviceName(_ rawName: String?) -> String {
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "unknown"
        }
        let lower = name.lowercased()
        let knownFactoryNames = [
            "mi rc", "siri remote", "apple tv remote", "apple remote",
            "chromecast remote", "google tv remote"
        ]
        if knownFactoryNames.contains(where: { lower.contains($0) }) ||
            RemoteModel.allCases.contains(where: { RemoteDeviceNamePolicy.isFactoryName(name, model: $0) }) {
            return name
        }
        let hash = String(format: "%04x", abs(name.hashValue) % 0x10000)
        return "device_\(hash)"
    }
}
