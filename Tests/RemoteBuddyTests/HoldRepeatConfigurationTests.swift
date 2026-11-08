import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Configurable hold actions") @MainActor
struct HoldRepeatConfigurationTests {
    private final class Events {
        var triggers: [ButtonTrigger] = []
        var actions: [ButtonAction] = []
    }

    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let name = "hold-repeat-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(AppSettings(defaults: defaults))
    }

    private func monitor(_ settings: AppSettings, clock: ControlledTestScheduler, events: Events,
                         seized: Bool = true) -> HIDRemoteMonitor {
        settings.customMappingEnabled = true
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            scheduler: clock, runtimePermissions: { true }, nativeSuppressionAvailable: { true },
            actionPerformer: { _, trigger, configured in
                events.triggers.append(trigger)
                events.actions.append(configured.action)
                return true
            }, frontmostBundleIdentifier: { "test.editor" }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "hold-test", profileID: profile, isSeized: seized)
        return monitor
    }

    private func press(_ button: RemoteButton, on monitor: HIDRemoteMonitor) {
        let usage = button.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
    }

    private func release(_ monitor: HIDRemoteMonitor) {
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
    }

    @Test func navigationVolumeAndPowerShowRepeatAsTheirDefaultLongPressValue() throws {
        try withSettings { settings in
            for button in [RemoteButton.up, .down, .left, .right, .volumeUp, .volumeDown, .power] {
                #expect(settings.configuredBaseAction(for: button, trigger: .longPress).action == .repeatSingleClick)
            }
            #expect(settings.configuredAction(for: .back, trigger: .longPress).action == .disabled)
        }
    }

    @Test func defaultPowerRepeatsDeletionWhileBackSendsEscapeOnce() throws {
        try withSettings { settings in
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            clock.advance(to: 450)
            #expect(events.actions == Array(repeating: .deleteBackward, count: 4))
            release(monitor)
            clock.advance(to: 1_000)
            #expect(events.actions.count == 4)
            press(.back, on: monitor)
            clock.advance(to: 2_000)
            #expect(events.actions == Array(repeating: .deleteBackward, count: 4) + [.escape])
            release(monitor)
            #expect(events.actions.count == 5)
        }
    }

    @Test(arguments: RemoteButton.xiaomiCases)
    func everyPhysicalButtonCanRepeatAndStopsOnRelease(button: RemoteButton) throws {
        try withSettings { settings in
            settings.setAction(.deleteBackward, for: button)
            settings.setAction(.repeatSingleClick, for: button, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(button, on: monitor)
            #expect(events.actions == [.deleteBackward])
            clock.advance(to: 349)
            #expect(events.actions.count == 1)
            clock.advance(to: 450)
            #expect(events.actions == Array(repeating: .deleteBackward, count: 4))
            #expect(events.triggers.allSatisfy { $0 == .singleClick })
            release(monitor)
            clock.advance(to: 1_000)
            #expect(events.actions.count == 4)
        }
    }

    @Test func specialLongPressRunsOnceInsteadOfRepeatingTheSingleAction() throws {
        try withSettings { settings in
            settings.setAction(.escape, for: .up, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.up, on: monitor)
            clock.advance(to: 549)
            #expect(events.actions.isEmpty)
            clock.advance(to: 1_000)
            #expect(events.actions == [.escape])
            #expect(events.triggers == [.longPress])
            release(monitor)
            clock.advance(to: 2_000)
            #expect(events.actions == [.escape])
        }
    }

    @Test func clearingLongPressDisablesRepeatIncludingNativeArrowPassthrough() throws {
        try withSettings { settings in
            settings.setAction(.disabled, for: .left, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events, seized: false)
            defer { monitor.disconnectSimulatedDevice() }
            press(.left, on: monitor)
            clock.advance(to: 1_000)
            #expect(events.actions == [.arrowLeft])
            release(monitor)
            clock.advance(to: 2_000)
            #expect(events.actions == [.arrowLeft])
        }
    }

    @Test func repeatCoexistsWithDoublePressWithoutEmittingExtraSinglesOnRelease() throws {
        try withSettings { settings in
            settings.setAction(.deleteBackward, for: .power)
            settings.setAction(.repeatSingleClick, for: .power, trigger: .longPress)
            settings.setAction(.escape, for: .power, trigger: .doubleClick)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            clock.advance(to: 20)
            release(monitor)
            clock.advance(to: 100)
            press(.power, on: monitor)
            clock.advance(to: 120)
            release(monitor)
            clock.advance(to: 1_000)
            #expect(events.actions == [.escape])
            #expect(events.triggers == [.doubleClick])
            press(.power, on: monitor)
            clock.advance(to: 1_450)
            #expect(events.actions == [.escape, .deleteBackward, .deleteBackward, .deleteBackward])
            release(monitor)
            clock.advance(to: 2_000)
            #expect(events.actions.count == 4)
        }
    }

    @Test func changingTheHoldValueStopsAnActiveRepeatAndCanRepeatCustomShortcuts() throws {
        try withSettings { settings in
            settings.setAction(.customShortcut, for: .power)
            settings.setShortcut(.init(keyCode: 8, modifierFlags: .command, keyLabel: "C"), for: .power)
            settings.setAction(.repeatSingleClick, for: .power, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            clock.advance(to: 350)
            #expect(events.actions == [.customShortcut, .customShortcut])
            settings.setAction(.escape, for: .power, trigger: .longPress)
            clock.advance(to: 1_000)
            #expect(events.actions.count == 2)
        }
    }

    @Test func cancelledRepeatCannotFireAgainstANewerPressOfTheSameButton() throws {
        try withSettings { settings in
            settings.setAction(.repeatSingleClick, for: .power, trigger: .longPress)
            let clock = ControlledTestScheduler(), events = Events()
            let monitor = monitor(settings, clock: clock, events: events)
            defer { monitor.disconnectSimulatedDevice() }
            press(.power, on: monitor)
            let stale = try #require(clock.tasks.first { $0.delay == HIDRemoteTiming.repeatStartMilliseconds })
            release(monitor)
            press(.power, on: monitor)
            #expect(events.actions.count == 2)
            stale.fire(includingCancelled: true)
            #expect(events.actions.count == 2)
            clock.advance(to: 350)
            #expect(events.actions.count == 3)
            monitor.disconnectSimulatedDevice()
            clock.advance(to: 1_000)
            #expect(events.actions.count == 3)
        }
    }

    @Test func importRejectsRepeatOutsideTheLongPressSlot() throws {
        try withSettings { settings in
            var payload = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
            payload["buttonBindings"] = ["power": "repeatSingleClick"]
            payload["secondaryButtonBindings"] = ["ok": ["doubleClick": ["action": "repeatSingleClick"]]]
            payload["unifiedBaseBindings"] = [["button": "menu", "trigger": "singleClick",
                                               "configured": ["action": "repeatSingleClick"]]]
            try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: payload))
            #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains("buttonBindings") == true)
            #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains("secondaryButtonBindings") == true)
            #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains("unifiedBaseBindings") == true)
            #expect(settings.action(for: .power) == .deleteBackward)
            #expect(settings.configuredAction(for: .ok, trigger: .doubleClick).action == .disabled)
            #expect(settings.action(for: .menu) == .disabled)
        }
    }

    @Test func resetRestoresDefaultRepeatingHoldsOverInheritedActions() throws {
        try withSettings { settings in
            settings.setBaseBinding(.init(action: .escape, shortcut: nil),
                for: .volumeUp, trigger: .longPress, profileID: nil)
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            settings.selectRemoteProfile(profile)
            settings.resetBindings()
            #expect(settings.allowsHoldRepeat(for: .volumeUp))
        }
    }

    @Test func holdValuesPersistPerDeviceAndSurviveExportImportAndReset() throws {
        try withSettings { settings in
            let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
            let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc001)
            settings.selectRemoteProfile(first)
            settings.setBaseBinding(.init(action: .repeatSingleClick, shortcut: nil),
                for: .power, trigger: .longPress, profileID: first)
            settings.selectRemoteProfile(second)
            settings.setBaseBinding(.init(action: .escape, shortcut: nil),
                for: .power, trigger: .longPress, profileID: second)
            #expect(settings.allowsHoldRepeat(for: .power, profileID: first))
            #expect(!settings.allowsHoldRepeat(for: .power, profileID: second))
            let restored = AppSettings(defaults: settings.defaults)
            #expect(restored.allowsHoldRepeat(for: .power, profileID: first))
            #expect(restored.configuredAction(for: .power, trigger: .longPress, profileID: second).action == .escape)
            settings.selectRemoteProfile(first)
            let data = try settings.exportedConfigurationData()
            try withSettings { imported in
                try imported.importConfiguration(from: data)
                #expect(imported.allowsHoldRepeat(for: .power))
                imported.resetBindings()
                #expect(imported.allowsHoldRepeat(for: .power))
                #expect(!imported.allowsHoldRepeat(for: .back))
                #expect(imported.allowsHoldRepeat(for: .volumeUp))
            }
            settings.resetBindings()
            #expect(settings.allowsHoldRepeat(for: .power, profileID: first))
            #expect(settings.configuredAction(for: .power, trigger: .longPress, profileID: second).action == .escape)
        }
    }
}
