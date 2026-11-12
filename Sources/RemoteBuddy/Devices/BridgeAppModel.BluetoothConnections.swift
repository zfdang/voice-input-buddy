import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    var selectedBluetoothBridge: BluetoothRemoteBridge? {
        guard let identifier = settings.selectedRemoteProfile?.bluetoothIdentifier else { return nil }
        return connections.bridges[identifier]
    }

    func startBluetoothConnections() {
        let identifiers = Set(settings.remoteDeviceProfiles.compactMap(\.bluetoothIdentifier))
        for identifier in identifiers where connections.bridges[identifier] == nil {
            let bridge = BluetoothRemoteBridge(
                settings: settings,
                delegate: self,
                targetIdentifier: identifier,
                allowsG9N9N: true,
                allowsT1Remote: true
            )
            observeRemoteHIDIdentity(bridge)
            connections.bridges[identifier] = bridge
            bridge.setSystemSuspended(
                audio.suspensionState.isSuspended,
                reason: "bridge_start"
            )
            bridge.start()
        }
        startBluetoothDiscoveryIfNeeded()
    }

    func startBluetoothDiscoveryIfNeeded() {
        guard started, connections.discoveryBridge == nil else { return }
        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: self,
            allowsG9N9N: true,
            allowsT1Remote: true,
            adoptUnidentifiedATVVAsT1: { [weak self] in
                guard let self else { return false }
                return self.settings.onboardingStep == .remote &&
                    self.settings.onboardingControlSource == .t1Remote
            },
            excludedIdentifiers: { [weak self] in
                guard let self else { return [] }
                return Set(self.connections.bridges.keys).union(self.settings.excludedForgottenBluetoothIdentifiers())
            }
        )
        observeRemoteHIDIdentity(bridge)
        connections.discoveryBridge = bridge
        bridge.setSystemSuspended(
            audio.suspensionState.isSuspended,
            reason: "bridge_start"
        )
        bridge.start()
    }

    func registerBluetoothBridgeIfNeeded(
        _ bridge: BluetoothRemoteBridge,
        diagnosticLog: (String) -> Void = { AppLogger.shared.write($0) }
    ) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else {
            diagnosticLog(
                "REMOTE PROFILE phase=completed result=rejected reason=missing_identifier"
            )
            return nil
        }
        guard settings.allowsSetupCandidate(
            bluetoothIdentifier: identifier,
            model: bridge.identifiedModel
        ) else { return nil }
        guard bridge.bindVerifiedIdentity(identifier) else {
            diagnosticLog(
                "REMOTE PROFILE phase=completed result=rejected reason=identity_mismatch"
            )
            return nil
        }
        let existingProfileID = settings.profileID(forBluetoothIdentifier: identifier)
        let profileID = existingProfileID ?? settings.registerBluetoothRemote(identifier: identifier, model: bridge.identifiedModel ?? .unknown)
        var attachedBridge = false
        if connections.discoveryBridge === bridge {
            connections.discoveryBridge = nil
            connections.bridges[identifier] = bridge
            startBluetoothDiscoveryIfNeeded()
            attachedBridge = true
        } else if connections.bridges[identifier] == nil {
            connections.bridges[identifier] = bridge
            attachedBridge = true
        }
        let appliedTelemetry = applyPendingRemoteTelemetry(identifier: identifier, profileID: profileID)
        if existingProfileID == nil || attachedBridge || appliedTelemetry {
            diagnosticLog(
                "REMOTE PROFILE phase=completed result=persisted reason=verified_remote_path " +
                    "created=\(existingProfileID == nil)"
            )
        }
        return profileID
    }

    @discardableResult
    private func applyPendingRemoteTelemetry(identifier: UUID, profileID: UUID) -> Bool {
        let hadBattery = pendingRemoteBatteryLevels[identifier] != nil
        let hadPower = pendingRemotePowerStates[identifier] != nil
        let hadModel = pendingRemoteModels[identifier] != nil
        if let level = pendingRemoteBatteryLevels.removeValue(forKey: identifier) {
            remoteBatteryLevels[profileID] = min(100, max(0, level))
        }
        if let powerState = pendingRemotePowerStates.removeValue(forKey: identifier) {
            remotePowerStates[profileID] = powerState
        }
        if let model = pendingRemoteModels.removeValue(forKey: identifier) {
            settings.updateRemoteProfileModel(profileID, model: model)
            refreshRemoteDeviceNames(reason: .connection)
        }
        if hadBattery || hadPower || hadModel {
            AppLogger.shared.write(
                "REMOTE PROFILE_DIAGNOSTIC phase=completed result=applied reason=profile_ready " +
                    "battery=\(hadBattery) power=\(hadPower) model=\(hadModel)"
            )
            return true
        }
        return false
    }

    func bluetoothIdentifier(for bridge: BluetoothRemoteBridge) -> UUID? {
        bridge.deviceIdentifier ?? connections.bridges.first(where: { $0.value === bridge })?.key
    }

    func remoteProfileID(for bridge: BluetoothRemoteBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        return settings.profileID(forBluetoothIdentifier: identifier)
    }

    func selectRemoteProfile(_ profileID: UUID) {
        settings.selectRemoteProfile(profileID)
        refreshBluetoothPresentation()
    }

    @discardableResult
    func removeRemoteDevice(_ profileID: UUID) -> Bool {
        guard !isVoiceConfigurationBusy,
              let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID }),
              settings.removeRemoteProfile(profileID) else { return false }
        if let identifier = profile.bluetoothIdentifier {
            if let bridge = connections.bridges.removeValue(forKey: identifier) {
                bridge.stop()
                connections.states.removeValue(forKey: ObjectIdentifier(bridge))
            }
            if let discovery = connections.discoveryBridge, discovery.deviceIdentifier == identifier {
                connections.discoveryBridge = nil
                discovery.stop()
                connections.states.removeValue(forKey: ObjectIdentifier(discovery))
                startBluetoothDiscoveryIfNeeded()
            }
            remoteDeviceInformation.removeValue(forKey: identifier)
            pendingRemoteBatteryLevels.removeValue(forKey: identifier)
            pendingRemotePowerStates.removeValue(forKey: identifier)
            pendingRemoteModels.removeValue(forKey: identifier)
        }
        if let fingerprint = profile.hidFingerprint {
            appliedHIDMonitoringConfiguration = nil
            hidMonitors.removeValue(forKey: fingerprint)?.stop()
            if discoveryHIDMonitor?.deviceFingerprint == fingerprint {
                discoveryHIDMonitor?.stop()
                discoveryHIDMonitor = nil
                startHIDDiscoveryIfNeeded(allowBackOnly: !settings.customMappingEnabled)
            }
        }
        remoteBatteryLevels.removeValue(forKey: profileID)
        remotePowerStates.removeValue(forKey: profileID)
        remoteSystemDeviceNames.removeValue(forKey: profileID)
        refreshBluetoothPresentation()
        AppLogger.shared.write("REMOTE PROFILE phase=completed result=removed")
        return true
    }

    func removeUncommittedOnboardingRemotes() {
        for profileID in settings.uncommittedOnboardingRemoteProfileIDs() {
            _ = removeRemoteDevice(profileID)
        }
    }

    func dismissOnboardingSetup() {
        removeUncommittedOnboardingRemotes()
        settings.dismissOnboarding()
        if let profileID = settings.selectedRemoteProfileID {
            selectRemoteProfile(profileID)
        }
        applyHIDSettings()
        refreshRemoteDiscovery()
    }

    var onboardingRemoteProfiles: [RemoteDeviceProfile] {
        settings.remoteDeviceProfiles.filter {
            connectedRemoteProfileIDs.contains($0.id) &&
                Self.canLearnHIDIdentity(model: $0.model, source: settings.onboardingControlSource)
        }
    }

    func selectOnboardingRemoteIfNeeded() {
        guard settings.onboardingStep == .remote else { return }
        let profiles = onboardingRemoteProfiles
        guard !profiles.contains(where: { $0.id == settings.selectedRemoteProfileID }),
              profiles.count == 1, let profile = profiles.first else { return }
        selectRemoteProfile(profile.id)
    }

    func selectDefaultMappingRemoteIfAvailable() {
        let localization = LocalizationSnapshot(language: settings.applicationLanguage)
        let connectedProfiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles.filter { isRemoteConnected($0.id) },
            modelName: { profile in
                RemoteDeviceNamePolicy.displayName(
                    for: profile,
                    among: self.settings.remoteDeviceProfiles,
                    defaultName: localization.text(profile.model.localizationKey)
                )
            },
            systemName: { self.systemDeviceName(for: $0) }
        )
        guard let profile = RemoteDeviceNamePolicy.defaultMappingProfile(
            from: connectedProfiles
        ) else {
            AppLogger.shared.write(
                "REMOTE MAPPING_DEFAULT phase=completed result=preserved " +
                    "reason=xiaomi_unavailable"
            )
            return
        }
        guard profile.id != settings.selectedRemoteProfileID else {
            AppLogger.shared.write(
                "REMOTE MAPPING_DEFAULT phase=completed result=preserved " +
                    "reason=xiaomi_already_selected"
            )
            return
        }
        AppLogger.shared.write(
            "REMOTE MAPPING_DEFAULT phase=completed result=selected " +
                "reason=xiaomi_default family=xiaomi"
        )
