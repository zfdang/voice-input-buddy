import Foundation


enum OnboardingControlValidationPolicy {
    static func suppressConfiguredActions(
        at step: OnboardingStep,
        source: OnboardingControlSource
    ) -> Bool {
        guard step == .remote || step == .controls else { return false }
        switch source {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return true
        case .unselected:
            return false
        }
    }
}

enum OnboardingSecureInputPolicy {
    static let warningDelay: TimeInterval = 3

    static func shouldMonitor(
        step: OnboardingStep,
        source: OnboardingControlSource
    ) -> Bool {
        guard step == .remote || step == .controls else { return false }
        switch source {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return true
        case .unselected:
            return false
        }
    }

    static func shouldShowWarning(
        step: OnboardingStep,
        source: OnboardingControlSource,
        remoteConnected: Bool,
        remoteButtonObserved: Bool,
        secureInputActive: Bool?,
        waitStartedAtUptime: TimeInterval?,
        nowUptime: TimeInterval
    ) -> Bool {
        guard shouldMonitor(step: step, source: source),
              remoteConnected,
              !remoteButtonObserved,
              secureInputActive == true,
              let waitStartedAtUptime
        else { return false }
        return nowUptime - waitStartedAtUptime >= warningDelay
    }
}


enum OnboardingBuildCapabilities {
    static var availableControlSources: [OnboardingControlSource] {
        let sources = RemoteSetupDevice.allCases.compactMap(\.onboardingSource)
        return sources.reduce(into: []) { unique, source in
            if !unique.contains(source) { unique.append(source) }
        }
    }
}

struct OnboardingVoicePairingPlan: Equatable {
    let binding: VoiceToolUserBinding
    let controlSource: OnboardingControlSource
    let fnTapModeEnabled: Bool
    let chromecastVoiceMode: ChromecastVoiceMode?
    let evidenceState: VoiceToolEvidenceState

    static func resolve(
        tool: OnboardingVoiceTool,
        controlSource: OnboardingControlSource,
        preferredGesture: VoiceGestureMode? = nil,
        userBinding: VoiceToolUserBinding? = nil,
        forceFunctionKey: Bool = false
    ) -> Self? {
        guard tool != .unselected, controlSource != .unselected else { return nil }
        let profile = VoiceToolAdapterProfile.profile(for: tool)

        if let userBinding {
            var effectiveBinding = userBinding
            if forceFunctionKey {
                effectiveBinding = VoiceToolUserBinding(
                    tool: userBinding.tool,
                    shortcut: .function,
                    gestureMode: userBinding.gestureMode,
                    source: userBinding.source,
                    validationState: userBinding.validationState,
                    verifiedToolVersion: userBinding.verifiedToolVersion,
                    verifiedAt: userBinding.verifiedAt
                )
            }
            guard effectiveBinding.tool == tool,
                  profile.supportedModes.contains(effectiveBinding.gestureMode),
                  canDrive(
                    gesture: effectiveBinding.gestureMode,
                    shortcut: effectiveBinding.shortcut,
                    from: controlSource
                  ) else { return nil }
            return makePlan(
                binding: effectiveBinding,
                controlSource: controlSource,
                evidenceState: profile.evidenceState
            )
        }

        let candidates = gestureCandidates(
            profile: profile,
            controlSource: controlSource,
            preferredGesture: preferredGesture
        )
        for gesture in candidates {
            let shortcut = forceFunctionKey ? VoiceKeyMode.function : profile.defaultShortcutByMode[gesture]
            guard let shortcut,
                  canDrive(gesture: gesture, shortcut: shortcut, from: controlSource)
            else { continue }
            return makePlan(
                binding: VoiceToolUserBinding(
                    tool: tool,
                    shortcut: shortcut,
                    gestureMode: gesture,
                    source: .documentedDefault,
                    validationState: .staged,
                    verifiedToolVersion: nil,
                    verifiedAt: nil
                ),
                controlSource: controlSource,
                evidenceState: profile.evidenceState
            )
        }
        return nil
    }

