import Foundation

extension BridgeAppModel {
    func observeRemoteHIDIdentity(_ bridge: BluetoothRemoteBridge) {
        bridge.onDeviceInformationUpdate = { [weak self, weak bridge] in
            guard let self, let bridge, let identifier = bridge.deviceIdentifier else { return }
            self.remoteDeviceInformation[identifier] = bridge.deviceInformation
        }
        bridge.onHIDIdentityUpdate = { [weak self, weak bridge] in
            guard let self, let bridge else { return }
            self.learnSelectedRemoteHIDIdentity(bridge)
        }
    }

    func learnSelectedRemoteHIDIdentity(_ bridge: BluetoothRemoteBridge) {
        // BLE readiness includes the adapter's model and capability validation.
        guard case .ready = bridge.state,
              let profileID = remoteProfileID(for: bridge),
              let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID }),
              [RemoteModel.rc001, .rc003, .chromecastVoiceRemote].contains(profile.model)
        else { return }
        let identity = bridge.reportedHIDIdentity ?? (profile.model.isChromecastRemote ? .chromecast : .xiaomi)
        if !identity.isStandard {
            guard !settings.isOnboardingComplete, settings.selectedRemoteProfileID == profileID,
                  settings.onboardingStep == .remote || settings.onboardingStep == .controls,
                  Self.canLearnHIDIdentity(model: profile.model, source: settings.onboardingControlSource)
            else { return }
        }
        guard let name = bridge.currentSystemDeviceName(),
              let candidate = RemoteHIDCandidate.identified(identity: identity, expectedName: name,
                  among: RemoteHIDCandidate.available()) else { return }
        bindCompatibleRemote(candidate, profileID: profileID, select: false)
    }

    static func canLearnHIDIdentity(model: RemoteModel, source: OnboardingControlSource) -> Bool {
        switch source {
        case .chromecastRemote: return model.isChromecastRemote
        case .xiaomiRemote: return model == .rc001 || model == .rc003
        default: return false
        }
    }

    @discardableResult
    func bindCompatibleRemote(_ candidate: RemoteHIDCandidate, profileID: UUID, select: Bool = true) -> Bool {
        guard !settings.forgottenHIDFingerprints.contains(candidate.id),
              let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID }),
              let identifier = profile.bluetoothIdentifier,
              let bridge = connections.bridges[identifier], case .ready = bridge.state,
              !profile.model.isChromecastRemote || bridge.identifiedModel == .chromecastVoiceRemote,
              candidate.binding.identity != .xiaomi || !profile.model.isChromecastRemote,
              candidate.binding.identity != .chromecast || profile.model.isChromecastRemote,
              RemoteHIDCandidate.available().contains(candidate),
              !isStreaming, !voiceKeyLatch.isHeld,
              !voiceFnTapSession.requiresCleanupBeforeMapping else { return false }
        guard settings.bindCompatibleHID(candidate.binding, to: profileID) else {
            return settings.remoteDeviceProfiles.contains {
                $0.id == profileID && $0.hidFingerprint == candidate.id &&
                    ($0.compatibleHIDBinding == candidate.binding || candidate.binding.identity.isStandard)
            }
        }
        if select { selectRemoteProfile(profileID) }
        if started { applyHIDSettings(restartSiriRemote: false) }
        AppLogger.shared.write("REMOTE HID binding_saved custom_identity=\(!candidate.binding.identity.isStandard)")
        return true
    }
}
