import AppKit
import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Keyboard filter recovery")
@MainActor
struct KeyboardFilterRecoveryTests {
    @Test func transientDisableReturnsBeforePermissionQueriesOrDeviceTeardown() throws {
        let name = "filter-recovery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let monitor = HIDRemoteMonitor(settings: settings, profileID: nil,
            eventSuppressor: model.hidEventSuppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: UUID())
        var resets = 0
        monitor.onInputReset = { _ in resets += 1 }
        model.hidMonitors["test"] = monitor
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(!model.hidEventSuppressor.handle(type: .tapDisabledByTimeout, event: event))
        #expect(resets == 0)
        #expect(model.hidMonitors["test"] === monitor)
        #expect(!model.hidEventSuppressor.isRunning)
        // The terminal notification still tears down all mappings.
        model.hidEventSuppressor.onSystemDisabled?()
        #expect(resets == 1)
        #expect(model.hidMonitors.isEmpty)
        #expect(model.hidMonitoringInterrupted)
        monitor.onInputReset = nil
    }

    @Test(arguments: [false, true])
    func failedEnablesRetryWithoutAnotherSystemEventAndStopAtTheBudget(recovers: Bool) {
        let clock = ControlledTestScheduler()
        var permissionChecks = 0, enables = 0, stops = 0
        let recovery = EventTapRecovery(now: { Double(clock.now) / 1000 },
            dispatch: { delay, work in _ = clock.voiceSchedule(delay, work) })
        recovery.recover(type: .tapDisabledByTimeout, isCurrent: { true },
            permissionsGranted: { permissionChecks += 1; return true },
            enable: { enables += 1; return recovers && enables == 3 }, stop: { stops += 1 })
        #expect(permissionChecks == 0 && enables == 0 && stops == 0)
        clock.runAll()
        #expect(enables == (recovers ? 3 : 5))
        #expect(stops == (recovers ? 0 : 1))
        #expect(clock.activeCount == 0)
    }

    @Test(arguments: [false, true])
    func queuedRecoveryRespectsPermissionRevocationAndPortReplacement(replaced: Bool) {
        let clock = ControlledTestScheduler()
        var current = true, granted = true
        var checks = 0, enables = 0, stops = 0
        let recovery = EventTapRecovery(now: { Double(clock.now) / 1000 },
            dispatch: { delay, work in _ = clock.voiceSchedule(delay, work) })
        recovery.recover(type: .tapDisabledByUserInput, isCurrent: { current },
            permissionsGranted: { checks += 1; return granted },
            enable: { enables += 1; return true }, stop: { stops += 1 })
        granted = false
        if replaced { current = false }
        clock.runAll()
        #expect(checks == (replaced ? 0 : 1))
        #expect(enables == 0)
        #expect(stops == (replaced ? 0 : 1))
    }

    @Test func unavailableNativeFilterBlocksMappedActionsDuringRecovery() throws {
        let name = "filter-recovery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let clock = ControlledTestScheduler()
        var available = true
        var actions = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: UUID(), scheduler: clock,
            runtimePermissions: { true }, nativeSuppressionAvailable: { available },
            actionPerformer: { _, _, _ in actions += 1; return true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: UUID(), isSeized: false)
        available = false
        monitor.handleSimulatedReport(reportID: 1, data: Data([0x28, 0x00]))
        clock.advance(to: 1000)
        #expect(actions == 0)
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        available = true
        monitor.handleSimulatedReport(reportID: 1, data: Data([0x28, 0x00]))
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(actions == 1)
        monitor.disconnectSimulatedDevice()
    }
}
