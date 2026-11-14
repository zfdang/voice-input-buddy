import Combine
import Foundation

extension AppSettings {
    private static let forgottenBluetoothModelsKey = "forgottenRemoteModelsByBluetoothIdentifier"
    private static let forgottenHIDModelsKey = "forgottenRemoteModelsByHIDFingerprint"

    // A forgotten remote must not immediately be recreated by background discovery.
    var forgottenBluetoothIdentifiers: Set<UUID> {
        Set((defaults.stringArray(forKey: "forgottenRemoteBluetoothIdentifiers") ?? []).compactMap(UUID.init(uuidString:)))
    }

    var forgottenHIDFingerprints: Set<String> {
        Set(defaults.stringArray(forKey: "forgottenRemoteHIDFingerprints") ?? [])
    }

    private var forgottenBluetoothModels: [String: String] {
        defaults.dictionary(forKey: Self.forgottenBluetoothModelsKey) as? [String: String] ?? [:]
    }

    private var forgottenHIDModels: [String: String] {
        defaults.dictionary(forKey: Self.forgottenHIDModelsKey) as? [String: String] ?? [:]
    }

    var allowsForgottenRemoteDuringActiveControlSetup: Bool {
        !isOnboardingComplete && (onboardingStep == .remote || onboardingStep == .controls)
    }

    private var activeSetupSelectedProfile: RemoteDeviceProfile? {
        guard !isOnboardingComplete,
              let profile = selectedRemoteProfile else { return nil }
        if onboardingControlSource != .unselected,
           profile.model != .unknown,
           !onboardingControlSource.matchesConfirmedCandidate(profile.model) {
            return nil
        }
        return profile
    }

    func excludedForgottenBluetoothIdentifiers() -> Set<UUID> {
        var forgotten = forgottenBluetoothIdentifiers
        if let activeBluetoothID = activeSetupSelectedProfile?.bluetoothIdentifier {
            forgotten.remove(activeBluetoothID)
        }
        guard allowsForgottenRemoteDuringActiveControlSetup else { return forgotten }
        let models = forgottenBluetoothModels
        return forgotten.filter { identifier in
            guard let raw = models[identifier.uuidString],
                  let storedModel = RemoteModel(rawValue: raw),
                  storedModel != .unknown else { return false }
            return !onboardingControlSource.matchesConfirmedCandidate(storedModel)
        }
    }

    func excludedForgottenHIDFingerprints() -> Set<String> {
        var forgotten = forgottenHIDFingerprints
        if let activeHIDFingerprint = activeSetupSelectedProfile?.hidFingerprint {
            forgotten.remove(activeHIDFingerprint)
        }
        guard allowsForgottenRemoteDuringActiveControlSetup else { return forgotten }
        let models = forgottenHIDModels
        return forgotten.filter { fingerprint in
            if let raw = models[fingerprint],
               let storedModel = RemoteModel(rawValue: raw),
               storedModel != .unknown {
                return !onboardingControlSource.matchesConfirmedCandidate(storedModel)
            }
            return onboardingControlSource != .xiaomiRemote
        }
    }

    func allowsSetupCandidate(bluetoothIdentifier: UUID, model: RemoteModel?) -> Bool {
        guard forgottenBluetoothIdentifiers.contains(bluetoothIdentifier) else { return true }
        if activeSetupSelectedProfile?.bluetoothIdentifier == bluetoothIdentifier {
            return true
        }
        guard allowsForgottenRemoteDuringActiveControlSetup else { return false }
        if let raw = forgottenBluetoothModels[bluetoothIdentifier.uuidString],
           let storedModel = RemoteModel(rawValue: raw),
           storedModel != .unknown {
            return onboardingControlSource.matchesConfirmedCandidate(storedModel)
        }
        guard let model else { return false }
        return onboardingControlSource.matchesConfirmedCandidate(model)
    }

    func allowsSetupCandidate(hidFingerprint: String, model: RemoteModel?) -> Bool {
        guard forgottenHIDFingerprints.contains(hidFingerprint) else { return true }
        if activeSetupSelectedProfile?.hidFingerprint == hidFingerprint {
            return true
        }
        guard allowsForgottenRemoteDuringActiveControlSetup else { return false }
        if let raw = forgottenHIDModels[hidFingerprint],
           let storedModel = RemoteModel(rawValue: raw),
           storedModel != .unknown {
            return onboardingControlSource.matchesConfirmedCandidate(storedModel)
        }
        if let model, model != .unknown {
            return onboardingControlSource.matchesConfirmedCandidate(model)
        }
        return onboardingControlSource == .xiaomiRemote
    }