    private static func gestureCandidates(
        profile: VoiceToolAdapterProfile,
        controlSource: OnboardingControlSource,
        preferredGesture: VoiceGestureMode?
    ) -> [VoiceGestureMode] {
        var result: [VoiceGestureMode] = []
        func append(_ mode: VoiceGestureMode?) {
            guard let mode, profile.supportedModes.contains(mode), !result.contains(mode) else {
                return
            }
            result.append(mode)
        }
        append(preferredGesture)
        if controlSource.supportedGestureModes.contains(.hold) { append(.hold) }
        append(profile.recommendedMode)
        append(.toggle)
        append(.hold)
        return result
    }

    private static func canDrive(
        gesture: VoiceGestureMode,
        shortcut: VoiceKeyMode,
        from source: OnboardingControlSource
    ) -> Bool {
        if source.supportedGestureModes.contains(gesture) { return true }
        return gesture == .toggle &&
            shortcut == .function &&
            source.supportedGestureModes == [.hold]
    }

    private static func makePlan(
        binding: VoiceToolUserBinding,
        controlSource: OnboardingControlSource,
        evidenceState: VoiceToolEvidenceState
    ) -> Self {
        let fnTap = binding.gestureMode == .toggle &&
            binding.shortcut == .function &&
            !controlSource.supportedGestureModes.contains(.toggle)
        let chromecastMode: ChromecastVoiceMode? = controlSource == .chromecastRemote
            ? (binding.gestureMode == .toggle ? .toggle : .hold)
            : nil
        return Self(
            binding: binding,
            controlSource: controlSource,
            fnTapModeEnabled: fnTap,
            chromecastVoiceMode: chromecastMode,
            evidenceState: evidenceState
        )
    }
}

/// Onboarding 右栏使用的遥控器图片来源。
///
/// 物理遥控器的图片必须跟随用户选择的来源，不能把一张小米图片当成所有硬件的占位图。
enum OnboardingRemotePhotoKind: Equatable {
    case bundled(resourceName: String)
    case siriRemote
    case chromecastRemote
    case placeholder

    static func resolve(
        source: OnboardingControlSource,
        selectedModel: RemoteModel?,
        selectedDevice: RemoteSetupDevice? = nil
    ) -> Self {
        switch source {
        case .xiaomiRemote:
            // Only a Xiaomi profile may refine the image. A previously selected
            // Apple/Chromecast profile must never replace the Xiaomi card artwork.
            if let selectedModel,
               selectedModel == .rc001 || selectedModel == .rc003 {
                guard let resource = XiaomiRemoteCatalog.photoResource(for: selectedModel) else {
                    return .placeholder
                }
                return .bundled(resourceName: resource)
            }
            return .bundled(resourceName: XiaomiRemoteCatalog.photoResource(for: .rc003)
                ?? "RC003-remote-photo")
        case .siriRemote:
            return .siriRemote
        case .chromecastRemote:
            if let selectedDevice, selectedDevice.onboardingSource == .chromecastRemote {
                return .bundled(resourceName: selectedDevice.illustrationResource)
            }
            return .bundled(resourceName: RemoteSetupDevice.chromecastG9N9N.illustrationResource)
        case .unselected:
            return .placeholder
        }
    }
}

enum OnboardingVoiceToolAvailability: String, Equatable, Hashable {
    case available
    case notInstalled
    case unknown
}

enum OnboardingVoiceToolVisibilityPolicy {
    // Discovery affects availability badges and setup readiness, not the catalog.
    // Both onboarding and Settings must expose the same supported integrations.
    static let tools = OnboardingVoiceTool.allCases.filter { $0 != .unselected }
}

enum OnboardingVoiceToolRuntimeState: String, Equatable, Hashable {
    case running
    case notRunning = "not_running"
    case unknown
    case notApplicable = "not_applicable"
}

enum OnboardingVoiceToolRuntimePolicy {
    static func requiresRunningApplication(for tool: OnboardingVoiceTool) -> Bool {
        switch VoiceToolAdapterProfile.profile(for: tool).installationProbe {
        case .applicationBundle:
            return true
        case .inputSource, .none:
            return false
        }
    }

}

struct OnboardingCapabilities: Equatable {
    var systemFunctionKeyAvailable = false
    var bluetoothGranted = false
    var inputMonitoringGranted = false
    var accessibilityGranted = false
    var remoteConnected = false
    var remoteButtonObserved = false
    var microphoneDriverInstalled = false
    var audioReady = false
    var audioOutputSelected = false
    var voiceSessionStarted = false
    var voiceSamplesReceived = false
    var voiceSessionEnded = false
    var transcriptionAppeared = false
    var manualTranscriptInputObserved = false
    var testedRemoteButtonCount = 0
}

