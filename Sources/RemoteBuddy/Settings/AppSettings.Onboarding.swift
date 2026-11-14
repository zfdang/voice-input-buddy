import Combine
import Foundation

private struct OnboardingReturnConfiguration: Codable {
    let completedVersion: Int
    let step: OnboardingStep
    let voiceTool: OnboardingVoiceTool
    let controlSource: OnboardingControlSource
    let device: String?
    let remoteAvailability: OnboardingRemoteAvailability
    let appleRemoteGeneration: OnboardingAppleRemoteGeneration?
    let preferredGesture: VoiceGestureMode?
    let verifiedBinding: VoiceToolUserBinding?
    let voiceKeyMode: VoiceKeyMode
    let fnTapModeEnabled: Bool
    let customMappingEnabled: Bool
    let selectedRemoteProfileID: UUID?
    let initialRemoteProfileIDs: [UUID]
}

extension AppSettings {
    private static let onboardingReturnConfigurationKey = "onboarding.returnConfiguration"

    private var onboardingReturnConfiguration: OnboardingReturnConfiguration? {
        guard let data = defaults.data(forKey: Self.onboardingReturnConfigurationKey) else { return nil }
        return try? JSONDecoder().decode(OnboardingReturnConfiguration.self, from: data)
    }

    var canDismissOnboarding: Bool {
        guard let configuration = onboardingReturnConfiguration else { return false }
        return configuration.completedVersion >= Self.currentOnboardingVersion
    }

