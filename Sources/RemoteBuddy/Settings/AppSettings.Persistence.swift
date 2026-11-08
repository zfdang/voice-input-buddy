import Combine
import Foundation

extension AppSettings {
    func saveBindings() {
        let raw = Dictionary(uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonBindings)
        }
    }

    func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonShortcuts)
        }
    }

    func saveButtonApplicationProfileIDs() {
        let raw = Dictionary(
            uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonApplicationProfileIDs)
        }
    }

    func saveButtonRapidPressEnabled() {
        let raw = Dictionary(
            uniqueKeysWithValues: buttonRapidPressEnabled.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonRapidPressEnabled)
        }
    }

    func saveSecondaryBindings() {
        let raw = Dictionary(uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
            (
                button.rawValue,
                Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
            )
        })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.secondaryButtonBindings)
        }
    }

    func saveSelectedRemoteProfileMappings() {
        guard !isLoadingRemoteProfile, !isResettingBindings,
              let selectedRemoteProfileID,
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == selectedRemoteProfileID })
        else { return }
        remoteDeviceProfiles[index].mappings = RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings,
            buttonRapidPressEnabled: buttonRapidPressEnabled
        )
    }

    func saveCustomApplicationProfiles() {
        guard let data = try? JSONEncoder().encode(customApplicationProfiles) else { return }
        defaults.set(data, forKey: Keys.customApplicationProfiles)
    }

    func saveRemoteDeviceProfiles() {
        guard let data = try? JSONEncoder().encode(remoteDeviceProfiles) else { return }
        defaults.set(data, forKey: Keys.remoteDeviceProfiles)
    }

    func saveContinuousRecordingPowerBindingBackup() {
        guard let continuousRecordingPowerBindingBackup else {
            defaults.removeObject(forKey: Keys.continuousRecordingPowerBindingBackup)
            return
        }
        if let data = try? JSONEncoder().encode(continuousRecordingPowerBindingBackup) {
            defaults.set(data, forKey: Keys.continuousRecordingPowerBindingBackup)
        }
    }

    func applyContinuousRecordingExperimentState(
        enabled: Bool,
        backup: ConfiguredButtonAction?
    ) {
        let enabled = enabled && Self.continuousRecordingExperimentAvailable
        if enabled {
            let current = configuredAction(for: .power, trigger: .singleClick)
            continuousRecordingPowerBindingBackup = Self.safeContinuousRecordingBackup(
                backup ?? current
            )
            experimentalContinuousRecordingEnabled = true
            customMappingEnabled = true
            setAction(.toggleLongRecording, for: .power, trigger: .singleClick)
            return
        }

        experimentalContinuousRecordingEnabled = false
        if backup != nil || action(for: .power) == .toggleLongRecording {
            let restored = Self.safeContinuousRecordingBackup(
                backup ?? ConfiguredButtonAction(action: Self.defaultBindings[.power] ?? .disabled, shortcut: nil)
            )
            setAction(restored.action, for: .power, trigger: .singleClick)
            setShortcut(restored.shortcut, for: .power, trigger: .singleClick)
            setApplicationProfileID(
                restored.applicationProfileID,
                for: .power,
                trigger: .singleClick
            )
        }
        continuousRecordingPowerBindingBackup = nil
    }

    private static func safeContinuousRecordingBackup(
        _ binding: ConfiguredButtonAction
    ) -> ConfiguredButtonAction {
        guard binding.action == .toggleLongRecording else { return binding }
        return ConfiguredButtonAction(action: Self.defaultBindings[.power] ?? .disabled, shortcut: nil)
    }
}
