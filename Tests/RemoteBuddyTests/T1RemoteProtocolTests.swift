import Foundation
import Testing
@testable import RemoteBuddy

@Suite("T1-Remote protocol, HID mapping, and admission")
struct T1RemoteProtocolTests {
    @Test func decodesFrontButtonsAndVoiceHoldAcrossReportsWithoutSeizure() {
        // Report 1: OK (0x28), Voice hold (0xAA), and modified QWERTY chord (Shift + A).
        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([RemoteButton.ok.hidUsage], voiceHoldPressed: false))

        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([], voiceHoldPressed: true))

        // Back QWERTY keys (plain or modified) pass straight through without hijacking button actions.
        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([], voiceHoldPressed: false))
        #expect(T1RemoteProtocol.decodeHIDReport(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x02, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00])
        ) == .usages([], voiceHoldPressed: false))

        // Report 2: Consumer Control keys and neutral AC Search (0x0221).
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0x24, 0x02])) == [RemoteButton.back.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0x23, 0x02])) == [RemoteButton.home.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0xE2, 0x00])) == [RemoteButton.mute.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0xE9, 0x00])) == [RemoteButton.volumeUp.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0xEA, 0x00])) == [RemoteButton.volumeDown.hidUsage])
        #expect(T1RemoteProtocol.usages(reportID: 2, data: Data([0x02, 0x21, 0x02])) == [])

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

        // Holding OK stays active while air-mouse reports arrive.
        monitor.handleSimulatedT1Report(reportID: 1, data: Data([0x01, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00]))
        #expect(active == [.ok])
        monitor.handleSimulatedT1Report(reportID: 4, data: Data([0x04, 0x00, 0x04, 0xFF, 0x00]))
        #expect(active == [.ok])
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
        // Foreign ATVV products remain rejected even with T1 onboarding fallback.
        for foreign in ["RemoteG10", "G10", "Chromecast Remote", "Chromecast"] {
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

        mapper.restore()
        #expect(t1Mappings.isEmpty)
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

    @Test func t1DevicesSkipHIDSeizureToPreserveKeyboardAndAirMouse() {
        #expect(!HIDRemoteMonitor.shouldAttemptSeizure(isT1Device: true))
        #expect(HIDRemoteMonitor.shouldAttemptSeizure(isT1Device: false))
    }

    @Test @MainActor func t1ReportUsageStateTracksHeldButtonsIndependentlyPerReport() {
        var state = T1ReportUsageState()
        #expect(state.update(reportID: T1RemoteProtocol.keyboardReportID, usages: [0x4F]) == [0x4F])
        #expect(state.update(reportID: T1RemoteProtocol.consumerReportID, usages: [0xE9]) == [0x4F, 0xE9])
        #expect(state.update(reportID: T1RemoteProtocol.consumerReportID, usages: []) == [0x4F])
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

        // Hold Right Arrow on Report 1, then press & release Vol+ on Report 2, then release Right Arrow on Report 1.
        monitor.handleSimulatedT1Report(
            reportID: T1RemoteProtocol.keyboardReportID,
            data: Data([0x01, 0x00, 0x00, 0x4F, 0x00, 0x00, 0x00, 0x00, 0x00])
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
            [.right],
            [.right, .volumeUp],
            [.right],
            [],
        ])
    }
}
