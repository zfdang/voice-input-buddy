import AppKit
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Runtime operation lifecycle")
@MainActor
struct RuntimeOperationLifecycleTests {
    @Test func disabledCaptureNotifiesPromptAndCancelsQueuedKeys() throws {
        var pending: [() -> Void] = []
        var captures = 0
        var failures: [ShortcutCaptureStartFailure] = []
        let monitor = ShortcutCaptureMonitor(onCapture: { _ in captures += 1 },
            onUnavailable: { failures.append($0) }, accessibilityTrusted: { false },
            modifierIsPressed: { _ in false }, dispatchCallback: { pending.append($0) })
        monitor.resetCaptureState()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
        #expect(monitor.handle(type: .keyDown, event: key))
        #expect(!monitor.handle(type: .tapDisabledByTimeout, event: key))
        pending.forEach { $0() }
        #expect(captures == 0)
        #expect(failures == [.accessibilityPermissionRequired])
    }

    @Test(arguments: [false, true])
    func cancelledRecorderDiscardsQueuedCapture(reset: Bool) throws {
        var pending: [() -> Void] = []
        var captured: [CustomKeyboardShortcut] = []
        let monitor = ShortcutCaptureMonitor(onCapture: { captured.append($0) },
            accessibilityTrusted: { true }, modifierIsPressed: { _ in false },
            dispatchCallback: { pending.append($0) })
        monitor.resetCaptureState()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
        #expect(monitor.handle(type: .keyDown, event: key))
        #expect(pending.count == 1)
        if reset { monitor.resetCaptureState() } else { monitor.stop() }
        pending.removeFirst()()
        #expect(captured.isEmpty)
    }

    @Test func staleAudioStartupCannotStopNewSession() async throws {
        let name = "operation-lifecycle-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        model.audio.startupGeneration = 2
        model.audio.output.registerPendingVoiceBuffer()
        model.finishAudioStartup(generation: 1, configurationGeneration: 1, configured: false, devices: [])
        // Wait for the actual production cleanup queue; no live HAL device is allocated.
        await withCheckedContinuation { continuation in
            model.audio.preparationQueue.async { continuation.resume() }
        }
        #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 1)
    }
    @Test func currentRecorderDeliversOnceAndDoesNotRetainStoppedMonitor() throws {
        var pending: [() -> Void] = []
        var captures = 0
        var monitor: ShortcutCaptureMonitor? = ShortcutCaptureMonitor(onCapture: { _ in captures += 1 },
            accessibilityTrusted: { true }, modifierIsPressed: { _ in false },
            dispatchCallback: { pending.append($0) })
        weak let weakMonitor = monitor
        monitor?.resetCaptureState()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
        #expect(monitor?.handle(type: .keyDown, event: key) == true)
        pending.removeFirst()()
        #expect(captures == 1)
        monitor?.resetCaptureState()
        #expect(monitor?.handle(type: .keyDown, event: key) == true)
        monitor = nil
        #expect(weakMonitor == nil)
        pending.removeFirst()()
        #expect(captures == 1)
    }

    @Test func stoppedModifierRecorderDiscardsQueuedCapture() throws {
        var pending: [() -> Void] = []
        var captures = 0
        let monitor = ShortcutCaptureMonitor(onCapture: { _ in captures += 1 },
            accessibilityTrusted: { true }, modifierIsPressed: { _ in false },
            dispatchCallback: { pending.append($0) })
        monitor.resetCaptureState()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true))
        key.type = .flagsChanged
        key.flags = .maskCommand
        #expect(monitor.handle(type: .flagsChanged, event: key))
        key.flags = []
        #expect(monitor.handle(type: .flagsChanged, event: key))
        #expect(pending.count == 1)
        monitor.stop()
        pending.removeFirst()()
        #expect(captures == 0)
    }

    @Test func startupAlwaysTargetsOwnedMicrophoneAndRejectsStaleEnumeration() throws {
        let name = "startup-selection-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        let model = BridgeAppModel(settings: settings)
        model.started = true
        defer { model.started = false }
        model.audio.startupGeneration = 2
        // Represents the main-actor handoff after a slow background enumeration.
        var requests: [String] = []
        model.prepareAudioStartup(generation: 1, devices: [], configureOutput: { uid, _ in requests.append(uid) })
        #expect(requests.isEmpty)
        model.prepareAudioStartup(generation: 2, devices: [], configureOutput: { uid, _ in requests.append(uid) })
        #expect(requests == [BuddyMicrophoneDevicePolicy.deviceUID])
        #expect(settings.selectedAudioDeviceUID == BuddyMicrophoneDevicePolicy.deviceUID)
        #expect(model.audio.output.pendingVoiceBufferCountForDiagnostics == 0)
    }

    @Test(arguments: [false, true])
    func unavailableNativeFilterCannotDuplicateMappedActions(seized: Bool) throws {
        let name = "mapping-filter-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        settings.setAction(.commandQuit, for: .up)
        var actions = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in actions += 1; return true },
            diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile, isSeized: seized)
        let usage = RemoteButton.up.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(actions == (seized ? 1 : 0))
        monitor.disconnectSimulatedDevice()
    }

    @Test(arguments: [false, true])
    func lostFilterCancelsDelayedActions(longPress: Bool) throws {
        let name = "mapping-filter-lost-" + UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        if longPress { settings.setAction(.commandQuit, for: .up, trigger: .longPress) }
        let scheduler = ControlledTestScheduler()
        var filtering = true
        var actions = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            scheduler: scheduler, runtimePermissions: { true }, nativeSuppressionAvailable: { filtering },
            actionPerformer: { _, _, _ in actions += 1; return true },
            diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile, isSeized: false)
        let usage = RemoteButton.up.hidUsage
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        let beforeLoss = actions
        #expect(beforeLoss == (longPress ? 0 : 1))
        filtering = false
        scheduler.fire(afterMilliseconds: longPress ? HIDRemoteTiming.longPressMilliseconds : HIDRemoteTiming.repeatStartMilliseconds)
        #expect(actions == beforeLoss)
        monitor.disconnectSimulatedDevice()
    }

}
