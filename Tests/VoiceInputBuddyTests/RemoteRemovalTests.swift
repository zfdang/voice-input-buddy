import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Removing remotes") @MainActor
struct RemoteRemovalTests {
    @Test func removalPreservesOtherDeviceAndRemembersExclusionsAcrossRelaunch() throws {
        let suite = "remote-removal-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let firstIdentifier = UUID(), secondIdentifier = UUID()
        let first = settings.registerBluetoothRemote(identifier: firstIdentifier, model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: secondIdentifier, model: .rc003)
        #expect(settings.registerBluetoothRemote(identifier: firstIdentifier, model: .rc003) == first)
        #expect(first != second)
        #expect(settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "first-hid"), to: first))
        #expect(settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "second-hid"), to: second))
        settings.selectRemoteProfile(second)
        settings.setGainDB(17, for: second)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .ok, trigger: .singleClick, profileID: second)
        settings.selectRemoteProfile(first)
        settings.setBaseBinding(.init(action: .commandPaste, shortcut: nil), for: .ok, trigger: .singleClick, profileID: first)
        #expect(settings.removeRemoteProfile(first))
        #expect(!settings.removeRemoteProfile(first))
        let restored = AppSettings(defaults: defaults)
        #expect(restored.remoteDeviceProfiles.map(\.id) == [second])
        #expect(restored.selectedRemoteProfileID == second)
        #expect(restored.gainDB(for: second) == 17)
        #expect(restored.configuredAction(for: .ok, trigger: .singleClick, profileID: second).action == .commandCopy)
        #expect(restored.forgottenBluetoothIdentifiers == [firstIdentifier])
        #expect(restored.forgottenHIDFingerprints == ["first-hid"])
        #expect(!restored.unifiedBaseBindings.contains { $0.remoteProfileID == first })
        SettingsPageBehavior.beginDeviceSetup(settings: restored)
        #expect(restored.forgottenBluetoothIdentifiers.isEmpty)
        #expect(restored.forgottenHIDFingerprints.isEmpty)
    }

    @Test func removingLastDeviceDoesNotInheritItsMappingsOnNextAddition() throws {
        let suite = "remote-removal-last-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(first)
        settings.setAction(.commandCopy, for: .ok)
        #expect(settings.removeRemoteProfile(first))
        #expect(settings.selectedRemoteProfileID == nil)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.remoteDeviceProfiles.isEmpty)
        let next = restored.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        restored.selectRemoteProfile(next)
        #expect(restored.action(for: .ok) != .commandCopy)
    }

    @Test func removingADeviceStopsItsBridgeWithoutRemovingAnother() throws {
        let suite = "remote-removal-bridge-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let firstID = UUID(), secondID = UUID()
        let first = settings.registerBluetoothRemote(identifier: firstID, model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: secondID, model: .rc003)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        let firstBridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: firstID)
        let secondBridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: secondID)
        model.connections.bridges[firstID] = firstBridge
        model.connections.bridges[secondID] = secondBridge
        #expect(model.removeRemoteDevice(first))
        #expect(model.connections.bridges[firstID] == nil)
        #expect(model.connections.bridges[secondID] === secondBridge)
        #expect(settings.remoteDeviceProfiles.map(\.id) == [second])
        #expect(settings.forgottenBluetoothIdentifiers.contains(firstID))
        let discovery = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { settings.forgottenBluetoothIdentifiers })
        #expect(!discovery.acceptsCandidateIdentifier(firstID))
        #expect(discovery.acceptsCandidateIdentifier(secondID))
        settings.allowForgottenRemotesForSetup()
        #expect(discovery.acceptsCandidateIdentifier(firstID))
        model.connections.stopAll()
    }
}
