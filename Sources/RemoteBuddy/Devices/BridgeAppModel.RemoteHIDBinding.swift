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
              [RemoteModel.rc001, .rc003, .chromecastVoiceRemote, .t1Remote].contains(profile.model)
        else { return }
        let fallbackIdentity: RemoteHIDIdentity = profile.model.isChromecastRemote
            ? .chromecast
            : (profile.model.isT1Remote ? .t1Remote : .xiaomi)
        let identity = bridge.reportedHIDIdentity ?? fallbackIdentity
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
        case .t1Remote: return model.isT1Remote
        case .xiaomiRemote: return model == .rc001 || model == .rc003
        default: return false
        }
    }

    @discardableResult
    func bindCompatibleRemote(_ candidate: RemoteHIDCandidate, profileID: UUID, select: Bool = true) -> Bool {
        guard let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID }),
              settings.allowsSetupCandidate(hidFingerprint: candidate.id, model: profile.model),
              let identifier = profile.bluetoothIdentifier,
              let bridge = connections.bridges[identifier], case .ready = bridge.state,
              !profile.model.isChromecastRemote || bridge.identifiedModel == .chromecastVoiceRemote,
              !profile.model.isT1Remote || bridge.identifiedModel == .t1Remote,
              candidate.binding.identity != .xiaomi || !profile.model.isATVVRemote,
              candidate.binding.identity != .chromecast || profile.model.isChromecastRemote,
              candidate.binding.identity != .t1Remote || profile.model.isT1Remote,
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
