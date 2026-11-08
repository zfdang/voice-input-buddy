import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let continuousRecordingExperimentAvailable = false
    static let currentOnboardingVersion = 1

    enum Keys {
        static let gainDB = "gainDB"
        static let customMappingEnabled = "customMappingEnabled"
        static let buttonBindings = "buttonBindings"
        static let buttonShortcuts = "buttonShortcuts"
        static let buttonApplicationProfileIDs = "buttonApplicationProfileIDs"
        static let secondaryButtonBindings = "secondaryButtonBindings"
        static let buttonRapidPressEnabled = "buttonRapidPressEnabled"
        static let customApplicationProfiles = "customApplicationProfiles"
        static let remoteDeviceProfiles = "remoteDeviceProfiles"
        static let selectedRemoteProfileID = "selectedRemoteProfileID"
        static let applicationLanguage = "applicationLanguage"
        static let appIconIdentifier = "appIconIdentifier"
        static let showDockIcon = "showDockIcon"
        static let showStatusBarIcon = "showStatusBarIcon"
        static let openMainWindowAtLaunch = "openMainWindowAtLaunch"
        static let checksForPreReleaseUpdates = "checksForPreReleaseUpdates"
        static let experimentalContinuousRecordingEnabled = "experimentalContinuousRecordingEnabled"
        static let voiceFnTapModeEnabled = "voiceFnTapModeEnabled"
        static let voiceKeyMode = "voiceKeyMode"
        static let chromecastVoiceMode = "chromecast.voiceMode"
        static let continuousRecordingPowerBindingBackup = "continuousRecordingPowerBindingBackup"
        static let lastLaunchedBuild = "launch.lastLaunchedBuild"
        static let onboardingPurpose = "onboarding.purpose"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
        static let onboardingStep = "onboarding.step"
        static let onboardingRemoteAvailability = "onboarding.remoteAvailability"
        static let onboardingControlSource = "onboarding.controlSource"
        static let onboardingDevice = "onboarding.device"
        static let onboardingAppleRemoteGeneration = "onboarding.appleRemoteGeneration"
        static let onboardingVoiceTool = "onboarding.voiceTool"
        static let onboardingVoiceBindingPreference = "onboarding.voiceBindingPreference"
        static let onboardingPreferredGesture = "onboarding.preferredGesture"
        static let onboardingVerifiedVoiceBinding = "onboarding.verifiedVoiceBinding"
        static let onboardingStagedVoiceBinding = "onboarding.stagedVoiceBinding"
        static let onboardingTrialSnapshot = "onboarding.trialSnapshot"
        static let firstUseEvents = "onboarding.diagnostics.events"
        static let firstUseStepStartedAt = "onboarding.diagnostics.stepStartedAt"
        static let firstUseLastSignature = "onboarding.diagnostics.lastSignature"
    }

    let defaults: UserDefaults

    @Published private var storedGainDB: Double
    var gainDB: Double {
        get { storedGainDB }
        set {
            let normalized = Self.normalizedGain(newValue)
            let changed = storedGainDB != normalized
            if changed { storedGainDB = normalized }
            defaults.set(normalized, forKey: Keys.gainDB)
            if changed { saveSelectedRemoteGain() }
        }
    }

    var selectedAudioDeviceUID: String { BuddyMicrophoneDevicePolicy.deviceUID }

    @Published var customMappingEnabled: Bool {
        didSet { defaults.set(customMappingEnabled, forKey: Keys.customMappingEnabled) }
    }

    @Published var unifiedBaseBindings: [UnifiedButtonBinding] = [] {
        didSet {
            if !isResettingBindings, let data = try? JSONEncoder().encode(unifiedBaseBindings) {
                defaults.set(data, forKey: "unifiedBaseBindings")
            }
        }
    }

    func setBaseBinding(_ configured: ConfiguredButtonAction, for button: RemoteButton,
                        trigger: ButtonTrigger, profileID: UUID?) {
        var bindings = unifiedBaseBindings
        bindings.removeAll { $0.remoteProfileID == profileID && $0.button == button && $0.trigger == trigger }
        bindings.append(UnifiedButtonBinding(remoteProfileID: profileID, button: button,
                                            trigger: trigger, configured: configured))
        unifiedBaseBindings = bindings
    }

    @Published var buttonBindings: [RemoteButton: ButtonAction] {
        didSet {
            saveBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        didSet {
            saveShortcuts()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonApplicationProfileIDs: [RemoteButton: UUID] {
        didSet {
            saveButtonApplicationProfileIDs()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        didSet {
            saveSecondaryBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonRapidPressEnabled: [RemoteButton: Bool] {
        didSet {
            saveButtonRapidPressEnabled()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var customApplicationProfiles: [CustomApplicationProfile] {
        didSet { saveCustomApplicationProfiles() }
    }

    @Published var remoteDeviceProfiles: [RemoteDeviceProfile] {
        didSet { saveRemoteDeviceProfiles() }
    }

    @Published var selectedRemoteProfileID: UUID? {
        didSet { defaults.set(selectedRemoteProfileID?.uuidString, forKey: Keys.selectedRemoteProfileID) }
    }

    @Published var applicationLanguage: AppLanguage {
        didSet { defaults.set(applicationLanguage.rawValue, forKey: Keys.applicationLanguage) }
    }

    @Published var appIconIdentifier: AppIconIdentifier {
        didSet {
            defaults.set(appIconIdentifier.rawValue, forKey: Keys.appIconIdentifier)
        }
    }

    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    @Published var showStatusBarIcon: Bool {
        didSet { defaults.set(showStatusBarIcon, forKey: Keys.showStatusBarIcon) }
    }

    @Published var openMainWindowAtLaunch: Bool {
        didSet { defaults.set(openMainWindowAtLaunch, forKey: Keys.openMainWindowAtLaunch) }
    }

    @Published var checksForPreReleaseUpdates: Bool {
        didSet {
            defaults.set(checksForPreReleaseUpdates, forKey: Keys.checksForPreReleaseUpdates)
        }
    }

    @Published var experimentalContinuousRecordingEnabled: Bool {
        didSet {
            defaults.set(
                experimentalContinuousRecordingEnabled,
                forKey: Keys.experimentalContinuousRecordingEnabled
            )
        }
    }

    @Published var voiceFnTapModeEnabled: Bool {
        didSet {
            defaults.set(
                voiceFnTapModeEnabled,
                forKey: Keys.voiceFnTapModeEnabled
            )
        }
    }

    /// 语音键触发语音输入工具时发送的按键，例如 Fn/Globe、Command 或 Option。
    @Published var voiceKeyMode: VoiceKeyMode {
        didSet {
            defaults.set(voiceKeyMode.rawValue, forKey: Keys.voiceKeyMode)
        }
    }

    /// Chromecast 语音手势模式。默认 `toggle`（按一下开始、再按一下结束）。
    @Published var chromecastVoiceMode: ChromecastVoiceMode {
        didSet {
            defaults.set(chromecastVoiceMode.rawValue, forKey: Keys.chromecastVoiceMode)
        }
    }

    var continuousRecordingPowerBindingBackup: ConfiguredButtonAction? {
        didSet { saveContinuousRecordingPowerBindingBackup() }
    }

    var isLoadingRemoteProfile = false
    var isResettingBindings = false

    @Published var onboardingPurpose: OnboardingPurpose {
        didSet { defaults.set(onboardingPurpose.rawValue, forKey: Keys.onboardingPurpose) }
    }

    @Published var onboardingCompletedVersion: Int {
        didSet {
            defaults.set(onboardingCompletedVersion, forKey: Keys.onboardingCompletedVersion)
        }
    }

    @Published var onboardingStep: OnboardingStep {
        didSet { defaults.set(onboardingStep.rawValue, forKey: Keys.onboardingStep) }
    }

    @Published var onboardingRemoteAvailability: OnboardingRemoteAvailability {
        didSet {
            defaults.set(
                onboardingRemoteAvailability.rawValue,
                forKey: Keys.onboardingRemoteAvailability
            )
        }
    }

    var onboardingControlMethod: OnboardingControlMethod {
        onboardingControlSource.controlMethod
    }

    @Published var onboardingDevice: RemoteSetupDevice? {
        didSet { defaults.set(onboardingDevice?.rawValue, forKey: Keys.onboardingDevice) }
    }

    @Published var onboardingControlSource: OnboardingControlSource {
        didSet {
            defaults.set(onboardingControlSource.rawValue, forKey: Keys.onboardingControlSource)
        }
    }

    @Published var onboardingAppleRemoteGeneration: OnboardingAppleRemoteGeneration? {
        didSet {
            defaults.set(
                onboardingAppleRemoteGeneration?.rawValue,
                forKey: Keys.onboardingAppleRemoteGeneration
            )
        }
    }

    @Published var onboardingVoiceTool: OnboardingVoiceTool {
        didSet { defaults.set(onboardingVoiceTool.rawValue, forKey: Keys.onboardingVoiceTool) }
    }

    @Published var onboardingVoiceBindingPreference: OnboardingVoiceBindingPreference {
        didSet {
            defaults.set(
                onboardingVoiceBindingPreference.rawValue,
                forKey: Keys.onboardingVoiceBindingPreference
            )
        }
    }

    @Published var onboardingPreferredGesture: VoiceGestureMode? {
        didSet {
            defaults.set(onboardingPreferredGesture?.rawValue, forKey: Keys.onboardingPreferredGesture)
        }
    }

    @Published var verifiedVoiceToolBinding: VoiceToolUserBinding? {
        didSet {
            if let verifiedVoiceToolBinding,
               let data = try? JSONEncoder().encode(verifiedVoiceToolBinding) {
                defaults.set(data, forKey: Keys.onboardingVerifiedVoiceBinding)
            } else {
                defaults.removeObject(forKey: Keys.onboardingVerifiedVoiceBinding)
            }
        }
    }

    @Published var stagedVoiceToolBinding: VoiceToolUserBinding?

    var isOnboardingComplete: Bool {
        onboardingCompletedVersion >= Self.currentOnboardingVersion
    }

    /// Keys whose stored data existed but could not be decoded on the last load. The raw
    /// bytes are preserved under "<key>.corrupt" so a reset is recoverable and visible
    /// instead of looking like a first run.
    @Published private(set) var corruptedSettingKeys: [String] = []

    /// Splits "never saved" from "saved but unreadable". Only the latter is a fault, and
    /// silently treating it as a first run is what let user configuration disappear.
    /// Static because callers run inside `init` before the instance is fully formed.
    private static func decodeSetting<T: Decodable>(
        _ type: T.Type,
        forKey key: String,
        from defaults: UserDefaults,
        corrupted: inout [String]
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            defaults.set(data, forKey: "\(key).corrupt")
            defaults.removeObject(forKey: key)
            corrupted.append(key)
            AppLogger.shared.write(
                "SETTINGS decode_failed category=\(diagnosticSettingCategory(key)) " +
                "bytes=\(data.count) reason=\(diagnosticDecodeReason(error))"
            )
            if let event = PublicDiagnosticEvent(
                component: "settings", action: "load", phase: "failed", result: "defaults_applied",
                reason: "\(diagnosticSettingCategory(key))_\(diagnosticDecodeReason(error))", source: "app"
            ) { AppLogger.shared.record(event) }
            return nil
        }
    }

    static func diagnosticSettingCategory(_ key: String) -> String {
        switch key {
        case "remoteDeviceProfiles": "remote_profiles"
        case "buttonBindings", "buttonShortcuts", "buttonApplicationProfileIDs",
             "secondaryButtonBindings", "buttonRapidPressEnabled", "continuousRecordingPowerBindingBackup":
            "button_mapping"
        case "customApplicationProfiles": "custom_apps"
        case "onboarding.stagedVoiceBinding": "onboarding"
        default: "other"
        }
    }

    static func diagnosticDecodeReason(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted: "data_corrupted"
        case DecodingError.keyNotFound: "key_missing"
        case DecodingError.typeMismatch: "type_mismatch"
        case DecodingError.valueNotFound: "value_missing"
        default: "unknown"
        }
    }

    static func normalizedGain(_ value: Double) -> Double {
        value.isFinite ? min(24, max(0, value)) : 10
    }

    init(defaults: UserDefaults = .standard) {
        var corruptedKeys: [String] = []
        self.defaults = defaults
        Self.restoreInterruptedOnboardingTrial(in: defaults)
        remoteDeviceProfiles = []
        selectedRemoteProfileID = nil
        storedGainDB = defaults.object(forKey: Keys.gainDB) == nil
            ? 10.0
            : Self.normalizedGain(defaults.double(forKey: Keys.gainDB))
        customMappingEnabled = defaults.bool(forKey: Keys.customMappingEnabled)

        if let decoded = Self.decodeSetting(
            [String: ButtonAction].self,
            forKey: Keys.buttonBindings,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonBindings = Self.defaultBindings.merging(
                Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                })
            ) { _, saved in saved }
        } else {
            buttonBindings = Self.defaultBindings
        }

        if let decoded = Self.decodeSetting(
            [String: CustomKeyboardShortcut].self,
            forKey: Keys.buttonShortcuts,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonShortcuts = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            })
        } else {
            buttonShortcuts = [:]
        }

        if let decoded = Self.decodeSetting(
            [String: UUID].self,
            forKey: Keys.buttonApplicationProfileIDs,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonApplicationProfileIDs = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                }
            )
        } else {
            buttonApplicationProfileIDs = [:]
        }

        if let decoded = Self.decodeSetting(
            [String: Bool].self,
            forKey: Keys.buttonRapidPressEnabled,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            buttonRapidPressEnabled = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                }
            )
        } else {
            buttonRapidPressEnabled = [:]
        }

        let shouldSeedSecondaryBindings = defaults.object(forKey: Keys.secondaryButtonBindings) == nil &&
            defaults.object(forKey: Keys.buttonBindings) == nil &&
            defaults.object(forKey: Keys.remoteDeviceProfiles) == nil
        if let decoded = Self.decodeSetting(
            [String: [String: ConfiguredButtonAction]].self,
            forKey: Keys.secondaryButtonBindings,
            from: defaults,
            corrupted: &corruptedKeys
        ) {
            secondaryButtonBindings = Dictionary(uniqueKeysWithValues: decoded.compactMap { buttonKey, bindings in
                guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
                let parsed = Dictionary(uniqueKeysWithValues: bindings.compactMap { triggerKey, binding in
                    ButtonTrigger(rawValue: triggerKey).map { ($0, binding) }
                })
                return parsed.isEmpty ? nil : (button, parsed)
            })
        } else {
            // Seed the new long-press default only when no mappings have been saved.
            // An absent OK binding in an existing configuration must stay disabled.
            secondaryButtonBindings = shouldSeedSecondaryBindings ? Self.defaultSecondaryBindings : [:]
        }

        customApplicationProfiles = Self.decodeSetting(
            [CustomApplicationProfile].self,
            forKey: Keys.customApplicationProfiles,
            from: defaults,
            corrupted: &corruptedKeys
        ) ?? []

        applicationLanguage = AppLanguage(
            rawValue: defaults.string(forKey: Keys.applicationLanguage) ?? ""
        ) ?? .system
        let storedAppIcon = AppIconIdentifier(
            rawValue: defaults.string(forKey: Keys.appIconIdentifier)
                ?? AppIconIdentifier.standard.rawValue
        )
        appIconIdentifier = storedAppIcon
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        showStatusBarIcon = defaults.object(forKey: Keys.showStatusBarIcon) == nil
            ? true
            : defaults.bool(forKey: Keys.showStatusBarIcon)
        openMainWindowAtLaunch = defaults.object(forKey: Keys.openMainWindowAtLaunch) == nil
            ? true
            : defaults.bool(forKey: Keys.openMainWindowAtLaunch)
        checksForPreReleaseUpdates = defaults.bool(forKey: Keys.checksForPreReleaseUpdates)
        experimentalContinuousRecordingEnabled = defaults.bool(
            forKey: Keys.experimentalContinuousRecordingEnabled
        )
        voiceFnTapModeEnabled = defaults.bool(forKey: Keys.voiceFnTapModeEnabled)
        voiceKeyMode = VoiceKeyMode(
            rawValue: defaults.string(forKey: Keys.voiceKeyMode) ?? ""
        ) ?? .function
        chromecastVoiceMode = ChromecastVoiceMode(
            rawValue: defaults.string(forKey: Keys.chromecastVoiceMode) ?? ""
        ) ?? .productDefault
        continuousRecordingPowerBindingBackup = Self.decodeSetting(
            ConfiguredButtonAction.self,
            forKey: Keys.continuousRecordingPowerBindingBackup,
            from: defaults,
            corrupted: &corruptedKeys
        )
        onboardingPurpose = defaults.string(forKey: Keys.onboardingPurpose)
            .flatMap(OnboardingPurpose.init(rawValue:)) ?? .initialSetup
        onboardingCompletedVersion = defaults.integer(forKey: Keys.onboardingCompletedVersion)
        onboardingStep = defaults.string(forKey: Keys.onboardingStep)
            .flatMap(OnboardingStep.init(rawValue:)) ?? .permissions
        let persistedControlSource = defaults.string(forKey: Keys.onboardingControlSource)
            .flatMap(OnboardingControlSource.init(rawValue:))
            .flatMap { OnboardingBuildCapabilities.availableControlSources.contains($0) ? $0 : nil }
            ?? .unselected
        onboardingControlSource = persistedControlSource
        onboardingDevice = defaults.string(forKey: Keys.onboardingDevice)
            .flatMap(RemoteSetupDevice.init(rawValue:))
            ?? RemoteSetupDevice.device(for: persistedControlSource)
        onboardingAppleRemoteGeneration = defaults.string(
            forKey: Keys.onboardingAppleRemoteGeneration
        ).flatMap(OnboardingAppleRemoteGeneration.init(rawValue:))
        onboardingRemoteAvailability = persistedControlSource == .unselected ? .unselected : .hasRemote
        onboardingVoiceTool = defaults.string(forKey: Keys.onboardingVoiceTool)
            .flatMap(OnboardingVoiceTool.init(rawValue:)) ?? .unselected
        onboardingVoiceBindingPreference = defaults.string(
            forKey: Keys.onboardingVoiceBindingPreference
        )
            .flatMap(OnboardingVoiceBindingPreference.init(rawValue:))
            ?? .documentedDefault
        onboardingPreferredGesture = defaults.string(forKey: Keys.onboardingPreferredGesture)
            .flatMap(VoiceGestureMode.init(rawValue:))
        verifiedVoiceToolBinding = Self.decodeSetting(
            VoiceToolUserBinding.self,
            forKey: Keys.onboardingVerifiedVoiceBinding,
            from: defaults,
            corrupted: &corruptedKeys
        )
        stagedVoiceToolBinding = Self.decodeSetting(
            VoiceToolUserBinding.self,
            forKey: Keys.onboardingStagedVoiceBinding,
            from: defaults,
            corrupted: &corruptedKeys
        )
        if
            let decoded = Self.decodeSetting(
                [RemoteDeviceProfile].self,
                forKey: Keys.remoteDeviceProfiles,
                from: defaults,
                corrupted: &corruptedKeys
            ),
            !decoded.isEmpty
        {
            remoteDeviceProfiles = decoded
            if let event = PublicDiagnosticEvent(
                component: "settings", action: "load", phase: "completed", result: "loaded",
                reason: "remote_profiles", source: "app"
            ) { AppLogger.shared.record(event) }
            let savedID = defaults.string(forKey: Keys.selectedRemoteProfileID).flatMap(UUID.init(uuidString:))
            selectedRemoteProfileID = decoded.contains(where: { $0.id == savedID })
                ? savedID
                : decoded.first?.id
            if let selectedRemoteProfileID,
               let selected = decoded.first(where: { $0.id == selectedRemoteProfileID }) {
                if let storedGain = selected.gainDB, storedGain.isFinite, (0...24).contains(storedGain) { gainDB = storedGain }
                buttonBindings = Self.defaultBindings.merging(selected.mappings.parsedButtonBindings) {
                    _, saved in saved
                }
                buttonShortcuts = selected.mappings.parsedButtonShortcuts
                buttonApplicationProfileIDs = selected.mappings.parsedButtonApplicationProfileIDs
                secondaryButtonBindings = selected.mappings.parsedSecondaryButtonBindings
                buttonRapidPressEnabled = selected.mappings.parsedButtonRapidPressEnabled
            }
        }
        applyContinuousRecordingExperimentState(
            enabled: experimentalContinuousRecordingEnabled,
            backup: continuousRecordingPowerBindingBackup
        )
        unifiedBaseBindings = Self.decodeSetting(
            [UnifiedButtonBinding].self, forKey: "unifiedBaseBindings",
            from: defaults, corrupted: &corruptedKeys
        ) ?? []
        corruptedSettingKeys = corruptedKeys
        if shouldSeedSecondaryBindings { saveSecondaryBindings() }
    }

    /// What the last import in this session refused to adopt, or `nil` when it adopted
    /// everything. In memory only: it describes one user action, not stored state, and it must
    /// not outlive the session in which the user imported the file.
    @Published var configurationImportNotice: ConfigurationImportReport?

    /// Bundle identifiers, audio device identifiers and display names are matched or displayed,
    /// never executed, so a length bound is the whole requirement for them.
    static let maximumImportedIdentifierLength = 256
    static let maximumImportedPathLength = 1_024
    static let maximumImportedKeyLabelLength = 64
    /// macOS virtual key codes are 7-bit; this app's own label table stops at 126 and
    /// `RemoteButton.nativeEvent` never exceeds it. A larger code is not a key.
    static let maximumImportedKeyCode: UInt16 = 127

    enum ImportedApplicationProfile {
        case usable(CustomApplicationProfile)
        case notInstalledOnThisMac(CustomApplicationProfile)
        case rejected
    }
}
