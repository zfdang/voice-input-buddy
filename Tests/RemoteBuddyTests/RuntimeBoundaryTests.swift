import AppKit
import CoreAudio
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Runtime boundaries")
@MainActor
struct RuntimeBoundaryTests {
    private func values() -> (UserDefaults, String) {
        let name = "runtime-boundary-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test(arguments: [OnboardingStep.remote, .controls])
    func validationObservesButtonsWithoutExecutingConfiguredActions(step: OnboardingStep) {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.commandQuit, for: .right)
        let profile = UUID()
        var observed = 0
        var actions = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in actions += 1; return true },
            diagnosticLogger: { _ in })
        monitor.onButtonPressed = { _, _, _ in
            observed += 1
            return (profile, !OnboardingControlValidationPolicy.suppressConfiguredActions(at: step, source: .xiaomiRemote))
        }
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile)
        let usage = RemoteButton.right.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(observed == 1)
        #expect(actions == 0)
        monitor.disconnectSimulatedDevice()
        #expect(!OnboardingControlValidationPolicy.suppressConfiguredActions(at: .voiceTest, source: .xiaomiRemote))
    }

    @Test func resetPreservesReleaseOfNativePassthroughArrow() throws {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let filter = KeyboardEventSuppressor(uptime: { 0 })
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            eventSuppressor: filter, ownsEventSuppressor: false,
            runtimePermissions: { true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile, isSeized: false)
        let usage = RemoteButton.right.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: true))
        #expect(!filter.handle(type: .keyDown, event: down))
        monitor.cancelMappingInteractions()
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: false))
        #expect(!filter.handle(type: .keyUp, event: up))
        monitor.disconnectSimulatedDevice()
    }

    @Test func currentImportWithoutUnifiedBindingsClearsExistingOverrides() throws {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var object = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        object.removeValue(forKey: "unifiedBaseBindings")
        settings.setBaseBinding(ConfiguredButtonAction(action: .commandQuit, shortcut: nil), for: .right, trigger: .singleClick, profileID: nil)
        #expect(settings.configuredBaseAction(for: .right, trigger: .singleClick).action == .commandQuit)
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.unifiedBaseBindings.isEmpty)
        #expect(settings.configuredBaseAction(for: .right, trigger: .singleClick).action == .arrowRight)
    }

    @Test func configurationUsesOneFormatAndRejectsOtherVersionsBeforeMutation() throws {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var object = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        #expect(object["formatVersion"] as? Int == PersonalizedConfiguration.currentFormatVersion)
        settings.gainDB = 12
        for version in [1, 3] {
            object["formatVersion"] = version
            do {
                try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
                Issue.record("Unsupported format was accepted")
            } catch AppConfigurationError.unsupportedVersion {
                #expect(settings.gainDB == 12)
            }
        }
    }

    @Test(arguments: [ButtonTrigger.singleClick, .doubleClick, .longPress])
    func clearingGesturePersistsWithoutChangingOtherGestures(trigger: ButtonTrigger) {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        for gesture in ButtonTrigger.allCases {
            settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil),
                for: .right, trigger: gesture, profileID: nil)
        }
        settings.setBaseBinding(.disabled, for: .right, trigger: trigger, profileID: nil)
        let reloaded = AppSettings(defaults: defaults)
        for gesture in ButtonTrigger.allCases {
            #expect(reloaded.configuredBaseAction(for: .right, trigger: gesture, profileID: nil).action
                == (gesture == trigger ? .disabled : .commandCopy))
        }
        settings.setBaseBinding(.init(action: .commandPaste, shortcut: nil),
            for: .right, trigger: trigger, profileID: nil)
        #expect(settings.configuredBaseAction(for: .right, trigger: trigger, profileID: nil).action == .commandPaste)
    }

    @Test func corruptedMappingsAreReportedAndPreservedWhileDefaultsRecover() {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "buttonBindings")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.corruptedSettingKeys.contains("buttonBindings"))
        #expect(defaults.data(forKey: "buttonBindings.corrupt") == corrupt)
        #expect(settings.action(for: .right) == .arrowRight)
        #expect(defaults.data(forKey: "buttonBindings") == nil)
        let coldStart = AppSettings(defaults: defaults)
        #expect(!coldStart.corruptedSettingKeys.contains("buttonBindings"))
        #expect(coldStart.action(for: .right) == .arrowRight)
        #expect(defaults.data(forKey: "buttonBindings.corrupt") == corrupt)
        settings.setAction(.commandCopy, for: .right)
        let recovered = AppSettings(defaults: defaults)
        #expect(!recovered.corruptedSettingKeys.contains("buttonBindings"))
        #expect(recovered.action(for: .right) == .commandCopy)
        #expect(defaults.data(forKey: "buttonBindings.corrupt") == corrupt)
    }

    @Test func modelDestructionRemovesHALListenersWithoutExplicitStopAndNeverRemovesTwice() {
        for explicitlyStopped in [false, true] {
            let (defaults, name) = values()
            defer { defaults.removePersistentDomain(forName: name) }
            var model: BridgeAppModel? = BridgeAppModel(settings: AppSettings(defaults: defaults), initialAudioDevices: [])
            weak var released = model
            let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices,
                kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDefaultSystemOutputDevice]
            model?.audio.retainHardwareListener { _, _ in }
            model?.audio.observedHardwareAddresses = selectors.map {
                AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
            }
            var removed: [AudioObjectPropertySelector] = []
            model?.audio.hardwareListenerRemover = { address, _, _ in
                removed.append(address.mSelector)
                return noErr
            }
            if explicitlyStopped { model?.stopObservingAudioHardware() }
            model = nil
            #expect(released == nil)
            #expect(removed == selectors)
        }
    }

    @Test func oversizedConfigurationIsRejectedBeforeReadingOrDecoding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data(repeating: 32, count: ConfigurationFileReader.maximumBytes + 1)
        try data.write(to: file)
        #expect(throws: AppConfigurationError.self) { try ConfigurationFileReader.read(from: file) }
        #expect(throws: AppConfigurationError.self) { try AppSettings.validatedConfiguration(from: data) }
        try Data("small".utf8).write(to: file)
        #expect(try ConfigurationFileReader.read(from: file) == Data("small".utf8))
    }
    @Test func focusInputWaitsForActualFocusCompletionEvenIfOldFieldWasEditable() {
        let snapshot = VoiceInputDestinationSnapshot(bundleIdentifier: "example.editor", role: "AXTextArea", subrole: "", enabled: true, editable: true, protectedContent: false, semanticText: "Composer", focusIdentity: "old")
        let coordinator = VoiceInputDestinationCoordinator(schedule: { _, _ in ScheduledOperation(cancellation: {}) }, snapshot: { snapshot })
        let intent = VoiceInputDestinationIntent.resolve(configured: .init(action: .focusInput, shortcut: nil), applicationProfile: nil)
        #expect(intent == .focusInput)
        let id = coordinator.beginTargetSwitch(intent: .focusInput)
        var result: VoiceInputDestinationWaitResult?
        if case .waiting = coordinator.waitUntilReady(completion: { result = $0 }) {} else { Issue.record("Must wait for the focus callback") }
        #expect(result == nil)
        coordinator.completeFocusOperation(requestID: id + 1, succeeded: true)
        #expect(result == nil)
        coordinator.completeFocusOperation(requestID: id, succeeded: true)
        #expect(result == .ready)
        let failed = coordinator.beginTargetSwitch(intent: .focusInput)
        _ = coordinator.waitUntilReady { result = $0 }
        coordinator.completeFocusOperation(requestID: failed, succeeded: false)
        #expect(result == .cancelled(.actionFailed))
    }

    @Test func unifiedMappingCorruptionIsPreservedAfterSavingNewMappings() {
        let (defaults, name) = values()
        defer { defaults.removePersistentDomain(forName: name) }
        let bad = Data("corrupt mappings".utf8)
        defaults.set(bad, forKey: "unifiedBaseBindings")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.corruptedSettingKeys.contains("unifiedBaseBindings"))
        #expect(defaults.data(forKey: "unifiedBaseBindings.corrupt") == bad)
        settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .right, trigger: .singleClick, profileID: nil)
        #expect(AppSettings(defaults: defaults).configuredBaseAction(for: .right, trigger: .singleClick, profileID: nil).action == .commandCopy)
        #expect(defaults.data(forKey: "unifiedBaseBindings.corrupt") == bad)
    }

    @Test func mergedHALChangesIgnoreOnlyPureDefaultInputChanges() {
        #expect(AudioHardwareChangeProperties(details: "properties=default_input,default_input").affectsOnlyDefaultInput)
        #expect(!AudioHardwareChangeProperties(details: "properties=devices,default_input").affectsOnlyDefaultInput)
        #expect(!AudioHardwareChangeProperties(details: "engine_change").affectsOnlyDefaultInput)
        #expect(VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(details: "properties=default_system_output,default_system_output", configurationHealthy: true))
        #expect(!VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(details: "properties=devices,default_system_output", configurationHealthy: true))
    }

    @Test func unpairedDiscoveryDoesNotOwnVoiceSessionAndDeepLinksRejectUnknownSource() throws {
        let device = UUID()
        #expect(!BluetoothVoiceDeviceOwnershipPolicy.matches(nil, active: nil))
        #expect(!BluetoothVoiceDeviceOwnershipPolicy.matches(nil, active: device))
        #expect(!BluetoothVoiceDeviceOwnershipPolicy.matches(UUID(), active: device))
        #expect(BluetoothVoiceDeviceOwnershipPolicy.matches(device, active: device))
        for source in ["", "?source=invalid!name", "?source=external"] {
            let request = try #require(RemoteBuddyDeepLinkRequest.parse(URL(string: "voice-input-buddy://launch" + source)!))
            #expect(request.mayActivateSettings == (source == "?source=external"))
        }
    }

    @Test func outputStopAnswersDrainAndRejectsLaterReservations() async {
        let output = VirtualAudioOutput(logger: { _ in })
        output.registerPendingVoiceBuffer()
        let outcome = await withCheckedContinuation { continuation in
            output.endSessionAfterDraining { (outcome: VirtualAudioDrainOutcome) in continuation.resume(returning: outcome) }
            output.stop()
        }
        #expect(outcome == .forced)
        #expect(output.diagnosticSnapshot(deliveryGeneration: 0).pendingBuffers == 0)
        #expect(!output.enqueue(samples: [1, 2, 3]))
        #expect(output.diagnosticSnapshot(deliveryGeneration: 0).pendingBuffers == 0)
    }

    @Test func failedAudioConfigurationReleasesReservationsAndReadiness() async {
        let output = VirtualAudioOutput(logger: { _ in })
        output.registerPendingVoiceBuffer()
        let configured = await withCheckedContinuation { continuation in
            output.configureAsync(deviceUID: "nonexistent-test-device-" + UUID().uuidString) {
                continuation.resume(returning: $0)
            }
        }
        #expect(!configured)
        #expect(!output.isReadyForTestTone)
        #expect(output.diagnosticSnapshot(deliveryGeneration: 0).pendingBuffers == 0)
    }

}
