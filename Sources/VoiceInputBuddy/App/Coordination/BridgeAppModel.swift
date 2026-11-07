import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

@MainActor
final class BridgeAppModel: ObservableObject, BluetoothRemoteBridgeDelegate {
    static let longRecordingOpenTimeout: TimeInterval = 5
    static let longRecordingCloseTimeout: TimeInterval = 2
    static let rc003VoiceExtensionOpenTimeout: TimeInterval = 5
    static let rc003VoiceExtensionInterval: TimeInterval = 8
    static let rc003VoiceExtensionMaximumDuration: TimeInterval = 120

    let connections = BluetoothConnectionRegistry()
    let voiceSession = VoiceSessionRuntime()
    let audio = AudioRuntime()

    let settings: AppSettings
    let commonPhraseStore: CommonPhraseStore
    lazy var commonPhrases = CommonPhraseController(store: commonPhraseStore)
    let loginItemService: LoginItemService

    @Published var connectionStatus = LocalizedMessage("bluetooth.status.initializing")
    @Published var hidStatus = LocalizedMessage("button_mapping.status.disabled")
    @Published var audioStatus = LocalizedMessage("audio.output.none_selected")
    @Published var buddyMicrophoneStatus = LocalizedMessage("audio.compatibility.checking")
    @Published var isStreaming = false
    @Published var isConnected = false
    @Published var isVoiceTriggerEnabled = false
    @Published var activeRemoteButtons = Set<RemoteButton>()
    /// Chromecast 画布的活动按键（控制 ID）。与苹果遥控器链路完全隔离，互不清除。
    @Published private(set) var activeChromecastControlIDs = Set<String>()
    @Published var lastRemoteButtonPress: RemoteButton?
    @Published var connectedRemoteProfileIDs = Set<UUID>()
    @Published var remoteBatteryLevels: [UUID: Int] = [:]
    @Published var remotePowerStates: [UUID: RemotePowerState] = [:]
    var pendingRemoteBatteryLevels: [UUID: Int] = [:]
    var pendingRemotePowerStates: [UUID: RemotePowerState] = [:]
    var pendingRemoteModels: [UUID: RemoteModel] = [:]
    @Published var remoteSystemDeviceNames: [UUID: String] = [:]
    @Published var remoteDeviceInformation: [UUID: RemoteDeviceInformation] = [:]
    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var testToneStatus = LocalizedMessage("audio.output.none_selected")
    @Published var isPlayingTestTone = false
    @Published var isAudioOutputReady = false {
        didSet { if isAudioOutputReady { isAudioOutputVerified = true } }
    }
    /// The last configuration of the selected output succeeded. Idle release stops
    /// the engine but keeps this result; a failed configuration or stop clears it.
    @Published var isAudioOutputVerified = false
    @Published var hasReceivedCurrentVoiceSamples = false
    @Published var activeVoiceSource: RemoteInputSource?
    @Published var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")
    @Published var voiceKeyCompatibilityWarning: VoiceKeyCompatibilityWarning?

    func isOnboardingControlSourceConnected(_ source: OnboardingControlSource) -> Bool {
        switch source {
        case .xiaomiRemote:
            return connectedRemoteProfileIDs.contains { profileID in
                guard let model = settings.remoteDeviceProfiles.first(where: {
                    $0.id == profileID
                })?.model else { return false }
                return !model.usesPrivateAdapter && !model.isChromecastRemote
            }
        case .siriRemote:
            return false
        case .chromecastRemote:
            return connectedRemoteProfileIDs.contains { id in
                settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model.isChromecastRemote == true
            }
        case .unselected:
            return false
        }
    }

    var activePhysicalVoiceControlSource: OnboardingControlSource? {
        if voiceSession.isActive {
            let profile = voiceSession.activeDeviceIdentifier.flatMap { settings.profileID(forBluetoothIdentifier: $0) }
                .flatMap { id in settings.remoteDeviceProfiles.first { $0.id == id } }
            return profile?.model.isChromecastRemote == true ? .chromecastRemote : .xiaomiRemote
        }
        return nil
    }

