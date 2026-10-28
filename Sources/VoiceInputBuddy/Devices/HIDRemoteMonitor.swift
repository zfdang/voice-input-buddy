import AppKit
import CryptoKit
import Foundation
import IOKit.hid
import IOKit.hidsystem

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    // IOHID callbacks are scheduled on CFRunLoopGetMain().
    MainActor.assumeIsolated {
        guard let context else { return }
        let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.deviceDidMatch(result: result, device: device)
    }
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    // IOHID callbacks are scheduled on CFRunLoopGetMain().
    MainActor.assumeIsolated {
        guard let context else { return }
        let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
        monitor.deviceDidRemove(device: device)
    }
}

private func hidInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    // IOHID callbacks are scheduled on CFRunLoopGetMain().
    MainActor.assumeIsolated {
        guard let context else { return }
        let monitor = Unmanaged<HIDRemoteMonitor>.fromOpaque(context).takeUnretainedValue()
        guard result == kIOReturnSuccess else {
            monitor.reportCallbackRejected(reason: "io_error", result: result, reportLength: reportLength)
            return
        }
        guard let sender else {
            monitor.reportCallbackRejected(reason: "missing_sender", result: result, reportLength: reportLength)
            return
        }
        guard reportLength > 0 else {
            monitor.reportCallbackRejected(reason: "empty_report", result: result, reportLength: reportLength)
            return
        }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        let data = Data(bytes: report, count: reportLength)
        monitor.handleReport(from: device, reportID: reportID, data: data)
    }
}

enum HIDReportRoutingDecision: Equatable {
    case accepted(String)
    case rejected(String)
}

enum HIDDeviceMatchDecision: Equatable {
    case activate(String)
    case probe
    case rejected(String)
}

@MainActor
final class HIDRemoteMonitor {
    private let settings: AppSettings
    private let allowsG9N9N: Bool
    private var currentReportIsGoogle = false
    private var currentReportDescriptor: Data?
    var reportedModel: RemoteModel { currentReportIsGoogle ? .chromecastVoiceRemote : .unknown }
    private let eventSuppressor: KeyboardEventSuppressor
    private let ownsEventSuppressor: Bool
    private let scheduler: HIDRemoteScheduling
    private let permissionPoll: HIDPermissionPoll
    private let nativeSuppressionAvailable: () -> Bool
    private let runtimePermissions: () -> Bool
    private let actionPerformer: (RemoteButton, ButtonTrigger, ConfiguredButtonAction) -> Bool
    private let nativeKeyStatePoster: KeyboardInjector.KeyStatePoster
    private let appSwitcherSession: KeyboardInjector.AppSwitcherSession
    private let frontmostBundleIdentifier: () -> String?
    private let diagnosticLogger: (String) -> Void
    private let karabinerElementsInstalled: () -> Bool
    private let targetFingerprint: String?
    private let excludedFingerprints: () -> Set<String>
    private var allowedLocationIDs: Set<UInt32>?
    private var backOnlyMode = false
    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var probedDevices: [IOHIDDevice] = []
    private(set) var deviceFingerprint: String?
    private(set) var profileID: UUID?
    private var activeDeviceIsSeized = false
    private var activeUsages = Set<UInt16>()
    private var nativePassthroughUsages = Set<UInt16>()
    private var usageExpiryTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    private var repeatTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    private var repeatTokens: [UInt16: UUID] = [:]
    private var nonRepeatablePressedButtons = Set<RemoteButton>()
    private var nonRepeatableReleaseTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var gestureRecognizer = RemoteButtonGestureRecognizer()
    private var doubleClickTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var longPressTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    private var permissionPollSubscription: HIDPermissionPoll.Subscription?
    private var appSwitcherTimeout: HIDRemoteScheduledTask?
    private var appSwitcherFrontmostMonitor: HIDRemoteScheduledTask?
    private var appSwitcherConfirmationProbe: HIDRemoteScheduledTask?
    private var appSwitcherOriginBundleIdentifier: String?
    private(set) var status = LocalizedMessage("button_mapping.status.disabled")
    var onStatus: ((LocalizedMessage) -> Void)?
    var onActiveButtons: ((UUID?, Set<RemoteButton>) -> Void)?
    var onButtonPressed: ((UUID?, String, RemoteButton) -> (profileID: UUID, shouldPerformAction: Bool)?)?
    var onRuntimeButton: ((UUID?, RemoteButton, RemoteButtonPhase) -> Bool)?
    var claimsRuntimeButton: ((UUID?, RemoteButton) -> Bool)?
    var onInputReset: ((UUID?) -> Void)?
    var onMonitoringInterrupted: (() -> Void)?
    var onCandidateAvailable: (() -> Void)?
    var onDeviceConnected: ((UUID?, String) -> Void)?
    var isMonitoring: Bool { manager != nil }
    var onInternalAction: ((UUID?, ButtonAction) -> Void)?

    init(
        settings: AppSettings,
        allowsG9N9N: Bool = false,
        profileID: UUID? = nil,
        targetFingerprint: String? = nil,
        excludedFingerprints: @escaping () -> Set<String> = { [] },
        eventSuppressor: KeyboardEventSuppressor = KeyboardEventSuppressor(),
        ownsEventSuppressor: Bool = true,
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionPoll: HIDPermissionPoll = .shared,
        runtimePermissions: @escaping () -> Bool = {
            HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
        },
        nativeSuppressionAvailable: (() -> Bool)? = nil,
        actionPerformer: ((
            RemoteButton,
            ButtonTrigger,
            ConfiguredButtonAction
        ) -> Bool)? = nil,
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        diagnosticLogger: @escaping (String) -> Void = AppLogger.shared.write,
        karabinerElementsInstalled: @escaping () -> Bool = {
            HIDRemoteMonitor.isKarabinerElementsInstalled()
        },
        appSwitcherKeyStatePoster: @escaping KeyboardInjector.KeyStatePoster = KeyboardInjector.postKeyState
    ) {
        self.settings = settings
        self.allowsG9N9N = allowsG9N9N
        self.profileID = profileID
        self.targetFingerprint = targetFingerprint
        self.excludedFingerprints = excludedFingerprints
        self.eventSuppressor = eventSuppressor
        self.ownsEventSuppressor = ownsEventSuppressor
        self.scheduler = scheduler
        self.permissionPoll = permissionPoll
        self.runtimePermissions = runtimePermissions
        self.nativeSuppressionAvailable = nativeSuppressionAvailable ?? { eventSuppressor.isRunning }
        self.nativeKeyStatePoster = appSwitcherKeyStatePoster
        self.appSwitcherSession = KeyboardInjector.AppSwitcherSession(
            keyStatePoster: appSwitcherKeyStatePoster
        )
        self.actionPerformer = actionPerformer ?? { _, _, configured in
            KeyboardInjector.send(
                configured.action,
                shortcut: configured.shortcut,
                applicationProfile: settings.customApplicationProfile(
                    id: configured.applicationProfileID
                )
            )
        }
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.diagnosticLogger = diagnosticLogger
        self.karabinerElementsInstalled = karabinerElementsInstalled
    }

