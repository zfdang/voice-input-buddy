import Foundation
import Combine
import Testing
@testable import RemoteBuddy

@Suite("Remote gain and automatic driver setup")
@MainActor
struct RemoteGainAndDriverTests {
    @Test func repeatedSliderValuesDoNotRewriteTheProfileLibrary() throws {
        let name = "gain-writes-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(profile)
        var profileUpdates = 0
        let subscription = settings.$remoteDeviceProfiles.dropFirst().sink { _ in profileUpdates += 1 }
        defer { subscription.cancel() }
        settings.setGainDB(8, for: profile)
        #expect(profileUpdates == 1)
        for _ in 0..<120 { settings.setGainDB(8, for: profile) }
        settings.gainDB = 8
        #expect(profileUpdates == 1)
        #expect(AppSettings(defaults: defaults).gainDB(for: profile) == 8)
    }

    @Test func gainsPersistIndependentlyAndFollowTheRecordingDevice() throws {
        let suite = "remote-gain-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let firstBluetooth = UUID(), secondBluetooth = UUID()
        let first = settings.registerBluetoothRemote(identifier: firstBluetooth, model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: secondBluetooth, model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(first)
        settings.setGainDB(6, for: first)
        settings.setGainDB(18, for: second)
        #expect(settings.gainDB == 6)
        #expect(settings.gainDB(forBluetoothIdentifier: secondBluetooth) == 18)
        settings.selectRemoteProfile(second)
        #expect(settings.gainDB == 18)
        #expect(settings.gainDB(forBluetoothIdentifier: firstBluetooth) == 6)
        settings.gainDB = 12 // The voice-test slider edits only the selected remote.
        #expect(settings.gainDB(for: first) == 6)
        #expect(settings.gainDB(for: second) == 12)
        for invalid in [Double.nan, .infinity, -1, 25] { settings.setGainDB(invalid, for: first) }
        #expect(settings.gainDB(for: first) == 6)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.gainDB(for: first) == 6)
        #expect(restored.gainDB(for: second) == 12)
        #expect(restored.gainDB == 12)
        let exported = try settings.exportedConfigurationData()
        restored.setGainDB(0, for: first)
        restored.setGainDB(0, for: second)
        try restored.importConfiguration(from: exported)
        #expect(restored.gainDB(for: first) == 6)
        #expect(restored.gainDB(for: second) == 12)
        #expect(restored.configurationImportNotice == nil)
    }

    @Test func firstRemoteAdoptsThePreparedGainWithoutChangingLaterDeviceDefaults() throws {
        let suite = "first-remote-gain-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.gainDB = 18
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(first)
        #expect(settings.gainDB(for: first) == 18)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(second)
        #expect(settings.gainDB == 10)
        #expect(settings.gainDB(for: first) == 18)
    }

    @Test func fixedOutputCannotBeOverriddenByStoredOrImportedSelection() throws {
        let suite = "fixed-output-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("speaker", forKey: "selectedAudioDeviceUID")
        defaults.set("BlackHole2ch_UID", forKey: "lastKnownAudioDeviceUID")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.selectedAudioDeviceUID == BuddyMicrophoneDevicePolicy.deviceUID)
        var payload = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        #expect(payload["selectedAudioDeviceUID"] == nil)
        payload["selectedAudioDeviceUID"] = "speaker"
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: payload))
        #expect(settings.selectedAudioDeviceUID == BuddyMicrophoneDevicePolicy.deviceUID)
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: "speaker", name: BuddyMicrophoneDevicePolicy.deviceName))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch"))
    }

    @Test func driverStepRequiresAConfiguredOutput() {
        var capabilities = OnboardingCapabilities(bluetoothGranted: true, inputMonitoringGranted: true, accessibilityGranted: true, microphoneDriverInstalled: true, audioOutputSelected: true)
        for method in [OnboardingControlMethod.physicalRemote] {
            #expect(!OnboardingFlowPolicy.canContinue(from: .audio, voiceTool: .unselected,
                controlMethod: method, capabilities: capabilities))
        }
        capabilities.audioReady = true
        #expect(OnboardingFlowPolicy.canContinue(from: .audio, voiceTool: .unselected,
            controlMethod: .physicalRemote, capabilities: capabilities))
    }

    @Test func driverCheckKeepsManualNavigationInBothDirections() throws {
        let name = "driver-navigation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingControlSource(.xiaomiRemote)
        settings.setOnboardingStep(.audio)
        let device = AudioDeviceInfo(id: 1, uid: BuddyMicrophoneDevicePolicy.deviceUID,
            name: BuddyMicrophoneDevicePolicy.deviceName)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [device])
        let view = OnboardingView(model: model, permissionOverrides: .allGranted)
        #expect(!view.canContinue)
        view.continueFlow()
        #expect(settings.onboardingStep == .audio)
        model.isAudioOutputReady = true
        #expect(view.canContinue)
        #expect(settings.onboardingStep == .audio)
        view.continueFlow()
        #expect(settings.onboardingStep == .voiceTool)
        settings.setOnboardingStep(try #require(settings.onboardingPurpose.previousStep(before: .voiceTool)))
        #expect(settings.onboardingStep == .audio)
        #expect(view.canContinue)
        settings.setOnboardingStep(try #require(settings.onboardingPurpose.previousStep(before: .audio)))
        #expect(settings.onboardingStep == .controls)
        #expect(OnboardingStep.visibleCases[2] == .remote)
        #expect(OnboardingStep.visibleCases[3] == .controls)
        #expect(OnboardingStep.visibleCases[4] == .audio)
    }
}