    func unforgetRemotes(_ profiles: [RemoteDeviceProfile]) {
        let identifiers = Set(profiles.compactMap(\.bluetoothIdentifier))
        let fingerprints = Set(profiles.compactMap(\.hidFingerprint))
        if !identifiers.isEmpty {
            let remaining = forgottenBluetoothIdentifiers.subtracting(identifiers)
            if remaining.isEmpty {
                defaults.removeObject(forKey: "forgottenRemoteBluetoothIdentifiers")
            } else {
                defaults.set(remaining.map(\.uuidString), forKey: "forgottenRemoteBluetoothIdentifiers")
            }
            var models = forgottenBluetoothModels
            for identifier in identifiers {
                models.removeValue(forKey: identifier.uuidString)
            }
            if models.isEmpty {
                defaults.removeObject(forKey: Self.forgottenBluetoothModelsKey)
            } else {
                defaults.set(models, forKey: Self.forgottenBluetoothModelsKey)
            }
        }
        if !fingerprints.isEmpty {
            let remaining = forgottenHIDFingerprints.subtracting(fingerprints)
            if remaining.isEmpty {
                defaults.removeObject(forKey: "forgottenRemoteHIDFingerprints")
            } else {
                defaults.set(Array(remaining), forKey: "forgottenRemoteHIDFingerprints")
            }
            var models = forgottenHIDModels
            for fingerprint in fingerprints {
                models.removeValue(forKey: fingerprint)
            }
            if models.isEmpty {
                defaults.removeObject(forKey: Self.forgottenHIDModelsKey)
            } else {
                defaults.set(models, forKey: Self.forgottenHIDModelsKey)
            }
        }
    }

    @discardableResult
    func removeRemoteProfile(_ profileID: UUID) -> Bool {
        guard let profile = remoteDeviceProfiles.first(where: { $0.id == profileID }) else { return false }
        if let identifier = profile.bluetoothIdentifier {
            defaults.set(forgottenBluetoothIdentifiers.union([identifier]).map(\.uuidString),
                         forKey: "forgottenRemoteBluetoothIdentifiers")
            var models = forgottenBluetoothModels
            models[identifier.uuidString] = profile.model.rawValue
            defaults.set(models, forKey: Self.forgottenBluetoothModelsKey)
        }
        if let fingerprint = profile.hidFingerprint {
            defaults.set(Array(forgottenHIDFingerprints.union([fingerprint])),
                         forKey: "forgottenRemoteHIDFingerprints")
            var models = forgottenHIDModels
            models[fingerprint] = profile.model.rawValue
            defaults.set(models, forKey: Self.forgottenHIDModelsKey)
        }
        if selectedRemoteProfileID == profileID {
            if let replacement = remoteDeviceProfiles.first(where: { $0.id != profileID }) {
                selectRemoteProfile(replacement.id)
            } else {
                selectedRemoteProfileID = nil
                withLoadingRemoteProfile {
                    gainDB = 10
                    buttonBindings = Self.defaultBindings
                    buttonShortcuts = [:]
                    buttonApplicationProfileIDs = [:]
                    secondaryButtonBindings = [:]
                }
            }
        }
        unifiedBaseBindings.removeAll { $0.remoteProfileID == profileID }
        remoteDeviceProfiles.removeAll { $0.id == profileID }
        if isOnboardingComplete {
            synchronizeOnboardingRemoteWithSelectedProfile()
        }
        return true
    }

    func action(for button: RemoteButton) -> ButtonAction {
        configuredAction(for: button, trigger: .singleClick).action
    }

    func action(for button: RemoteButton, profileID: UUID?) -> ButtonAction {
        configuredAction(for: button, trigger: .singleClick, profileID: profileID).action
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton) {
        buttonBindings[button] = action
    }

    func shortcut(for button: RemoteButton) -> CustomKeyboardShortcut? {
        buttonShortcuts[button]
    }

