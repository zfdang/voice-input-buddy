import Foundation
import Testing
@testable import RemoteBuddy

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
        #expect(restored.forgottenBluetoothIdentifiers == [firstIdentifier])
        #expect(restored.forgottenHIDFingerprints == ["first-hid"])
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
            excludedIdentifiers: { settings.excludedForgottenBluetoothIdentifiers() })
        #expect(!discovery.acceptsCandidateIdentifier(firstID))
        #expect(discovery.acceptsCandidateIdentifier(secondID))

        // Opening add-device setup keeps forgotten devices excluded until the matching remote step begins.
        settings.completeOnboarding()
        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        #expect(!discovery.acceptsCandidateIdentifier(firstID))

        // Unrelated setup source (.t1Remote) still rejects forgotten .rc003.
        settings.setOnboardingControlSource(.t1Remote)
        settings.setOnboardingStep(.remote)
        #expect(!discovery.acceptsCandidateIdentifier(firstID))

        // Matching setup source (.xiaomiRemote) allows discovery only while actively connecting/testing,
        // and cancelling restores exclusion.
        settings.setOnboardingControlSource(.xiaomiRemote)
        #expect(discovery.acceptsCandidateIdentifier(firstID))
        model.dismissOnboardingSetup()
        #expect(!discovery.acceptsCandidateIdentifier(firstID))
        model.connections.stopAll()
    }

    @Test func cancellingAddDeviceRemovesTransientProfileWhileCompletingReleasesOnlyAddedRemote() throws {
        let suite = "remote-removal-scoping-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let existingID = UUID()
        let xiaomiID = UUID()
        let t1ID = UUID()

        let existingProfile = settings.registerBluetoothRemote(identifier: existingID, model: .rc003)
        let xiaomiProfile = settings.registerBluetoothRemote(identifier: xiaomiID, model: .rc003)
        let t1Profile = settings.registerBluetoothRemote(identifier: t1ID, model: .t1Remote)
        #expect(settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "xiaomi-fp"), to: xiaomiProfile))
        #expect(settings.bindCompatibleHID(.init(identity: .t1Remote, fingerprint: "t1-fp"), to: t1Profile))
        settings.selectRemoteProfile(existingProfile)
        settings.completeOnboarding()

        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        #expect(model.removeRemoteDevice(xiaomiProfile))
        #expect(model.removeRemoteDevice(t1Profile))
        #expect(settings.forgottenBluetoothIdentifiers == [xiaomiID, t1ID])
        #expect(settings.forgottenHIDFingerprints == ["xiaomi-fp", "t1-fp"])

        // 1. Entering add-device does not release either forgotten remote; entering T1 Step 2
        // still blocks deleted Xiaomi, transiently permits T1, and rolls T1 back on dismiss.
        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        #expect(!settings.allowsSetupCandidate(bluetoothIdentifier: t1ID, model: .t1Remote))
        #expect(!settings.allowsSetupCandidate(hidFingerprint: "t1-fp", model: .t1Remote))

        settings.setOnboardingControlSource(.t1Remote)
        settings.setOnboardingStep(.remote)
        #expect(!settings.allowsSetupCandidate(bluetoothIdentifier: xiaomiID, model: .rc003))
        #expect(!settings.allowsSetupCandidate(hidFingerprint: "xiaomi-fp", model: .rc003))
        #expect(settings.allowsSetupCandidate(bluetoothIdentifier: t1ID, model: .t1Remote))
        #expect(settings.allowsSetupCandidate(hidFingerprint: "t1-fp", model: .t1Remote))

        let transientT1Profile = settings.registerBluetoothRemote(identifier: t1ID, model: .t1Remote)
        let transientBridge = BluetoothRemoteBridge(settings: settings, delegate: model, targetIdentifier: t1ID)
        model.connections.bridges[t1ID] = transientBridge
        #expect(settings.remoteDeviceProfiles.contains { $0.id == transientT1Profile })

        model.dismissOnboardingSetup()
        #expect(settings.remoteDeviceProfiles.map(\.id) == [existingProfile])
        #expect(model.connections.bridges[t1ID] == nil)
        #expect(settings.forgottenBluetoothIdentifiers == [xiaomiID, t1ID])
        #expect(settings.forgottenHIDFingerprints == ["xiaomi-fp", "t1-fp"])

        // 2. Actually completing T1 setup unforgets ONLY T1 while leaving deleted Xiaomi forgotten.
        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        settings.setOnboardingControlSource(.t1Remote)
        settings.setOnboardingStep(.remote)
        let confirmedT1 = settings.registerBluetoothRemote(identifier: t1ID, model: .t1Remote)
        #expect(settings.bindCompatibleHID(.init(identity: .t1Remote, fingerprint: "t1-fp"), to: confirmedT1))
        settings.completeOnboarding()

        #expect(Set(settings.remoteDeviceProfiles.map(\.id)) == [existingProfile, confirmedT1])
        #expect(settings.forgottenBluetoothIdentifiers == [xiaomiID])
        #expect(settings.forgottenHIDFingerprints == ["xiaomi-fp"])
        model.connections.stopAll()
    }
}
