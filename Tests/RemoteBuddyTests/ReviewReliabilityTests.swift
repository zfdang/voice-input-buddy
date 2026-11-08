import AppKit
import CoreAudio
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Review reliability regressions")
@MainActor
struct ReviewReliabilityTests {
    @Test @MainActor func devicePagePolicyMatchesViewForEverySelection() throws {
        let name = "review-policy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingStep(.remoteAvailability)
        let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
        #expect(!view.canContinue)
        for device in RemoteSetupDevice.allCases {
            view.selectDevice(device)
            #expect(OnboardingFlowPolicy.canContinue(from: .remoteAvailability, voiceTool: .unselected,
                remoteAvailability: settings.onboardingRemoteAvailability,
                selectedDevice: device, capabilities: view.capabilities) == view.canContinue)
            #expect(view.canContinue == device.canStartSetup)
            #expect(view.failureReason == nil)
        }
        #expect(!OnboardingFlowPolicy.canContinue(from: .remoteAvailability, voiceTool: .unselected,
            capabilities: .init()))
    }

    @Test @MainActor func sharedCaptureUsesLatestCallbackAndDoesNotRetainCoordinator() {
        var oldCalls = 0
        var newCalls = 0
        var coordinator: ShortcutCaptureView.Coordinator? = .init(
            onCapture: { _ in oldCalls += 1 }, onFailure: { _ in })
        weak let observed = coordinator
        let callback = coordinator!.captureHandler()
        coordinator!.onCapture = { _ in newCalls += 1 }
        let shortcut = CustomKeyboardShortcut(keyCode: 8, modifierFlags: .command, keyLabel: "C")
        callback(shortcut)
        #expect(oldCalls == 0)
        #expect(newCalls == 1)
        coordinator = nil
        #expect(observed == nil)
        callback(shortcut)
        #expect(newCalls == 1)
    }

    @Test func deviceWriterRejectsGlobalRoutesBeforeCallingCoreAudio() {
        var calls = 0
        let writer: CoreAudioDevicePropertyWriter.Writer = { _, _, _, _, _, _ in calls += 1; return noErr }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        #expect(!CoreAudioDevicePropertyWriter.write(UInt32(0), to: AudioObjectID(kAudioObjectSystemObject),
            address: &address, writer: writer))
        #expect(!CoreAudioDevicePropertyWriter.write(UInt32(0), to: AudioObjectID(kAudioObjectUnknown),
            address: &address, writer: writer))
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        #expect(!CoreAudioDevicePropertyWriter.write(UInt32(0), to: 42, address: &address, writer: writer))
        #expect(calls == 0)
        address.mSelector = kAudioDevicePropertyMute
        #expect(CoreAudioDevicePropertyWriter.write(UInt32(0), to: 42, address: &address, writer: writer))
        #expect(calls == 1)
        #expect(!CoreAudioDevicePropertyWriter.write(UInt32(0), to: 42, address: &address,
            writer: { _, _, _, _, _, _ in kAudioHardwareIllegalOperationError }))
    }

    @Test func volumeAndMuteRepairReadinessRequiresObservedRecovery() {
        let muted = VirtualAudioDeviceAudibilitySnapshot(output: .init(mute: true, volume: 0.1))
        #expect(muted.requiresAudibilityRepair)
        var result = VirtualAudioDeviceAudibilityRepairResult(applicable: true, before: muted, after: muted)
        #expect(!result.isReady)
        result.after = .init()
        #expect(!result.isReady)
        result.after = .init(output: .init(mute: false, volume: 1))
        #expect(result.isReady)
        #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 0.2))
        #expect(VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: 0.199))
        for value in [Float.nan, .infinity, -.infinity] {
            #expect(!VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: value))
        }
    }

    @Test func resetBindingsPersistsCompleteSelectedProfileAndKeepsOtherDevices() throws {
        let name = "review-bindings-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID())
        let second = settings.registerBluetoothRemote(identifier: UUID())
        settings.selectRemoteProfile(second)
        settings.setAction(.commandCopy, for: .left)
        settings.selectRemoteProfile(first)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
            for: .left, trigger: .singleClick, profileID: first)
        settings.resetBindings()
        let restored = AppSettings(defaults: defaults)
        #expect(restored.configuredBaseAction(for: .left, trigger: .singleClick, profileID: first).action == .arrowLeft)
        restored.selectRemoteProfile(second)
        #expect(restored.configuredAction(for: .left, trigger: .singleClick).action == .commandCopy)
    }
    @Test func audibilityRepairRestoresBothScopesAndReadsBackActualState() {
        var state = VirtualAudioDeviceAudibilitySnapshot(
            output: .init(mute: true, volume: 0), input: .init(mute: true, volume: 0.1))
        var writes: [AudioObjectPropertyScope] = []
        let result = VirtualAudioAudibilityRepair.run(read: { state }, writeMute: { scope, value in
            #expect(value == 0)
            writes.append(scope)
            if scope == kAudioDevicePropertyScopeOutput { state.output.mute = false }
            else { state.input.mute = false }
            return true
        }, writeVolume: { scope, value in
            #expect(value == 1)
            writes.append(scope)
            if scope == kAudioDevicePropertyScopeOutput { state.output.volume = value }
            else { state.input.volume = value }
            return true
        })
        #expect(result.isReady)
        #expect(result.unmuteAttempted && result.volumeRestoreAttempted)
        #expect(!result.writeFailed)
        #expect(writes == [kAudioDevicePropertyScopeOutput, kAudioDevicePropertyScopeOutput,
                           kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeInput])
    }

    @Test func failedAudibilityWriteCannotClaimReadinessAndUnknownLevelsAreNotWritten() {
        let muted = VirtualAudioDeviceAudibilitySnapshot(output: .init(mute: true, volume: 0))
        let failed = VirtualAudioAudibilityRepair.run(read: { muted },
            writeMute: { _, _ in false }, writeVolume: { _, _ in false })
        #expect(failed.writeFailed)
        #expect(!failed.isReady)
        var writes = 0
        let unknown = VirtualAudioAudibilityRepair.run(read: { .init() },
            writeMute: { _, _ in writes += 1; return true },
            writeVolume: { _, _ in writes += 1; return true })
        #expect(!unknown.unmuteAttempted && !unknown.volumeRestoreAttempted)
        #expect(writes == 0)
    }

    @Test @MainActor func immutableLocalizationSnapshotKeepsItsLanguageWhenUISelectionChanges() throws {
        let name = "review-localization-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults),
                                      resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
        store.select(.english)
        let snapshot = store.snapshot
        store.select(.simplifiedChinese)
        #expect(snapshot.locale.identifier == "en")
        #expect(store.locale.identifier == "zh-Hans")
        #expect(snapshot.text("common.action.cancel") == "Cancel")
        #expect(store.text("common.action.cancel") != snapshot.text("common.action.cancel"))
    }

}
