import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("G9N9N Enter chord")
struct G9N9NEnterChordTests {
    @Test @MainActor func eachDirectionAndRepeatedReportsProduceIndependentTaps() throws {
        let name = "g9n9n-chord-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingStep = .complete
        var actions: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: UUID(),
            runtimePermissions: { true }, actionPerformer: { _, _, configured in
                actions.append(configured.action); return true
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: UUID())
        defer { monitor.disconnectSimulatedDevice() }
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        for index: UInt8 in [3, 4, 5, 6, 3] {
            monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, index]), descriptor: descriptor)
        }
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 3, 7]), descriptor: descriptor)
        #expect(actions == Array(repeating: .returnKey, count: 6))
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 0, 0]), descriptor: descriptor)
        #expect(actions.count == 6)
        settings.customMappingEnabled = false
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        #expect(actions.count == 6)
    }

    @Test @MainActor func chordRequiresExclusiveDeviceAndDoesNotTriggerDuringSetup() throws {
        let name = "g9n9n-chord-safety-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingStep = .complete
        var actions: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: UUID(),
            runtimePermissions: { true }, actionPerformer: { _, _, configured in
                actions.append(configured.action); return true
            }, diagnosticLogger: { _ in })
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: UUID(), isSeized: false)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        #expect(actions.isEmpty)
        monitor.disconnectSimulatedDevice()
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: UUID())
        settings.onboardingStep = .controls
        settings.onboardingControlSource = .chromecastRemote
        monitor.onButtonPressed = { profile, _, _ in profile.map { ($0, false) } }
        var observed = Set<RemoteButton>()
        monitor.onActiveButtons = { _, buttons in observed.formUnion(buttons) }
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 3]), descriptor: descriptor)
        #expect(actions.isEmpty)
        #expect(observed == [.ok, .up])
        monitor.disconnectSimulatedDevice()
    }

    @Test func onlyOkWithOneDirectionIsAChord() {
        let ok = RemoteButton.ok.hidUsage
        #expect(!G9N9NProtocol.isEnterChord([ok]))
        #expect(!G9N9NProtocol.isEnterChord([ok, RemoteButton.back.hidUsage]))
        #expect(!G9N9NProtocol.isEnterChord([RemoteButton.up.hidUsage, RemoteButton.down.hidUsage]))
        #expect(!G9N9NProtocol.isEnterChord([ok, RemoteButton.up.hidUsage, RemoteButton.down.hidUsage]))
    }

    @Test func workaroundRequiresGoogleProtocolAndTheIndexedReportLayout() {
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        #expect(G9N9NProtocol.usesChordWorkaround(isGoogleProtocol: true, reportID: 1, descriptor: descriptor))
        #expect(!G9N9NProtocol.usesChordWorkaround(isGoogleProtocol: false, reportID: 1, descriptor: descriptor))
        #expect(!G9N9NProtocol.usesChordWorkaround(isGoogleProtocol: true, reportID: 2, descriptor: descriptor))
        #expect(!G9N9NProtocol.usesChordWorkaround(isGoogleProtocol: true, reportID: 1, descriptor: nil))
        #expect(!G9N9NProtocol.usesChordWorkaround(isGoogleProtocol: true, reportID: 1, descriptor: Data([0])))
    }

    @Test @MainActor func unsupportedDirectionPairsDoNotStartHeldActions() throws {
        let name = "g9n9n-other-pair-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingStep = .complete
        var actions: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: UUID(),
            runtimePermissions: { true }, actionPerformer: { _, _, configured in
                actions.append(configured.action); return true
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: UUID())
        defer { monitor.disconnectSimulatedDevice() }
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 7, 4]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 5, 4]), descriptor: descriptor)
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 6, 5]), descriptor: descriptor)
        #expect(actions == [.returnKey])
    }

    @Test @MainActor func otherReportLayoutsKeepTheirConfiguredActions() throws {
        let name = "g9n9n-isolation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.onboardingStep = .complete
        settings.setAction(.escape, for: .ok)
        settings.setAction(.deleteBackward, for: .up)
        var actions: [ButtonAction] = []
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { _, _, configured in
                actions.append(configured.action); return true
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "other", profileID: profile)
        defer { monitor.disconnectSimulatedDevice() }
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x41, 0, 0x42, 0]))
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0, 0]))
        #expect(Set(actions) == [.escape, .deleteBackward])
        monitor.disconnectSimulatedDevice()
        actions.removeAll()
        monitor.connectSimulatedDevice(fingerprint: "xiaomi", profileID: profile)
        let ok = RemoteButton.ok.hidUsage, up = RemoteButton.up.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([
            UInt8(ok & 0xff), UInt8(ok >> 8), UInt8(up & 0xff), UInt8(up >> 8)
        ]))
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(Set(actions) == [.escape, .deleteBackward])
    }
}