    func assignProfileID(_ profileID: UUID) {
        self.profileID = profileID
    }

    nonisolated static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    nonisolated static var isInputMonitoringGranted: Bool {
        inputMonitoringAccess == kIOHIDAccessTypeGranted
    }

    @discardableResult
    nonisolated static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start(
        powerKeySuppressed: Bool,
        allowedLocationIDs: Set<UInt32>? = nil,
        allowBackOnly: Bool = false
    ) {
        stop()
        self.allowedLocationIDs = allowedLocationIDs
        backOnlyMode = allowBackOnly && !settings.customMappingEnabled
        guard settings.customMappingEnabled || backOnlyMode else {
            updateStatus(LocalizedMessage("button_mapping.status.system_managed"))
            return
        }
        let targetModel = settings.remoteDeviceProfiles.first { $0.id == profileID }?.model
        let families = Self.monitorFamilies(targetModel: targetModel,
            powerKeySuppressed: powerKeySuppressed || backOnlyMode, allowsGoogle: allowsG9N9N)
        let inputGranted = Self.isInputMonitoringGranted
        let accessibilityGranted = KeyboardInjector.isAccessibilityTrusted
        AppLogger.shared.write(
            "HID PERMISSIONS input=\(inputGranted) accessibility=\(accessibilityGranted)"
        )
        guard HIDPermissionGate.canMonitor(
            mappingEnabled: settings.customMappingEnabled || backOnlyMode,
            inputMonitoringGranted: inputGranted,
            accessibilityGranted: accessibilityGranted,
            powerKeySuppressed: families.xiaomi || families.google
        ) else {
            if !inputGranted {
                updateStatus(LocalizedMessage("button_mapping.permission.input_monitoring_required"))
            } else if !accessibilityGranted {
                updateStatus(LocalizedMessage("button_mapping.permission.accessibility_required"))
            } else {
                updateStatus(LocalizedMessage("button_mapping.error.power_suppression_failed"))
                AppLogger.shared.write("HID START rejected power_suppressed=false")
            }
            return
        }

        let matches = Self.deviceMatchingCriteria(
            includeXiaomi: families.xiaomi,
            includeGoogle: families.google,
            additionalIdentities: settings.compatibleHIDIdentities(includeXiaomi: families.xiaomi, includeGoogle: families.google)
        )
        guard !matches.isEmpty else {
            updateStatus(LocalizedMessage("button_mapping.error.power_suppression_failed"))
            return
        }

        if settings.customMappingEnabled {
            let suppressionReady = eventSuppressor.start()
            AppLogger.shared.write("HID FILTER ready=\(suppressionReady)")
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, hidInputReport, context)
        // Matching immediately enumerates already-connected devices. An unopened
        // manager does not forward callbacks registered after that enumeration
        // to existing devices, so install callbacks before setting the matches.
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        // Scheduling/matching discovers devices without opening every interface.
        // Open only a selected/probed device, so its first open can request seizure.
        self.manager = manager
        startPermissionMonitor()
        updateStatus(LocalizedMessage("button_mapping.status.waiting_for_device"))
        AppLogger.shared.write("HID START mode=adaptive")
    }

    isolated deinit { stop() }

    func stop() {
        if ownsEventSuppressor { eventSuppressor.stop() }
        permissionPollSubscription?.cancel()
        permissionPollSubscription = nil
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(
                manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
        }
        resetInputState()
        let closingDeviceCount = probedDevices.count + (activeDevice == nil ? 0 : 1)
        let hasIOKitResources = manager != nil || closingDeviceCount > 0
        defer {
            if hasIOKitResources { diagnosticLogger("HID TEARDOWN phase=completed") }
        }
        if hasIOKitResources {
            diagnosticLogger("HID TEARDOWN phase=begin devices=\(closingDeviceCount) manager=\(manager != nil)")
        }
        probedDevices.forEach {
            IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        probedDevices.removeAll()
        if let activeDevice {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            deviceFingerprint = nil
            activeDeviceIsSeized = false
        }
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else {
            diagnosticLogger("HID DEVICE rejected reason=match_error result=\(result)")
            updateStatus(LocalizedMessage("button_mapping.error.device_open_failed"))
            return
        }
        // HID may become visible after BLE readiness. Retry association outside the
        // matching callback because learning can restart the manager.
        DispatchQueue.main.async { [weak self] in self?.onCandidateAvailable?() }
        currentReportIsGoogle = allowsG9N9N && isGoogleDevice(device)
        guard !isGoogleCandidateIdentity(device) || currentReportIsGoogle else { return }
        guard currentReportIsGoogle || Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger("HID DEVICE rejected reason=unsafe_location")
            return
        }
        switch Self.deviceMatchDecision(
            reportingFingerprint: Self.fingerprint(for: device),
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        ) {
        case let .activate(fingerprint):
            if backOnlyMode {
                probeDevice(device)
            } else {
                _ = activateDevice(device, fingerprint: fingerprint)
            }
        case .probe:
            probeDevice(device)
        case let .rejected(reason):
            diagnosticLogger("HID DEVICE rejected reason=\(reason)")
        }
    }

    private func probeDevice(_ device: IOHIDDevice) {
        guard !probedDevices.contains(where: { CFEqual($0, device) }) else { return }
        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess else {
            let karabinerInstalled = karabinerElementsInstalled()
            updateStatus(Self.deviceOpenFailureMessage(
                result: monitorResult,
                karabinerElementsInstalled: karabinerInstalled
            ))
            if Self.deviceOpenFailureMessageKey(
                result: monitorResult,
                karabinerElementsInstalled: karabinerInstalled
            ) != nil {
                AppLogger.shared.write(
                    "HID DEVICE PROBE BLOCKED reason=exclusive_access " +
                        "karabiner_installed=\(karabinerInstalled) monitor=\(monitorResult)"
                )
            }
            diagnosticLogger("HID DEVICE PROBE FAILED monitor=\(monitorResult)")
            return
        }
        probedDevices.append(device)
        diagnosticLogger("HID DEVICE probing mode=monitored")
    }

