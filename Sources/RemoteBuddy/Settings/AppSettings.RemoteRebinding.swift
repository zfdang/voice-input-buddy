import Foundation

extension AppSettings {
    /// Explicit user-selected replacement. The original profile remains the owner of mappings and gain.
    @discardableResult
    func rebindBluetoothRemote(profileID: UUID, to replacementProfileID: UUID) -> Bool {
        guard profileID != replacementProfileID,
              let original = remoteDeviceProfiles.first(where: { $0.id == profileID }),
              let replacement = remoteDeviceProfiles.first(where: { $0.id == replacementProfileID }),
              original.model == replacement.model,
              [RemoteModel.rc001, .rc003, .chromecastVoiceRemote].contains(original.model),
              let identifier = replacement.bluetoothIdentifier,
              identifier != original.bluetoothIdentifier,
              replacement.hidFingerprint == nil || original.hidFingerprint == nil ||
                replacement.hidFingerprint == original.hidFingerprint else { return false }
        var rebound = original
        rebound.bluetoothIdentifier = identifier
        if rebound.hidFingerprint == nil {
            rebound.hidFingerprint = replacement.hidFingerprint
            rebound.compatibleHIDBinding = replacement.compatibleHIDBinding
        }
        remoteDeviceProfiles = remoteDeviceProfiles.compactMap { profile in
            if profile.id == replacementProfileID { return nil }
            return profile.id == profileID ? rebound : profile
        }
        unifiedBaseBindings.removeAll { $0.remoteProfileID == replacementProfileID }
        if selectedRemoteProfileID == replacementProfileID { selectRemoteProfile(profileID) }
        return true
    }
}
