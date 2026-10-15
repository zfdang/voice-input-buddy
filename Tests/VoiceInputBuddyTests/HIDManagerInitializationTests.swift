import Foundation
import Testing
@testable import VoiceInputBuddy

/// Models the unopened IOKit manager contract confirmed with a native LLDB probe:
/// enumeration installs the current report callback on a device; later manager
/// callback registration does not retrofit devices already enumerated.
private final class UnopenedHIDManager {
    var managerReportCallback: ((Data) -> Void)?
    private var deviceReportCallback: ((Data) -> Void)?
    private var matched = false
    private var scheduled = false
    private let initiallyConnected: Bool

    init(initiallyConnected: Bool) {
        self.initiallyConnected = initiallyConnected
    }

    func matchDevices() {
        matched = true
        if initiallyConnected { connectDevice() }
    }

    func schedule() { scheduled = true }

    func connectDevice() {
        guard matched else { return }
        deviceReportCallback = managerReportCallback
    }

    func emit(_ data: Data) {
        guard scheduled else { return }
        deviceReportCallback?(data)
    }
}

@Suite("HID manager initialization")
@MainActor
struct HIDManagerInitializationTests {
    @Test(arguments: [true, false])
    func tvReportsReachAppSwitcherAcrossMonitorRestarts(initiallyConnected: Bool) throws {
        let name = "hid-manager-initialization-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.appSwitcher, for: .tv)
        let profileID = UUID()
        var keyEdges: [(UInt16, Bool)] = []
        var reportCount = 0
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            runtimePermissions: { true },
            nativeSuppressionAvailable: { true },
            diagnosticLogger: { _ in },
            appSwitcherKeyStatePoster: { code, down, _ in
                keyEdges.append((code, down))
                return true
            }
        )
        // Each restart gets a new manager, just as startHIDMonitors() does.
        for _ in 0..<2 {
            let manager = UnopenedHIDManager(initiallyConnected: initiallyConnected)
            monitor.connectSimulatedDevice(fingerprint: "remote", profileID: profileID, isSeized: false)
            keyEdges.removeAll()
            let previousReportCount = reportCount
            HIDRemoteMonitor.initializeManager(
                registerCallbacks: {
                    manager.managerReportCallback = { data in
                        reportCount += 1
                        monitor.handleSimulatedReport(reportID: 1, data: data)
                    }
                },
                matchDevices: manager.matchDevices,
                schedule: manager.schedule
            )
            if !initiallyConnected { manager.connectDevice() }
            #expect(keyEdges.isEmpty)
            let tv = RemoteButton.tv.hidUsage
            manager.emit(Data([UInt8(tv & 255), UInt8(tv >> 8)]))
            manager.emit(Data([0, 0]))
            #expect(reportCount == previousReportCount + 2)
            #expect(keyEdges.contains { $0 == 55 && $1 }) // Hold Command.
            #expect(keyEdges.contains { $0 == 48 && $1 }) // Tab opens the switcher.
            monitor.disconnectSimulatedDevice()
            #expect(keyEdges.contains { $0 == 55 && !$1 }) // Teardown releases Command.
        }
    }
}
