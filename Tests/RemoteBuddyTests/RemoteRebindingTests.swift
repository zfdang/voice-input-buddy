import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Explicit remote rebinding") @MainActor
struct RemoteRebindingTests {
    @Test func replacementPreservesProfileMappingsGainAndHIDOwnerAcrossRelaunch() throws {
        let suite = "rebind-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let old = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let binding = RemoteHIDBinding(identity: .xiaomi, fingerprint: "same-physical-device")
        #expect(settings.bindCompatibleHID(binding, to: old))
        settings.selectRemoteProfile(old)
        settings.setGainDB(17, for: old)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .ok, trigger: .singleClick, profileID: old)
        let identifier = UUID()
        let new = settings.registerBluetoothRemote(identifier: identifier, model: .rc003)
        settings.selectRemoteProfile(new)
        #expect(settings.rebindBluetoothRemote(profileID: old, to: new))
        let restored = AppSettings(defaults: defaults)
        #expect(restored.remoteDeviceProfiles.count == 1)
        #expect(restored.profileID(forBluetoothIdentifier: identifier) == old)
        #expect(restored.profileID(forHIDFingerprint: binding.fingerprint) == old)
        #expect(restored.selectedRemoteProfileID == old)
        #expect(restored.gainDB(for: old) == 17)
        #expect(restored.configuredAction(for: .ok, trigger: .singleClick, profileID: old).action == .commandCopy)
    }

    @Test func differentModelsAndIndependentHIDIdentitiesCannotBeCombined() throws {
        let suite = "rebind-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let a = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let b = settings.registerBluetoothRemote(identifier: UUID(), model: .rc001)
        #expect(!settings.rebindBluetoothRemote(profileID: a, to: b))
        settings.updateRemoteProfileModel(b, model: .rc003)
        #expect(settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "a"), to: a))
        #expect(settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "b"), to: b))
        #expect(!settings.rebindBluetoothRemote(profileID: a, to: b))
        #expect(settings.remoteDeviceProfiles.count == 2)
    }
}