    private func promoteProbedDevice(_ device: IOHIDDevice, fingerprint: String) -> Bool {
        guard let selectedIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return false
        }
        let selectedDevice = probedDevices.remove(at: selectedIndex)
        probedDevices.forEach {
            IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        probedDevices.removeAll()
        activeDevice = selectedDevice
        deviceFingerprint = fingerprint
        activeDeviceIsSeized = false
        updateStatus(LocalizedMessage(
            eventSuppressor.isRunning
                ? "button_mapping.status.connected_fallback"
                : "button_mapping.status.connected_system_actions_may_remain"
        ))
        AppLogger.shared.write("HID CONNECTED mode=probed")
        onDeviceConnected?(profileID, fingerprint)
        return true
    }

    @discardableResult
    private func activateDevice(
        _ device: IOHIDDevice,
        fingerprint: String
    ) -> Bool {
        let seizeResult = IOHIDDeviceOpen(
            device,
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
        )
        if seizeResult == kIOReturnSuccess {
            activeDevice = device
            deviceFingerprint = fingerprint
            activeDeviceIsSeized = true
            updateStatus(LocalizedMessage("button_mapping.status.connected"))
            AppLogger.shared.write("HID CONNECTED mode=seized")
            onDeviceConnected?(profileID, fingerprint)
            return true
        }

        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let karabinerInstalled = karabinerElementsInstalled()
        if let exclusiveMessageKey = Self.deviceOpenFailureMessageKey(
            result: monitorResult,
            karabinerElementsInstalled: karabinerInstalled
        ) {
            updateStatus(LocalizedMessage(exclusiveMessageKey))
            AppLogger.shared.write(
                "HID DEVICE OPEN BLOCKED reason=exclusive_access " +
                    "karabiner_installed=\(karabinerInstalled) " +
                    "seize=\(seizeResult) monitor=\(monitorResult)"
            )
            return false
        }
        guard monitorResult == kIOReturnSuccess else {
            updateStatus(LocalizedMessage("button_mapping.error.device_read_failed", arguments: [String(monitorResult)]))
            AppLogger.shared.write(
                "HID DEVICE OPEN FAILED seize=\(seizeResult) monitor=\(monitorResult)"
            )
            return false
        }

        activeDevice = device
        deviceFingerprint = fingerprint
        activeDeviceIsSeized = false
        updateStatus(
            LocalizedMessage(
                eventSuppressor.isRunning
                    ? "button_mapping.status.connected_fallback"
                    : "button_mapping.status.connected_system_actions_may_remain"
            )
        )
        AppLogger.shared.write(
            "HID CONNECTED mode=monitored " +
                AppLogger.errorFields(domain: "io_return", code: Int(seizeResult), fieldPrefix: "seize_error")
        )
        onDeviceConnected?(profileID, fingerprint)
        return true
    }

    fileprivate func deviceDidRemove(device: IOHIDDevice) {
        if let activeDevice, CFEqual(activeDevice, device) {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            deviceFingerprint = nil
            resetInputState()
            activeDeviceIsSeized = false
            updateStatus(LocalizedMessage("button_mapping.status.disconnected"))
            AppLogger.shared.write("HID DISCONNECTED")
            return
        }
        guard let probeIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return
        }
        let probedDevice = probedDevices.remove(at: probeIndex)
        IOHIDDeviceClose(probedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        diagnosticLogger("HID DEVICE probe_removed")
    }

