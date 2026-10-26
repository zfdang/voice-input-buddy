import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Long recording device ownership")
@MainActor
struct LongRecordingOwnershipTests {
    private func withRemotes(_ body: (BridgeAppModel, BluetoothRemoteBridge, BluetoothRemoteBridge, UUID) throws -> Void) throws {
        let name = "long-recording-owner-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let ownerID = UUID(), otherID = UUID()
        let ownerProfile = settings.registerBluetoothRemote(identifier: ownerID, model: .rc003)
        let otherProfile = settings.registerBluetoothRemote(identifier: otherID, model: .rc001)
        settings.selectRemoteProfile(ownerProfile)
        let model = BridgeAppModel(settings: settings)
        let owner = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: ownerID)
        let other = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: otherID)
        model.connections.bridges[ownerID] = owner
        model.connections.bridges[otherID] = other
        model.connections.states[ObjectIdentifier(owner)] = .ready("Owner")
        model.connections.states[ObjectIdentifier(other)] = .ready("Other")
        model.refreshBluetoothPresentation()
        defer {
            model.finishLongRecording(reason: "test_cleanup")
            owner.stop()
            other.stop()
        }
        try body(model, owner, other, otherProfile)
    }

    @Test func pendingRequestCapturesTheBridgeBeforePreparationAndRejectsOtherVoice() throws {
        try withRemotes { model, owner, other, otherProfile in
            #expect(model.toggleLongRecording())
            #expect(model.longRecordingBridge === owner)
            let generation = model.longRecordingGeneration
            model.selectRemoteProfile(otherProfile)
            model.bluetoothBridgeDidStartVoice(other)
            #expect(model.longRecordingRequested)
            #expect(model.longRecordingBridge === owner)
            #expect(model.longRecordingGeneration == generation)
            #expect(!model.voiceSession.isActive)
            #expect(model.voiceSession.pendingStart.identifier == nil)
            model.stopLongRecording(reason: "cancel")
            #expect(model.longRecordingBridge == nil)
            #expect(!model.startLongRecordingAfterAudioReady(true, generation: generation))
        }
    }

    @Test(arguments: [false, true])
    func unrelatedTransitionsPreservePendingAndActiveRecording(active: Bool) throws {
        try withRemotes { model, owner, other, _ in
            model.longRecordingBridge = owner
            model.longRecordingRequested = true
            model.longRecordingGeneration = 12
            if active { model.voiceSession.begin(deviceIdentifier: owner.deviceIdentifier!) }
            for state in [BluetoothBridgeState.scanning, .reconnecting, .discovering] {
                model.bluetoothBridge(other, didChange: state)
                #expect(model.longRecordingRequested)
                #expect(model.longRecordingGeneration == 12)
                #expect(model.longRecordingBridge === owner)
                #expect(model.voiceSession.isActive == active)
            }
            model.bluetoothBridge(owner, didChange: .reconnecting)
            #expect(!model.longRecordingRequested)
            #expect(model.longRecordingBridge == nil)
            #expect(!model.voiceSession.isActive)
            #expect(!model.shouldKeepVirtualAudioActive)
            #expect(!model.startLongRecordingAfterAudioReady(true, generation: 12))
        }
    }

    @Test func stopTargetsTheOwnerAfterSelectionChangesAndRetainsOwnershipUntilClosed() throws {
        try withRemotes { model, owner, other, otherProfile in
            model.longRecordingBridge = owner
            model.longRecordingRequested = true
            model.voiceSession.begin(deviceIdentifier: owner.deviceIdentifier!)
            owner.simulateMicrophoneOpenedForTesting(true)
            model.selectRemoteProfile(otherProfile)
            #expect(model.toggleLongRecording())
            #expect(!model.longRecordingRequested)
            #expect(owner.isMicrophoneClosePending)
            #expect(!other.isMicrophoneClosePending)
            #expect(model.longRecordingBridge === owner)
            #expect(model.longRecordingCloseTimer != nil)
            model.bluetoothBridge(other, didChange: .reconnecting)
            #expect(model.longRecordingBridge === owner)
            #expect(model.longRecordingCloseTimer != nil)
            model.bluetoothBridgeDidStopVoice(owner)
            #expect(model.longRecordingBridge == nil)
            #expect(model.longRecordingCloseTimer == nil)
            #expect(!model.shouldKeepVirtualAudioActive)
        }
    }

    @Test func ownerDisconnectClearsClosingWatchdog() throws {
        try withRemotes { model, owner, _, _ in
            model.longRecordingBridge = owner
            model.longRecordingRequested = true
            model.voiceSession.begin(deviceIdentifier: owner.deviceIdentifier!)
            model.stopLongRecording(reason: "test")
            #expect(model.longRecordingCloseTimer != nil)
            model.bluetoothBridge(owner, didChange: .reconnecting)
            #expect(model.longRecordingBridge == nil)
            #expect(model.longRecordingCloseTimer == nil)
            #expect(!model.shouldKeepVirtualAudioActive)
        }
    }
}