#if DEBUG
        if ProcessInfo.processInfo.environment["REMOTE_BUDDY_SETTINGS_SCREENSHOT_DIR"] != nil {
            settings.selectRemoteProfile(profile.id)
            return
        }
#endif
        selectRemoteProfile(profile.id)
    }

    func activateRemoteProfile(for bridge: BluetoothRemoteBridge) -> UUID? {
        guard let profileID = registerBluetoothBridgeIfNeeded(bridge) else { return nil }
        selectRemoteProfile(profileID)
        return profileID
    }

    /// Refresh display metadata without starting discovery, reconnecting, or changing device identity.
    func refreshRemoteDeviceNames(reason: RemoteDeviceNameRefreshReason) {
        guard started, CBManager.authorization == .allowedAlways else { return }
        remoteDeviceNameRefreshOperation &+= 1
        var requested = 0
        var resolved = 0
        var changed = 0
        for (identifier, bridge) in connections.bridges {
            guard let profileID = settings.profileID(forBluetoothIdentifier: identifier),
                  connectedRemoteProfileIDs.contains(profileID)
            else { continue }
            requested += 1
            bridge.refreshBatteryState(reason: reason.rawValue)
            let name = bridge.currentSystemDeviceName()
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolved += 1
            }
            if let name = RemoteDeviceNamePolicy.observedSystemName(from: name) {
                remoteSystemDeviceNames[profileID] = name
            }
            if settings.updateRemoteProfileSystemName(profileID, name: name) { changed += 1 }
        }
        AppLogger.shared.write(
            "REMOTE NAME REFRESH operation_id=\(remoteDeviceNameRefreshOperation) " +
                "phase=completed reason=\(reason.rawValue) requested=\(requested) " +
                "resolved=\(resolved) changed=\(changed) unavailable=\(requested - resolved)"
        )
    }

    func refreshBluetoothPresentation() {
        let allStates = connections.states.values
        let connectedBluetoothProfileIDs = Set<UUID>(connections.bridges.compactMap { identifier, bridge in
            guard let profileID = settings.profileID(forBluetoothIdentifier: identifier),
                  let state = connections.states[ObjectIdentifier(bridge)],
                  case .ready = state
            else { return nil }
            return profileID
        })
        connectedChromecastProfileIDs = Set(connectedBluetoothProfileIDs.filter { id in
            settings.remoteDeviceProfiles.first { $0.id == id }?.model.isChromecastRemote == true
        })
        connectedRemoteProfileIDs = connectedBluetoothProfileIDs
            .union(connectedChromecastProfileIDs)
        let bluetoothIsReady = allStates.contains { state in
            if case .ready = state { return true }
            return false
        }
        isConnected = bluetoothIsReady
            || !connectedChromecastProfileIDs.isEmpty
        if let selectedRemoteProfileID = settings.selectedRemoteProfileID,
                  connectedChromecastProfileIDs.contains(selectedRemoteProfileID) {
            connectionStatus = LocalizedMessage("connection.status.chromecast_connected")
        } else if let selectedBluetoothBridge,
           let state = connections.states[ObjectIdentifier(selectedBluetoothBridge)] {
            connectionStatus = state.message
        } else if let ready = allStates.first(where: { state in
            if case .ready = state { return true }
            return false
        }) {
            connectionStatus = ready.message
        } else if !connectedChromecastProfileIDs.isEmpty {
            connectionStatus = LocalizedMessage("connection.status.chromecast_connected")
        } else if let state = allStates.first {
            connectionStatus = state.message
        } else {
            connectionStatus = LocalizedMessage("connection.status.searching")
        }
    }
}
