import CoreBluetooth
import Foundation

enum BluetoothBridgeState: Equatable {
    case stopped
    case bluetoothUnavailable(LocalizedMessage)
    case scanning
    case connecting
    case discovering
    case ready(String)
    case reconnecting
    case failed(LocalizedMessage)

    var message: LocalizedMessage {
        switch self {
        case .stopped: return LocalizedMessage("common.status.stopped")
        case .bluetoothUnavailable(let reason): return reason
        case .scanning: return LocalizedMessage("connection.status.searching")
        case .connecting: return LocalizedMessage("connection.status.connecting")
        case .discovering: return LocalizedMessage("connection.status.initializing_voice")
        case .ready: return LocalizedMessage("connection.status.connected_to_device")
        case .reconnecting: return LocalizedMessage("connection.status.reconnecting")
        case .failed(let reason): return reason
        }
    }
}

@MainActor
protocol BluetoothRemoteBridgeDelegate: AnyObject {
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didChange state: BluetoothBridgeState)
    func bluetoothBridgeDidStartVoice(_ bridge: BluetoothRemoteBridge)
    func bluetoothBridgeDidStopVoice(_ bridge: BluetoothRemoteBridge)
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didDecode samples: [Int16])
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdateBatteryLevel level: Int?)
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didIdentifyRemoteModel model: RemoteModel)
    func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdatePowerState state: RemotePowerState?)
    func bluetoothBridgeDeviceNameDidChange(_ bridge: BluetoothRemoteBridge)
}

@MainActor
private final class BluetoothRemotePeripheralDelegateProxy: NSObject, @preconcurrency CBPeripheralDelegate {
    let generation: UInt64
    weak var owner: BluetoothRemoteBridge?

    init(generation: UInt64, owner: BluetoothRemoteBridge) {
        self.generation = generation
        self.owner = owner
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.handleWriteResponse(peripheral: peripheral, generation: generation,
                                   characteristic: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        owner?.handleWriteReady(peripheral: peripheral, generation: generation)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        owner?.handleNameUpdate(peripheral: peripheral, generation: generation)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.handleDiscoveredServices(
            peripheral: peripheral,
            generation: generation,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        owner?.handleDiscoveredCharacteristics(
            peripheral: peripheral,
            generation: generation,
            service: service,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleNotificationState(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleCharacteristicValue(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }
}

enum BluetoothBatteryPollingPolicy {
    static let interval: TimeInterval = 5 * 60

    static func shouldPoll(
        supportsNotifications: Bool,
        isNotifying: Bool
    ) -> Bool {
        !supportsNotifications || !isNotifying
    }
}

@MainActor
final class BluetoothRemoteBridge: NSObject {
    private static let defaultCapabilities = ATVVCapabilities(
        version: 0x0100,
        codecs: 0x02,
        interaction: 0x03,
        frameSize: 120,
        selectedCodec: 0x02,
        sampleRate: 16_000
    )

    private let settings: AppSettings
    private let allowsG9N9N: Bool
    private var googleCandidate = false
    private var googleReadiness = G9N9NReadiness()
    private var microphoneKeepalive: DispatchWorkItem?
    private(set) var identifiedModel: RemoteModel?
    private(set) var reportedHIDIdentity: RemoteHIDIdentity?
    var onHIDIdentityUpdate: (() -> Void)?
    private(set) var deviceInformation = RemoteDeviceInformation() {
        didSet {
            if deviceInformation != oldValue { onDeviceInformationUpdate?() }
        }
    }
    var onDeviceInformationUpdate: (() -> Void)?
    private weak var delegate: BluetoothRemoteBridgeDelegate?
    private(set) var targetIdentifier: UUID?
    private let excludedIdentifiers: () -> Set<UUID>
    /// 已被判定为「别的产品」的标识；本桥此后一律不再连接，也不再走扫描回退。
    private var rejectedIdentifiers = Set<UUID>()
    private var central: CBCentralManager?
    private var centralGeneration: UInt64?
    private var peripheral: CBPeripheral?
    private var peripheralDelegateProxy: BluetoothRemotePeripheralDelegateProxy?
    private var transmitCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var batteryStatusCharacteristic: CBCharacteristic?
    private var batteryLevelNeedsPolling = false
    private var batteryStatusNeedsPolling = false
    private var batteryRefreshWorkItem: DispatchWorkItem?
    private var batteryPollingActive = false
    private var hasObservedBatteryLevel = false
    private var lastObservedBatteryLevel: Int?
    private var hasObservedPowerState = false
    private var lastObservedPowerState: RemotePowerState?
    private var subscribedUUIDs = Set<CBUUID>()
    private var scanSubscription: UUID?
    private let scanWatchdog = BluetoothScanWatchdog()
    private let reconnectWakeMonitor = BluetoothReconnectWakeMonitor()
    private var remoteWakeStartedAt: TimeInterval?
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var initializationTimeoutWorkItem: DispatchWorkItem?
    private let disconnectWatchdog = BluetoothDisconnectWatchdog()
    private var capabilitiesRequested = false
    private var capabilitiesConfirmed = false
    private var modelFormatResolved = false
    private var requestedReconnectDelay: TimeInterval?
    private var reconnectPolicy = BluetoothReconnectPolicy()
    private var currentAttemptUsesCachedTarget = false
    private var generationCounter: UInt64 = 0
    private var lifecycle: BluetoothLifecyclePhase = .stopped
    private var shouldRun = false
    private var systemSuspension = BluetoothSystemSuspensionState()
    private var capabilities = BluetoothRemoteBridge.defaultCapabilities
    private let audioDecoder: BluetoothAudioPipeline
    private var voiceStartNotified = false
    private var streaming: Bool { audioDecoder.isStreaming }
    var hasPendingVoiceWork: Bool { audioDecoder.hasPendingVoiceWork || voiceStartNotified }
    private lazy var acknowledgedWrites = AcknowledgedBluetoothWriteQueue(
        send: { [weak self] data in
            guard let self, let peripheral = self.peripheral,
                  let characteristic = self.transmitCharacteristic else { return }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        },
        onFailure: { [weak self] in
            guard let self else { return }
            self.cancelMicrophoneCloseWatchdog()
            self.microphoneClosePending = false
            self.microphoneCloseSessionID = nil
            self.microphoneOpened = false
            self.stopStreaming()
            AppLogger.shared.write("BLE WRITE failed reason=response_or_timeout")
            self.scheduleReconnect()
        }
    )
    private lazy var unacknowledgedWrites = FlowControlledBluetoothWriteQueue(
        canSend: { [weak self] in self?.peripheral?.canSendWriteWithoutResponse == true },
        send: { [weak self] data in
            guard let self, let peripheral = self.peripheral,
                  let characteristic = self.transmitCharacteristic else { return }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        },
        onFailure: { [weak self] in
            guard let self else { return }
            self.cancelMicrophoneCloseWatchdog()
            self.microphoneClosePending = false
            self.microphoneCloseSessionID = nil
            self.microphoneOpened = false
            self.stopStreaming()
            AppLogger.shared.write("BLE WRITE failed reason=flow_control_timeout")
            self.scheduleReconnect()
        }
    )
    // This is a requested-open flag; ATVV stream notifications establish actual streaming.
    private var microphoneOpened = false
    private var microphoneClosePending = false
    private var microphoneCloseSessionID: UInt8?
    private var microphoneCloseWatchdog: ScheduledOperation?
    private let scheduleMicrophoneClose: OperationScheduler
    private var microphoneCloseWatchdogToken: UUID?
    private var cancelledMicrophoneOpenAt: TimeInterval?
    private var sessionID: UInt8 = 0
    private var activeStreamSessionID: UInt8?
    private var lastStopAt: TimeInterval?

    var isMicrophoneClosePending: Bool { microphoneClosePending }
    var isMicrophoneOpen: Bool { microphoneOpened }

    func simulateMicrophoneOpenedForTesting(_ opened: Bool) {
        microphoneOpened = opened
    }

    func simulateStreamStopForTesting() {
        handleRemoteStreamStop()
    }

    func simulateLocalStopStreamingForTesting() {
        stopStreaming()
    }

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let batteryLevelStatusUUID = CBUUID(string: "2BED")
    private let deviceInformationServiceUUID = CBUUID(string: "180A")
    private let modelNumberUUID = CBUUID(string: "2A24")
    private let pnpIDUUID = CBUUID(string: "2A50")
    private let firmwareRevisionUUID = CBUUID(string: "2A26")

    var deviceIdentifier: UUID? {
        peripheral?.identifier ?? targetIdentifier
    }

    /// Pin a discovery bridge to its verified device before it becomes a registered bridge.
    /// This identity survives peripheral teardown and must bypass discovery exclusions.
    @discardableResult
    func bindVerifiedIdentity(_ identifier: UUID) -> Bool {
        guard targetIdentifier == nil || targetIdentifier == identifier else { return false }
        targetIdentifier = identifier
        return true
    }

    func acceptsCandidateIdentifier(_ identifier: UUID) -> Bool {
        guard !rejectedIdentifiers.contains(identifier) else { return false }
        if let targetIdentifier { return identifier == targetIdentifier }
        return !excludedIdentifiers().contains(identifier)
    }

    /// Refresh the system snapshot without changing the bridge's connection or audio state.
    func currentSystemDeviceName() -> String? {
        guard shouldRun, let central, central.state == .poweredOn,
              let peripheral, case .ready = lifecycle
        else { return nil }
        return central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .first(where: { $0.identifier == peripheral.identifier })?.name
    }

    /// Re-read optional battery characteristics without changing connection or audio state.
    func refreshBatteryTelemetry(reason: String) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              lifecycle.isReady,
              let peripheral,
              peripheral.state == .connected
        else { return }
        requestBatteryTelemetryRefresh(
            peripheral: peripheral,
            reason: reason,
            pollingOnly: false
        )
    }

    fileprivate func handleNameUpdate(peripheral: CBPeripheral, generation: UInt64) {
        guard shouldRun, isCurrent(peripheral), lifecycle == .ready(generation) else { return }
        delegate?.bluetoothBridgeDeviceNameDidChange(self)
    }

    private(set) var state: BluetoothBridgeState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.bluetoothBridge(self, didChange: state)
        }
    }

    init(
        settings: AppSettings,
        delegate: BluetoothRemoteBridgeDelegate,
        targetIdentifier: UUID? = nil,
        allowsG9N9N: Bool = false,
        audioPipeline: BluetoothAudioPipeline = BluetoothAudioPipeline(),
        scheduleMicrophoneClose: @escaping OperationScheduler = ScheduledOperation.mainQueue,
        excludedIdentifiers: @escaping () -> Set<UUID> = { [] }
    ) {
        self.settings = settings
        self.audioDecoder = audioPipeline
        self.scheduleMicrophoneClose = scheduleMicrophoneClose
        self.allowsG9N9N = allowsG9N9N
        self.delegate = delegate
        self.targetIdentifier = targetIdentifier
        self.excludedIdentifiers = excludedIdentifiers
        super.init()
    }

    isolated deinit {
        // stop() publishes state and requires a live owner. Destruction releases
        // resources directly and never queues work capturing this dying bridge.
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem?.cancel()
        batteryRefreshWorkItem?.cancel()
        microphoneKeepalive?.cancel()
        scanWatchdog.cancel()
        reconnectWakeMonitor.cancel()
        disconnectWatchdog.cancel()
        if let token = scanSubscription {
            SharedBluetoothScanner.shared.unsubscribe(token)
        }
        peripheral?.delegate = nil
        central?.delegate = nil
        if let central, let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func start() {
        shouldRun = true
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            AppLogger.shared.write(
                "BLE SYSTEM_SUSPENSION phase=deferred result=paused reason=bridge_start"
            )
            return
        }
        beginConnectionCycle()
    }

    func stop() {
        shouldRun = false
        reconnectWorkItem?.cancel()
        stopBatteryPolling(reason: "bridge_stopped")
        reconnectPolicy.reset()
        stopScan()
        closeMicrophoneIfNeeded()
        resetSession()
        if let central, let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        // Do not depend on a disconnect callback after powered-off or teardown.
        finishAttempt(reconnectAfter: nil)
        state = .stopped
    }

    func reconnectNow() {
        guard shouldRun else { return }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            AppLogger.shared.write(
                "BLE SYSTEM_SUSPENSION phase=deferred result=paused reason=reconnect_requested"
            )
            return
        }
        _ = systemSuspension.consumeConnectionCycleNeeded()
        reconnectWorkItem?.cancel()
        reconnectPolicy.reset()
        stopScan()
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = 0.1
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            publishReconnectingState()
            central.cancelPeripheralConnection(peripheral)
            startDisconnectTimeout()
            return
        }
        finishAttempt(reconnectAfter: 0.1)
    }

