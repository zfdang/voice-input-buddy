import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Virtual microphone identity")
struct AudioDeviceIdentityTests {
    @Test(arguments: ["Remote Buddy", "Remote Buddy Mic", "Voice Input Buddy", "Voice Input Buddy Mic", "BlackHole 2ch"])
    func matchingNameDoesNotProveDriverIsInstalled(name: String) {
        let foreign = AudioDeviceInfo(id: 1, uid: "unrelated-output", name: name)
        #expect(BuddyMicrophoneDevicePolicy.device(in: [foreign]) == nil)
        #expect(VirtualAudioDeviceDiagnosticKind.classify(foreign) == .other)
        #expect(!CoreAudioDeviceCatalog.ensureVirtualAudioDeviceAudible(foreign).applicable)
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: foreign.uid, name: foreign.name))
    }

    @Test func stableUIDRecognizesRenamedDrivers() {
        let owned = AudioDeviceInfo(id: 1, uid: BuddyMicrophoneDevicePolicy.deviceUID, name: "Renamed microphone")
        #expect(BuddyMicrophoneDevicePolicy.device(in: [owned])?.id == owned.id)
        #expect(VirtualAudioDeviceDiagnosticKind.classify(owned) == .buddyMic)
        #expect(VirtualAudioDeviceDiagnosticKind.classify(
            AudioDeviceInfo(id: 2, uid: "BlackHole2ch_UID", name: "Renamed BlackHole")) == .blackHole2ch)
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(uid: owned.uid, name: owned.name))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: "BlackHole2ch_UID", name: "Renamed BlackHole"))
    }
}
