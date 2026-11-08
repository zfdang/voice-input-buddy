import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

/// Turns the storage keys and application names in a `ConfigurationImportReport` into the
/// warning the button mapping page shows. Storage keys are an implementation detail, so they
/// are collapsed onto the settings a user recognizes; an unrecognized key still surfaces under
/// a generic item so a future importable key cannot be dropped silently — silence about dropped
/// entries is the exact defect this notice exists to close.
enum ConfigurationImportNoticeText {
    static let titleKey = "settings.import_notice.title"
    static let rejectedKey = "settings.import_notice.rejected"
    static let missingApplicationKey = "settings.import_notice.missing_app"
    static let nextStepKey = "settings.import_notice.next_step"
    static let separatorKey = "settings.import_notice.separator"
    static let buttonMappingItemKey = "settings.import_notice.item.button_mapping"
    static let customApplicationItemKey = "settings.import_notice.item.custom_application"
    static let audioGainItemKey = "settings.import_notice.item.audio_gain"
    static let otherItemKey = "settings.import_notice.item.other"

    /// Fixed display order, so the sentence reads the same no matter which order the import
    /// happened to reject entries in.
    private static let itemKeyOrder = [
        buttonMappingItemKey,
        customApplicationItemKey,
        audioGainItemKey,
        otherItemKey,
    ]

    private static let itemKeysByStorageKey: [String: String] = [
        "buttonBindings": buttonMappingItemKey,
        "unifiedBaseBindings": buttonMappingItemKey,
        "buttonShortcuts": buttonMappingItemKey,
        "buttonApplicationProfileIDs": buttonMappingItemKey,
        "secondaryButtonBindings": buttonMappingItemKey,
        "buttonRapidPressEnabled": buttonMappingItemKey,
        "continuousRecordingPowerBindingBackup": buttonMappingItemKey,
        "customApplicationProfiles": customApplicationItemKey,
        "remoteGainDB": audioGainItemKey,
    ]

    /// Deduplicated, order-stable localization keys naming what was skipped.
    static func affectedItemKeys(for storageKeys: [String]) -> [String] {
        let matched = Set(storageKeys.map { itemKeysByStorageKey[$0] ?? otherItemKey })
        return itemKeyOrder.filter(matched.contains)
    }

    static func rejectedSummary(
        for storageKeys: [String],
        localize: (String) -> String
    ) -> String? {
        let itemKeys = affectedItemKeys(for: storageKeys)
        guard !itemKeys.isEmpty else { return nil }
        let list = itemKeys.map(localize).joined(separator: localize(separatorKey))
        return String(format: localize(rejectedKey), list)
    }

    /// Names come from the imported file, so they are only ever displayed, never resolved.
    static func missingApplicationSummary(
        for applicationNames: [String],
        localize: (String) -> String
    ) -> String? {
        guard !applicationNames.isEmpty else { return nil }
        return String(
            format: localize(missingApplicationKey),
            applicationNames.joined(separator: localize(separatorKey))
        )
    }
}

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
        "buttonRapidPressEnabled": buttonMappingItemKey,
        "continuousRecordingPowerBindingBackup": buttonMappingItemKey,
        "customApplicationProfiles": customApplicationItemKey,
        "remoteDeviceProfiles": remoteDeviceItemKey,
    ]

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