    /// 主动重建本桥的语音链路，重新从发现/连接开始。
    ///
    /// `reason` 是稳定枚举（`system_wake` / `session_activated`），只用于把「系统唤醒」和
    /// 「会话切回前台」两种触发区分开，不参与状态机判定。
    func recoverVoiceLink(reason: String) {
        guard shouldRun else {
            AppLogger.shared.write("BLE RECOVERY phase=skipped cause=bridge_stopped trigger=\(reason)")
            return
        }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            AppLogger.shared.write(
                "BLE RECOVERY phase=deferred cause=system_suspended trigger=\(reason)"
            )
            return
        }
        let centralState = central.map { String($0.state.rawValue) } ?? "none"
        AppLogger.shared.write(
            "BLE RECOVERY phase=requested trigger=\(reason) state=\(String(describing: state)) " +
                "lifecycle=\(String(describing: lifecycle)) " +
                "central_state=\(centralState) " +
                "generation=\(generationCounter)"
        )
        reconnectNow()
    }

    func setSystemSuspended(_ suspended: Bool, reason: String) {
        if suspended {
            guard systemSuspension.suspend(phase: lifecycle) else { return }
            stopBatteryPolling(reason: "system_suspended")
            stopScan()
            if !lifecycle.isReady,
               let central,
               let peripheral,
               peripheral.state != .disconnected {
                requestedReconnectDelay = nil
                lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
                central.cancelPeripheralConnection(peripheral)
            }
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connectionTimeoutWorkItem?.cancel()
            connectionTimeoutWorkItem = nil
            initializationTimeoutWorkItem?.cancel()
            initializationTimeoutWorkItem = nil
            AppLogger.shared.write(
                "BLE SYSTEM_SUSPENSION phase=started result=paused reason=\(reason) " +
                    "lifecycle=\(String(describing: lifecycle)) " +
                    "ready_preserved=\(lifecycle.isReady)"
            )
            return
        }

        guard systemSuspension.resume() else { return }
        if let generation = currentGeneration(), lifecycle.isReady {
            updateBatteryPollingSchedule(generation: generation)
        }
        AppLogger.shared.write(
            "BLE SYSTEM_SUSPENSION phase=completed result=resumed reason=\(reason) " +
                "connection_cycle_needed=\(systemSuspension.connectionCycleNeeded)"
        )
    }

    func resumeConnectionCycleIfNeeded(reason: String) {
        guard shouldRun, !lifecycle.isReady else { return }
        guard systemSuspension.consumeConnectionCycleNeeded() else { return }
        AppLogger.shared.write(
            "BLE SYSTEM_SUSPENSION phase=recovering result=requested reason=\(reason) " +
                "lifecycle=\(String(describing: lifecycle))"
        )
        reconnectNow()
    }

    private func stopScan() {
        scanWatchdog.cancel()
        reconnectWakeMonitor.cancel()
        if let scanSubscription {
            MainActor.assumeIsolated { SharedBluetoothScanner.shared.unsubscribe(scanSubscription) }
        }
        scanSubscription = nil
    }

    private var canRecoverRemoteWake: Bool {
        targetIdentifier != nil && BluetoothReconnectWakePolicy.canRecover(
            phase: lifecycle, shouldRun: shouldRun, suspended: systemSuspension.isSuspended
        )
    }

    /// Called only for activity routed to this saved remote's HID profile.
    func recoverAfterRemoteActivity(reason: String) {
        guard canRecoverRemoteWake, central?.state == .poweredOn else { return }
        AppLogger.shared.write("BLE WAKE RECOVERY trigger=\(reason) phase=\(lifecycle) result=retry_now")
        remoteWakeStartedAt = ProcessInfo.processInfo.systemUptime
        reconnectPolicy.reset()
        startFreshConnectionCycle()
    }

    /// Recreate the central and proxy generation even when the system already
    /// owns the connection: the same CBPeripheral object can survive a retry.
    func recoverSystemConnectedRemote(reason: String) {
        guard canRecoverRemoteWake, let central, central.state == .poweredOn,
              let targetIdentifier,
              let candidate = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
                .first(where: { $0.identifier == targetIdentifier }),
              acceptsCandidateIdentifier(candidate.identifier) else { return }
        let decision = VoiceRemoteAdmission.decide(identifier: candidate.identifier,
            targetIdentifier: targetIdentifier, advertisesVoiceService: true,
            name: candidate.name, advertisedName: nil, allowsG9N9N: allowsG9N9N)
        guard decision.isAdopted else {
            reject(candidate, reason: decision.logReason, source: "wake_system_connected")
            return
        }
        AppLogger.shared.write("BLE WAKE RECOVERY trigger=\(reason) phase=\(lifecycle) result=system_connected")
        remoteWakeStartedAt = ProcessInfo.processInfo.systemUptime
        reconnectPolicy.reset()
        startFreshConnectionCycle()
    }

    private func monitorRemoteWake() {
        guard canRecoverRemoteWake else { return }
        let generation = lifecycle.generation
        reconnectWakeMonitor.arm(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.canRecoverRemoteWake && self.lifecycle.generation == generation
        }, checkConnected: { [weak self] in
            self?.recoverSystemConnectedRemote(reason: "system_connected_poll")
        })
    }

    private func finishRemoteWakeRecovery(result: String) {
        guard let startedAt = remoteWakeStartedAt else { return }
        remoteWakeStartedAt = nil
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        AppLogger.shared.write("BLE WAKE RECOVERY phase=completed result=\(result) elapsed_ms=\(elapsed)")
    }

    private func beginConnectionCycle() {
        guard shouldRun else { return }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            return
        }
        guard central == nil else { return }
        generationCounter &+= 1
        let generation = generationCounter
        lifecycle = .scanning(generation)
        let manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        central = manager
        centralGeneration = generation
        if manager.state == .poweredOn {
            discoverOrScan(using: manager, generation: generation)
        }
    }

    @discardableResult
    func requestMicrophoneOpen() -> Bool {
        guard !systemSuspension.isSuspended else { return false }
        guard let generation = currentGeneration(),
              ATVVSessionGate.canOpenMicrophone(
                  phase: lifecycle,
                  generation: generation,
                  capabilitiesConfirmed: capabilitiesConfirmed,
                  sampleRate: capabilities.sampleRate,
                  microphoneClosePending: microphoneClosePending
              ),
              !microphoneOpened,
              !streaming,
              !microphoneClosePending
        else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_rejected")
            return false
        }
        guard write(ATVVProtocol.microphoneOpen(
            version: capabilities.version,
            codec: capabilities.selectedCodec
        )) else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_write_failed")
            return false
        }
        cancelledMicrophoneOpenAt = nil
        microphoneOpened = true
        AppLogger.shared.write("ATVV MIC_OPEN host_request")
        return true
    }

    @discardableResult
    func requestMicrophoneExtend() -> Bool {
        guard microphoneOpened,
              streaming,
              !microphoneClosePending,
              let command = ATVVProtocol.microphoneExtend(
                  version: capabilities.version,
                  sessionID: sessionID
              ),
              write(command)
        else {
            AppLogger.shared.write("ATVV MIC_EXTEND rejected session=\(sessionID)")
            return false
        }
        AppLogger.shared.write("ATVV MIC_EXTEND request session=\(sessionID)")
        return true
    }

    @discardableResult
    func requestMicrophoneClose() -> Bool {
        guard microphoneOpened || streaming || microphoneClosePending else { return true }
        let currentSession = sessionID
        let cancelledOpenAt = ATVVSessionGate.cancelledOpenUptime(
            microphoneOpened: microphoneOpened,
            streaming: streaming
        )
        let didWrite = write(ATVVProtocol.microphoneClose(
            version: capabilities.version,
            sessionID: currentSession
        ))
        if didWrite {
            microphoneOpened = false
            microphoneClosePending = false
            microphoneCloseSessionID = nil
            cancelMicrophoneCloseWatchdog()
            cancelledMicrophoneOpenAt = cancelledOpenAt
        } else {
            microphoneClosePending = true
            microphoneCloseSessionID = currentSession
            if cancelledMicrophoneOpenAt == nil {
                cancelledMicrophoneOpenAt = cancelledOpenAt
            }
            scheduleMicrophoneCloseWatchdog(for: currentSession)
            AppLogger.shared.write(
                "ATVV MIC_CLOSE write_failed session=\(currentSession) pending=true"
            )
        }
        AppLogger.shared.write(
            "ATVV MIC_CLOSE request session=\(currentSession) written=\(didWrite)"
        )
        return didWrite
    }

    private func scheduleMicrophoneCloseWatchdog(for session: UInt8) {
        guard microphoneCloseWatchdog == nil else { return }
        let generation = currentGeneration()
        let token = UUID()
        microphoneCloseWatchdogToken = token
        microphoneCloseWatchdog = scheduleMicrophoneClose(5) { [weak self] in
            guard let self,
                  self.microphoneClosePending,
                  self.microphoneCloseWatchdogToken == token,
                  self.currentGeneration() == generation,
                  self.microphoneCloseSessionID == session
            else { return }
            AppLogger.shared.write("ATVV MIC_CLOSE timeout reason=close_retry_exhausted session=\(session)")
            self.microphoneOpened = false
            self.microphoneClosePending = false
            self.microphoneCloseSessionID = nil
            self.cancelMicrophoneCloseWatchdog()
            self.stopStreaming()
            self.scheduleReconnect()
        }
    }

    private func cancelMicrophoneCloseWatchdog() {
        microphoneCloseWatchdogToken = nil
        microphoneCloseWatchdog?.cancel()
        microphoneCloseWatchdog = nil
    }

    private func discoverOrScan(using central: CBCentralManager, generation: UInt64) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              self.central === central,
              lifecycle == .scanning(generation),
              central.state == .poweredOn
        else { return }
        resetPeripheral()

        BluetoothDiscoverySequence.run(
            cachedTarget: { () -> CBPeripheral? in
                guard reconnectPolicy.consumeCachedTargetRetrievalPermission(),
                      let identifier = targetIdentifier else { return nil }
                return central.retrievePeripherals(withIdentifiers: [identifier]).first
            },
            connectedCandidates: {
                let candidates = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
                if !candidates.isEmpty {
                    AppLogger.shared.write(
                        "BLE SYSTEM CONNECTED CANDIDATES count=\(candidates.count) names=" +
                            candidates.map { $0.name ?? "unknown" }.joined(separator: ",")
                    )
                }
                return candidates
            },
            adopt: { candidate, source in
                guard acceptsCandidateIdentifier(candidate.identifier) else { return false }
                return adopt(
                    candidate,
                    using: central,
                    generation: generation,
                    source: source.rawValue,
                    advertisesVoiceService: true,
                    advertisedName: nil,
                    usesCachedTarget: source == .cachedTarget
                )
            },
            scan: {
                state = .scanning
                stopScan()
                scanSubscription = MainActor.assumeIsolated {
                    SharedBluetoothScanner.shared.subscribe { [weak self, weak central] advertisement in
                        guard let self, let central, self.central === central,
                              !self.systemSuspension.isSuspended,
                              self.lifecycle == .scanning(generation), self.peripheral == nil,
                              self.acceptsCandidateIdentifier(advertisement.identifier) else { return }
                        let serviceMatch = (advertisement.data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                            .contains(self.serviceUUID) == true
                        let decision = VoiceRemoteAdmission.decide(identifier: advertisement.identifier,
                            targetIdentifier: self.targetIdentifier, advertisesVoiceService: serviceMatch,
                            name: advertisement.name, advertisedName: advertisement.name, allowsG9N9N: self.allowsG9N9N)
                        switch decision {
                        case .adoptSavedIdentity, .adoptRecognizedName: break
                        default: return
                        }
                        guard let candidate = central.retrievePeripherals(withIdentifiers: [advertisement.identifier]).first else { return }
                        _ = self.adopt(candidate, using: central, generation: generation, source: "shared_scan",
                            advertisesVoiceService: serviceMatch, advertisedName: advertisement.name)
                    }
                }
                scanWatchdog.arm(isCurrent: { [weak self, weak central] in
                    guard let self, let central else { return false }
                    return self.shouldRun && !self.systemSuspension.isSuspended &&
                        self.central === central && self.lifecycle == .scanning(generation) &&
                        self.peripheral == nil && central.state == .poweredOn
                }, rediscover: { [weak self, weak central] in
                    guard let self, let central else { return }
                    self.discoverOrScan(using: central, generation: generation)
                })
                AppLogger.shared.write("BLE SCANNING")
                monitorRemoteWake()
            }
        )
    }

    /// 三条发现路径——已保存标识、系统已连接设备、扫描广播——**必须共用这一份判定**。
    /// 分成三份写就会出现「某条路径漏掉/误收」这类只在特定配对状态下复现的缺陷。
    @discardableResult
    private func adopt(
        _ candidate: CBPeripheral,
        using central: CBCentralManager,
        generation: UInt64,
        source: String,
        advertisesVoiceService: Bool,
        advertisedName: String?,
        usesCachedTarget: Bool = false
    ) -> Bool {
        let decision = VoiceRemoteAdmission.decide(
            identifier: candidate.identifier,
            targetIdentifier: targetIdentifier,
            advertisesVoiceService: advertisesVoiceService,
            name: candidate.name,
            advertisedName: advertisedName,
            allowsG9N9N: allowsG9N9N
        )
        switch decision {
        case .adoptSavedIdentity, .adoptRecognizedName:
            googleCandidate = allowsG9N9N && (
                G9N9NProtocol.isCandidateName(advertisedName ?? candidate.name) ||
                settings.remoteDeviceProfiles.contains {
                    $0.bluetoothIdentifier == candidate.identifier && $0.model.isChromecastRemote
                }
            )
            connect(
                candidate,
                using: central,
                generation: generation,
                source: source,
                usesCachedTarget: usesCachedTarget
            )
            return true
        case .ignore:
            return false
        case .rejectForeignProduct, .rejectUnrecognizedName, .rejectUnnamed:
            reject(candidate, reason: decision.logReason, source: source)
            return false
        }
    }

    /// 明确记录并拒绝一台设备，此后本桥不再尝试连接它。
    ///
    /// 必须是显式日志：设备名对不上、名字不认识、根本没拿到名字，这三种情况在没有原因字段的
    /// 日志里长得完全一样，无法二分「为什么这台遥控器没被接管」。
    private func reject(_ candidate: CBPeripheral, reason: String, source: String) {
        guard rejectedIdentifiers.insert(candidate.identifier).inserted else { return }
        AppLogger.shared.write(
            "BLE REJECTED reason=\(reason) source=\(source) name=\(candidate.name ?? "unknown")"
        )
    }

    private func connect(
        _ candidate: CBPeripheral,
        using central: CBCentralManager,
        generation: UInt64,
        source: String,
        usesCachedTarget: Bool = false
    ) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              self.central === central,
              peripheral == nil,
              lifecycle == .scanning(generation)
        else { return }
        stopScan()
        peripheral = candidate
        currentAttemptUsesCachedTarget = usesCachedTarget
        let proxy = BluetoothRemotePeripheralDelegateProxy(generation: generation, owner: self)
        peripheralDelegateProxy = proxy
        candidate.delegate = proxy
        lifecycle = .connecting(generation)
        state = .connecting
        startConnectionTimeout(generation: generation)
        central.connect(candidate, options: nil)
        AppLogger.shared.write("BLE CONNECTING source=\(source) name=\(candidate.name ?? "unknown")")
    }

    private func resetPeripheral() {
        acknowledgedWrites.reset()
        unacknowledgedWrites.reset()
        disconnectWatchdog.cancel()
        stopBatteryPolling(reason: "peripheral_reset")
        deviceInformation = RemoteDeviceInformation()
        peripheral?.delegate = nil
        peripheral = nil
        peripheralDelegateProxy = nil
        requestedReconnectDelay = nil
        transmitCharacteristic = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        batteryCharacteristic = nil
        batteryStatusCharacteristic = nil
        batteryLevelNeedsPolling = false
        batteryStatusNeedsPolling = false
        hasObservedBatteryLevel = false
        lastObservedBatteryLevel = nil
        hasObservedPowerState = false
        lastObservedPowerState = nil
        subscribedUUIDs.removeAll()
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        capabilitiesRequested = false
        capabilitiesConfirmed = false
        modelFormatResolved = false
        googleReadiness = G9N9NReadiness()
        identifiedModel = nil
        reportedHIDIdentity = nil
        capabilities = Self.defaultCapabilities
        currentAttemptUsesCachedTarget = false
        resetSession()
        audioDecoder.reset(peripheral: true)
    }

    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        guard let peripheral else { return false }
        return peripheral === candidate
    }

    private func currentGeneration() -> UInt64? {
        lifecycle.generation
    }

    private func startInitializationTimeout(generation: UInt64) {
        initializationTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.currentGeneration() == generation,
                  self.lifecycle == .discovering(generation) ||
                    self.lifecycle == .awaitingCapabilities(generation)
            else { return }
            self.failInitialization(LocalizedMessage(self.googleCandidate && !self.googleReadiness.identityConfirmed
                ? "google.remote.unconfirmed_identity" : "connection.error.voice_service_timeout"))
        }
        initializationTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func startDisconnectTimeout() {
        guard case let .disconnecting(generation) = lifecycle else { return }
        disconnectWatchdog.arm(isCurrent: { [weak self] in
            self?.shouldRun == true && self?.lifecycle == .disconnecting(generation)
        }, onTimeout: { [weak self] in
            guard let self else { return }
            AppLogger.shared.write("BLE DISCONNECT TIMEOUT")
            self.finishAttempt(reconnectAfter: self.requestedReconnectDelay ?? 0.5)
        })
    }

    private func startConnectionTimeout(generation: UInt64) {
        connectionTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.currentGeneration() == generation,
                  self.lifecycle == .connecting(generation)
            else { return }
            AppLogger.shared.write("BLE CONNECT TIMEOUT")
            self.connectionTimeoutWorkItem = nil
            self.scheduleReconnect(bypassCachedTarget: self.currentAttemptUsesCachedTarget)
        }
        connectionTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func resetSession() {
        cancelMicrophoneCloseWatchdog()
        microphoneClosePending = false
        microphoneCloseSessionID = nil
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        audioDecoder.reset()
        if voiceStartNotified {
            voiceStartNotified = false
            delegate?.bluetoothBridgeDidStopVoice(self)
        }
        microphoneOpened = false
        cancelledMicrophoneOpenAt = nil
        sessionID = 0
        activeStreamSessionID = nil
    }

    private func publishReconnectingState() {
        // Keep the actionable failure visible until the next connection attempt starts.
        if case .failed = state { return }
        state = .reconnecting
    }

    private func scheduleReconnect(bypassCachedTarget: Bool = false) {
        guard shouldRun else { return }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            publishReconnectingState()
            AppLogger.shared.write(
                "BLE RECONNECT deferred reason=system_suspended"
            )
            return
        }
        reconnectWorkItem?.cancel()
        publishReconnectingState()
        let delay = nextAutomaticReconnectDelay(
            bypassCachedTarget: bypassCachedTarget || currentAttemptUsesCachedTarget
        )
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = delay
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
            startDisconnectTimeout()
            return
        }
        finishAttempt(reconnectAfter: delay)
    }

    private func nextAutomaticReconnectDelay(bypassCachedTarget: Bool) -> TimeInterval {
        let delay = reconnectPolicy.nextAutomaticDelay(
            bypassCachedTarget: bypassCachedTarget,
            jitterUnit: Double.random(in: 0 ... 1)
        )
        let cachedIdentifierBypassed = targetIdentifier != nil &&
            !reconnectPolicy.allowsCachedTargetRetrieval
        AppLogger.shared.write(
            "BLE RECONNECT scheduled failure_count=\(reconnectPolicy.consecutiveFailureCount) " +
                "delay_ms=\(Int((delay * 1_000).rounded())) " +
                "cached_identifier_bypassed=\(cachedIdentifierBypassed)"
        )
        return delay
    }

    private func reconnectDelayAfterFailure(bypassCachedTarget: Bool) -> TimeInterval? {
        guard shouldRun else { return nil }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            return 0
        }
        return requestedReconnectDelay ?? nextAutomaticReconnectDelay(
            bypassCachedTarget: bypassCachedTarget
        )
    }

    private func finishAttempt(reconnectAfter delay: TimeInterval?) {
        finishRemoteWakeRecovery(result: "interrupted")
        let finishedGeneration = lifecycle.generation ?? generationCounter
        stopScan()
        requestedReconnectDelay = nil
        resetPeripheral()

        guard shouldRun, let delay else {
            central?.delegate = nil
            central = nil
            centralGeneration = nil
            lifecycle = .stopped
            return
        }

        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            lifecycle = .stopped
            publishReconnectingState()
            AppLogger.shared.write(
                "BLE RECONNECT deferred reason=system_suspended"
            )
            return
        }

        publishReconnectingState()
        lifecycle = .waitingReconnect(finishedGeneration)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.lifecycle == .waitingReconnect(finishedGeneration)
            else { return }
            self.reconnectWorkItem = nil
            self.startFreshConnectionCycle()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        monitorRemoteWake()
    }

    static func controlWriteType(for properties: CBCharacteristicProperties) -> CBCharacteristicWriteType? {
        if properties.contains(.write) { return .withResponse }
        if properties.contains(.writeWithoutResponse) { return .withoutResponse }
        return nil
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        guard peripheral != nil, let transmitCharacteristic else { return false }
        guard let type = Self.controlWriteType(for: transmitCharacteristic.properties) else { return false }
        if type == .withResponse { return acknowledgedWrites.enqueue(data) }
        return unacknowledgedWrites.enqueue(data)
    }

    fileprivate func handleWriteReady(peripheral: CBPeripheral, generation: UInt64) {
        guard shouldRun, isCurrent(peripheral), currentGeneration() == generation else { return }
        unacknowledgedWrites.pump()
        if microphoneClosePending, microphoneCloseSessionID == sessionID {
            _ = requestMicrophoneClose()
        }
    }

    fileprivate func handleWriteResponse(peripheral: CBPeripheral, generation: UInt64,
                                         characteristic: CBCharacteristic, error: Error?) {
        guard shouldRun, isCurrent(peripheral), currentGeneration() == generation,
              characteristic === transmitCharacteristic else { return }
        acknowledgedWrites.acknowledge(success: error == nil)
        if microphoneClosePending, microphoneCloseSessionID == sessionID {
            _ = requestMicrophoneClose()
        }
    }

    private func closeMicrophoneIfNeeded() {
        _ = requestMicrophoneClose()
    }

    private func requestCapabilitiesIfPossible() {
        guard let generation = currentGeneration(),
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        guard transmitCharacteristic != nil,
              let audioCharacteristic,
              let controlCharacteristic,
              subscribedUUIDs.contains(audioCharacteristic.uuid),
              subscribedUUIDs.contains(controlCharacteristic.uuid),
              let peripheral
        else { return }
        guard !capabilitiesRequested else { return }
        capabilitiesRequested = true
        write(ATVVProtocol.getCapabilitiesV10)
        lifecycle = .awaitingCapabilities(generation)
        state = .discovering
        AppLogger.shared.write("ATVV CAPABILITIES requested name=\(peripheral.name ?? "MI RC")")
    }

    private func updateBatteryPollingSchedule(generation: UInt64) {
        let needsPolling = batteryLevelNeedsPolling || batteryStatusNeedsPolling
        guard shouldRun, needsPolling else {
            stopBatteryPolling(reason: "notifications_active")
            return
        }
        guard batteryRefreshWorkItem == nil else { return }
        if !batteryPollingActive {
            batteryPollingActive = true
            AppLogger.shared.write(
                "BLE BATTERY polling_started interval_ms=" +
                    "\(Int((BluetoothBatteryPollingPolicy.interval * 1_000).rounded())) " +
                    "level=\(batteryLevelNeedsPolling) power=\(batteryStatusNeedsPolling)"
            )
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.batteryRefreshWorkItem = nil
            guard self.shouldRun,
                  !self.systemSuspension.isSuspended,
                  self.currentGeneration() == generation,
                  self.lifecycle.isReady,
                  let peripheral = self.peripheral,
                  peripheral.state == .connected
            else {
                self.stopBatteryPolling(reason: "connection_inactive")
                return
            }
            self.requestBatteryTelemetryRefresh(
                peripheral: peripheral,
                reason: "timer",
                pollingOnly: true
            )
            self.updateBatteryPollingSchedule(generation: generation)
        }
        batteryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BluetoothBatteryPollingPolicy.interval,
            execute: work
        )
    }

    private func stopBatteryPolling(reason: String) {
        batteryRefreshWorkItem?.cancel()
        batteryRefreshWorkItem = nil
        guard batteryPollingActive else { return }
        batteryPollingActive = false
        AppLogger.shared.write("BLE BATTERY polling_stopped reason=\(reason)")
    }

    private func requestBatteryTelemetryRefresh(
        peripheral: CBPeripheral,
        reason: String,
        pollingOnly: Bool
    ) {
        var requested: [String] = []
        if let batteryCharacteristic,
           !pollingOnly || batteryLevelNeedsPolling {
            peripheral.readValue(for: batteryCharacteristic)
            requested.append("level")
        }
        if let batteryStatusCharacteristic,
           !pollingOnly || batteryStatusNeedsPolling {
            peripheral.readValue(for: batteryStatusCharacteristic)
            requested.append("power")
        }
        guard !requested.isEmpty else { return }
        AppLogger.shared.write(
            "BLE BATTERY refresh_requested reason=\(reason) " +
                "fields=\(requested.joined(separator: ","))"
        )
    }

    private func handleControl(_ data: Data) {
        let bytes = Array(data)
        guard let opcode = bytes.first,
              let generation = currentGeneration()
        else { return }

        switch opcode {
        case 0x0B:
            guard lifecycle.acceptsCapabilities(generation: generation) else {
                AppLogger.shared.write("ATVV CAPS ignored_stale_phase")
                return
            }
            guard let parsed = ATVVCapabilities.parse(data, allowingLegacyLayout: !googleCandidate) else {
                failInitialization(LocalizedMessage("connection.error.invalid_voice_response"))
                return
            }
            if googleCandidate && !googleReadiness.acceptCapabilities(parsed) {
                rejectUnsupportedAudio(LocalizedMessage("google.remote.unsupported_protocol"))
                return
            }
            deviceInformation.capabilities = parsed
            capabilities = parsed
            AppLogger.shared.write(
                "ATVV CAPS version=\(parsed.version) codec=\(parsed.selectedCodec) frame=\(parsed.frameSize)"
            )
            if !ATVVProtocol.supportsAudio(sampleRate: parsed.sampleRate) ||
                !ATVVProtocol.supportsFrameSize(parsed.frameSize) {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_16khz_codec"))
                return
            }
            capabilitiesConfirmed = true
            finishInitializationIfReady(generation: generation)
        case 0x08:
            guard requestMicrophoneOpen() else {
                AppLogger.shared.write("ATVV MIC_OPEN remote_request_ignored")
                return
            }
            AppLogger.shared.write("ATVV MIC_OPEN remote_request")
        case 0x04:
            if googleCandidate && (bytes.count < 4 || bytes[2] != 0x02) {
                _ = requestMicrophoneClose()
                stopStreaming()
                return
            }
            guard ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate,
                microphoneClosePending: microphoneClosePending
            ) else {
                AppLogger.shared.write("ATVV STREAM_START ignored_not_ready")
                return
            }
            if bytes.count >= 3 {
                let codec = bytes[2]
                capabilities = ATVVCapabilities(
                    version: capabilities.version,
                    codecs: capabilities.codecs,
                    interaction: bytes[1],
                    frameSize: capabilities.frameSize,
                    selectedCodec: codec,
                    sampleRate: codec == 0x02 ? 16_000 : 8_000
                )
            }
            guard ATVVProtocol.supportsAudio(sampleRate: capabilities.sampleRate) else {
                rejectUnsupportedAudio(LocalizedMessage("connection.error.unsupported_8khz_codec"))
                return
            }
            deviceInformation.capabilities = capabilities
            let explicitSessionID: UInt8? = bytes.count >= 4 ? bytes[3] : nil
            let receivedSessionID = explicitSessionID ?? sessionID
            if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
                cancelledAt: cancelledMicrophoneOpenAt
            ) {
                write(ATVVProtocol.microphoneClose(
                    version: capabilities.version,
                    sessionID: receivedSessionID
                ))
                AppLogger.shared.write(
                    "ATVV STREAM_START ignored_cancelled session=\(receivedSessionID)"
                )
                return
            }
            cancelledMicrophoneOpenAt = nil
            if ATVVStreamStartPolicy.shouldReplaceStream(
                isStreaming: streaming,
                activeSessionID: activeStreamSessionID,
                incomingSessionID: explicitSessionID
            ) {
                stopStreaming()
            }
            sessionID = receivedSessionID
            if let explicitSessionID { activeStreamSessionID = explicitSessionID }
            startStreaming()
        case 0x00:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleRemoteStreamStop()
        case 0x0C:
            guard googleCandidate, lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleRemoteStreamStop()
            state = .failed(LocalizedMessage("google.remote.microphone_refused"))
        case 0x0A:
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            guard bytes.count >= 7 else { return }
            let predictorBits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            let predictor = Int(Int16(bitPattern: predictorBits))
            audioDecoder.synchronize(predictor: predictor, stepIndex: Int(bytes[6]))
        default:
            break
        }
    }

    private func finishInitializationIfReady(generation: UInt64) {
        guard ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: capabilitiesConfirmed,
            isGoogleCandidate: googleCandidate,
            googleReady: googleReadiness.isReady,
            modelFormatResolved: modelFormatResolved
        ),
        lifecycle == .awaitingCapabilities(generation), let peripheral else { return }
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        reconnectPolicy.reset()
        currentAttemptUsesCachedTarget = false
        lifecycle = .ready(generation)
        finishRemoteWakeRecovery(result: "ready")
        state = .ready(peripheral.name ?? (googleCandidate ? "G9N9N" : "MI RC"))
    }

    private func scheduleMicrophoneKeepalive() {
        microphoneKeepalive?.cancel()
        guard googleCandidate, streaming, let generation = currentGeneration() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.streaming, self.currentGeneration() == generation else { return }
            _ = self.requestMicrophoneExtend()
            self.scheduleMicrophoneKeepalive()
        }
        microphoneKeepalive = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func startStreaming() {
        guard !systemSuspension.isSuspended || streaming else {
            _ = requestMicrophoneClose()
            return
        }
        guard !streaming else { return }
        let partialFrameBytes = audioDecoder.pendingByteCount
        if partialFrameBytes > 0 {
            AppLogger.shared.write(
                "ATVV FRAME discarded session=\(sessionID) reason=stream_start " +
                    "streaming_before=\(streaming) partial_frame_bytes=\(partialFrameBytes)"
            )
        }
        guard audioDecoder.beginStream(onStart: { [weak self] in
            guard let self else { return }
            self.voiceStartNotified = true
            self.delegate?.bluetoothBridgeDidStartVoice(self)
        }) else { return }
        lastStopAt = nil
        microphoneOpened = true
        scheduleMicrophoneKeepalive()
        AppLogger.shared.write("ATVV STREAM START session=\(sessionID)")
    }

    private func stopStreaming() {
        activeStreamSessionID = nil
        microphoneKeepalive?.cancel()
        microphoneKeepalive = nil
        guard streaming else { return }
        let partialFrameBytes = audioDecoder.pendingByteCount
        audioDecoder.endStream { [weak self] in
            guard let self else { return }
            self.voiceStartNotified = false
            self.delegate?.bluetoothBridgeDidStopVoice(self)
        }
        lastStopAt = ProcessInfo.processInfo.systemUptime
        AppLogger.shared.write(
            "ATVV STREAM STOP session=\(sessionID) partial_frame_bytes=\(partialFrameBytes)"
        )
    }

    private func handleRemoteStreamStop() {
        microphoneOpened = false
        microphoneClosePending = false
        microphoneCloseSessionID = nil
        cancelMicrophoneCloseWatchdog()
        stopStreaming()
    }

    private func handleAudio(_ data: Data) {
        guard let generation = currentGeneration(),
              ATVVSessionGate.canOpenMicrophone(
                phase: lifecycle,
                generation: generation,
                capabilitiesConfirmed: capabilitiesConfirmed,
                sampleRate: capabilities.sampleRate,
                microphoneClosePending: microphoneClosePending
              )
        else {
            AppLogger.shared.write("ATVV AUDIO ignored_not_ready")
            return
        }
        if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledMicrophoneOpenAt
        ) {
            AppLogger.shared.write("ATVV AUDIO ignored_cancelled_open")
            return
        }
        cancelledMicrophoneOpenAt = nil
        if !streaming {
            let receivedAt = ProcessInfo.processInfo.systemUptime
            if let lastStopAt, ATVVSessionGate.shouldIgnoreAudioAfterStop(stoppedAt: lastStopAt, now: receivedAt) {
                let delayMilliseconds = max(
                    0,
                    Int(((receivedAt - lastStopAt) * 1_000).rounded())
                )
                AppLogger.shared.write(
                    "ATVV AUDIO ignored_after_stop session=\(sessionID) " +
                        "delay_ms=\(delayMilliseconds) bytes=\(data.count)"
                )
                return
            }
            startStreaming()
            AppLogger.shared.write("ATVV STREAM implicit_audio_race")
        }

        let accepted = audioDecoder.append(data, frameSize: capabilities.frameSize,
            gainDB: settings.gainDB(forBluetoothIdentifier: deviceIdentifier)) { [weak self] samples in
            guard let self else { return }
            self.delegate?.bluetoothBridge(self, didDecode: samples)
        }
        if !accepted {
            AppLogger.shared.write("ATVV AUDIO rejected reason=decode_backlog")
            _ = requestMicrophoneClose()
            stopStreaming()
        }
    }

    private func rejectUnsupportedAudio(_ message: LocalizedMessage) {
        state = .failed(message)
        closeMicrophoneIfNeeded()
        if streaming {
            stopStreaming()
        } else {
            audioDecoder.reset()
        }
        scheduleReconnect(bypassCachedTarget: true)
    }

    private func failInitialization(_ message: LocalizedMessage) {
        AppLogger.shared.write("BLE INITIALIZATION failed reason=\(message.key)")
        state = .failed(message)
        audioDecoder.reset()
        scheduleReconnect(bypassCachedTarget: true)
    }
}

