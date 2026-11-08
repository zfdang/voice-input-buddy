import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth remote wake recovery")
struct BluetoothReconnectWakeTests {
    @Test func connectedRemoteInterruptsMinuteBackoffOnNextSnapshotCheck() {
        let clock = ControlledTestScheduler()
        let monitor = BluetoothReconnectWakeMonitor(scheduler: clock)
        var phase = BluetoothLifecyclePhase.waitingReconnect(8)
        var systemConnected = false
        var attempts = 0
        let delayedRetry = clock.schedule(afterMilliseconds: 60_000, repeatingEveryMilliseconds: nil) {
            attempts += 1
        }
        monitor.arm(isCurrent: {
            BluetoothReconnectWakePolicy.canRecover(phase: phase, shouldRun: true, suspended: false)
        }, checkConnected: {
            guard systemConnected else { return }
            delayedRetry.cancel()
            attempts += 1
            phase = .connecting(8)
        })
        clock.advance(to: 26_000)
        #expect(attempts == 0)
        systemConnected = true
        clock.advance(to: 28_000)
        #expect(attempts == 1)
        clock.advance(to: 60_000)
        #expect(attempts == 1)
        #expect(clock.activeCount == 0)
    }

    @Test func offlineSnapshotChecksPreserveTheScheduledRetry() {
        let clock = ControlledTestScheduler()
        let monitor = BluetoothReconnectWakeMonitor(scheduler: clock)
        var queries = 0
        var retries = 0
        clock.schedule(afterMilliseconds: 60_000, repeatingEveryMilliseconds: nil) { retries += 1 }
        monitor.arm(isCurrent: { true }, checkConnected: { queries += 1 })
        clock.advance(to: 59_999)
        #expect(queries == 29)
        #expect(retries == 0)
        clock.advance(to: 60_000)
        #expect(retries == 1)
        monitor.cancel()
    }

    @Test func cancellationAndReplacementIgnoreAlreadyQueuedChecks() throws {
        let clock = ControlledTestScheduler()
        let monitor = BluetoothReconnectWakeMonitor(scheduler: clock)
        var queries = 0
        monitor.arm(isCurrent: { true }, checkConnected: { queries += 1 })
        let stale = try #require(clock.tasks.first)
        monitor.arm(isCurrent: { true }, checkConnected: { queries += 1 })
        stale.fire(includingCancelled: true)
        #expect(queries == 0)
        clock.advance(to: 2_000)
        #expect(queries == 1)
        monitor.cancel()
        clock.tasks.last?.fire(includingCancelled: true)
        #expect(queries == 1)
        #expect(clock.activeCount == 0)
    }

    @Test func recoveryNeverInterruptsAnActiveAttemptOrSuspendedBridge() {
        let activePhases: [BluetoothLifecyclePhase] = [
            .stopped, .connecting(1), .discovering(1), .awaitingCapabilities(1),
            .ready(1), .disconnecting(1), .waitingBluetoothPower(1)
        ]
        for phase in activePhases {
            #expect(!BluetoothReconnectWakePolicy.canRecover(phase: phase, shouldRun: true, suspended: false))
        }
        for phase in [BluetoothLifecyclePhase.scanning(1), .waitingReconnect(1)] {
            #expect(BluetoothReconnectWakePolicy.canRecover(phase: phase, shouldRun: true, suspended: false))
            #expect(!BluetoothReconnectWakePolicy.canRecover(phase: phase, shouldRun: false, suspended: false))
            #expect(!BluetoothReconnectWakePolicy.canRecover(phase: phase, shouldRun: true, suspended: true))
        }
    }

    @Test func suspensionStopsPollingEvenWhenACallbackWasAlreadyQueued() throws {
        let clock = ControlledTestScheduler()
        let monitor = BluetoothReconnectWakeMonitor(scheduler: clock)
        var suspended = false
        var queries = 0
        monitor.arm(isCurrent: {
            BluetoothReconnectWakePolicy.canRecover(phase: .waitingReconnect(1), shouldRun: true, suspended: suspended)
        }, checkConnected: { queries += 1 })
        let queued = try #require(clock.tasks.first)
        suspended = true
        queued.fire()
        queued.fire(includingCancelled: true)
        #expect(queries == 0)
        #expect(clock.activeCount == 0)
    }

    @Test @MainActor func hidConnectionNotificationCarriesTheRemoteIdentity() throws {
        let suite = "remote-wake-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = HIDRemoteMonitor(settings: AppSettings(defaults: defaults),
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        let profile = UUID()
        var observed: [(UUID?, String)] = []
        monitor.onDeviceConnected = { observed.append(($0, $1)) }
        monitor.connectSimulatedDevice(fingerprint: "remote-a", profileID: profile)
        #expect(observed.count == 1)
        #expect(observed.first?.0 == profile)
        #expect(observed.first?.1 == "remote-a")
        monitor.disconnectSimulatedDevice()
    }
}
