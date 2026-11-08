import ApplicationServices
import Foundation

/// Setting the system-wide AX object configures the default for ALL AX queries in this process.
/// It does not change the timeout used by other clients.
/// Swift initializes this once; ordinary attribute reads do not repeatedly reconfigure AX.
enum AccessibilityMessaging {
    static let queryQueue = DispatchQueue(label: "voice-input-buddy.accessibility", qos: .userInitiated)

    static func attributes(_ element: AXUIElement, keys: [String]) -> [String: Any] {
        prepareQueries()
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &values) == .success,
              let values = values as? [Any], values.count == keys.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(keys, values).map { ($0, $1) })
    }

    private static let setupResult = configureTimeout(
        install: { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.05) },
        reportFailure: AppLogger.shared.write
    )

    @discardableResult
    static func configureTimeout(install: () -> AXError, reportFailure: (String) -> Void) -> AXError {
        let result = install()
        if result != .success {
            reportFailure("AX TIMEOUT configuration_failed code=\(result.rawValue)")
        }
        return result
    }

    static func prepareQueries() {
        _ = setupResult
    }
}