    func shortcut(for button: RemoteButton, profileID: UUID?) -> CustomKeyboardShortcut? {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return shortcut(for: button) }
        return profile.mappings.parsedButtonShortcuts[button]
    }

    func setShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton) {
        buttonShortcuts[button] = shortcut
    }

    func applicationProfileID(for button: RemoteButton) -> UUID? {
        buttonApplicationProfileIDs[button]
    }

    func applicationProfileID(for button: RemoteButton, profileID: UUID?) -> UUID? {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return applicationProfileID(for: button) }
        return profile.mappings.parsedButtonApplicationProfileIDs[button]
    }

    func allowsHoldRepeat(for button: RemoteButton, profileID: UUID? = nil) -> Bool {
        configuredBaseAction(for: button, trigger: .longPress,
            profileID: profileID ?? selectedRemoteProfileID).action == .repeatSingleClick
    }

    func defaultAction(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction {
        switch trigger {
        case .singleClick:
            return ConfiguredButtonAction(
                action: Self.defaultBindings[button] ?? .disabled,
                shortcut: nil
            )
        case .doubleClick:
            return Self.defaultSecondaryBindings[button]?[.doubleClick] ?? .disabled
        case .longPress:
            return Self.defaultSecondaryBindings[button]?[.longPress] ??
                defaultSecondaryAction(for: button, trigger: .longPress)
        }
    }

    private func defaultSecondaryAction(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction {
        guard trigger == .longPress,
              [.up, .down, .left, .right, .power, .volumeUp, .volumeDown].contains(button)
        else { return .disabled }
        return ConfiguredButtonAction(action: .repeatSingleClick, shortcut: nil)
    }

    func customApplicationProfile(id: UUID?) -> CustomApplicationProfile? {
        guard let id else { return nil }
        return customApplicationProfiles.first(where: { $0.id == id })
    }

    @discardableResult
    func addCustomApplicationProfile(_ profile: CustomApplicationProfile) -> UUID {
        customApplicationProfiles.append(profile)
        return profile.id
    }

    func updateCustomApplicationProfile(_ profile: CustomApplicationProfile) {
        guard let index = customApplicationProfiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        customApplicationProfiles[index] = profile
    }

    func configuredBaseAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> ConfiguredButtonAction {
        configuredBaseAction(for: button, trigger: trigger, profileID: selectedRemoteProfileID)
    }

    func configuredBaseAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        profileID: UUID?
    ) -> ConfiguredButtonAction {
        if let binding = unifiedBaseBindings.first(where: {
            $0.remoteProfileID == profileID && $0.button == button && $0.trigger == trigger
        }) { return binding.configured }
        if let binding = unifiedBaseBindings.first(where: {
            $0.remoteProfileID == nil && $0.button == button && $0.trigger == trigger
        }) { return binding.configured }

        if let profileID,
           profileID != selectedRemoteProfileID,
           let profile = remoteDeviceProfiles.first(where: { $0.id == profileID }) {
            let bindings = profile.mappings.parsedButtonBindings
            let shortcuts = profile.mappings.parsedButtonShortcuts
            if trigger == .singleClick {
                return ConfiguredButtonAction(
                    action: bindings[button] ?? .disabled,
                    shortcut: shortcuts[button],
                    applicationProfileID: profile.mappings.parsedButtonApplicationProfileIDs[button]
                )
            }
            return profile.mappings.parsedSecondaryButtonBindings[button]?[trigger] ??
                defaultSecondaryAction(for: button, trigger: trigger)
        }

        if trigger == .singleClick {
            return ConfiguredButtonAction(
                action: buttonBindings[button] ?? .disabled,
                shortcut: buttonShortcuts[button],
                applicationProfileID: applicationProfileID(for: button)
            )
        }
        return secondaryButtonBindings[button]?[trigger] ??
            defaultSecondaryAction(for: button, trigger: trigger)
    }

    func configuredAction(for button: RemoteButton, trigger: ButtonTrigger) -> ConfiguredButtonAction {
        configuredAction(for: button, trigger: trigger, profileID: selectedRemoteProfileID)
    }

    func configuredAction(for button: RemoteButton, trigger: ButtonTrigger,
                          profileID: UUID?) -> ConfiguredButtonAction {
        let configured = configuredBaseAction(for: button, trigger: trigger, profileID: profileID)
        guard configured.action != .repeatSingleClick || trigger == .longPress else { return .disabled }
        return configured
    }

    var selectedRemoteProfile: RemoteDeviceProfile? {
        guard let selectedRemoteProfileID else { return nil }
        return remoteDeviceProfiles.first(where: { $0.id == selectedRemoteProfileID })
    }

    func selectRemoteProfile(_ profileID: UUID) {
        guard profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return }
        let nextGain = profile.gainDB ?? (selectedRemoteProfileID == nil ? gainDB : 10)
        saveSelectedRemoteGain()
        withLoadingRemoteProfile {
            selectedRemoteProfileID = profileID
            gainDB = Self.normalizedGain(nextGain)
            buttonBindings = Self.defaultBindings.merging(profile.mappings.parsedButtonBindings) {
                _, saved in saved
            }
            buttonShortcuts = profile.mappings.parsedButtonShortcuts
            buttonApplicationProfileIDs = profile.mappings.parsedButtonApplicationProfileIDs
            secondaryButtonBindings = profile.mappings.parsedSecondaryButtonBindings
        }
    }

    func gainDB(for profileID: UUID) -> Double {
        guard let profile = remoteDeviceProfiles.first(where: { $0.id == profileID }) else { return 10 }
        let value = profile.gainDB ?? (profileID == selectedRemoteProfileID ? gainDB : 10)
        return value.isFinite ? min(24, max(0, value)) : 10
    }

    func gainDB(forBluetoothIdentifier identifier: UUID?) -> Double {
        guard let identifier, let profileID = profileID(forBluetoothIdentifier: identifier) else { return gainDB }
        return gainDB(for: profileID)
    }

    func setGainDB(_ value: Double, for profileID: UUID) {
        guard value.isFinite, (0...24).contains(value),
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        if remoteDeviceProfiles[index].gainDB != value {
            remoteDeviceProfiles[index].gainDB = value
        }
        if selectedRemoteProfileID == profileID, gainDB != value { gainDB = value }
    }

    func saveSelectedRemoteGain() {
        guard !isLoadingRemoteProfile, gainDB.isFinite, (0...24).contains(gainDB),
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == selectedRemoteProfileID }) else { return }
        guard remoteDeviceProfiles[index].gainDB != gainDB else { return }
        remoteDeviceProfiles[index].gainDB = gainDB
    }

    var compatibleHIDBindings: [RemoteHIDBinding] {
        remoteDeviceProfiles.compactMap { profile in
            guard !profile.model.usesPrivateAdapter,
                  profile.model != .unknown,
                  let binding = profile.compatibleHIDBinding,
                  !binding.identity.isStandard,
                  binding.identity.vendorID != 0,
                  binding.fingerprint == profile.hidFingerprint else { return nil }
            return binding
        }
    }

    func compatibleHIDIdentities(
        includeXiaomi: Bool,
        includeGoogle: Bool,
        includeT1: Bool = false
    ) -> [RemoteHIDIdentity] {
        let valid = compatibleHIDBindings
        return remoteDeviceProfiles.compactMap { profile in
            guard let binding = profile.compatibleHIDBinding, valid.contains(binding),
                  (includeGoogle && profile.model.isChromecastRemote) ||
                    (includeT1 && profile.model.isT1Remote) ||
                    (includeXiaomi && (profile.model == .rc001 || profile.model == .rc003)) else { return nil }
            return binding.identity
        }
    }

    @discardableResult
    func bindCompatibleHID(_ binding: RemoteHIDBinding, to profileID: UUID) -> Bool {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }),
              [RemoteModel.rc001, .rc003, .chromecastVoiceRemote, .t1Remote].contains(remoteDeviceProfiles[index].model),
              binding.identity != .xiaomi || (!remoteDeviceProfiles[index].model.isChromecastRemote && !remoteDeviceProfiles[index].model.isT1Remote),
              binding.identity != .chromecast || remoteDeviceProfiles[index].model.isChromecastRemote,
              binding.identity != .t1Remote || remoteDeviceProfiles[index].model.isT1Remote,
              binding.identity.vendorID != 0, !binding.fingerprint.isEmpty,
              !remoteDeviceProfiles.contains(where: {
                  $0.id != profileID && $0.hidFingerprint == binding.fingerprint
              }) else { return false }
        var profile = remoteDeviceProfiles[index]
        profile.hidFingerprint = binding.fingerprint
        // Standard identities already belong to the built-in list.
        profile.compatibleHIDBinding = binding.identity.isStandard ? nil : binding
        guard profile != remoteDeviceProfiles[index] else { return false }
        remoteDeviceProfiles[index] = profile
        return true
    }

    @discardableResult
    func registerBluetoothRemote(identifier: UUID, model: RemoteModel = .unknown) -> UUID {
        if let existing = remoteDeviceProfiles.first(where: { $0.bluetoothIdentifier == identifier }) {
            return existing.id
        }
        let matching = remoteDeviceProfiles.indices.filter {
            remoteDeviceProfiles[$0].bluetoothIdentifier == nil && remoteDeviceProfiles[$0].model == model
        }
        let matchingIndex = model.isATVVRemote
            ? (matching.count == 1 ? matching.first : nil) : matching.first
        let emptyIndex = remoteDeviceProfiles.firstIndex {
            $0.bluetoothIdentifier == nil && $0.model == .unknown &&
                (!model.isATVVRemote || $0.hidFingerprint == nil)
        }
        if let index = matchingIndex ?? emptyIndex {
            remoteDeviceProfiles[index].bluetoothIdentifier = identifier
            if model != .unknown { remoteDeviceProfiles[index].model = model }
            return remoteDeviceProfiles[index].id
        }
        let profile = RemoteDeviceProfile(
            model: model,
            bluetoothIdentifier: identifier,
            mappings: mappingsForNewRemote()
        )
        remoteDeviceProfiles.append(profile)
        inheritUnifiedBindings(from: selectedRemoteProfileID, to: profile.id)
        return profile.id
    }

    @discardableResult
    func registerHIDRemote(fingerprint: String, model: RemoteModel = .unknown) -> UUID? {
        if let existing = remoteDeviceProfiles.first(where: { $0.hidFingerprint == fingerprint }) {
            return existing.id
        }
        if model.isATVVRemote {
            let candidates = remoteDeviceProfiles.indices.filter {
                remoteDeviceProfiles[$0].model == model && remoteDeviceProfiles[$0].hidFingerprint == nil
            }
            if candidates.count == 1, let index = candidates.first {
                remoteDeviceProfiles[index].hidFingerprint = fingerprint
                return remoteDeviceProfiles[index].id
            }
            // Multiple independent BLE identities cannot be joined by a product label alone.
            let profile = RemoteDeviceProfile(model: model, hidFingerprint: fingerprint,
                                              mappings: mappingsForNewRemote())
            remoteDeviceProfiles.append(profile)
            inheritUnifiedBindings(from: selectedRemoteProfileID, to: profile.id)
            return profile.id
        }
        let candidates = remoteDeviceProfiles.indices.filter {
            let profile = remoteDeviceProfiles[$0]
            return profile.hidFingerprint == nil &&
                (profile.model == model || model == .unknown &&
                    [RemoteModel.rc001, .rc003, .unknown].contains(profile.model))
        }
        guard candidates.count <= 1 else {
            AppLogger.shared.write("REMOTE HID binding_deferred reason=ambiguous_bluetooth_profiles")
            return nil
        }
        if let index = candidates.first {
            let defaultMappings = RemoteDeviceMappings(
                buttonBindings: Self.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
            if remoteDeviceProfiles[index].mappings == defaultMappings,
               let configured = remoteDeviceProfiles.first(where: {
                   $0.id != remoteDeviceProfiles[index].id && $0.mappings != defaultMappings
               }) {
                remoteDeviceProfiles[index].mappings = configured.mappings
            }
            remoteDeviceProfiles[index].hidFingerprint = fingerprint
            return remoteDeviceProfiles[index].id
        }
        let profile = RemoteDeviceProfile(
            model: model,
            hidFingerprint: fingerprint,
            mappings: mappingsForNewRemote()
        )
        remoteDeviceProfiles.append(profile)
        inheritUnifiedBindings(from: selectedRemoteProfileID, to: profile.id)
        return profile.id
    }

    private func inheritUnifiedBindings(from sourceID: UUID?, to targetID: UUID) {
        guard let sourceID else { return }
        let toCopy = unifiedBaseBindings.filter { $0.remoteProfileID == sourceID }
        for binding in toCopy {
            setBaseBinding(binding.configured, for: binding.button, trigger: binding.trigger, profileID: targetID)
        }
    }

    func profileID(forBluetoothIdentifier identifier: UUID) -> UUID? {
        remoteDeviceProfiles.first(where: { $0.bluetoothIdentifier == identifier })?.id
    }

    func profileID(forHIDFingerprint fingerprint: String) -> UUID? {
        remoteDeviceProfiles.first(where: { $0.hidFingerprint == fingerprint })?.id
    }

    func bindHIDFingerprint(_ fingerprint: String, to profileID: UUID) {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        for candidate in remoteDeviceProfiles.indices where remoteDeviceProfiles[candidate].hidFingerprint == fingerprint {
            remoteDeviceProfiles[candidate].hidFingerprint = nil
        }
        remoteDeviceProfiles[index].hidFingerprint = fingerprint
    }

    private func mappingsForNewRemote() -> RemoteDeviceMappings {
        selectedRemoteProfile?.mappings ?? RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
    }

    func updateRemoteProfile(
        _ profileID: UUID,
        model: RemoteModel,
        customName: String
    ) {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        remoteDeviceProfiles[index].model = model
        remoteDeviceProfiles[index].customName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The system name is a display cache, never a device identity or a stored numbered label.
    @discardableResult
    func updateRemoteProfileSystemName(
        _ profileID: UUID,
        name: String?
    ) -> Bool {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }),
              let customName = RemoteDeviceNamePolicy.customName(
                from: name, model: remoteDeviceProfiles[index].model
              ),
              remoteDeviceProfiles[index].customName != customName
        else { return false }
        remoteDeviceProfiles[index].customName = customName
        return true
    }

    func updateRemoteProfileModel(_ profileID: UUID, model: RemoteModel) {
        guard model != .unknown,
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }),
              remoteDeviceProfiles[index].model != model
        else { return }
        remoteDeviceProfiles[index].model = model
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        guard trigger != .singleClick else {
            setAction(action, for: button)
            return
        }

        var bindings = secondaryButtonBindings[button] ?? [:]
        let shortcut = bindings[trigger]?.shortcut
        let applicationProfileID = bindings[trigger]?.applicationProfileID
        bindings[trigger] = ConfiguredButtonAction(
            action: action,
            shortcut: shortcut,
            applicationProfileID: applicationProfileID
        )
        secondaryButtonBindings[button] = bindings.isEmpty ? nil : bindings
    }

    func setApplicationProfileID(
        _ applicationProfileID: UUID?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard trigger != .singleClick else {
            buttonApplicationProfileIDs[button] = applicationProfileID
            return
        }
        guard var bindings = secondaryButtonBindings[button], var binding = bindings[trigger] else {
            return
        }
        binding.applicationProfileID = applicationProfileID
        bindings[trigger] = binding
        secondaryButtonBindings[button] = bindings
    }

    func setShortcut(
        _ shortcut: CustomKeyboardShortcut?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard trigger != .singleClick else {
            setShortcut(shortcut, for: button)
            return
        }
        guard var bindings = secondaryButtonBindings[button], var binding = bindings[trigger] else {
            return
        }
        binding.shortcut = shortcut
        bindings[trigger] = binding
        secondaryButtonBindings[button] = bindings
    }

    func resetBindings() {
        withResettingBindings {
            buttonBindings = Self.defaultBindings
            buttonShortcuts = [:]
            unifiedBaseBindings.removeAll { $0.remoteProfileID == selectedRemoteProfileID }
            // Override inherited bindings only for the selected device.
            if let device = selectedRemoteProfileID {
                for inherited in unifiedBaseBindings.filter({ $0.remoteProfileID == nil }) {
                    setBaseBinding(
                        defaultAction(for: inherited.button, trigger: inherited.trigger),
                        for: inherited.button,
                        trigger: inherited.trigger,
                        profileID: device
                    )
                }
            }
            buttonApplicationProfileIDs = [:]
            secondaryButtonBindings = Self.defaultSecondaryBindings
        }
        saveSelectedRemoteProfileMappings()
        encodeAndSave(unifiedBaseBindings, forKey: "unifiedBaseBindings")
    }
}

extension AppSettings {
    static let defaultSecondaryBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] = [
        .ok: [.longPress: ConfiguredButtonAction(action: .commandReturn, shortcut: nil)],
    ]

    static let defaultBindings: [RemoteButton: ButtonAction] = [
        .power: .deleteBackward,
        .up: .arrowUp,
        .left: .arrowLeft,
        .ok: .returnKey,
        .right: .arrowRight,
        .down: .arrowDown,
        .back: .escape,
        .volumeUp: .volumeUp,
        .home: .appSwitcher,
        .volumeDown: .volumeDown,
        .menu: .contextMenu,
        .tv: .playPause,
        .playPause: .playPause,
        .mute: .volumeMute,
    ]
}
