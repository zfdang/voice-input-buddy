import Foundation
import Testing
@testable import RemoteBuddy

@Suite("T1-Remote protocol, HID mapping, and admission")
struct T1RemoteProtocolTests {
    @Test func decodesFrontButtonsAndVoiceHoldAcrossReportsWithoutSeizure() {
        // Report 1: Menu (0x65) stays mapped even when rear modifiers are held;
        // Voice hold (0xAA) sets voiceHoldPressed without entering usages.
        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([RemoteButton.menu.hidUsage], voiceHoldPressed: false))
        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x02, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([RemoteButton.menu.hidUsage], voiceHoldPressed: false))

        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([], voiceHoldPressed: true))

        // Enter (0x28), arrows (0x4F..0x52), and back QWERTY keys (plain or modified) pass straight
        // through natively so customizing buttons never hijacks the rear keyboard's Enter or arrows.
        for passthroughKey: UInt8 in [0x04, 0x28, 0x4F, 0x50, 0x51, 0x52] {
            #expect(T1RemoteProtocol.decodeHIDReport(
                reportID: T1RemoteProtocol.keyboardReportID,
                data: Data([0x01, 0x00, 0x00, passthroughKey, 0x00, 0x00, 0x00, 0x00, 0x00])
            ) == .usages([], voiceHoldPressed: false))
            #expect(T1RemoteProtocol.decodeHIDReport(
                reportID: T1RemoteProtocol.keyboardReportID,
                data: Data([0x01, 0x02, 0x00, passthroughKey, 0x00, 0x00, 0x00, 0x00, 0x00])
            ) == .usages([], voiceHoldPressed: false))
        }

        // Report 2: Consumer Control keys, explicit 0x0000 release, and ignored AC Search (0x0221)
        // so interleaved Search / unknown consumer usages do not clear held volume buttons.
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0x24, 0x02])) == [RemoteButton.back.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0x23, 0x02])) == [RemoteButton.home.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0xE2, 0x00])) == [RemoteButton.mute.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0xE9, 0x00])) == [RemoteButton.volumeUp.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0xEA, 0x00])) == [RemoteButton.volumeDown.hidUsage])
        #expect(T1RemoteProtocol.decodeHIDReport(reportID: 2, data: Data([0x02, 0x21, 0x02])) == .ignore)
        #expect(T1RemoteProtocol.decodeHIDReport(reportID: 2, data: Data([0x02, 0xCD, 0x00])) == .ignore)
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0x00, 0x00])) == [])

        // Report 3: System Control power down bit (0x01 -> RemoteButton.power).
        #expect(T1RemoteProtocol.usages(reportID: 3, data: Data([0x03, 0x01])) == [RemoteButton.power.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 3, data: Data([0x03, 0x00])) == [])

        // Reports 4 (Air Mouse) and 0x5A (Vendor) are ignored without producing errors.
        #expect(T1RemoteProtocol.decodeHIDReport(reportID: 4, data: Data([0x04, 0x00, 0x05, 0xFE, 0x00])) == .ignore)
        #expect(T1RemoteProtocol.decodeHIDReport(reportID: 0x5A, data: Data([0x5A, 0x01, 0x02])) == .ignore)
        #expect(T1RemoteProtocol.decodeHIDReport(reportID: 1, data: Data([0x01, 0x00])) == .invalid)
    }

    @Test @MainActor func airMouseReportsPreserveHeldButtonsAndReport1TracksVoiceHoldRelease() throws {
        let suite = "t1-monitor-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true

        let profileID = UUID()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsT1Remote: true,
            profileID: profileID,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "t1-sim", profileID: profileID)

        var active: Set<RemoteButton> = []
        var voiceHoldEvents: [(UUID?, Bool)] = []
        monitor.onActiveButtons = { _, buttons in active = buttons }
        monitor.onT1VoiceHoldChanged = { id, pressed in voiceHoldEvents.append((id, pressed)) }

        // Holding Menu stays active while air-mouse reports arrive.
        monitor.handleSimulatedT1Report(reportID: 1, data: Data([0x01, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(active == [.menu])
        monitor.handleSimulatedT1Report(reportID: 4, data: Data([0x04, 0x00, 0x04, 0xFF, 0x00]))
        #expect(active == [.menu])
        monitor.handleSimulatedT1Report(reportID: 1, data: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(active.isEmpty)

        // Pressing Voice sends Report 2 (0x0221) + Report 1 (0xAA); a Report 2 release while 0xAA is still held
        // must not prematurely fire voice-hold release.
        monitor.handleSimulatedT1Report(reportID: 2, data: Data([0x02, 0x21, 0x02]))
        monitor.handleSimulatedT1Report(reportID: 1, data: Data([0x01, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00]))
        monitor.handleSimulatedT1Report(reportID: 2, data: Data([0x02, 0x00, 0x00]))
        #expect(voiceHoldEvents.count == 1)
        #expect(voiceHoldEvents.last?.1 == true)

        monitor.handleSimulatedT1Report(reportID: 1, data: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(voiceHoldEvents.count == 2)
        #expect(voiceHoldEvents.last?.1 == false)
        monitor.disconnectSimulatedDevice()
    }

    @Test func admissionAndReadinessSupportClonesWhileProtectingForeignProducts() throws {
        let caps = try #require(ATVVCapabilities.parse(Data([0x0B, 1, 0, 2, 3, 0, 120]), allowingLegacyLayout: false))
        var known = T1RemoteReadiness()
        let knownCapsAccepted = known.acceptCapabilities(caps)
        let knownRejectsXiaomi = known.acceptIdentity(.xiaomi, allowCustomIdentity: true)
        let knownRejectsChromecast = known.acceptIdentity(.chromecast, allowCustomIdentity: true)
        let knownAcceptsT1 = known.acceptIdentity(.t1Remote)
        #expect(knownCapsAccepted)
        #expect(!knownRejectsXiaomi)
        #expect(!knownRejectsChromecast)
        #expect(knownAcceptsT1)
        #expect(known.isReady)

        // OEM/rebranded clones with custom VID/PID are accepted when custom identity admission is active.
        var clone = T1RemoteReadiness()
        let customIdentity = RemoteHIDIdentity(vendorID: 0x1234, productID: 0x5678)
        let cloneCapsAccepted = clone.acceptCapabilities(caps)
        let cloneRejectedWithoutCustom = clone.acceptIdentity(customIdentity, allowCustomIdentity: false)
        let cloneAcceptedWithCustom = clone.acceptIdentity(customIdentity, allowCustomIdentity: true)
        #expect(cloneCapsAccepted)
        #expect(!cloneRejectedWithoutCustom)
        #expect(cloneAcceptedWithCustom)
        #expect(clone.isReady)

        // Foreign VIDs (Xiaomi, Google, Apple across any PID) are rejected even with custom identity admission.
        for foreignVID: UInt16 in [0x2717, 0x18D1, 0x05AC, 0x004C] {
            var rejected = T1RemoteReadiness()
            let foreignCapsAccepted = rejected.acceptCapabilities(caps)
            let foreignIdentityAccepted = rejected.acceptIdentity(
                RemoteHIDIdentity(vendorID: foreignVID, productID: 0x9999),
                allowCustomIdentity: true
            )
            #expect(foreignCapsAccepted)
            #expect(!foreignIdentityAccepted)
            #expect(!rejected.isReady)
        }

        // Custom clone identity gating: denied outside onboarding for newly discovered peripherals,
        // allowed during onboarding or for an already-saved matching T1 profile.
        #expect(!T1RemoteReadiness.shouldAllowCustomIdentity(
            adoptUnidentifiedATVVAsT1: false,
            isTargetedPeripheral: false,
            savedModelIsT1Remote: false,
            savedCustomIdentity: nil,
            reportedIdentity: customIdentity
        ))
        #expect(T1RemoteReadiness.shouldAllowCustomIdentity(
            adoptUnidentifiedATVVAsT1: true,
            isTargetedPeripheral: false,
            savedModelIsT1Remote: false,
            savedCustomIdentity: nil,
            reportedIdentity: customIdentity
        ))
        #expect(T1RemoteReadiness.shouldAllowCustomIdentity(
            adoptUnidentifiedATVVAsT1: false,
            isTargetedPeripheral: true,
            savedModelIsT1Remote: true,
            savedCustomIdentity: customIdentity,
            reportedIdentity: customIdentity
        ))
        #expect(!T1RemoteReadiness.shouldAllowCustomIdentity(
            adoptUnidentifiedATVVAsT1: false,
            isTargetedPeripheral: true,
            savedModelIsT1Remote: true,
            savedCustomIdentity: RemoteHIDIdentity(vendorID: 0x1234, productID: 0x0001),
            reportedIdentity: customIdentity
        ))

        let id = UUID()
        #expect(!VoiceRemoteAdmission.decide(
            identifier: id, targetIdentifier: nil, advertisesVoiceService: true,
            name: "T1-Remote", advertisedName: nil, allowsT1Remote: false
        ).isAdopted)
        #expect(VoiceRemoteAdmission.decide(
            identifier: id, targetIdentifier: nil, advertisesVoiceService: true,
            name: "T1-Remote", advertisedName: nil, allowsT1Remote: true
        ).isAdopted)
        // During explicit T1 onboarding, renamed OEM clones advertising ATVV are admitted as T1.
        #expect(VoiceRemoteAdmission.decide(
            identifier: id, targetIdentifier: nil, advertisesVoiceService: true,
            name: "Bloepum Remote", advertisedName: nil, allowsT1Remote: true, adoptUnidentifiedATVVAsT1: true
        ).isAdopted)
        // Unnamed ATVV peripherals must stay rejected even during T1 onboarding.
        for unnamed in [nil, "", "   "] as [String?] {
            #expect(VoiceRemoteAdmission.decide(
                identifier: id, targetIdentifier: nil, advertisesVoiceService: true,
                name: unnamed, advertisedName: nil, allowsT1Remote: true, adoptUnidentifiedATVVAsT1: true
            ) == .rejectUnnamed)
        }
        // Foreign and non-T1 named ATVV products remain rejected even with T1 onboarding fallback.
        for foreign in ["RemoteG10", "G10", "Chromecast Remote", "Chromecast", "GY3LE", "Google TV Streamer", "Siri Remote", "G9N9N"] {
            #expect(!VoiceRemoteAdmission.decide(
                identifier: id, targetIdentifier: nil, advertisesVoiceService: true,
                name: foreign, advertisedName: nil, allowsT1Remote: true, adoptUnidentifiedATVVAsT1: true
            ).isAdopted)
        }
        // Unrecognized non-T1 names are also rejected when T1 onboarding fallback is inactive.
        for other in ["GY3LE", "Google TV Streamer", "Unrelated microphone"] {
            #expect(!VoiceRemoteAdmission.decide(
                identifier: id, targetIdentifier: nil, advertisesVoiceService: true,
                name: other, advertisedName: nil, allowsT1Remote: true, adoptUnidentifiedATVVAsT1: false
            ).isAdopted)
        }
    }

    @Test func keyMapperNeutralizesSpotlightVoiceKeysAndPowerThenRestores() {
        let suite = "t1-mapper-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var t1Mappings: [HIDUsageMapping] = []
        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                [
                    RemoteHIDMappingService(
                        registryID: 9001,
                        locationID: 77,
                        family: .t1Remote,
                        readMappings: { t1Mappings },
                        setMappings: { updated in t1Mappings = updated; return true }
                    ),
                ]
            },
            recoveryDefaults: defaults,
            bootID: "boot-t1"
        )

        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        #expect(t1Mappings.contains(RemoteHIDKeyMappingPolicy.neutralT1VoiceSearchKey))
        #expect(t1Mappings.contains(RemoteHIDKeyMappingPolicy.neutralT1VoiceHoldKey))
        #expect(t1Mappings.contains(RemoteHIDKeyMappingPolicy.suppressedT1PowerKey))
        #expect(!mapper.needsReapply(suppressPowerKey: true, neutralizeVoiceKey: false))

        // Disabling custom mapping (when native voice key neutralization is inactive) removes all
        // synthetic T1 UserKeyMapping entries instead of leaving 0x0221/0xAA behind.
        #expect(mapper.apply(suppressPowerKey: false, neutralizeVoiceKey: false))
        #expect(!t1Mappings.contains(RemoteHIDKeyMappingPolicy.neutralT1VoiceSearchKey))
        #expect(!t1Mappings.contains(RemoteHIDKeyMappingPolicy.neutralT1VoiceHoldKey))
        #expect(!t1Mappings.contains(RemoteHIDKeyMappingPolicy.suppressedT1PowerKey))
        #expect(!mapper.needsReapply(suppressPowerKey: false, neutralizeVoiceKey: false))

        // Re-apply and test restore()
        #expect(mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: false))
        mapper.restore()
        #expect(t1Mappings.isEmpty)
    }

    @Test func keyMapperRollsBackMixedXiaomiAndT1ServicesWhenT1WriteFails() {
        let suite = "t1-mixed-rollback-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var xiaomiMappings: [HIDUsageMapping] = []
        let t1Mappings: [HIDUsageMapping] = []
        let mapper = RemoteHIDKeyMapper(
            serviceProvider: {
                [
                    RemoteHIDMappingService(
                        registryID: 1001,
                        locationID: 1,
                        family: .xiaomi,
                        readMappings: { xiaomiMappings },
                        setMappings: { updated in xiaomiMappings = updated; return true }
                    ),
                    RemoteHIDMappingService(
                        registryID: 9001,
                        locationID: 2,
                        family: .t1Remote,
                        readMappings: { t1Mappings },
                        setMappings: { _ in false }
                    ),
                ]
            },
            recoveryDefaults: defaults,
            bootID: "boot-mixed"
        )

        #expect(!mapper.apply(suppressPowerKey: true, neutralizeVoiceKey: true))
        #expect(xiaomiMappings.isEmpty)
        #expect(!mapper.isApplied)
        #expect(!mapper.isVoiceKeyNeutralized)
    }

    @Test @MainActor func logsIgnoredT1VendorAndChangedMouseReportsWithoutFlooding() {
        let suite = "t1-ignored-log-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        var logs: [String] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsT1Remote: true,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            diagnosticLogger: { logs.append($0) }
        )

        monitor.handleSimulatedT1Report(reportID: 0x5A, data: Data([0x5A, 0x01, 0x02]))
        monitor.handleSimulatedT1Report(reportID: 0x5A, data: Data([0x5A, 0x01, 0x03]))
        monitor.handleSimulatedT1Report(reportID: 4, data: Data([0x04, 0x00, 0x00, 0x00]))
        monitor.handleSimulatedT1Report(reportID: 4, data: Data([0x04, 0x00, 0x00, 0x00]))
        monitor.handleSimulatedT1Report(reportID: 4, data: Data([0x04, 0x01, 0x00, 0x00]))

        let vendorLogs = logs.filter { $0.contains("HID T1 vendor_report") }
        let mouseLogs = logs.filter { $0.contains("HID T1 mouse_report") }
        #expect(vendorLogs.count == 2)
        #expect(vendorLogs.first?.contains("payload=5A 01 02") == true)
        #expect(mouseLogs.count == 2)
    }

    @Test func t1OnboardingPromptsDistinguishPressReleaseStartAndSecondPressStop() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")

        let t1HoldZh = OnboardingVoiceGesturePrompt.text(
            for: .hold,
            fnTapModeEnabled: false,
            controlSource: .t1Remote,
            locale: zh
        )
        let xiaomiHoldZh = OnboardingVoiceGesturePrompt.text(
            for: .hold,
            fnTapModeEnabled: false,
            controlSource: .xiaomiRemote,
            locale: zh
        )
        #expect(t1HoldZh.contains("按一下") && t1HoldZh.contains("再按一下"))
        #expect(xiaomiHoldZh.contains("按住"))

        let t1TapEn = OnboardingVoiceGesturePrompt.text(
            for: .hold,
            fnTapModeEnabled: true,
            controlSource: .t1Remote,
            locale: en
        )
        let t1HoldEn = OnboardingVoiceGesturePrompt.text(
            for: .hold,
            fnTapModeEnabled: false,
            controlSource: .t1Remote,
            locale: en
        )
        #expect(t1TapEn.contains("Press and release") && t1TapEn.contains("once more"))
        #expect(t1HoldEn.contains("Press and release") && t1HoldEn.contains("holds the voice key"))
    }

    @Test func t1DevicesOpenMonitoredWithoutSeizureAttemptWhileOthersTrySeizeFirst() {
        #expect(!HIDRemoteMonitor.shouldAttemptSeizure(isT1Device: true))
        #expect(HIDRemoteMonitor.shouldAttemptSeizure(isT1Device: false))

        var t1OpenOptions: [IOOptionBits] = []
        let t1Outcome = HIDRemoteMonitor.openDevice(isT1Device: true) { option in
            t1OpenOptions.append(option)
            return kIOReturnSuccess
        }
        #expect(t1OpenOptions == [IOOptionBits(kIOHIDOptionsTypeNone)])
        #expect(t1Outcome == .monitored(seizeAttemptResult: nil))

        var otherOpenOptions: [IOOptionBits] = []
        let fallbackOutcome = HIDRemoteMonitor.openDevice(isT1Device: false) { option in
            otherOpenOptions.append(option)
            return option == IOOptionBits(kIOHIDOptionsTypeSeizeDevice) ? kIOReturnExclusiveAccess : kIOReturnSuccess
        }
        #expect(otherOpenOptions == [
            IOOptionBits(kIOHIDOptionsTypeSeizeDevice),
            IOOptionBits(kIOHIDOptionsTypeNone),
        ])
        #expect(fallbackOutcome == .monitored(seizeAttemptResult: kIOReturnExclusiveAccess))
    }

    @Test @MainActor func t1ReportUsageStateTracksHeldButtonsIndependentlyPerReport() {
        var state = T1ReportUsageState()
        #expect(state.update(reportID: T1RemoteProtocol.keyboardReportID, usages: [0x65]) == [0x65])
        #expect(state.update(reportID: T1RemoteProtocol.consumerReportID, usages: [0xE9]) == [0x65, 0xE9])
        #expect(state.update(reportID: T1RemoteProtocol.consumerReportID, usages: []) == [0x65])
        #expect(state.update(reportID: T1RemoteProtocol.keyboardReportID, usages: []) == [])

        let suite = "t1-per-report-state-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsT1Remote: true,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            diagnosticLogger: { _ in }
        )
        defer { monitor.cancelMappingInteractions() }

        var activeHistory: [Set<RemoteButton>] = []
        monitor.onActiveButtons = { _, buttons in
            activeHistory.append(buttons)
        }

        // Hold Menu on Report 1, then press & release Vol+ on Report 2, then release Menu on Report 1.
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.consumerReportID,
            data: Data([0x02, 0xE9, 0x00])
        )
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.consumerReportID,
            data: Data([0x02, 0x00, 0x00])
        )
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        )

        #expect(activeHistory == [
            [.menu],
            [.menu, .volumeUp],
            [.menu],
            [],
        ])
    }

    @Test @MainActor func t1FirstVoiceReleaseDoesNotCloseActiveToggleStream() throws {
        let suite = "t1-toggle-release-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true

        let bridgeID = UUID()
        let mappings = RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let profile = RemoteDeviceProfile(
            model: .t1Remote,
            bluetoothIdentifier: bridgeID,
            hidFingerprint: "t1-sim",
            mappings: mappings
        )
        settings.remoteDeviceProfiles = [profile]
        settings.selectedRemoteProfileID = profile.id

        var tapEnabled = false
        let suppressor = KeyboardEventSuppressor(
            permissionsGranted: { true },
            tapOperations: .init(
                start: { tapEnabled = true; return true },
                stop: { tapEnabled = false },
                isEnabled: { tapEnabled }
            )
        )
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: [],
            hidEventSuppressor: suppressor,
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { [weak settings] in settings?.onboardingVoiceTool ?? .unselected },
            installMonitor: { _ in NSObject() },
            removeMonitor: { _ in }
        )

        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: model,
            targetIdentifier: bridgeID
        )
        model.connections.bridges[bridgeID] = bridge
        bridge.simulateReadyStateForTesting()
        model.connections.states[ObjectIdentifier(bridge)] = bridge.state
        model.started = true
        defer {
            model.stopHIDMonitors()
            model.preferredInputSourceMonitor.stop()
            model.cancelHIDMappingRecovery(reason: "test_cleanup")
            bridge.stop()
            model.connections.bridges.values.forEach { $0.stop() }
            model.connections.discoveryBridge?.stop()
            model.connections.bridges.removeAll()
            model.connections.states.removeAll()
            model.connections.discoveryBridge = nil
            model.started = false
        }

        model.applyHIDSettings()
        let monitor = try #require(model.hidMonitors["t1-sim"])
        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(bridge.isMicrophoneOpen)

        // Initial Voice press + release in toggle mode must not request MIC_CLOSE.
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
        #expect(bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)
    }

    @Test @MainActor func interleavedReport2SearchPreservesVolumeHoldUntilZeroRelease() throws {
        let suite = "t1-report2-interleave-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true

        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsT1Remote: true,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            diagnosticLogger: { _ in }
        )
        defer { monitor.cancelMappingInteractions() }

        var activeHistory: [Set<RemoteButton>] = []
        monitor.onActiveButtons = { _, buttons in
            activeHistory.append(buttons)
        }

        // Holding Vol+ must survive an interleaved AC Search (0x0221) report until explicit 0x0000 release.
        monitor.handleSimulatedT1Report(reportID: T1RemoteProtocol.consumerReportID, data: Data([0x02, 0xE9, 0x00]))
        monitor.handleSimulatedT1Report(reportID: T1RemoteProtocol.consumerReportID, data: Data([0x02, 0x21, 0x02]))
        monitor.handleSimulatedT1Report(reportID: T1RemoteProtocol.consumerReportID, data: Data([0x02, 0x00, 0x00]))

        #expect(activeHistory == [
            [.volumeUp],
            [],
        ])
    }

    @Test @MainActor func t1IgnoredReportsRefreshHeldExpiryAndCancelEmitsVoiceHoldRelease() throws {
        let suite = "t1-ignored-expiry-reset-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true

        let clock = ControlledTestScheduler()
        let profileID = UUID()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            allowsT1Remote: true,
            profileID: profileID,
            scheduler: clock,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            diagnosticLogger: { _ in }
        )
        defer { monitor.cancelMappingInteractions() }

        var activeHistory: [Set<RemoteButton>] = []
        var voiceHoldEvents: [(UUID?, Bool)] = []
        monitor.onActiveButtons = { _, buttons in activeHistory.append(buttons) }
        monitor.onT1VoiceHoldChanged = { id, held in voiceHoldEvents.append((id, held)) }

        // Hold Menu on Report 1 at t=0.
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
        #expect(activeHistory.last == [.menu])

        // At t=5s, Air Mouse (Report 4, .ignore) arrives and must push out the 8s missing-release deadline.
        clock.advance(to: 5_000)
        monitor.handleSimulatedT1Report(reportID: T1RemoteProtocol.mouseReportID, data: Data([0x04, 0x00, 0x02, 0xFE, 0x00]))

        // Advancing past original t=8s (to t=10s) must keep Menu active.
        clock.advance(to: 10_000)
        #expect(activeHistory.last == [.menu])

        // After 8s of silence following the t=5s ignored frame (t=13.1s), missing-release synthesizes release.
        clock.advance(to: 13_100)
        #expect(activeHistory.last == [])

        // Holding 0xAA Voice followed by cancelMappingInteractions() must emit voiceHold(false).
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])
        )
        #expect(voiceHoldEvents.last?.1 == true)
        monitor.cancelMappingInteractions()
        #expect(voiceHoldEvents.count == 2)
        #expect(voiceHoldEvents.last?.0 == profileID)
        #expect(voiceHoldEvents.last?.1 == false)
    }

    @Test @MainActor func t1ATVVKeepaliveExtendSecondPressWatchdogAndCooldownLifecycle() async throws {
        @MainActor
        final class SpyDelegate: BluetoothRemoteBridgeDelegate {
            var startCount = 0
            var stopCount = 0
            func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didChange state: BluetoothBridgeState) {}
            func bluetoothBridgeDidStartVoice(_ bridge: BluetoothRemoteBridge) { startCount += 1 }
            func bluetoothBridgeDidStopVoice(_ bridge: BluetoothRemoteBridge) { stopCount += 1 }
            func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didDecode samples: [Int16]) {}
            func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdateBatteryLevel level: Int?) {}
            func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didIdentifyRemoteModel model: RemoteModel) {}
            func bluetoothBridge(_ bridge: BluetoothRemoteBridge, didUpdatePowerState state: RemotePowerState?) {}
            func bluetoothBridgeDeviceNameDidChange(_ bridge: BluetoothRemoteBridge) {}
        }

        let suite = "t1-atvv-keepalive-watchdog-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        let clock = ControlledTestScheduler()
        let spy = SpyDelegate()
        let audioQueue = DispatchQueue(label: "t1.atvv.test.audio")
        let audioPipeline = BluetoothAudioPipeline(queue: audioQueue)
        func flushAudio() async {
            await withCheckedContinuation { continuation in
                audioQueue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }

        var writtenCommands: [Data] = []
        let bridge = BluetoothRemoteBridge(
            settings: settings,
            delegate: spy,
            targetIdentifier: UUID(),
            allowsT1Remote: true,
            audioPipeline: audioPipeline,
            scheduleMicrophoneClose: clock.voiceSchedule
        )
        defer { bridge.stop() }
        bridge.testingControlWriteHandler = { data in
            writtenCommands.append(data)
            return true
        }
        bridge.simulateT1ReadyStateForTesting(nowUptime: { Double(clock.now) / 1_000 })

        // Session 1: AUDIO_START (0x04) starts 10s MIC_EXTEND keepalive, capped at 30 extensions (~300s).
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x01]))
        await flushAudio()
        #expect(spy.startCount == 1)

        clock.advance(to: 10_000)
        #expect(writtenCommands == [Data([0x0E, 0x01])])

        // Advance to 310s (extension 30 at 300s fires MIC_EXTEND, then iteration 31 at 310s sends MIC_CLOSE and stops).
        clock.advance(to: 310_000)
        await flushAudio()
        let extendCount = writtenCommands.filter { $0 == Data([0x0E, 0x01]) }.count
        let closeCommands = writtenCommands.filter { $0 == Data([0x0D, 0x01]) }
        #expect(extendCount == 30)
        #expect(closeCommands.count == 1)
        #expect(spy.stopCount == 0)

        // Remote never answered 0x00 within 5s after the capped MIC_CLOSE: streamStopWatchdog fires at 315s.
        clock.advance(to: 315_000)
        await flushAudio()
        #expect(spy.stopCount == 1)
        #expect(!bridge.hasPendingVoiceWork)

        // Cooldown (0.8s for T1) ignores premature audio at +0.4s and accepts audio at +0.9s.
        let stopAtMs = clock.now
        clock.advance(to: stopAtMs + 400)
        bridge.simulateAudioPacketForTesting(Data(repeating: 0x22, count: 20))
        await flushAudio()
        #expect(spy.startCount == 1)

        clock.advance(to: stopAtMs + 900)
        bridge.simulateAudioPacketForTesting(Data(repeating: 0x22, count: 20))
        await flushAudio()
        #expect(spy.startCount == 2)

        // Session 2: AUDIO_START with session 0x02 -> second press 0x08 requests MIC_CLOSE and cancels further keepalive,
        // then unacknowledged close triggers the 5s streamStopWatchdog.
        writtenCommands.removeAll()
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x02]))
        bridge.simulateControlPacketForTesting(Data([0x08]))
        await flushAudio()
        #expect(writtenCommands == [Data([0x0D, 0x02])])
        #expect(spy.stopCount == 1)

        let secondCloseAtMs = clock.now
        clock.advance(to: secondCloseAtMs + 5_100)
        await flushAudio()
        #expect(spy.stopCount == 2)
        #expect(writtenCommands == [Data([0x0D, 0x02])])

        // Session 3: Explicit 0x00 AUDIO_STOP clears stream immediately and cancels watchdog.
        bridge.simulateControlPacketForTesting(Data([0x04, 0x03, 0x02, 0x03]))
        bridge.simulateControlPacketForTesting(Data([0x00]))
        await flushAudio()
        #expect(spy.stopCount == 3)
        #expect(!bridge.hasPendingVoiceWork)
    }
}
