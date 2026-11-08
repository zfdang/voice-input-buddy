import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth pending start isolation")
@MainActor
struct BluetoothPendingStartTests {
    @Test func busyRemoteDoesNotRegisterOrSelectTheRejectedDevice() throws {
        let suite = "bluetooth-busy-selection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let owner = UUID(), rejected = UUID()
        let selected = settings.registerBluetoothRemote(identifier: owner)
        settings.selectRemoteProfile(selected)
        model.voiceSession.activeDeviceIdentifier = owner
        model.voiceSession.isActive = true
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: rejected)
        model.bluetoothBridgeDidStartVoice(bridge)
        #expect(settings.selectedRemoteProfileID == selected)
        #expect(settings.profileID(forBluetoothIdentifier: rejected) == nil)
        #expect(model.voiceSession.activeDeviceIdentifier == owner)
        #expect(model.voiceSession.isActive)
        #expect(model.voiceSession.pendingStart.identifier == nil)
    }

    @Test func oldConfigurationCompletionCannotConsumeRestartedAudio() {
        let pending = BluetoothPendingAudioStart()
        let device = UUID()
        let old = pending.begin(for: device)
        let acceptedOldAudio = pending.audio.appendIfWaiting([1, 2])
        #expect(acceptedOldAudio)
        #expect(pending.cancel(ifOwnedBy: device))
        let current = pending.begin(for: device)
        let acceptedCurrentAudio = pending.audio.appendIfWaiting([3, 4])
        #expect(acceptedCurrentAudio)
        #expect(!pending.matches(identifier: device, operationID: old))
        #expect(pending.matches(identifier: device, operationID: current))
        #expect(pending.drain() == [3, 4])
        #expect(!pending.matches(identifier: device, operationID: current))
    }

    @Test func disconnectClearsOnlyThePendingStartOwnedByThatBridge() throws {
        let suite = "bluetooth-pending-disconnect-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let owner = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: owner)
        let other = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: UUID())
        model.voiceSession.pendingStart.begin(for: owner)
        model.voiceSession.stopRequested = true
        let accepted = model.voiceSession.pendingStart.audio.appendIfWaiting([1, 2])
        #expect(accepted)
        model.bluetoothBridge(other, didChange: .reconnecting)
        #expect(model.voiceSession.pendingStart.identifier == owner)
        #expect(model.voiceSession.stopRequested)
        model.bluetoothBridge(bridge, didChange: .reconnecting)
        #expect(model.voiceSession.pendingStart.identifier == nil)
        #expect(!model.voiceSession.stopRequested)
        #expect(model.voiceSession.pendingStart.drain().isEmpty)
    }

    @Test func microphoneCloseFailureRetainsClosePendingAndDoesNotPretendClosed() throws {
        let suite = "bluetooth-close-pending-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let owner = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: owner)

        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)

        let didWrite = bridge.requestMicrophoneClose()
        #expect(!didWrite)
        #expect(bridge.isMicrophoneOpen)
        #expect(bridge.isMicrophoneClosePending)

        let secondAttempt = bridge.requestMicrophoneClose()
        #expect(!secondAttempt)
        #expect(bridge.isMicrophoneClosePending)

        bridge.stop()
        #expect(!bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)
    }

    @Test func closeTimeoutClearsOpenStateAndCancelledTimeoutCannotCloseANewRequest() throws {
        let suite = "bluetooth-close-timeout-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ControlledTestScheduler()
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model,
            scheduleMicrophoneClose: clock.voiceSchedule)
        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(!bridge.requestMicrophoneClose())
        clock.advance(to: 5_000)
        #expect(!bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)

        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(!bridge.requestMicrophoneClose())
        let stale = try #require(clock.tasks.last)
        bridge.simulateStreamStopForTesting()
        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(!bridge.requestMicrophoneClose())
        stale.fire(includingCancelled: true)
        #expect(bridge.isMicrophoneOpen)
        #expect(bridge.isMicrophoneClosePending)
        clock.advance(to: 10_000)
        #expect(!bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)
    }

    @Test func remoteStreamStopClearsMicrophoneClosePendingAndPreventsWatchdogReconnect() throws {
        let suite = "bluetooth-close-stop-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let owner = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: owner)

        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)

        let didWrite = bridge.requestMicrophoneClose()
        #expect(!didWrite)
        #expect(bridge.isMicrophoneClosePending)

        bridge.simulateStreamStopForTesting()

        #expect(!bridge.isMicrophoneClosePending)
        #expect(!bridge.isMicrophoneOpen)
    }

    @Test func localStopStreamingPreservesMicrophoneClosePendingForRetry() throws {
        let suite = "bluetooth-local-stop-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let owner = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: owner)

        bridge.simulateMicrophoneOpenedForTesting(true)
        #expect(bridge.isMicrophoneOpen)
        #expect(!bridge.isMicrophoneClosePending)

        let didWrite = bridge.requestMicrophoneClose()
        #expect(!didWrite)
        #expect(bridge.isMicrophoneClosePending)

        // Local stop (e.g. decode backlog) must NOT cancel the pending close intent
        bridge.simulateLocalStopStreamingForTesting()

        #expect(bridge.isMicrophoneClosePending)
        #expect(bridge.isMicrophoneOpen)

        // Remote confirmed stop clears the close intent
        bridge.simulateStreamStopForTesting()

        #expect(!bridge.isMicrophoneClosePending)
        #expect(!bridge.isMicrophoneOpen)
    }
}