    func preserveCompletedOnboarding() {
        guard isOnboardingComplete, onboardingReturnConfiguration == nil else { return }
        discardOnboardingVoiceTrial()
        let configuration = OnboardingReturnConfiguration(
            completedVersion: onboardingCompletedVersion,
            step: onboardingStep,
            voiceTool: onboardingVoiceTool,
            controlSource: onboardingControlSource,
            device: onboardingDevice?.rawValue,
            remoteAvailability: onboardingRemoteAvailability,
            appleRemoteGeneration: onboardingAppleRemoteGeneration,
            preferredGesture: onboardingPreferredGesture,
            verifiedBinding: verifiedVoiceToolBinding,
            voiceKeyMode: voiceKeyMode,
            fnTapModeEnabled: voiceFnTapModeEnabled,
            customMappingEnabled: customMappingEnabled,
            selectedRemoteProfileID: selectedRemoteProfileID,
            initialRemoteProfileIDs: remoteDeviceProfiles.map(\.id)
        )
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.onboardingReturnConfigurationKey)
        }
    }

    func uncommittedOnboardingRemoteProfileIDs() -> [UUID] {
        let initialIDs = Set(onboardingReturnConfiguration?.initialRemoteProfileIDs ?? [])
        let forgottenBluetooth = forgottenBluetoothIdentifiers
        let forgottenHID = forgottenHIDFingerprints
        return remoteDeviceProfiles.compactMap { profile in
            guard !initialIDs.contains(profile.id) else { return nil }
            let matchesForgottenBluetooth = profile.bluetoothIdentifier.map { forgottenBluetooth.contains($0) } ?? false
            let matchesForgottenHID = profile.hidFingerprint.map { forgottenHID.contains($0) } ?? false
            return (matchesForgottenBluetooth || matchesForgottenHID) ? profile.id : nil
        }
    }

    func confirmedTransientOnboardingProfile() -> RemoteDeviceProfile? {
        let transientIDs = Set(uncommittedOnboardingRemoteProfileIDs())
        guard !transientIDs.isEmpty else { return nil }
        if let selectedID = selectedRemoteProfileID,
           transientIDs.contains(selectedID),
           let selectedProfile = remoteDeviceProfiles.first(where: { $0.id == selectedID }) {
            return selectedProfile
        }
        if transientIDs.count == 1,
           let onlyID = transientIDs.first {
            return remoteDeviceProfiles.first(where: { $0.id == onlyID })
        }
        return nil
    }

    func unconfirmedTransientRemoteProfileIDs() -> [UUID] {
        let confirmedID = confirmedTransientOnboardingProfile()?.id
        return uncommittedOnboardingRemoteProfileIDs().filter { $0 != confirmedID }
    }

    func dismissOnboarding() {
        guard canDismissOnboarding, let configuration = onboardingReturnConfiguration else { return }
        for profileID in uncommittedOnboardingRemoteProfileIDs() {
            _ = removeRemoteProfile(profileID)
        }
        discardOnboardingVoiceTrial()
        onboardingVoiceTool = configuration.voiceTool
        onboardingControlSource = configuration.controlSource
        onboardingDevice = configuration.device.flatMap(RemoteSetupDevice.init(rawValue:))
        onboardingRemoteAvailability = configuration.remoteAvailability
        onboardingAppleRemoteGeneration = configuration.appleRemoteGeneration
        onboardingPreferredGesture = configuration.preferredGesture
        verifiedVoiceToolBinding = configuration.verifiedBinding
        voiceKeyMode = configuration.voiceKeyMode
        voiceFnTapModeEnabled = configuration.fnTapModeEnabled
        customMappingEnabled = configuration.customMappingEnabled
        if let profileID = configuration.selectedRemoteProfileID {
            selectRemoteProfile(profileID)
        }
        synchronizeOnboardingRemoteWithSelectedProfile()
        onboardingPurpose = .initialSetup
        onboardingStep = configuration.step
        defaults.removeObject(forKey: Self.onboardingReturnConfigurationKey)
        onboardingCompletedVersion = configuration.completedVersion
    }

    func setOnboardingStep(_ step: OnboardingStep) {
        guard !isOnboardingComplete, onboardingStep != step else { return }
        // A lost prerequisite may require repair outside the shortened flow.
        if !onboardingPurpose.steps.contains(step) {
            onboardingPurpose = .initialSetup
        }
        onboardingStep = step
    }

    func recordFirstUseEvent(
        _ kind: FirstUseEventKind,
        step: OnboardingStep,
        failureReason: FirstUseFailureReason? = nil,
        voiceAttemptID: Int? = nil,
        voiceResult: FirstUseVoiceAttemptResult? = nil,
        at date: Date = Date()
    ) {
        let stepStartedAt = defaults.object(forKey: Keys.firstUseStepStartedAt) as? Date ?? date
        let event = FirstUseEvent(
            timestamp: date,
            kind: kind,
            step: step,
            elapsedMilliseconds: max(0, Int(date.timeIntervalSince(stepStartedAt) * 1_000)),
            failureReason: failureReason,
            voiceAttemptID: voiceAttemptID,
            voiceResult: voiceResult
        )
        if kind == .blocked,
           defaults.string(forKey: Keys.firstUseLastSignature) == event.deduplicationSignature {
            return
        }
        var events = firstUseEvents
        events.append(event)
        if events.count > 100 {
            events.removeFirst(events.count - 100)
        }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Keys.firstUseEvents)
        }
        defaults.set(event.deduplicationSignature, forKey: Keys.firstUseLastSignature)
        if kind == .entered {
            defaults.set(date, forKey: Keys.firstUseStepStartedAt)
        }

        AppLogger.shared.write(event.runtimeLogMessage)
    }

    var firstUseEvents: [FirstUseEvent] {
        // Deliberately not reported through corruptedSettingKeys: a computed getter can run
        // many times and would append duplicates, and onboarding local diagnostics is not user
        // configuration that deserves a configuration-loss warning. It still logs and backs
        // up the unreadable bytes, then cleans the corrupted key so the loss stays recoverable
        // without repeatedly re-triggering decode failures on subsequent reads.
        guard let data = defaults.data(forKey: Keys.firstUseEvents) else { return [] }
        do {
            return try JSONDecoder().decode([FirstUseEvent].self, from: data)
        } catch {
            defaults.set(data, forKey: "\(Keys.firstUseEvents).corrupt")
            defaults.removeObject(forKey: Keys.firstUseEvents)
            AppLogger.shared.write(
                "SETTINGS decode_failed key=\(Keys.firstUseEvents) bytes=\(data.count) error=\(error)"
            )
            return []
        }
    }

    func setOnboardingVoiceTool(_ voiceTool: OnboardingVoiceTool) {
        guard onboardingVoiceTool != voiceTool else { return }
        discardOnboardingVoiceTrial()
        onboardingVoiceTool = voiceTool
        onboardingPreferredGesture = nil
        stagedVoiceToolBinding = nil
    }

    func setOnboardingPreferredGesture(_ gesture: VoiceGestureMode?) {
        guard onboardingPreferredGesture != gesture else { return }
        discardOnboardingVoiceTrial()
        onboardingPreferredGesture = gesture
        stagedVoiceToolBinding = nil
    }

    func selectOnboardingDevice(_ device: RemoteSetupDevice) {
        setOnboardingControlSource(device.onboardingSource ?? .unselected)
        onboardingDevice = device
    }

    // Integration setup skips device selection, so derive its source from the
    // current profile instead of reusing a previous wizard's selection.
    func synchronizeOnboardingRemoteWithSelectedProfile() {
        let source: OnboardingControlSource
        switch selectedRemoteProfile?.model {
        case .rc001, .rc003: source = .xiaomiRemote
        case .t1Remote: source = .t1Remote
        case .chromecastVoiceRemote: source = .chromecastRemote
        case .appleSiriRemoteA2540, .appleSiriRemoteA2854: source = .siriRemote
        case .unknown, nil: source = .unselected
        }
        setOnboardingControlSource(source)
    }

    func setOnboardingControlSource(_ source: OnboardingControlSource) {
        onboardingDevice = RemoteSetupDevice.device(for: source)
        guard onboardingControlSource != source else { return }
        onboardingControlSource = source
        switch source {
        case .xiaomiRemote, .t1Remote, .siriRemote, .chromecastRemote:
            onboardingRemoteAvailability = .hasRemote
        case .unselected:
            onboardingRemoteAvailability = .unselected
        }
        discardOnboardingVoiceTrial()
    }

    func setOnboardingAppleRemoteGeneration(_ generation: OnboardingAppleRemoteGeneration?) {
        onboardingAppleRemoteGeneration = generation
        if generation != nil, onboardingControlSource != .siriRemote {
            setOnboardingControlSource(.siriRemote)
        }
    }

    func beginOnboardingVoiceTrial(_ plan: OnboardingVoicePairingPlan, applyVoiceSettings: Bool = true) {
        if defaults.data(forKey: Keys.onboardingTrialSnapshot) == nil {
            let snapshot = OnboardingVoiceConfigurationSnapshot(
                voiceKeyMode: voiceKeyMode,
                voiceFnTapModeEnabled: voiceFnTapModeEnabled
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: Keys.onboardingTrialSnapshot)
            }
        }
        stagedVoiceToolBinding = plan.binding
        if let data = try? JSONEncoder().encode(plan.binding) {
            defaults.set(data, forKey: Keys.onboardingStagedVoiceBinding)
        }
        if applyVoiceSettings {
            voiceKeyMode = plan.binding.shortcut
            voiceFnTapModeEnabled = plan.fnTapModeEnabled && plan.binding.shortcut == .function
        }
        AppLogger.shared.write(
            "ONBOARDING BINDING staged tool=\(plan.binding.tool.rawValue) " +
                "control_source=\(plan.controlSource.rawValue) " +
                "gesture=\(plan.binding.gestureMode.rawValue) " +
                "shortcut=\(plan.binding.shortcut.rawValue) " +
                "fn_tap=\(plan.fnTapModeEnabled) " +
                "binding_source=\(plan.binding.source.rawValue)"
        )
    }

    func stageLearnedOnboardingBinding(
        shortcut: VoiceKeyMode,
        gesture: VoiceGestureMode
    ) -> OnboardingVoicePairingPlan? {
        let binding = VoiceToolUserBinding(
            tool: onboardingVoiceTool,
            shortcut: shortcut,
            gestureMode: gesture,
            source: .userLearned,
            validationState: .staged,
            verifiedToolVersion: nil,
            verifiedAt: nil
        )
        guard let plan = OnboardingVoicePairingPlan.resolve(
            tool: onboardingVoiceTool,
            controlSource: onboardingControlSource,
            preferredGesture: gesture,
            userBinding: binding
        ) else { return nil }
        beginOnboardingVoiceTrial(plan)
        return plan
    }

    func verifyOnboardingVoiceBinding(at date: Date = Date()) {
        guard let stagedVoiceToolBinding else { return }
        let verified = stagedVoiceToolBinding.verified(at: date)
        verifiedVoiceToolBinding = verified
        self.stagedVoiceToolBinding = nil
        defaults.removeObject(forKey: Keys.onboardingStagedVoiceBinding)
        defaults.removeObject(forKey: Keys.onboardingTrialSnapshot)
        AppLogger.shared.write(
            "ONBOARDING BINDING verified tool=\(verified.tool.rawValue) " +
                "gesture=\(verified.gestureMode.rawValue) " +
                "shortcut=\(verified.shortcut.rawValue) " +
                "binding_source=\(verified.source.rawValue)"
        )
    }

    func discardOnboardingVoiceTrial() {
        guard let data = defaults.data(forKey: Keys.onboardingTrialSnapshot),
              let snapshot = try? JSONDecoder().decode(
                OnboardingVoiceConfigurationSnapshot.self,
                from: data
              ) else {
            stagedVoiceToolBinding = nil
            defaults.removeObject(forKey: Keys.onboardingStagedVoiceBinding)
            defaults.removeObject(forKey: Keys.onboardingTrialSnapshot)
            return
        }
        voiceKeyMode = snapshot.voiceKeyMode
        voiceFnTapModeEnabled = snapshot.voiceFnTapModeEnabled && snapshot.voiceKeyMode == .function
        stagedVoiceToolBinding = nil
        defaults.removeObject(forKey: Keys.onboardingStagedVoiceBinding)
        defaults.removeObject(forKey: Keys.onboardingTrialSnapshot)
        AppLogger.shared.write("ONBOARDING BINDING discarded reason=trial_not_verified")
    }

    func completeOnboarding() {
        let confirmedProfiles = confirmedTransientOnboardingProfile().map { [$0] } ?? []
        for profileID in unconfirmedTransientRemoteProfileIDs() {
            _ = removeRemoteProfile(profileID)
        }
        unforgetRemotes(confirmedProfiles)
        defaults.removeObject(forKey: Self.onboardingReturnConfigurationKey)
        recordFirstUseEvent(.completed, step: .complete)
        onboardingStep = .complete
        onboardingCompletedVersion = Self.currentOnboardingVersion
    }

    func restartOnboarding() {
        preserveCompletedOnboarding()
        onboardingPurpose = .initialSetup
        discardOnboardingVoiceTrial()
        verifiedVoiceToolBinding = nil
        defaults.removeObject(forKey: Keys.firstUseEvents)
        onboardingVoiceTool = .unselected
        onboardingRemoteAvailability = .unselected
        onboardingControlSource = .unselected
        onboardingDevice = nil
        onboardingAppleRemoteGeneration = nil
        onboardingPreferredGesture = nil
        onboardingStep = .permissions
        onboardingCompletedVersion = 0
        defaults.removeObject(forKey: Keys.firstUseStepStartedAt)
        defaults.removeObject(forKey: Keys.firstUseLastSignature)
    }

    static func restoreInterruptedOnboardingTrial(in defaults: UserDefaults) {
        guard let data = defaults.data(forKey: Keys.onboardingTrialSnapshot),
              let snapshot = try? JSONDecoder().decode(
                OnboardingVoiceConfigurationSnapshot.self,
                from: data
              ) else {
            defaults.removeObject(forKey: Keys.onboardingStagedVoiceBinding)
            defaults.removeObject(forKey: Keys.onboardingTrialSnapshot)
            return
        }
        if defaults.integer(forKey: Keys.onboardingCompletedVersion) < currentOnboardingVersion,
           defaults.string(forKey: Keys.onboardingStep) == OnboardingStep.voiceTest.rawValue,
           let bindingData = defaults.data(forKey: Keys.onboardingStagedVoiceBinding),
           let binding = try? JSONDecoder().decode(VoiceToolUserBinding.self, from: bindingData),
           binding.validationState == .staged,
           defaults.string(forKey: Keys.onboardingVoiceTool) == binding.tool.rawValue,
           let source = defaults.string(forKey: Keys.onboardingControlSource)
               .flatMap(OnboardingControlSource.init(rawValue:)),
           let plan = OnboardingVoicePairingPlan.resolve(
               tool: binding.tool, controlSource: source, userBinding: binding
           ) {
            // The wizard resumes directly at voice testing after relaunch. Its
            // staged trigger must resume too; retain the snapshot for cancellation.
            defaults.set(plan.binding.shortcut.rawValue, forKey: Keys.voiceKeyMode)
            defaults.set(plan.fnTapModeEnabled, forKey: Keys.voiceFnTapModeEnabled)
            AppLogger.shared.write("ONBOARDING BINDING restored reason=resuming_voice_test")
            return
        }
        defaults.set(snapshot.voiceKeyMode.rawValue, forKey: Keys.voiceKeyMode)
        defaults.set(
            snapshot.voiceFnTapModeEnabled && snapshot.voiceKeyMode == .function,
            forKey: Keys.voiceFnTapModeEnabled
        )
        defaults.removeObject(forKey: Keys.onboardingStagedVoiceBinding)
        defaults.removeObject(forKey: Keys.onboardingTrialSnapshot)
        AppLogger.shared.write("ONBOARDING BINDING restored reason=interrupted_trial")
    }
}
