import CoreAudio
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Integration audio status")
@MainActor
struct IntegrationAudioStatusTests {
    @Test func integrationDestinationSurvivesIdleEngineAndDetectsMissingDriver() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.audioDevices = [AudioDeviceInfo(id: 111, uid: BuddyMicrophoneDevicePolicy.deviceUID,
            name: BuddyMicrophoneDevicePolicy.deviceName)]
        #expect(model.audioStatus.key == "audio.output.none_selected")
        #expect(!model.isAudioOutputReady)
        #expect(model.integrationAudioDeviceStatus.key == "audio.compatibility.device_detected")
        model.audio.startupPending = true
        #expect(model.integrationAudioDeviceStatus.key == "audio.compatibility.checking")
        model.audio.startupPending = false
        model.audioDevices = []
        #expect(model.integrationAudioDeviceStatus.key == "audio.compatibility.device_not_detected")
        #expect(model.settings.selectedAudioDeviceUID == BuddyMicrophoneDevicePolicy.deviceUID)
    }

    @Test func devicePropertyTeardownCleansUpObservedDeviceProperties() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        var removedDeviceProperties: [(AudioObjectID, AudioObjectPropertySelector)] = []
        model.audio.devicePropertyListenerRemover = { objectID, address, _, _ in
            removedDeviceProperties.append((objectID, address.mSelector))
            return noErr
        }
        model.audio.retainHardwareListener { _, _ in }
        model.audio.observedDeviceProperties = [
            (objectID: 42, address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )),
            (objectID: 42, address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ))
        ]
        #expect(model.audio.observedDeviceProperties.count == 2)
        model.stopObservingAudioHardware()
        #expect(model.audio.observedDeviceProperties.isEmpty)
        #expect(removedDeviceProperties.count == 2)
        #expect(removedDeviceProperties[0].0 == 42 && removedDeviceProperties[0].1 == kAudioDevicePropertyMute)
        #expect(removedDeviceProperties[1].0 == 42 && removedDeviceProperties[1].1 == kAudioDevicePropertyVolumeScalar)
    }

    @Test func deviceMuteNotificationInvalidatesCachedOutputReadiness() async throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        model.isAudioOutputReady = true

        model.scheduleAudioRecovery(reason: "hardware_change", details: "properties=device_mute")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!model.isAudioOutputReady)
    }
}