enum OnboardingAudioSelectionPolicy {
    private static let supportedUIDs = [BuddyMicrophoneDevicePolicy.deviceUID]

    static func isSupportedDevice(uid: String, name: String) -> Bool {
        supportedUIDs.contains(uid)
    }

    static func isSupportedDeviceSelected(
        selectedUID: String,
        availableSupportedUIDs: some Sequence<String>
    ) -> Bool {
        selectedUID == BuddyMicrophoneDevicePolicy.deviceUID && availableSupportedUIDs.contains(selectedUID)
    }
}

enum OnboardingTranscriptInputPolicy {
    static func canEditText(keyCode: UInt16, characters: String?, commandHeld: Bool) -> Bool {
        // Navigation, shortcuts and function keys are not evidence of manual text.
        guard !commandHeld else { return false }
        if [51, 117].contains(keyCode) { return true }
        return characters?.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) &&
            !(0xF700...0xF8FF).contains($0.value) } == true
    }

    static func isManualPaste(eventTypeRawValue: UInt?, sourceStateID: Int64?,
        sourceUnixProcessID: Int64?) -> Bool {
        // Context-menu paste has no keyDown; a physical Cmd-V is manual. Synthetic
        // key events from dictation tools must remain eligible for voice validation.
        guard eventTypeRawValue == keyDownEventTypeRawValue else { return true }
        return isConfirmedPhysicalKeyboardInput(eventTypeRawValue: eventTypeRawValue,
            sourceStateID: sourceStateID, sourceUnixProcessID: sourceUnixProcessID)
    }

    private static let keyDownEventTypeRawValue: UInt = 10
    private static let hidSystemStateRawValue: Int64 = 1

    static func isConfirmedPhysicalKeyboardInput(
        eventTypeRawValue: UInt?,
        sourceStateID: Int64?,
        sourceUnixProcessID: Int64?
    ) -> Bool {
        guard eventTypeRawValue == keyDownEventTypeRawValue,
              sourceStateID == hidSystemStateRawValue,
              let sourceUnixProcessID,
              sourceUnixProcessID <= 0 else {
            return false
        }
        return true
    }
}

enum OnboardingVoiceTestConfigurationPolicy {
    static func requiresGlobalVoiceConfirmation(for voiceTool: OnboardingVoiceTool) -> Bool {
        voiceTool == .doubao
    }
}

enum OnboardingFlowPolicy {
    static func isPhysicalRemoteRecognized(
        at step: OnboardingStep,
        voiceConnectionReady: Bool,
        validatedHIDButtonObserved: Bool
    ) -> Bool {
        voiceConnectionReady || (step == .remote && validatedHIDButtonObserved)
    }

    static func shouldAutoSelectPhysicalRemote(
        at step: OnboardingStep,
        remoteConnected: Bool,
        suppressForUserBack: Bool = false
    ) -> Bool {
        step == .remoteAvailability && remoteConnected && !suppressForUserBack
    }

    static func shouldRequestRemoteReconnect(
        remoteConnected: Bool,
        remoteButtonObserved: Bool,
        recoveryRequested: Bool
    ) -> Bool {
        !remoteConnected && remoteButtonObserved && !recoveryRequested
    }

