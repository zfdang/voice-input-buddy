import Combine
import Foundation

extension AppSettings {
    func exportedConfigurationData() throws -> Data {
        let configuration = PersonalizedConfiguration(
            formatVersion: PersonalizedConfiguration.currentFormatVersion,
            gainDB: gainDB,
            remoteGainDB: Dictionary(uniqueKeysWithValues: remoteDeviceProfiles.map { ($0.id, gainDB(for: $0.id)) }),
            customMappingEnabled: customMappingEnabled,
            buttonBindings: Dictionary(
                uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) }
            ),
            buttonShortcuts: Dictionary(
                uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) }
            ),
            unifiedBaseBindings: unifiedBaseBindings,
            selectedMappingProfileID: selectedRemoteProfileID,
            buttonApplicationProfileIDs: Dictionary(
                uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
            ),
            secondaryButtonBindings: Dictionary(
                uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                    (
                        button.rawValue,
                        Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                    )
                }
            ),
            buttonRapidPressEnabled: buttonRapidPressEnabled.isEmpty
                ? nil
                : Dictionary(
                    uniqueKeysWithValues: buttonRapidPressEnabled.map { ($0.key.rawValue, $0.value) }
                ),
            customApplicationProfiles: customApplicationProfiles,
            applicationLanguage: applicationLanguage,
            appIconIdentifier: appIconIdentifier,
            showDockIcon: showDockIcon,
            showStatusBarIcon: showStatusBarIcon,
            openMainWindowAtLaunch: openMainWindowAtLaunch,
            checksForPreReleaseUpdates: checksForPreReleaseUpdates,
            experimentalContinuousRecordingEnabled: experimentalContinuousRecordingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeEnabled,
            voiceKeyMode: voiceKeyMode,
            continuousRecordingPowerBindingBackup: continuousRecordingPowerBindingBackup
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    var portablePendingApplications: Set<String> {
        Set(defaults.stringArray(forKey: "portableTransferPendingApplications") ?? [])
    }

    func portableApplicationRequiresVerification(_ profile: CustomApplicationProfile) -> Bool {
        profile.focusStrategy == .recordedAccessibility
            && portablePendingApplications.contains(profile.id.uuidString)
    }

    func markPortableApplicationVerified(_ id: UUID) {
        var pending = portablePendingApplications
        pending.remove(id.uuidString)
        defaults.set(pending.sorted(), forKey: "portableTransferPendingApplications")
        objectWillChange.send()
    }

    var voiceKeyConfigurationState: VoiceKeyConfigurationState {
        VoiceKeyConfigurationState(
            mode: voiceKeyMode,
            fnTapModeEnabled: voiceFnTapModeEnabled && voiceKeyMode == .function
        )
    }

    func voiceKeyConfigurationState(in data: Data) throws -> VoiceKeyConfigurationState {
        let configuration = try Self.validatedConfiguration(from: data)
        let mode = configuration.voiceKeyMode ?? .function
        let fnTapModeEnabled = (configuration.voiceFnTapModeEnabled ?? false) && mode == .function
        return VoiceKeyConfigurationState(
            mode: mode,
            fnTapModeEnabled: fnTapModeEnabled
        )
    }

    /// Adopts a payload that arrived from outside this Mac. Document-level values still reject
    /// the whole file (an unknown format or an impossible gain means nothing in it can be
    /// trusted), but a single bad entry only loses that entry: throwing the file away would
    /// punish a user whose configuration is 99% fine. Everything dropped is published in
    /// `configurationImportNotice` so the user is told rather than silently downgraded.
    func importConfiguration(from data: Data) throws {
        let configuration = try Self.validatedConfiguration(from: data)
        var rejected: Set<String> = []
        var missingApplications: [String] = []
        let importedMode = configuration.voiceKeyMode ?? .function
        let importedFnTapModeEnabled = (configuration.voiceFnTapModeEnabled ?? false) &&
            importedMode == .function
        let importedVoiceKeyConfiguration = VoiceKeyConfigurationState(
            mode: importedMode,
            fnTapModeEnabled: importedFnTapModeEnabled
        )

        let importedBindings = Dictionary(
            uniqueKeysWithValues: configuration.buttonBindings
                .compactMap { key, value -> (RemoteButton, ButtonAction)? in
                    guard let button = RemoteButton(rawValue: key) else {
                        rejected.insert(Keys.buttonBindings)
                        return nil
                    }
                    return (button, value)
                }
        )
        let importedShortcuts = Dictionary(
            uniqueKeysWithValues: configuration.buttonShortcuts
                .compactMap { key, value -> (RemoteButton, CustomKeyboardShortcut)? in
                    guard let button = RemoteButton(rawValue: key),
                          let shortcut = Self.validatedShortcut(value)
                    else {
                        rejected.insert(Keys.buttonShortcuts)
                        return nil
                    }
                    return (button, shortcut)
                }
        )
        let importedApplicationProfileIDs = Dictionary(
            uniqueKeysWithValues: (configuration.buttonApplicationProfileIDs ?? [:])
                .compactMap { key, value -> (RemoteButton, UUID)? in
                    guard let button = RemoteButton(rawValue: key) else {
                        rejected.insert(Keys.buttonApplicationProfileIDs)
                        return nil
                    }
                    return (button, value)
                }
        )
        let importedRapidPressEnabled = Dictionary(
            uniqueKeysWithValues: (configuration.buttonRapidPressEnabled ?? [:])
                .compactMap { key, value -> (RemoteButton, Bool)? in
                    guard let button = RemoteButton(rawValue: key) else {
                        rejected.insert(Keys.buttonRapidPressEnabled)
                        return nil
                    }
                    return (button, value)
                }
        )
        let importedSecondaryBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] =
            Dictionary(
                uniqueKeysWithValues: configuration.secondaryButtonBindings.compactMap {
                    buttonKey, bindings -> (RemoteButton, [ButtonTrigger: ConfiguredButtonAction])? in
                    guard let button = RemoteButton(rawValue: buttonKey) else {
                        rejected.insert(Keys.secondaryButtonBindings)
                        return nil
                    }
                    let parsed = Dictionary(
                        uniqueKeysWithValues: bindings.compactMap {
                            triggerKey, binding -> (ButtonTrigger, ConfiguredButtonAction)? in
                            guard let trigger = ButtonTrigger(rawValue: triggerKey),
                                  let validated = Self.validatedConfiguredAction(binding)
                            else {
                                rejected.insert(Keys.secondaryButtonBindings)
                                return nil
                            }
                            return (trigger, validated)
                        }
                    )
                    return parsed.isEmpty ? nil : (button, parsed)
                }
            )

        let importedApplicationProfiles = (configuration.customApplicationProfiles ?? [])
            .compactMap { profile -> CustomApplicationProfile? in
                switch Self.validatedApplicationProfile(profile) {
                case let .usable(profile):
                    return profile
                case let .notInstalledOnThisMac(profile):
                    missingApplications.append(profile.displayName)
                    return profile
                case .rejected:
                    rejected.insert(Keys.customApplicationProfiles)
                    return nil
                }
            }
        let importedRecordingBackup: ConfiguredButtonAction?
        if let backup = configuration.continuousRecordingPowerBindingBackup {
            importedRecordingBackup = Self.validatedConfiguredAction(backup)
            if importedRecordingBackup == nil {
                rejected.insert(Keys.continuousRecordingPowerBindingBackup)
            }
        } else {
            importedRecordingBackup = nil
        }

        gainDB = configuration.gainDB
        for (id, value) in configuration.remoteGainDB ?? [:] {
            guard value.isFinite, (0...24).contains(value) else { rejected.insert("remoteGainDB"); continue }
            if remoteDeviceProfiles.contains(where: { $0.id == id }) {
                setGainDB(value, for: id)
            } else if id == configuration.selectedMappingProfileID {
                if let selectedRemoteProfileID { setGainDB(value, for: selectedRemoteProfileID) }
            } else if value != 10 {
                rejected.insert("remoteGainDB")
            }
        }
        customMappingEnabled = configuration.customMappingEnabled
        buttonBindings = Self.defaultBindings.merging(importedBindings) { _, imported in imported }
        buttonShortcuts = importedShortcuts
        unifiedBaseBindings = importedUnifiedBindings(from: configuration, rejected: &rejected)
        buttonApplicationProfileIDs = importedApplicationProfileIDs
        secondaryButtonBindings = importedSecondaryBindings
        buttonRapidPressEnabled = importedRapidPressEnabled
        if configuration.customApplicationProfiles != nil {
            customApplicationProfiles = importedApplicationProfiles
            // Recorded targets must be tested on this Mac before automatic input.
            let pending = importedApplicationProfiles
                .filter { $0.focusStrategy == .recordedAccessibility }
                .map { $0.id.uuidString }
            defaults.set(pending.sorted(), forKey: "portableTransferPendingApplications")
        }
        applicationLanguage = configuration.applicationLanguage
        if let appIconIdentifier = configuration.appIconIdentifier {
            self.appIconIdentifier = appIconIdentifier
        }
        showDockIcon = configuration.showDockIcon
        if let showStatusBarIcon = configuration.showStatusBarIcon {
            self.showStatusBarIcon = showStatusBarIcon
        }
        if let openMainWindowAtLaunch = configuration.openMainWindowAtLaunch {
            self.openMainWindowAtLaunch = openMainWindowAtLaunch
        }
        if let checksForPreReleaseUpdates = configuration.checksForPreReleaseUpdates {
            self.checksForPreReleaseUpdates = checksForPreReleaseUpdates
        }
        voiceKeyMode = importedVoiceKeyConfiguration.mode
        voiceFnTapModeEnabled = importedVoiceKeyConfiguration.fnTapModeEnabled && voiceKeyMode == .function
        applyContinuousRecordingExperimentState(
            enabled: configuration.experimentalContinuousRecordingEnabled ?? false,
            backup: importedRecordingBackup
        )

        let report = ConfigurationImportReport(
            rejectedEntryStorageKeys: rejected.sorted(),
            applicationsMissingOnThisMac: missingApplications.sorted()
        )
        if !report.isClean {
            AppLogger.shared.write(
                "SETTINGS import_filtered rejected=\(report.rejectedEntryStorageKeys.joined(separator: ",")) " +
                    "missing_apps=\(report.applicationsMissingOnThisMac.count)"
            )
        }
        configurationImportNotice = report.isClean ? nil : report
    }
}
