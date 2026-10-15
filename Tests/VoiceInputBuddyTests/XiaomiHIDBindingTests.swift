import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Xiaomi HID identity binding")
struct XiaomiHIDBindingTests {
    @Test(arguments: [false, true])
    func ambiguousBluetoothProfilesWaitForExplicitBinding(selectSecond: Bool) throws {
        let name = "xiaomi-binding-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(selectSecond ? second : first)
        let before = settings.remoteDeviceProfiles
        #expect(settings.registerHIDRemote(fingerprint: "second-remote") == nil)
        #expect(settings.remoteDeviceProfiles == before)
        #expect(settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "second-remote"), to: second))
        #expect(settings.profileID(forHIDFingerprint: "second-remote") == second)
        #expect(settings.remoteDeviceProfiles.first { $0.id == first }?.hidFingerprint == nil)
        #expect(settings.registerHIDRemote(fingerprint: "second-remote") == second)
        #expect(settings.registerHIDRemote(fingerprint: "first-remote") == first)
    }

    @Test func aSingleXiaomiCandidateDoesNotBindAppleOrGoogleProfiles() throws {
        let name = "xiaomi-family-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let mappings = RemoteDeviceMappings(buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:], secondaryButtonBindings: [:])
        let apple = RemoteDeviceProfile(model: .appleSiriRemoteA2854, mappings: mappings)
        let google = RemoteDeviceProfile(model: .chromecastVoiceRemote, mappings: mappings)
        settings.remoteDeviceProfiles = [apple, google]
        settings.selectRemoteProfile(apple.id)
        let xiaomi = try #require(settings.registerHIDRemote(fingerprint: "xiaomi-only"))
        #expect(xiaomi != apple.id && xiaomi != google.id)
        #expect(settings.remoteDeviceProfiles.first { $0.id == apple.id }?.hidFingerprint == nil)
        #expect(settings.remoteDeviceProfiles.first { $0.id == google.id }?.hidFingerprint == nil)
    }
}
