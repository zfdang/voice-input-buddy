import Testing
@testable import RemoteBuddy

@Suite("Foreign audio device safety")
struct ForeignAudioDeviceSafetyTests {
    @Test func foreignBlackHoleDevicesDoNotReceiveAudibilityRepairs() {
        let device = AudioDeviceInfo(id: 0, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        #expect(!CoreAudioDeviceCatalog.ensureVirtualAudioDeviceAudible(device).applicable)
    }
}
