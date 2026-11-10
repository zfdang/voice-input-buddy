import Combine
import Foundation

extension AppSettings {
    static func describeEncodingError(_ error: Error) -> String {
        if let encodingError = error as? EncodingError {
            switch encodingError {
            case .invalidValue: return "EncodingError.invalidValue"
            @unknown default: return "EncodingError"
            }
        }
        return String(describing: type(of: error))
    }

    func encodeAndSave<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            AppLogger.shared.write("SETTINGS ERROR save failed for \(key): \(Self.describeEncodingError(error))")
        }
    }

    func saveBindings() {
        let raw = Dictionary(uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) })
        encodeAndSave(raw, forKey: Keys.buttonBindings)
    }

    func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) })
        encodeAndSave(raw, forKey: Keys.buttonShortcuts)
    }

    func saveButtonApplicationProfileIDs() {
        let raw = Dictionary(
            uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
        )
        encodeAndSave(raw, forKey: Keys.buttonApplicationProfileIDs)
    }

    func saveSecondaryBindings() {
        let raw = Dictionary(uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
            (
                button.rawValue,
                Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
            )
        })
        encodeAndSave(raw, forKey: Keys.secondaryButtonBindings)
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
            secondaryButtonBindings: secondaryButtonBindings
        )
    }

    func saveCustomApplicationProfiles() {
        encodeAndSave(customApplicationProfiles, forKey: Keys.customApplicationProfiles)
    }

    func saveRemoteDeviceProfiles() {
        encodeAndSave(remoteDeviceProfiles, forKey: Keys.remoteDeviceProfiles)
    }
}