    fileprivate func handleReport(from device: IOHIDDevice, reportID: UInt32, data: Data) {
        guard manager != nil else {
            diagnosticLogger("HID REPORT rejected reason=monitor_inactive")
            return
        }
        guard settings.customMappingEnabled || backOnlyMode else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled")
            return
        }
        currentReportIsGoogle = allowsG9N9N && isGoogleDevice(device)
        currentReportDescriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
        if currentReportIsGoogle {
            let payload = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            diagnosticLogger("HID GOOGLE report id=\(reportID) bytes=\(data.count) payload=\(payload)")
        }
        guard !isGoogleCandidateIdentity(device) || currentReportIsGoogle else { return }
        guard currentReportIsGoogle || Self.isLocationAllowed(
            locationID: Self.locationID(for: device),
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger("HID REPORT rejected reason=unsafe_location")
            return
        }
        let routing = Self.reportRoutingDecision(
            reportingFingerprint: Self.fingerprint(for: device),
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        )
        let fingerprint: String
        switch routing {
        case let .accepted(value):
            fingerprint = value
        case let .rejected(reason):
            diagnosticLogger("HID REPORT rejected reason=\(reason)")
            return
        }
        let discoveryUsages: Set<UInt16>?
        if deviceFingerprint == nil, targetFingerprint == nil {
            guard let usages = parsedUsages(reportID: reportID, data: data, source: "device") else {
                return
            }
            guard Self.shouldPromoteDiscoveryReport(usages: usages) else {
                diagnosticLogger(
                    "HID REPORT deferred reason=discovery_no_known_button source=device " +
                        "id=\(reportID) bytes=\(data.count) usage_count=\(usages.count)"
                )
                return
            }
            discoveryUsages = usages
        } else {
            discoveryUsages = nil
        }
        if deviceFingerprint == nil {
            if !promoteProbedDevice(device, fingerprint: fingerprint) {
                guard activateDevice(
                    device,
                    fingerprint: fingerprint
                ) else {
                    diagnosticLogger("HID REPORT rejected reason=device_activation_failed")
                    return
                }
            }
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked")
            releaseForRevokedPermissions()
            return
        }
        if let discoveryUsages {
            processParsedReport(
                reportID: reportID,
                data: data,
                source: "device",
                usages: discoveryUsages
            )
        } else {
            parseAndProcess(reportID: reportID, data: data, source: "device")
        }
    }

    fileprivate func reportCallbackRejected(
        reason: String,
        result: IOReturn,
        reportLength: CFIndex
    ) {
        diagnosticLogger(
            "HID REPORT callback_rejected reason=\(reason) result=\(result) " +
                "bytes=\(max(0, reportLength))"
        )
    }

    func connectSimulatedDevice(
        fingerprint: String,
        profileID: UUID?,
        isSeized: Bool = true
    ) {
        resetInputState()
        deviceFingerprint = fingerprint
        self.profileID = profileID
        activeDeviceIsSeized = isSeized
        onDeviceConnected?(profileID, fingerprint)
    }

    func handleSimulatedGoogleReport(reportID: UInt32, data: Data, descriptor: Data? = nil) {
        let previous = currentReportIsGoogle
        let previousDescriptor = currentReportDescriptor
        defer {
            currentReportIsGoogle = previous
            currentReportDescriptor = previousDescriptor
        }
        currentReportIsGoogle = true
        currentReportDescriptor = descriptor
        handleSimulatedReport(reportID: reportID, data: data)
    }

    func handleSimulatedReport(reportID: UInt32, data: Data) {
        guard settings.customMappingEnabled || backOnlyMode else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled source=simulated")
            return
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked source=simulated")
            releaseForRevokedPermissions()
            return
        }
        parseAndProcess(reportID: reportID, data: data, source: "simulated")
    }

    func handleSimulatedBackOnlyReport(reportID: UInt32, data: Data) {
        let previousBackOnlyMode = backOnlyMode
        backOnlyMode = true
        defer { backOnlyMode = previousBackOnlyMode }
        handleSimulatedReport(reportID: reportID, data: data)
    }

    private func parseAndProcess(reportID: UInt32, data: Data, source: String) {
        guard let usages = parsedUsages(reportID: reportID, data: data, source: source) else {
            return
        }
        processParsedReport(reportID: reportID, data: data, source: source, usages: usages)
    }

    private func parsedUsages(reportID: UInt32, data: Data, source: String) -> Set<UInt16>? {
        let decoded = currentReportIsGoogle
            ? G9N9NProtocol.usages(reportID: reportID, data: data, descriptor: currentReportDescriptor)
            : RemoteHIDReportParser.usages(reportID: reportID, data: data)
        guard let usages = decoded else {
            diagnosticLogger(
                "HID REPORT rejected reason=parse_failed source=\(source) " +
                    "id=\(reportID) bytes=\(data.count)"
            )
            return nil
        }
        return usages
    }

    private func processParsedReport(
        reportID: UInt32,
        data: Data,
        source: String,
        usages: Set<UInt16>
    ) {
        diagnosticLogger(
            "HID REPORT accepted source=\(source) id=\(reportID) bytes=\(data.count) " +
                "usage_count=\(usages.count) buttons=\(Self.buttonList(for: usages))"
        )
        // The tested indexed G9N9N drops its release reports before IOHID.
        // Treat each complete chord report as a tap, never as a held key.
        // Require exclusive ownership: otherwise the system may also deliver
        // the original buttons, including a down with no corresponding up.
        if currentReportIsGoogle, reportID == 1,
           G9N9NProtocol.usesIndexedConsumerLayout(currentReportDescriptor),
           usages.count > 1, !backOnlyMode,
           !OnboardingControlValidationPolicy.suppressConfiguredActions(
               at: settings.onboardingStep, source: settings.onboardingControlSource
           ) {
            if G9N9NProtocol.isEnterChord(usages) {
                processG9N9NEnterChord()
            } else {
                // Unsupported pairs cannot safely enter the held-button pipeline:
                // their missing release reports otherwise cause eight seconds of repeats.
                resetInputState()
                diagnosticLogger("HID G9N9N chord ignored reason=unsupported_pair")
            }
            return
        }
        if backOnlyMode {
            processBackOnly(usages: usages.intersection([RemoteButton.back.hidUsage]))
        } else {
            process(usages: usages)
        }
    }

    private func processG9N9NEnterChord() {
        resetInputState()
        guard activeDeviceIsSeized else {
            diagnosticLogger("HID G9N9N enter_chord ignored reason=device_not_exclusive")
            return
        }
        if let deviceFingerprint,
           let routing = onButtonPressed?(profileID, deviceFingerprint, .ok) {
            if profileID == nil { profileID = routing.profileID }
            guard routing.shouldPerformAction else { return }
        }
        guard profileID != nil else { return }
        let action = ConfiguredButtonAction(action: .returnKey, shortcut: nil)
        guard actionPerformer(.ok, .singleClick, action) else {
            if !runtimePermissionsAreValid() { releaseForRevokedPermissions() }
            return
        }
        diagnosticLogger("HID G9N9N enter_chord action=return")
    }

    func disconnectSimulatedDevice() {
        deviceFingerprint = nil
        resetInputState()
        activeDeviceIsSeized = false
    }

    private func process(usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        if !pressed.isEmpty || !released.isEmpty {
            diagnosticLogger(
                "HID EDGE pressed=\(Self.buttonList(for: pressed)) " +
                    "released=\(Self.buttonList(for: released))"
            )
        }
        activeUsages = usages
        for usage in released { usageExpiryTimers.removeValue(forKey: usage)?.cancel() }
        for usage in usages { refreshUsageExpiry(usage) }
        onActiveButtons?(profileID, RemoteButton.buttons(for: usages))

        for usage in pressed.sorted() {
            // A failed action may stop/reset the monitor. Do not dispatch further
            // presses from that stale snapshot, but still finish its release edges.
            guard activeUsages == usages else { break }
            guard let button = RemoteButton.usageMap[usage] else { continue }
            let preflightProfileID = profileID
            let preflightRecognizesDoubleClick = settings.configuredAction(
                for: button,
                trigger: .doubleClick,
                profileID: preflightProfileID
            ).action != .disabled
            let preflightRecognizesLongPress = settings.configuredAction(
                for: button,
                trigger: .longPress,
                profileID: preflightProfileID
            ).action != .disabled && !settings.allowsHoldRepeat(for: button, profileID: preflightProfileID)
            let preflightAction = settings.action(for: button, profileID: preflightProfileID)
            let usesNativePassthrough = preflightProfileID != nil &&
                claimsRuntimeButton?(preflightProfileID, button) != true && shouldUseNativePassthrough(
                button: button,
                action: preflightAction,
                recognizesDoubleClick: preflightRecognizesDoubleClick,
                recognizesLongPress: preflightRecognizesLongPress
            )
            if !activeDeviceIsSeized, !usesNativePassthrough {
                eventSuppressor.arm(button: button, edge: .down)
            }
            var shouldPerformAction = true
            if let deviceFingerprint,
               let routing = onButtonPressed?(profileID, deviceFingerprint, button) {
                if profileID == nil {
                    profileID = routing.profileID
                }
                shouldPerformAction = routing.shouldPerformAction
            }
            guard let profileID, shouldPerformAction else {
                if !activeDeviceIsSeized, usesNativePassthrough {
                    eventSuppressor.arm(button: button, edge: .down)
                }
                continue
            }

            // Observing a report is safe without a filter; injecting an additional action
            // is not. Default native arrows retain their one-to-one passthrough path.
            guard mappingDeliveryIsSafe || usesNativePassthrough else {
                pauseForUnavailableNativeFilter()
                continue
            }

            if onRuntimeButton?(profileID, button, .press) == true {
                if !activeDeviceIsSeized, usesNativePassthrough { eventSuppressor.arm(button: button, edge: .down) }
                continue
            }
            let recognizesDoubleClick = settings.configuredAction(
                for: button,
                trigger: .doubleClick,
                profileID: profileID
            ).action != .disabled
            let recognizesLongPress = settings.configuredAction(
                for: button,
                trigger: .longPress,
                profileID: profileID
            ).action != .disabled && !settings.allowsHoldRepeat(for: button, profileID: profileID)
            let action = settings.action(for: button, profileID: profileID)
            if appSwitcherSession.isActive,
               handleAppSwitcherControlPress(button) {
                continue
            }
            if appSwitcherSession.isActive, button == .tv {
                diagnosticLogger(
                    "HID GESTURE button=tv trigger=singleClick path=app_switcher"
                )
                guard performAppSwitcherAction(for: button, trigger: .singleClick) else {
                    continue
                }
                continue
            }
            if appSwitcherSession.isActive, action == .appSwitcher,
               !recognizesDoubleClick, !recognizesLongPress {
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=singleClick " +
                        "path=app_switcher"
                )
                guard performAppSwitcherAction(for: button, trigger: .singleClick) else {
                    continue
                }
                continue
            }
            if appSwitcherSession.isActive, action != .appSwitcher {
                finishAppSwitcherLifecycle(
                    reason: "unrelated_button_\(button.rawValue)",
                    confirmed: false
                )
            }
            if usesNativePassthrough {
                nativePassthroughUsages.insert(usage)
                diagnosticLogger(
                    "HID NATIVE PASSTHROUGH button=\(button.rawValue) action=\(action.rawValue)"
                )
                continue
            }
            if recognizesDoubleClick || recognizesLongPress || gestureRecognizer.isTracking(button) {
                let commands = gestureRecognizer.press(
                    button,
                    recognizesDoubleClick: recognizesDoubleClick,
                    recognizesLongPress: recognizesLongPress
                )
                guard processGestureCommands(commands) else { continue }
            } else {
                guard shouldAcceptRawPress(
                    button: button,
                    action: action,
                    allowsRapidPress: settings.allowsRapidPress(
                        for: button,
                        profileID: profileID
                    ),
                    frontmostBundleIdentifier: frontmostBundleIdentifier()
                ) else {
                    diagnosticLogger(
                        "HID PRESS rejected button=\(button.rawValue) " +
                            "action=\(action.rawValue) reason=awaiting_stable_release " +
                            "stable_release_ms=\(HIDRemoteTiming.stableReleaseMilliseconds)"
                    )
                    continue
                }
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=singleClick path=raw"
                )
                guard performConfiguredAction(for: button, trigger: .singleClick) else { continue }
            }
            startRepeatIfNeeded(usage: usage, button: button, action: action)
        }

        for usage in released {
            let usedNativePassthrough = nativePassthroughUsages.remove(usage) != nil
            if !activeDeviceIsSeized, !usedNativePassthrough,
               let button = RemoteButton.usageMap[usage] {
                eventSuppressor.arm(button: button, edge: .up)
            }
            cancelRepeat(for: usage)
            if let button = RemoteButton.usageMap[usage] {
                if onRuntimeButton?(profileID, button, .release) == true { continue }
                scheduleNonRepeatableRelease(for: button)
                guard processGestureCommands(gestureRecognizer.release(button)) else { continue }
            }
        }
    }

    private func refreshUsageExpiry(_ usage: UInt16) {
        usageExpiryTimers.removeValue(forKey: usage)?.cancel()
        guard let button = RemoteButton.usageMap[usage] else { return }
        usageExpiryTimers[usage] = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.missingReleaseTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.usageExpiryTimers.removeValue(forKey: usage)?.cancel()
            guard self.activeUsages.contains(usage) || self.nonRepeatablePressedButtons.contains(button) else { return }
            self.diagnosticLogger("HID BUTTON recovered reason=missing_release button=\(button.rawValue)")
            self.cancelRepeat(for: usage)
            self.doubleClickTimers.removeValue(forKey: button)?.cancel()
            self.longPressTimers.removeValue(forKey: button)?.cancel()
            self.gestureRecognizer.cancel(button)
            self.finishNonRepeatablePress(button)
            if self.nativePassthroughUsages.remove(usage) != nil {
                for event in button.nativeEvents {
                    if case .keyboard(let code) = event {
                        _ = self.nativeKeyStatePoster(code, false, [])
                    }
                }
            } else if !self.activeDeviceIsSeized {
                self.eventSuppressor.arm(button: button, edge: .up)
            }
            self.activeUsages.remove(usage)
            _ = self.onRuntimeButton?(self.profileID, button, .release)
            self.onActiveButtons?(self.profileID, RemoteButton.buttons(for: self.activeUsages))
        }
    }

    private func processBackOnly(usages: Set<UInt16>) {
        let pressed = usages.subtracting(activeUsages)
        for usage in activeUsages.subtracting(usages) { usageExpiryTimers.removeValue(forKey: usage)?.cancel() }
        activeUsages = usages
        for usage in usages { refreshUsageExpiry(usage) }
        onActiveButtons?(profileID, RemoteButton.buttons(for: usages))
        guard pressed.contains(RemoteButton.back.hidUsage) else { return }
        let configured = ConfiguredButtonAction(action: .deleteBackward, shortcut: nil)
        guard actionPerformer(.back, .singleClick, configured) else {
            if !runtimePermissionsAreValid() { releaseForRevokedPermissions() }
            return
        }
        AppLogger.shared.write(
            "HID BUTTON button=back trigger=singleClick action=deleteBackward path=back_only"
        )
    }

    nonisolated static func acceptsReport(reportingFingerprint: String?, activeFingerprint: String?) -> Bool {
        guard let reportingFingerprint, let activeFingerprint else { return false }
        return reportingFingerprint == activeFingerprint
    }

    nonisolated static func resolvedFingerprintForReport(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> String? {
        switch reportRoutingDecision(
            reportingFingerprint: reportingFingerprint,
            activeFingerprint: activeFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints
        ) {
        case let .accepted(fingerprint): fingerprint
        case .rejected: nil
        }
    }

    nonisolated static func reportRoutingDecision(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> HIDReportRoutingDecision {
        guard let reportingFingerprint else { return .rejected("fingerprint_unavailable") }
        if let activeFingerprint {
            return reportingFingerprint == activeFingerprint
                ? .accepted(activeFingerprint)
                : .rejected("active_fingerprint_mismatch")
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else {
            return .rejected("excluded_fingerprint")
        }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint
                ? .accepted(targetFingerprint)
                : .rejected("target_fingerprint_mismatch")
        }
        return .accepted(reportingFingerprint)
    }

    nonisolated static func deviceMatchDecision(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> HIDDeviceMatchDecision {
        guard let reportingFingerprint else {
            return .rejected("fingerprint_unavailable")
        }
        guard activeFingerprint == nil else {
            return .rejected("active_device_exists")
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else {
            return .rejected("excluded_fingerprint")
        }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint
                ? .activate(targetFingerprint)
                : .rejected("target_mismatch")
        }
        return .probe
    }

    nonisolated static func deviceMatchingCriteria(includeXiaomi: Bool, includeGoogle: Bool,
                                       additionalIdentities: [RemoteHIDIdentity] = []) -> [[String: Any]] {
        // IOHIDManager does not constrain matching by Product name. A name-only
        // dictionary acts as a wildcard and can open unrelated keyboards that
        // another remapper owns, failing the entire manager with exclusive access.
        var matches: [[String: Any]] = []
        if includeXiaomi {
            matches.append([kIOHIDVendorIDKey as String: 0x2717,
                            kIOHIDProductIDKey as String: 0x32B8])
        }
        if includeGoogle {
            matches.append([kIOHIDVendorIDKey as String: G9N9NProtocol.vendorID,
                            kIOHIDProductIDKey as String: G9N9NProtocol.productID])
        }
        var included = Set(matches.compactMap { match -> RemoteHIDIdentity? in
            guard let vendor = match[kIOHIDVendorIDKey] as? Int,
                  let product = match[kIOHIDProductIDKey] as? Int else { return nil }
            return RemoteHIDIdentity(vendorID: UInt16(vendor), productID: UInt16(product))
        })
        for identity in additionalIdentities where identity.vendorID != 0 && included.insert(identity).inserted {
            matches.append(identity.matchingDictionary)
        }
        return matches
    }

    nonisolated static func monitorFamilies(targetModel: RemoteModel?, powerKeySuppressed: Bool,
                                allowsGoogle: Bool) -> (xiaomi: Bool, google: Bool) {
        let xiaomi = powerKeySuppressed && (targetModel == nil || targetModel == .unknown || targetModel == .rc001 || targetModel == .rc003)
        let google = allowsGoogle && (targetModel == nil || targetModel?.isChromecastRemote == true)
        return (xiaomi, google)
    }

    nonisolated static func matchesGoogleProtocol(identity: RemoteHIDIdentity, fingerprint: String,
                                      profiles: [RemoteDeviceProfile]) -> Bool {
        let matching = profiles.filter { $0.model.isChromecastRemote && $0.hidFingerprint == fingerprint }
        if identity == .chromecast, matching.isEmpty { return true }
        return matching.contains { profile in
            (profile.compatibleHIDBinding?.identity == identity &&
             profile.compatibleHIDBinding?.fingerprint == fingerprint) ||
                (profile.compatibleHIDBinding == nil && identity == .chromecast)
        }
    }

    private func isGoogleCandidateIdentity(_ device: IOHIDDevice) -> Bool {
        guard let identity = RemoteHIDIdentity.read(from: device) else { return false }
        return identity == .chromecast || settings.compatibleHIDIdentities(
            includeXiaomi: false, includeGoogle: true).contains(identity)
    }

    private func isGoogleDevice(_ device: IOHIDDevice) -> Bool {
        guard let fingerprint = Self.fingerprint(for: device),
              let identity = RemoteHIDIdentity.read(from: device) else { return false }
        return Self.matchesGoogleProtocol(identity: identity, fingerprint: fingerprint,
            profiles: settings.remoteDeviceProfiles)
    }

    nonisolated static func shouldPromoteDiscoveryReport(usages: Set<UInt16>) -> Bool {
        !RemoteButton.buttons(for: usages).isEmpty
    }

    nonisolated static func deviceOpenFailureMessageKey(
        result: IOReturn,
        karabinerElementsInstalled: Bool
    ) -> String? {
        guard result == kIOReturnExclusiveAccess else { return nil }
        return karabinerElementsInstalled
            ? "button_mapping.error.exclusive_access.karabiner"
            : "button_mapping.error.exclusive_access"
    }

    nonisolated static func isKarabinerElementsInstalled(
        applicationURL: URL? = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.pqrs.Karabiner-Elements"
        ),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        if applicationURL != nil { return true }
        return [
            "/Applications/Karabiner-Elements.app",
            "/Library/Application Support/org.pqrs.Karabiner-Elements",
        ].contains(where: fileExists)
    }

    nonisolated static func isKarabinerElementsRunning(
        bundleIdentifiers: [String] = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    ) -> Bool {
        bundleIdentifiers.contains { identifier in
            let normalized = identifier.lowercased()
            return normalized == "org.pqrs.karabiner-elements" ||
                normalized == "org.pqrs.karabiner-eventviewer" ||
                normalized.hasPrefix("org.pqrs.karabiner.")
        }
    }

    private nonisolated static func deviceOpenFailureMessage(
        result: IOReturn,
        karabinerElementsInstalled: Bool
    ) -> LocalizedMessage {
        if let key = deviceOpenFailureMessageKey(
            result: result,
            karabinerElementsInstalled: karabinerElementsInstalled
        ) {
            return LocalizedMessage(key)
        }
        return LocalizedMessage(
            "button_mapping.error.device_read_failed",
            arguments: [String(result)]
        )
    }

    private nonisolated static func buttonList(for usages: Set<UInt16>) -> String {
        let buttons = usages.compactMap { RemoteButton.usageMap[$0]?.rawValue }.sorted()
        return buttons.isEmpty ? "none" : buttons.joined(separator: ",")
    }

    func shouldAcceptRawPress(
        button: RemoteButton,
        action: ButtonAction,
        allowsRapidPress: Bool = false,
        frontmostBundleIdentifier: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) -> Bool {
        guard !Self.shouldRepeat(
            action: action,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            enabled: settings.allowsHoldRepeat(for: button, profileID: profileID)
        ) else { return true }
        guard !allowsRapidPress else {
            finishNonRepeatablePress(button)
            return true
        }
        if nonRepeatableReleaseTimers[button] != nil {
            finishNonRepeatablePress(button)
        }
        guard nonRepeatablePressedButtons.insert(button).inserted else { return false }
        refreshUsageExpiry(button.hidUsage)
        return true
    }

    nonisolated static func shouldRepeat(
        action: ButtonAction,
        frontmostBundleIdentifier: String?,
        enabled: Bool
    ) -> Bool {
        guard enabled, action != .disabled else { return false }
        guard frontmostBundleIdentifier == PresetApplication.remoteMic.bundleIdentifier else {
            return true
        }
        return ![.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .deleteBackward].contains(action)
    }

    private func shouldUseNativePassthrough(
        button: RemoteButton,
        action: ButtonAction,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool
    ) -> Bool {
        guard !activeDeviceIsSeized,
              !appSwitcherSession.isActive,
              !recognizesDoubleClick,
              !recognizesLongPress,
              settings.allowsHoldRepeat(for: button, profileID: profileID),
              frontmostBundleIdentifier() != PresetApplication.remoteMic.bundleIdentifier
        else { return false }
        return (button == .left && action == .arrowLeft) ||
            (button == .right && action == .arrowRight)
    }

    func scheduleNonRepeatableRelease(for button: RemoteButton) {
        guard nonRepeatablePressedButtons.contains(button) else { return }
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.stableReleaseMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            self?.finishNonRepeatablePress(button)
        }
        nonRepeatableReleaseTimers[button] = timer
    }

    func finishNonRepeatablePress(_ button: RemoteButton) {
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        nonRepeatablePressedButtons.remove(button)
    }

    private func cancelRepeat(for usage: UInt16) {
        repeatTokens.removeValue(forKey: usage)
        repeatTimers.removeValue(forKey: usage)?.cancel()
    }

    private func startRepeatIfNeeded(
        usage: UInt16,
        button: RemoteButton,
        action: ButtonAction
    ) {
        let interval = HIDRemoteTiming.repeatIntervalMilliseconds(for: action)
        guard
            action != .disabled,
            Self.shouldRepeat(
                action: action,
                frontmostBundleIdentifier: frontmostBundleIdentifier(),
                enabled: settings.allowsHoldRepeat(for: button, profileID: profileID)
            )
        else { return }

        cancelRepeat(for: usage)
        let token = UUID()
        repeatTokens[usage] = token
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.repeatStartMilliseconds,
            repeatingEveryMilliseconds: interval
        ) { [weak self] in
            guard let self, self.repeatTokens[usage] == token else { return }
            guard self.activeUsages.contains(usage) else {
                self.cancelRepeat(for: usage)
                return
            }
            let configured = self.settings.configuredAction(
                for: button, trigger: .singleClick, profileID: self.profileID
            )
            if !Self.shouldRepeat(
                    action: configured.action,
                    frontmostBundleIdentifier: self.frontmostBundleIdentifier(),
                    enabled: self.settings.allowsHoldRepeat(for: button, profileID: self.profileID)
                ) {
                self.cancelRepeat(for: usage)
                return
            }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            guard self.mappingDeliveryIsSafe else {
                self.cancelRepeat(for: usage)
                self.pauseForUnavailableNativeFilter()
                return
            }
            // A hold has won over the deferred click; release must not emit another click.
            self.gestureRecognizer.cancel(button)
            self.doubleClickTimers.removeValue(forKey: button)?.cancel()
            self.longPressTimers.removeValue(forKey: button)?.cancel()
            if !self.performConfiguredAction(for: button, trigger: .singleClick) {
                self.cancelRepeat(for: usage)
            }
        }
        repeatTimers[usage] = timer
    }

    private func processGestureCommands(
        _ commands: [RemoteButtonGestureRecognizer.Command]
    ) -> Bool {
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                scheduleDoubleClickTimeout(for: button)
            case let .cancelDoubleClickTimeout(button):
                doubleClickTimers.removeValue(forKey: button)?.cancel()
            case let .scheduleLongPressTimeout(button):
                scheduleLongPressTimeout(for: button)
            case let .cancelLongPressTimeout(button):
                longPressTimers.removeValue(forKey: button)?.cancel()
            case let .trigger(button, trigger):
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=\(trigger.rawValue) path=recognizer"
                )
                guard performConfiguredAction(for: button, trigger: trigger) else { return false }
            }
        }
        return true
    }

    private func scheduleDoubleClickTimeout(for button: RemoteButton) {
        doubleClickTimers.removeValue(forKey: button)?.cancel()
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.doubleClickMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.doubleClickTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.doubleClickTimedOut(button))
        }
        doubleClickTimers[button] = timer
    }

    private func scheduleLongPressTimeout(for button: RemoteButton) {
        longPressTimers.removeValue(forKey: button)?.cancel()
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.longPressMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.longPressTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.longPressTimedOut(button))
        }
        longPressTimers[button] = timer
    }

    private func performConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return false
        }
        guard mappingDeliveryIsSafe else {
            pauseForUnavailableNativeFilter()
            return false
        }
        let configured = settings.configuredAction(
            for: button,
            trigger: trigger,
            profileID: profileID
        )
        if appSwitcherSession.isActive, button == .tv {
            return performAppSwitcherAction(for: button, trigger: trigger)
        }
        if configured.action == .appSwitcher {
            return performAppSwitcherAction(for: button, trigger: trigger)
        }
        if appSwitcherSession.isActive {
            finishAppSwitcherLifecycle(
                reason: "unrelated_action_\(configured.action.rawValue)",
                confirmed: false
            )
        }
        if configured.action.isAppInternal {
            onInternalAction?(profileID, configured.action)
            AppLogger.shared.write(
                "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
            )
            return true
        }
        guard actionPerformer(button, trigger, configured) else {
            diagnosticLogger(
                "HID ACTION failed button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                    "action=\(configured.action.rawValue)"
            )
            // A library rejection is not evidence of revoked Accessibility permission.
            // Preserve the held edge so duplicate reports cannot restart the action.
            if !runtimePermissionsAreValid() {
                releaseForRevokedPermissions()
            }
            return false
        }
        AppLogger.shared.write(
            "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
        )
        return true
    }

    private func performAppSwitcherAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        let wasActive = appSwitcherSession.isActive
        if !wasActive {
            appSwitcherOriginBundleIdentifier = frontmostBundleIdentifier()
        }
        let phase = appSwitcherSession.isActive ? "tab" : "start"
        let submitted = appSwitcherSession.trigger()
        diagnosticLogger(
            "HID APP SWITCHER button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "phase=\(phase) success=\(submitted)"
        )
        if submitted, !wasActive {
            startAppSwitcherLifecycle()
        } else if submitted {
            scheduleAppSwitcherTimeout()
        } else if wasActive {
            finishAppSwitcherLifecycle(reason: "tab_failed", confirmed: false)
        } else {
            appSwitcherOriginBundleIdentifier = nil
        }
        return submitted
    }

    private func handleAppSwitcherControlPress(_ button: RemoteButton) -> Bool {
        switch button {
        case .ok:
            let confirmed = appSwitcherSession.confirm()
            finishAppSwitcherLifecycle(
                reason: confirmed ? "confirmed" : "confirm_failed",
                confirmed: confirmed
            )
            return true
        case .back:
            finishAppSwitcherLifecycle(reason: "back", confirmed: false)
            return true
        case .left, .right:
            let moved = appSwitcherSession.moveSelection(left: button == .left)
            diagnosticLogger(
                "HID APP SWITCHER button=\(button.rawValue) phase=navigate success=\(moved)"
            )
            if !moved {
                finishAppSwitcherLifecycle(reason: "navigate_failed", confirmed: false)
            } else {
                scheduleAppSwitcherTimeout()
            }
            return true
        case .up, .down:
            diagnosticLogger(
                "HID APP SWITCHER button=\(button.rawValue) phase=navigate success=true " +
                    "direction=unsupported"
            )
            return true
        default:
            return false
        }
    }

    private func startAppSwitcherLifecycle() {
        scheduleAppSwitcherTimeout()
        appSwitcherConfirmationProbe?.cancel()
        appSwitcherConfirmationProbe = nil
        appSwitcherFrontmostMonitor?.cancel()
        appSwitcherFrontmostMonitor = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.appSwitcherFrontmostPollMilliseconds
        ) { [weak self] in
            guard let self, self.appSwitcherSession.isActive else { return }
            guard let origin = self.appSwitcherOriginBundleIdentifier,
                  let current = self.frontmostBundleIdentifier(),
                  current != origin
            else { return }
            self.finishAppSwitcherLifecycle(reason: "frontmost_changed", confirmed: false)
        }
    }

    private func scheduleAppSwitcherTimeout() {
        appSwitcherTimeout?.cancel()
        appSwitcherTimeout = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.appSwitcherTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.appSwitcherSession.isActive else { return }
            self.finishAppSwitcherLifecycle(reason: "timeout", confirmed: false)
        }
    }

    private func finishAppSwitcherLifecycle(reason: String, confirmed: Bool) {
        appSwitcherTimeout?.cancel()
        appSwitcherTimeout = nil
        appSwitcherFrontmostMonitor?.cancel()
        appSwitcherFrontmostMonitor = nil
        if appSwitcherSession.isActive {
            _ = appSwitcherSession.cancel()
        }
        diagnosticLogger(
            "HID APP SWITCHER ended reason=\(reason) confirmed=\(confirmed)"
        )
        if confirmed {
            appSwitcherConfirmationProbe?.cancel()
            appSwitcherConfirmationProbe = scheduler.schedule(
                afterMilliseconds: HIDRemoteTiming.appSwitcherConfirmationProbeMilliseconds,
                repeatingEveryMilliseconds: nil
            ) { [weak self] in
                guard let self else { return }
                self.appSwitcherConfirmationProbe = nil
                self.diagnosticLogger(
                    "HID APP SWITCHER selection bundle_id=" +
                        (self.frontmostBundleIdentifier() ?? "unknown")
                )
            }
        }
        appSwitcherOriginBundleIdentifier = nil
    }

    private func resetGestureRecognition() {
        doubleClickTimers.values.forEach { $0.cancel() }
        doubleClickTimers.removeAll()
        longPressTimers.values.forEach { $0.cancel() }
        longPressTimers.removeAll()
        gestureRecognizer.reset()
    }

    func cancelMappingInteractions() { resetInputState() }

    func cancelPendingButtonActions() {
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        repeatTokens.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        resetGestureRecognition()
        if appSwitcherSession.isActive { finishAppSwitcherLifecycle(reason: "common_phrases_opened", confirmed: false) }
    }

    private func resetInputState() {
        onInputReset?(profileID)
        if appSwitcherSession.isActive {
            _ = appSwitcherSession.cancel()
            diagnosticLogger("HID APP SWITCHER cancelled reason=input_reset")
        }
        appSwitcherTimeout?.cancel()
        appSwitcherTimeout = nil
        appSwitcherFrontmostMonitor?.cancel()
        appSwitcherFrontmostMonitor = nil
        appSwitcherConfirmationProbe?.cancel()
        appSwitcherConfirmationProbe = nil
        appSwitcherOriginBundleIdentifier = nil
        if !activeDeviceIsSeized {
            for usage in activeUsages.subtracting(nativePassthroughUsages) {
                if let button = RemoteButton.usageMap[usage] {
                    eventSuppressor.arm(button: button, edge: .up)
                }
            }
        }
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        repeatTokens.removeAll()
        nativePassthroughUsages.removeAll()
        usageExpiryTimers.values.forEach { $0.cancel() }
        usageExpiryTimers.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        resetGestureRecognition()
        activeUsages.removeAll()
        onActiveButtons?(profileID, [])
    }

    private var mappingDeliveryIsSafe: Bool {
        activeDeviceIsSeized || nativeSuppressionAvailable()
    }

    private func pauseForUnavailableNativeFilter() {
        if appSwitcherSession.isActive {
            finishAppSwitcherLifecycle(reason: "native_filter_unavailable", confirmed: false)
        }
        let message = LocalizedMessage("button_mapping.error.filter_unavailable")
        if status != message { updateStatus(message) }
    }

    private func runtimePermissionsAreValid() -> Bool {
        runtimePermissions()
    }

    private func startPermissionMonitor() {
        permissionPollSubscription?.cancel()
        permissionPollSubscription = permissionPoll.subscribe { [weak self] permissionsGranted in
            guard let self, self.manager != nil else { return }
            if !permissionsGranted {
                self.releaseForRevokedPermissions()
            }
        }
    }

    private func releaseForRevokedPermissions() {
        // This may be a shared tap. No monitor can safely filter input after revocation.
        eventSuppressor.stop()
        diagnosticLogger("HID TEARDOWN reason=permission_revoked filter=stopped")
        stop()
        onMonitoringInterrupted?()
        updateStatus(LocalizedMessage("button_mapping.permission.system_expired"))
        AppLogger.shared.write("HID RELEASED permission_revoked")
    }

    nonisolated static func fingerprint(for device: IOHIDDevice) -> String? {
        let keys = ["PhysicalDeviceUniqueID", kIOHIDSerialNumberKey, "DeviceAddress"]
        for key in keys {
            guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? String,
                  !value.isEmpty
            else { continue }
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else {
            return nil
        }
        return SHA256.hash(data: Data("location:\(location.uint64Value)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func locationID(for device: IOHIDDevice) -> UInt32? {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
    }

    nonisolated static func isLocationAllowed(
        locationID: UInt32?,
        allowedLocationIDs: Set<UInt32>?
    ) -> Bool {
        guard let allowedLocationIDs else { return true }
        guard let locationID else { return false }
        return allowedLocationIDs.contains(locationID)
    }

    private func updateStatus(_ value: LocalizedMessage) {
        status = value
        onStatus?(value)
    }
}