    let voiceFunctionMapper = RemoteHIDKeyMapper()
    lazy var preferredInputSourceMonitor = PreferredInputSourceMonitor(
        voiceTool: { [weak self] in
            self?.settings.onboardingVoiceTool ?? .unselected
        }
    )
    lazy var voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
        onStateChange: { [weak self] state in
            self?.handleVoiceInputDestinationState(state)
        }
    )
    lazy var voiceFnTapSession = VoiceFnTapSessionController(
        startTapCount: { [weak self] in
            self?.settings.onboardingVoiceTool.functionKeyStartTapCount ?? 1
        },
        destinationReadiness: { [weak self] completion in
            self?.voiceInputDestinationCoordinator.waitUntilReady(completion: completion) ?? .immediate
        },
        setFunctionKeyPressed: { KeyboardInjector.setFunctionKeyPressed($0) },
        enqueueAudio: { [weak self] samples in
            self?.enqueueVoiceFnTapAudio(samples)
        },
        drainAudio: { [weak self] operationID, completion in
            guard let self else {
                completion()
                return
            }
            self.audio.output.endSessionAfterDraining(
                source: "voice_fn_tap",
                operationID: operationID,
                maximumDelay: self.audio.output.pendingPlaybackDuration + 0.75
            ) { outcome in
                AppLogger.shared.write(
                    "VOICE FN TAP playback_stop operation_id=\(operationID) " +
                        "phase=completed result=\(outcome.rawValue)"
                )
                completion()
            }
        },
        onFailure: { [weak self] failure in
            self?.handleVoiceFnTapFailure(failure)
        },
        enqueuePreRollAudio: { [weak self] in self?.enqueueVoiceFnTapAudio($0, isPreRoll: true) },
        pendingPlaybackDuration: { [weak self] in self?.audio.output.pendingPlaybackDuration ?? 0 },
        logger: { AppLogger.shared.write($0) },
        onIdle: { [weak self] in
            self?.flushPendingVoiceToolMappingRefresh()
            self?.releaseVirtualAudioOutputIfUnused(reason: "voice_fn_tap_idle")
        }
    )
    private var voiceToolCancellable: AnyCancellable?
    var testToneGeneration = 0
    var voiceKeyLatch = VoiceKeyLatch()
    var voiceKeyReleaseRetry: ScheduledOperation?
    var voiceKeyReleaseRetryGeneration: UInt64 = 0
    var scheduleVoiceKeyReleaseRetry: OperationScheduler = ScheduledOperation.mainQueue
    var heldVoiceKeyMode: VoiceKeyMode?
    var pendingVoiceKeyMode: VoiceKeyMode?
    // Main-queue state; only input-source waits can pump/reenter that queue.
    var voiceKeyActivationInProgress = false
    var voiceKeyActivationGeneration: UInt64 = 0
    var pendingVoiceKeyActivationOwner: VoiceKeyLatch.Owner?
    var pendingVoiceKeyActivationCompletion: ((Bool) -> Void)?
    var pendingVoiceToolMappingRefresh = false
    weak var longRecordingBridge: BluetoothRemoteBridge?
    var longRecordingRequested = false
    var longRecordingGeneration: UInt64 = 0
    var longRecordingOpenTimer: DispatchSourceTimer?
    var longRecordingCloseTimer: DispatchSourceTimer?
    let rc003VoiceExtensionTestEnabled: Bool
    weak var rc003VoiceExtensionBridge: BluetoothRemoteBridge?
    var rc003VoiceExtensionActive = false
    var rc003VoiceExtensionAwaitingReopen = false
    var rc003VoiceExtensionGeneration: UInt64 = 0
    var rc003VoiceExtensionDidReceiveAudio = false
    var rc003VoiceExtensionTimer: DispatchSourceTimer?
    var rc003VoiceExtensionOpenTimer: DispatchSourceTimer?
    var rc003VoiceExtensionDeadlineTimer: DispatchSourceTimer?
    let hidEventSuppressor = KeyboardEventSuppressor()
    var hidMonitoringInterrupted = false
    var hidMonitors: [String: HIDRemoteMonitor] = [:]
    var discoveryHIDMonitor: HIDRemoteMonitor?
    var selectedRemoteVoiceCapabilities: RemoteVoiceCapabilities {
        .resolve(model: settings.selectedRemoteProfile?.model, declared: [])
    }

    /// Google readiness derives from the shared public Bluetooth bridges.
    var connectedChromecastProfileIDs = Set<UUID>()
    var hidPowerKeySuppressed = false
    var hidAllowedLocationIDs: Set<UInt32>?
    var started = false
    var remoteDeviceNameRefreshOperation: UInt64 = 0
    var appliedHIDPermissionSnapshot: HIDPermissionSnapshot?
    private var terminationObserver: NSObjectProtocol?
    var completedUpdateHIDRecoveryWorkItem: DispatchWorkItem?
    var hidMappingRecoveryWorkItem: DispatchWorkItem?
    var hidMappingRecoveryAttempt = 0
    var hidMappingRecoveryGeneration: UInt64 = 0
    lazy var audioHardwareListener = Self.makeAudioHardwareListener(owner: self)

    nonisolated private static func makeAudioHardwareListener(owner: BridgeAppModel) -> AudioObjectPropertyListenerBlock {
        { [weak owner] count, addresses in
            let properties = audioHardwarePropertyNames(count: count, addresses: addresses)
            DispatchQueue.main.async { [weak owner] in
                owner?.scheduleAudioRecovery(reason: "hardware_change", details: "properties=\(properties)")
            }
        }
    }

    var isRC003VoiceExtensionTestEnabled: Bool {
        rc003VoiceExtensionTestEnabled
    }

    init(
        settings: AppSettings? = nil,
        commonPhraseStore: CommonPhraseStore = CommonPhraseStore(),
        initialAudioDevices: [AudioDeviceInfo] = [],
        loginItemService: LoginItemService = LoginItemService(),
        rc003VoiceExtensionTestEnabled: Bool =
            ProcessInfo.processInfo.arguments.contains("--rc003-voice-extension-test") ||
            (Bundle.main.object(forInfoDictionaryKey: "RC003VoiceExtensionTestEnabled") as? Bool == true)
    ) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        self.commonPhraseStore = commonPhraseStore

        self.loginItemService = loginItemService
        self.rc003VoiceExtensionTestEnabled = rc003VoiceExtensionTestEnabled
        commonPhrases.onWillOpen = { [weak self] in self?.cancelPendingCommonPhraseButtonActions() }
        audioDevices = initialAudioDevices
        hidEventSuppressor.onSystemDisabled = { [weak self] in
            // Stop mapping as well: an unseized remote must not inject actions without filtering.
            guard let self else { return }
            self.hidMonitoringInterrupted = true
            self.stopHIDMonitors()
            let permissions = HIDPermissionSnapshot.current
            self.appliedHIDPermissionSnapshot = permissions
            self.hidStatus = LocalizedMessage(
                !permissions.inputMonitoringGranted ? "button_mapping.permission.input_monitoring_required" :
                    (!permissions.accessibilityGranted ? "button_mapping.permission.accessibility_required" :
                        "button_mapping.status.interrupted")
            )
        }
        voiceToolCancellable = settings.$onboardingVoiceTool
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.voiceToolDidChange()
            }
        audio.output.onConfigurationChange = { @Sendable [weak self] in
            DispatchQueue.main.async { [weak self] in self?.scheduleAudioRecovery(reason: "engine_configuration_change") }
        }

    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        startAudioSubsystem()
        applyHIDSettings()
        refreshRemoteDeviceNames(reason: .startup)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        AppLogger.shared.write(
            "APP START version=\(version) rc003_test=\(rc003VoiceExtensionTestEnabled)"
        )
    }

    isolated deinit {
        voiceKeyReleaseRetry?.cancel()
    }

    private(set) var isTerminating = false

    func prepareForTermination() {
        isTerminating = true
        commonPhrases.close(reason: "app_terminating")
    }

    func stop() {
        commonPhrases.close(reason: "app_stop")
        preferredInputSourceMonitor.stop()
        guard started else { return }
        started = false
        cancelHIDMappingRecovery(reason: "app_stop")
        completedUpdateHIDRecoveryWorkItem?.cancel()
        completedUpdateHIDRecoveryWorkItem = nil
        audio.invalidatePendingWork()
        stopObservingAudioHardware()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("app.status.stopped"),
            logReason: "app_stop"
        )
        stopLongRecording(reason: "app_stop")
        finishRC003VoiceExtensionTest(reason: "app_stop")
        voiceInputDestinationCoordinator.shutdown()
        voiceFnTapSession.shutdown()
        connections.stopAll()
        voiceSession.end()
        releaseVoiceKeyIfNeeded()
        stopHIDMonitors()
        isAudioOutputReady = false
        isAudioOutputVerified = false
        // Stop is serialized with configurations on the engine queue. Enumeration no
        // longer allocates audio resources, so a delayed preparation-queue stop is unsafe.
        audio.output.stop()
        voiceFunctionMapper.restore()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        AppLogger.shared.write("APP STOP")
    }

}
