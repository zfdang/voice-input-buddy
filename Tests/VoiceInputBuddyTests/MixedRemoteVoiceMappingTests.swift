import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Mixed remote voice mapping")
@MainActor
struct MixedRemoteVoiceMappingTests {
    @Test(arguments: VoiceKeyMode.allCases, [false, true])
    func googleSelectionPreservesTheXiaomiTriggerPolicy(mode: VoiceKeyMode, tapMode: Bool) throws {
        let name = "mixed-voice-mapping-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.setOnboardingVoiceTool(.other)
        settings.voiceKeyMode = mode
        settings.voiceFnTapModeEnabled = tapMode && mode == .function
        let model = BridgeAppModel(settings: settings)
        var mappings: [HIDUsageMapping] = []
        let mapper = RemoteHIDKeyMapper(serviceProvider: {
            [RemoteHIDMappingService(registryID: 1, readMappings: { mappings },
                setMappings: { mappings = $0; return true })]
        }, recoveryDefaults: defaults, bootID: "test")
        let expectedNeutral = mode != .function || tapMode
        for profile in [xiaomi, google, xiaomi] {
            settings.selectRemoteProfile(profile)
            #expect(model.shouldNeutralizeNativeVoiceKey == expectedNeutral)
            #expect(mapper.apply(neutralizeVoiceKey: model.shouldNeutralizeNativeVoiceKey))
            #expect(mappings.contains(expectedNeutral
                ? RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey
                : RemoteHIDKeyMappingPolicy.remoteVoiceKey))
        }
        mapper.restore()
    }

    @Test func orderedInputSourceActivationKeepsNativeFnNeutralForEitherSelection() throws {
        let name = "mixed-voice-mapping-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.setOnboardingVoiceTool(.weixin)
        settings.voiceKeyMode = .function
        settings.voiceFnTapModeEnabled = false
        let model = BridgeAppModel(settings: settings)
        for profile in [google, xiaomi] {
            settings.selectRemoteProfile(profile)
            #expect(model.requiresOrderedVoiceFn)
            #expect(model.shouldNeutralizeNativeVoiceKey)
        }
        settings.setOnboardingVoiceTool(.other)
        #expect(!model.shouldNeutralizeNativeVoiceKey)
    }
}