    static func canContinue(
        from step: OnboardingStep,
        voiceTool: OnboardingVoiceTool,
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        voiceKeyMode: VoiceKeyMode = .function,
        voiceToolGuideStepsCompleted: Bool = false,
        selectedDevice: RemoteSetupDevice? = nil,
        capabilities: OnboardingCapabilities
    ) -> Bool {
        if [.remote, .controls, .audio, .voiceTest].contains(step),
           missingRuntimePermission(controlMethod: controlMethod, capabilities: capabilities) != nil {
            return false
        }
        switch step {
        case .voiceTool:
            return voiceTool != .unselected && voiceToolGuideStepsCompleted
        case .remoteAvailability:
            return selectedDevice?.canStartSetup == true
        case .permissions:
            // Environment setup must work before a control device is selected.
            return capabilities.bluetoothGranted &&
                capabilities.inputMonitoringGranted &&
                capabilities.accessibilityGranted
        case .remote:
            return capabilities.remoteConnected && capabilities.remoteButtonObserved
        case .audio:
            return capabilities.microphoneDriverInstalled &&
                capabilities.audioOutputSelected &&
                capabilities.audioReady
        case .voiceTest:
            return capabilities.voiceSessionStarted &&
                capabilities.voiceSamplesReceived &&
                capabilities.voiceSessionEnded &&
                capabilities.transcriptionAppeared &&
                !capabilities.manualTranscriptInputObserved
        case .controls:
            return capabilities.testedRemoteButtonCount >= 3
        case .complete:
            return isControlSelectionValid(
                remoteAvailability: remoteAvailability,
                controlMethod: controlMethod
            ) &&
                (!controlMethod.requiresBluetoothPermission || capabilities.bluetoothGranted) &&
                (!controlMethod.requiresInputMonitoringPermission ||
                    capabilities.inputMonitoringGranted) &&
                capabilities.accessibilityGranted &&
                capabilities.remoteConnected &&
                capabilities.audioOutputSelected &&
                capabilities.audioReady
        }
    }

    static func missingRuntimePermission(controlMethod: OnboardingControlMethod,
                                         capabilities: OnboardingCapabilities) -> FirstUseFailureReason? {
        if controlMethod.requiresBluetoothPermission && !capabilities.bluetoothGranted {
            return .bluetoothPermissionDenied
        }
        if controlMethod.requiresInputMonitoringPermission && !capabilities.inputMonitoringGranted {
            return .inputMonitoringPermissionDenied
        }
        if !capabilities.accessibilityGranted { return .accessibilityPermissionDenied }
        return nil
    }

    static func recoveryStep(
        from step: OnboardingStep,
        voiceTool: OnboardingVoiceTool,
        remoteAvailability: OnboardingRemoteAvailability = .hasRemote,
        controlMethod: OnboardingControlMethod = .physicalRemote,
        capabilities: OnboardingCapabilities,
        hasSelectedAudioUID: Bool
    ) -> OnboardingStep? {
        let context = FirstUseDiagnosticContext(
            step: step,
            remoteAvailability: remoteAvailability,
            controlMethod: controlMethod,
            capabilities: capabilities,
            hasSelectedAudioUID: hasSelectedAudioUID
        )
        guard let failure = context.failureReason else { return nil }
        if step == .complete, failure == .completeRuntimeRegressed {
            if !isControlSelectionValid(
                remoteAvailability: remoteAvailability,
                controlMethod: controlMethod
            ) {
                return .remoteAvailability
            }
            if (controlMethod.requiresBluetoothPermission && !capabilities.bluetoothGranted) ||
                (controlMethod.requiresInputMonitoringPermission &&
                    !capabilities.inputMonitoringGranted) ||
                !capabilities.accessibilityGranted {
                return .permissions
            }
            if !capabilities.remoteConnected { return .remote }
            return .audio
        }
        return failure.recoveryStep
    }

    static func isControlSelectionValid(
        remoteAvailability: OnboardingRemoteAvailability,
        controlMethod: OnboardingControlMethod
    ) -> Bool {
        switch remoteAvailability {
        case .hasRemote:
            return controlMethod == .physicalRemote
        case .noRemote:
            return false
        case .unselected:
            return false
        }
    }
}

enum OnboardingLaunchPolicy {
    static func shouldStartRuntime(isComplete: Bool, step: OnboardingStep) -> Bool {
        isComplete || step.requiresRuntime
    }

    static func shouldShowMainWindow(
        isComplete: Bool,
        completedUpdate: Bool,
        openMainWindowAtLaunch: Bool
    ) -> Bool {
        !isComplete || completedUpdate || openMainWindowAtLaunch
    }
}

enum CompletedUpdatePermissionRepairPolicy {
    static func shouldOpenPermissions(
        isOnboardingComplete: Bool,
        completedUpdate: Bool,
        bluetoothGranted: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        isOnboardingComplete &&
            completedUpdate &&
            (!bluetoothGranted || !inputMonitoringGranted || !accessibilityGranted)
    }
}