extension BluetoothRemoteBridge: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, let generation = centralGeneration else { return }
        AppLogger.shared.write(
            "BLE CENTRAL state=\(central.state.rawValue) " +
                "lifecycle=\(String(describing: lifecycle)) " +
                "generation=\(generation)"
        )
        switch central.state {
        case .poweredOn:
            applyCentralRecovery(
                .poweredOn,
                central: central,
                generation: generation
            )
        case .poweredOff:
            applyCentralRecovery(
                .poweredOff,
                central: central,
                generation: generation
            )
            resetPeripheral()
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.off"))
        case .unauthorized:
            applyCentralRecovery(
                .unauthorized,
                central: central,
                generation: generation
            )
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.permission_denied"))
        case .unsupported:
            applyCentralRecovery(
                .unsupported,
                central: central,
                generation: generation
            )
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.unsupported"))
        case .resetting:
            applyCentralRecovery(
                .resetting,
                central: central,
                generation: generation
            )
            resetPeripheral()
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.resetting"))
        case .unknown:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.initializing"))
        @unknown default:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.unavailable"))
        }
    }

    private func applyCentralRecovery(
        _ event: BluetoothCentralRecoveryEvent,
        central: CBCentralManager,
        generation: UInt64
    ) {
        let transition = BluetoothCentralRecoveryPolicy.transition(
            from: lifecycle,
            generation: generation,
            event: event,
            shouldRun: shouldRun
        )
        if transition.shouldCancelScheduledReconnect {
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
        }
        lifecycle = transition.phase
        if transition.shouldReleaseCentral {
            resetPeripheral()
            stopScan()
            central.delegate = nil
            self.central = nil
            centralGeneration = nil
            lifecycle = .stopped
            return
        }
        guard !systemSuspension.isSuspended else {
            if transition.shouldStartFreshConnectionCycle || transition.shouldDiscover {
                systemSuspension.markConnectionCycleNeeded()
            }
            stopScan()
            return
        }
        if transition.shouldStartFreshConnectionCycle {
            startFreshConnectionCycle()
            return
        }
        if transition.shouldDiscover {
            discoverOrScan(using: central, generation: generation)
        }
    }

    private func startFreshConnectionCycle() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            stopScan()
            return
        }
        stopScan()
        central?.delegate = nil
        central = nil
        centralGeneration = nil
        lifecycle = .stopped
        beginConnectionCycle()
    }


    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        guard shouldRun else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidConnect(generation: generation)
        else { return }
        if VoiceRemoteAdmission.rejectsConnectedProduct(name: peripheral.name, allowsG9N9N: allowsG9N9N) {
            reject(peripheral, reason: "foreign_product", source: "did_connect")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard !systemSuspension.isSuspended else {
            systemSuspension.markConnectionCycleNeeded()
            lifecycle = .disconnecting(generation)
            central.cancelPeripheralConnection(peripheral)
            AppLogger.shared.write("BLE CONNECT deferred reason=system_suspended")
            return
        }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        lifecycle = .discovering(generation)
        state = .discovering
        startInitializationTimeout(generation: generation)
        peripheral.discoverServices([
            serviceUUID,
            batteryServiceUUID,
            deviceInformationServiceUUID,
        ])
        AppLogger.shared.write("BLE CONNECTED name=\(peripheral.name ?? "unknown")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidFailToConnect(generation: generation)
        else { return }
        AppLogger.shared.write(
            "BLE CONNECT FAILED " + AppLogger.optionalErrorFields(error)
        )
        let delay = reconnectDelayAfterFailure(
            bypassCachedTarget: currentAttemptUsesCachedTarget
        )
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    private func handleDisconnect(error: Error?) {
        let shouldBypassCachedTarget: Bool
        switch lifecycle {
        case .connecting, .discovering, .awaitingCapabilities:
            shouldBypassCachedTarget = true
        default:
            shouldBypassCachedTarget = false
        }
        AppLogger.shared.write(
            "BLE DISCONNECTED phase=\(lifecycle) " + AppLogger.optionalErrorFields(error)
        )
        let delay = reconnectDelayAfterFailure(
            bypassCachedTarget: shouldBypassCachedTarget || currentAttemptUsesCachedTarget
        )
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }
}

extension BluetoothRemoteBridge {
    fileprivate func handleDiscoveredServices(
        peripheral: CBPeripheral,
        generation: UInt64,
        error: Error?
    ) {
        guard shouldRun,
              !systemSuspension.isSuspended,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if let error {
            if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_service_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .failed(LocalizedMessage("connection.error.voice_service_missing"))
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        peripheral.discoverCharacteristics(
            [transmitUUID, audioUUID, controlUUID],
            for: service
        )
        if let batteryService = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) {
            peripheral.discoverCharacteristics(
                [batteryLevelUUID, batteryLevelStatusUUID],
                for: batteryService
            )
        }
        if let deviceInformationService = peripheral.services?.first(where: {
            $0.uuid == deviceInformationServiceUUID
        }) {
            peripheral.discoverCharacteristics([modelNumberUUID, pnpIDUUID, firmwareRevisionUUID], for: deviceInformationService)
        } else if !googleCandidate {
            modelFormatResolved = true
            finishInitializationIfReady(generation: generation)
        }
    }

    fileprivate func handleDiscoveredCharacteristics(
        peripheral: CBPeripheral,
        generation: UInt64,
        service: CBService,
        error: Error?
    ) {
        let isOptionalService = service.uuid == batteryServiceUUID ||
            service.uuid == deviceInformationServiceUUID
        guard shouldRun,
              (!systemSuspension.isSuspended || lifecycle.isReady),
              isCurrent(peripheral),
              currentGeneration() == generation,
              isOptionalService
                ? lifecycle.acceptsNotificationUpdate(generation: generation)
                : lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if service.uuid == batteryServiceUUID {
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY characteristic_discovery_failed " +
                        AppLogger.errorFields(error)
                )
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            guard let characteristics = service.characteristics else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelUUID }) {
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                let supportsNotifications = characteristic.properties.contains(.notify) ||
                    characteristic.properties.contains(.indicate)
                batteryLevelNeedsPolling = BluetoothBatteryPollingPolicy.shouldPoll(
                    supportsNotifications: supportsNotifications,
                    isNotifying: characteristic.isNotifying
                )
                if supportsNotifications {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelStatusUUID }) {
                batteryStatusCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                let supportsNotifications = characteristic.properties.contains(.notify) ||
                    characteristic.properties.contains(.indicate)
                batteryStatusNeedsPolling = BluetoothBatteryPollingPolicy.shouldPoll(
                    supportsNotifications: supportsNotifications,
                    isNotifying: characteristic.isNotifying
                )
                if supportsNotifications {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            }
            updateBatteryPollingSchedule(generation: generation)
            return
        }
        if service.uuid == deviceInformationServiceUUID {
            if let error {
                if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                    failInitialization(LocalizedMessage("google.remote.pairing_required"))
                    return
                }

                AppLogger.shared.write(
                    "BLE MODEL characteristic_discovery_failed " +
                        AppLogger.errorFields(error)
                )
                if !googleCandidate {
                    modelFormatResolved = true
                    finishInitializationIfReady(generation: generation)
                }
                return
            }
            let characteristics = service.characteristics ?? []
            let hasModelNumber = characteristics.contains(where: { $0.uuid == modelNumberUUID })
            if !hasModelNumber && !googleCandidate {
                modelFormatResolved = true
                finishInitializationIfReady(generation: generation)
            }
            for characteristic in characteristics where
                characteristic.uuid == modelNumberUUID || characteristic.uuid == pnpIDUUID ||
                characteristic.uuid == firmwareRevisionUUID {
                peripheral.readValue(for: characteristic)
            }
            return
        }
        if let error {
            if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case transmitUUID:
                transmitCharacteristic = characteristic
            case audioUUID:
                audioCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case controlUUID:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                continue
            }
        }
        guard transmitCharacteristic != nil,
              audioCharacteristic != nil,
              controlCharacteristic != nil
        else {
            state = .failed(LocalizedMessage("connection.error.voice_channel_incomplete"))
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        requestCapabilitiesIfPossible()
    }

    fileprivate func handleNotificationState(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              (!systemSuspension.isSuspended || lifecycle.isReady),
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsNotificationUpdate(generation: generation)
        else { return }
        let isOptionalCharacteristic = characteristic.uuid == batteryLevelUUID ||
            characteristic.uuid == batteryLevelStatusUUID
        if isOptionalCharacteristic {
            let supportsNotifications = characteristic.properties.contains(.notify) ||
                characteristic.properties.contains(.indicate)
            let needsPolling = BluetoothBatteryPollingPolicy.shouldPoll(
                supportsNotifications: supportsNotifications,
                isNotifying: error == nil && characteristic.isNotifying
            )
            if characteristic.uuid == batteryLevelUUID {
                batteryLevelNeedsPolling = needsPolling
            } else {
                batteryStatusNeedsPolling = needsPolling
            }
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY notification_failed uuid=\(characteristic.uuid.uuidString) " +
                        AppLogger.errorFields(error)
                )
            }
            updateBatteryPollingSchedule(generation: generation)
            return
        }
        if let error {
            if googleCandidate, G9N9NProtocol.requiresPairing(error) {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_subscription_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(bypassCachedTarget: true)
            return
        }
        guard characteristic.uuid == audioUUID || characteristic.uuid == controlUUID else {
            return
        }
        guard characteristic.isNotifying else {
            subscribedUUIDs.remove(characteristic.uuid)
            failInitialization(LocalizedMessage("connection.error.voice_channel_subscription_inactive"))
            return
        }
        subscribedUUIDs.insert(characteristic.uuid)
        requestCapabilitiesIfPossible()
    }

    fileprivate func handleCharacteristicValue(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation
        else { return }
        if let error {
            AppLogger.shared.write(
                "BLE GATT read_failed uuid=\(characteristic.uuid.uuidString) " + AppLogger.errorFields(error)
            )
            if googleCandidate, G9N9NProtocol.requiresPairing(error),
               characteristic.uuid == pnpIDUUID || characteristic.uuid == audioUUID || characteristic.uuid == controlUUID {
                failInitialization(LocalizedMessage("google.remote.pairing_required"))
                return
            }
            if characteristic.uuid == batteryLevelUUID {
                AppLogger.shared.write(
                    "BLE BATTERY read_failed " + AppLogger.errorFields(error)
                )
                hasObservedBatteryLevel = false
                lastObservedBatteryLevel = nil
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            } else if characteristic.uuid == batteryLevelStatusUUID {
                AppLogger.shared.write(
                    "BLE POWER read_failed " + AppLogger.errorFields(error)
                )
                hasObservedPowerState = false
                lastObservedPowerState = nil
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            } else if characteristic.uuid == modelNumberUUID {
                AppLogger.shared.write(
                    "BLE MODEL read_failed " + AppLogger.errorFields(error)
                )
                if !googleCandidate {
                    modelFormatResolved = true
                    finishInitializationIfReady(generation: generation)
                }
            }
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == pnpIDUUID {
            reportedHIDIdentity = RemoteHIDIdentity.fromPnP(data)
            deviceInformation.identity = reportedHIDIdentity
            if googleCandidate {
                guard googleReadiness.acceptIdentity(reportedHIDIdentity) else {
                    failInitialization(LocalizedMessage("google.remote.unconfirmed_identity"))
                    return
                }
                identifiedModel = .chromecastVoiceRemote
                delegate?.bluetoothBridge(self, didIdentifyRemoteModel: .chromecastVoiceRemote)
                finishInitializationIfReady(generation: generation)
            }
            onHIDIdentityUpdate?()
            return
        }
        if characteristic.uuid == firmwareRevisionUUID {
            deviceInformation.firmwareRevision = RemoteDeviceInformation.deviceString(data)
            return
        }
        if characteristic.uuid == batteryLevelUUID {
            let level = data.first.map(Int.init)
            guard !hasObservedBatteryLevel || lastObservedBatteryLevel != level else { return }
            hasObservedBatteryLevel = true
            lastObservedBatteryLevel = level
            AppLogger.shared.write("BLE BATTERY level=\(level.map(String.init) ?? "unknown")")
            delegate?.bluetoothBridge(self, didUpdateBatteryLevel: level)
            return
        }
        if characteristic.uuid == batteryLevelStatusUUID {
            let powerState = RemotePowerState.decodeBatteryLevelStatus(data)
            guard !hasObservedPowerState || lastObservedPowerState != powerState else { return }
            hasObservedPowerState = true
            lastObservedPowerState = powerState
            AppLogger.shared.write(
                "BLE POWER state=\(powerState?.logValue ?? "unavailable")"
            )
            delegate?.bluetoothBridge(self, didUpdatePowerState: powerState)
            return
        }
        if characteristic.uuid == modelNumberUUID {
            deviceInformation.modelNumber = RemoteDeviceInformation.deviceString(data)
            guard let modelNumber = String(data: data, encoding: .utf8) else {
                AppLogger.shared.write("BLE MODEL unreadable")
                if !googleCandidate {
                    modelFormatResolved = true
                    finishInitializationIfReady(generation: generation)
                }
                return
            }
            let normalizedModelNumber = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if googleCandidate {
                AppLogger.shared.write("BLE MODEL observed modelNumber=\(normalizedModelNumber)")
                return
            }

            audioDecoder.configureFormat(lowNibbleFirst: normalizedModelNumber.contains("ARN9"))
            if normalizedModelNumber.contains("ARN9") {
                // ARN9 firmware encodes ADPCM low-nibble-first; flipping the
                // default high-first order is required for intelligible audio.
                AppLogger.shared.write("BLE MODEL ARN9 adpcm=low-nibble-first")
            }
            modelFormatResolved = true
            if let model = RemoteModel.identified(by: modelNumber) {
                // 原始型号串必须一起记：广播名与型号**不是**一一对应（本机这台广播名是
                // 「小米蓝牙语音遥控器」，DIS 报的却是 RC003），只有原始串能支撑型号目录。
                AppLogger.shared.write(
                    "BLE MODEL identified=\(model.rawValue) modelNumber=\(normalizedModelNumber)"
                )
                identifiedModel = model
                delegate?.bluetoothBridge(self, didIdentifyRemoteModel: model)
            } else {
                AppLogger.shared.write("BLE MODEL unrecognized modelNumber=\(normalizedModelNumber)")
            }
            finishInitializationIfReady(generation: generation)
            return
        }
        if characteristic.uuid == controlUUID {
            guard lifecycle.acceptsCapabilities(generation: generation) ||
                    lifecycle.acceptsProtocolData(generation: generation)
            else { return }
            handleControl(data)
        } else if characteristic.uuid == audioUUID {
            guard lifecycle.acceptsProtocolData(generation: generation) else { return }
            handleAudio(data)
        }
    }
}
