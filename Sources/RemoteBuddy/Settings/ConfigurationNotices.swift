import Foundation

/// Turns the storage keys published by `AppSettings.corruptedSettingKeys` into the warning the
/// button mapping page shows. Storage keys are an implementation detail, so they are collapsed
/// onto the settings a user recognizes. An unrecognized key still surfaces under a generic item
/// so that adding a decoded key later cannot silently drop the warning again.
enum CorruptedSettingsNotice {
    static let titleKey = "settings.corrupted.title"
    static let summaryKey = "settings.corrupted.summary"
    static let recoveryKey = "settings.corrupted.recovery"
    static let nextStepKey = "settings.corrupted.next_step"
    static let separatorKey = "settings.corrupted.separator"
    static let buttonMappingItemKey = "settings.corrupted.item.button_mapping"
    static let customApplicationItemKey = "settings.corrupted.item.custom_application"
    static let remoteDeviceItemKey = "settings.corrupted.item.remote_device"
    static let otherItemKey = "settings.corrupted.item.other"

    private static let itemKeyOrder = [
        buttonMappingItemKey,
        customApplicationItemKey,
        remoteDeviceItemKey,
        otherItemKey,
    ]

    private static let itemKeysByStorageKey: [String: String] = [
        "buttonBindings": buttonMappingItemKey,
        "unifiedBaseBindings": buttonMappingItemKey,
        "buttonShortcuts": buttonMappingItemKey,
        "buttonApplicationProfileIDs": buttonMappingItemKey,
        "secondaryButtonBindings": buttonMappingItemKey,
        "customApplicationProfiles": customApplicationItemKey,
        "remoteGainDB": otherItemKey,
        "remoteDeviceProfiles": remoteDeviceItemKey,
    ]

    /// Deduplicated, order-stable localization keys naming what could not be decoded.
    static func affectedItemKeys(for storageKeys: [String]) -> [String] {
        let matched = Set(storageKeys.map { itemKeysByStorageKey[$0] ?? otherItemKey })
        return itemKeyOrder.filter(matched.contains)
    }

    static func summary(
        for storageKeys: [String],
        localize: (String) -> String
    ) -> String? {
        let itemKeys = affectedItemKeys(for: storageKeys)
        guard !itemKeys.isEmpty else { return nil }
        let list = itemKeys.map(localize).joined(separator: localize(separatorKey))
        return String(format: localize(summaryKey), list)
    }
}
