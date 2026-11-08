import AppKit
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Input lifecycle regressions")
@MainActor
struct InputLifecycleRegressionTests {
    private final class Probe {}
    private func defaults() -> (UserDefaults, String) {
        let name = "input-lifecycle-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func accessibilityTimeoutFailureIsReportedWithoutRetries() {
        var attempts = 0
        var messages: [String] = []
        let result = AccessibilityMessaging.configureTimeout(
            install: { attempts += 1; return .invalidUIElement }, reportFailure: { messages.append($0) })
        #expect(result == .invalidUIElement)
        #expect(attempts == 1)
        #expect(messages == ["AX TIMEOUT configuration_failed code=\(result.rawValue)"])
        messages.removeAll()
        let successful = AccessibilityMessaging.configureTimeout(install: { .success }, reportFailure: { messages.append($0) })
        #expect(successful == .success)
        #expect(messages.isEmpty)
    }

    @Test func interruptedMonitoringRecoversEvenWhenCachedPermissionsNeverChanged() {
        for granted in [false, true] {
            let snapshot = HIDPermissionSnapshot(inputMonitoringGranted: granted, accessibilityGranted: granted)
            let shouldRecover = HIDPermissionRecoveryPolicy.shouldReapplySettings(
                started: true, customMappingEnabled: true, monitoringInterrupted: true,
                previous: snapshot, current: snapshot)
            #expect(shouldRecover == granted)
        }
    }

    @Test func systemDisabledSharedFilterAlsoStopsDeviceMappings() {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        let model = BridgeAppModel(settings: settings)
        let monitor = HIDRemoteMonitor(settings: settings, profileID: nil,
            eventSuppressor: model.hidEventSuppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: UUID())
        var resets = 0
        monitor.onInputReset = { _ in resets += 1 }
        model.hidMonitors["test"] = monitor
        model.activeRemoteButtons = [.right]
        model.hidEventSuppressor.onSystemDisabled?()
        #expect(resets == 1)
        #expect(model.hidMonitors.isEmpty)
        #expect(model.activeRemoteButtons.isEmpty)
        #expect(model.hidMonitoringInterrupted)
        // UI messages can change independently; recovery uses the explicit interruption flag.
        model.hidStatus = LocalizedMessage("button_mapping.status.system_managed")
        let granted = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
        #expect(HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true, customMappingEnabled: true,
            monitoringInterrupted: model.hidMonitoringInterrupted, previous: granted, current: granted))
        monitor.onInputReset = nil
    }

    @Test(arguments: [VoiceKeyMode.function, .leftCommand, .rightOption])
    func deniedVoiceReleaseKeepsLatchUntilSuccessfulRetry(mode: VoiceKeyMode) {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        _ = model.voiceKeyLatch.transition(streaming: true, owner: .bluetooth)
        model.heldVoiceKeyMode = mode
        var attempts = 0
        let denied = model.releaseVoiceKeyIfNeeded { actualMode in
            attempts += 1
            #expect(actualMode == mode)
            return false
        }
        #expect(!denied)
        #expect(attempts == 1)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(model.heldVoiceKeyMode == mode)
        let recovered = model.releaseVoiceKeyIfNeeded { _ in attempts += 1; return true }
        #expect(recovered)
        #expect(attempts == 2)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(model.heldVoiceKeyMode == nil)
    }

    @Test func deniedFilterStartDoesNotCreateTapAndClearsPendingSuppression() throws {
        let filter = KeyboardEventSuppressor(uptime: { 0 }, permissionsGranted: { false })
        filter.arm(button: .right, edge: .down)
        #expect(!filter.start())
        #expect(!filter.isRunning)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: true))
        #expect(!filter.handle(type: .keyDown, event: event))
    }

    @Test func accessibilityTraversalStopsOnEitherNodeOrTimeBudget() {
        var now: TimeInterval = 10
        var budget = AccessibilityTraversalBudget(maximumNodes: 2, uptime: { now })
        func admit() -> Bool { budget.admitNode() }
        #expect(admit())
        #expect(admit())
        #expect(!admit())
        budget = AccessibilityTraversalBudget(maximumNodes: 5_000, uptime: { now })
        #expect(admit())
        now = 11
        #expect(!admit())
        now = 100
        #expect(!admit())
    }

    @Test(arguments: [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput])
    func tapRecoveryReturnsBeforePermissionChecksAndDoesNotReviveStoppedPorts(type: CGEventType) {
        var work: [() -> Void] = []
        var current = true
        var permissionChecks = 0, enables = 0, stops = 0
        EventTapPort.deferRecovery(type: type, dispatch: { work.append($0) },
            isCurrent: { current }, permissionsGranted: { permissionChecks += 1; return true },
            enable: { enables += 1 }, stop: { stops += 1 })
        #expect(permissionChecks == 0 && enables == 0 && stops == 0)
        current = false
        work.removeFirst()()
        #expect(permissionChecks == 0 && enables == 0 && stops == 0)
    }

    @Test(arguments: [false, true])
    func bothTapDisableNotificationsRecoverOnlyWithPermission(granted: Bool) {
        var work: [() -> Void] = []
        var enables = 0, stops = 0, checks = 0
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            EventTapPort.deferRecovery(type: type, dispatch: { work.append($0) },
                isCurrent: { true }, permissionsGranted: { checks += 1; return granted },
                enable: { enables += 1 }, stop: { stops += 1 })
            work.removeFirst()()
        }
        #expect(checks == 2)
        #expect(enables == (granted ? 2 : 0))
        #expect(stops == (granted ? 0 : 2))
    }

    @Test func revokedPermissionsClearSharedFilterBeforeInputReset() throws {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        var granted = true
        let filter = KeyboardEventSuppressor(uptime: { 0 })
        let monitor = HIDRemoteMonitor(settings: settings, profileID: nil,
            eventSuppressor: filter, ownsEventSuppressor: false, runtimePermissions: { granted },
            actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: UUID())
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: true))
        filter.arm(button: .right, edge: .down)
        #expect(filter.handle(type: .keyDown, event: event))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(filter.handle(type: .keyDown, event: event))
        var resets = 0
        var interruptions = 0
        monitor.onMonitoringInterrupted = { interruptions += 1 }
        monitor.onInputReset = { _ in
            resets += 1
            #expect(!filter.handle(type: .keyDown, event: event))
        }
        granted = false
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(resets == 1)
        #expect(interruptions == 1)
    }

    @Test func failedFnReleaseDoesNotReportCleanupCompleteOrReenter() {
        var operations: [() -> Void] = []
        var allowRelease = false
        var callbacks = 0
        let session = VoiceFnTapSessionController(
            startDelay: 0, tapDuration: 0,
            schedule: { _, operation in
                operations.append(operation)
                return ScheduledOperation(cancellation: {})
            },
            setFunctionKeyPressed: { pressed in pressed || allowRelease },
            enqueueAudio: { _ in }, drainAudio: { _, completion in completion() },
            onFailure: { _ in }
        )
        session.setEnabled(true)
        #expect(session.startVoice())
        operations.removeFirst()()
        operations.removeFirst()()
        #expect(session.requiresCleanupBeforeMapping)
        session.setEnabled(false) { _ in callbacks += 1 }
        #expect(callbacks == 0)
        allowRelease = true
        session.suspend()
        #expect(callbacks == 1)
        #expect(!session.requiresCleanupBeforeMapping)
    }

    @Test func mixedReportDeliversReleaseDespiteRejectedNewPress() {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        for button in RemoteButton.allCases {
            settings.setAction(.escape, for: button, trigger: .singleClick)
        }
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in false }, diagnosticLogger: { _ in })
        var releases: [RemoteButton] = []
        monitor.onRuntimeButton = { _, button, edge in
            if edge == .release { releases.append(button) }
            return false
        }
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile)
        func report(_ button: RemoteButton) {
            let usage = button.hidUsage
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        }
        report(.up)
        report(.right)
        #expect(releases == [.up])
        monitor.disconnectSimulatedDevice()
    }

    @Test func stoppedMonitorDoesNotDispatchRemainingPressesInSameReport() {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        for button in RemoteButton.allCases {
            settings.setAction(.escape, for: button, trigger: .singleClick)
        }
        var allowed = true
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { allowed }, actionPerformer: { _, _, _ in allowed = false; return false },
            diagnosticLogger: { _ in })
        var presses: [RemoteButton] = []
        monitor.onRuntimeButton = { _, button, edge in
            if edge == .press { presses.append(button) }
            return false
        }
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile)
        let usages = [RemoteButton.up.hidUsage, RemoteButton.right.hidUsage].sorted()
        let bytes = usages.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        monitor.handleSimulatedReport(reportID: 1, data: Data(bytes))
        #expect(presses.count == 1)
    }

    @Test(arguments: [false, true])
    func appSwitcherNavigationOwnsNativeArrowsOnUnseizedDevice(delayedNativeEvents: Bool) throws {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        settings.setAction(.appSwitcher, for: .tv)
        settings.setAction(.arrowRight, for: .right)
        settings.setAction(.arrowLeft, for: .left)
        // This exercises delivery order, not wall-clock expiry. AppKit event
        // creation can exceed the pending window on a busy UI/build machine.
        let filter = KeyboardEventSuppressor(uptime: { 0 })
        var selections: [UInt16] = []
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            eventSuppressor: filter, ownsEventSuppressor: false,
            runtimePermissions: { true }, nativeSuppressionAvailable: { true },
            diagnosticLogger: { _ in },
            appSwitcherKeyStatePoster: { code, down, _ in
                if down && (code == 123 || code == 124) { selections.append(code) }
                return true
            })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile, isSeized: false)
        func report(_ button: RemoteButton?) {
            let usage = button?.hidUsage ?? 0
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        }
        report(.tv)
        report(nil)
        for (button, code): (RemoteButton, UInt16) in [(.right, 124), (.left, 123), (.right, 124)] {
            report(button)
            // An identical held report must not inject a second navigation step.
            report(button)
            let nativeDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            if delayedNativeEvents { report(nil) }
            #expect(filter.handle(type: .keyDown, event: nativeDown))
            if !delayedNativeEvents { report(nil) }
            nativeDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            #expect(filter.handle(type: .keyDown, event: nativeDown))
            let nativeUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false))
            #expect(filter.handle(type: .keyUp, event: nativeUp))
        }
        #expect(selections == [124, 123, 124])
        monitor.disconnectSimulatedDevice()
    }

    @Test func rejectedActionDoesNotDisableMonitorWhilePermissionsRemainValid() {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        settings.customMappingEnabled = true
        let profile = UUID()
        var actions: [RemoteButton] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile,
            runtimePermissions: { true }, actionPerformer: { button, _, _ in
                actions.append(button)
                return button != .right
            }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile)
        for button: RemoteButton? in [.right, nil, .left] {
            let usage = button?.hidUsage ?? 0
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(usage & 255), UInt8(usage >> 8)]))
        }
        #expect(actions == [.right, .left])
        monitor.disconnectSimulatedDevice()
    }

    @Test func physicalKeyUpIsNeverConsumedAfterItsDownPassed() throws {
        let filter = KeyboardEventSuppressor()
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: false))
        filter.arm(nativeEvents: [.keyboard(keyCode: 50)], edge: .down)
        #expect(filter.handle(type: .keyDown, event: down))
        filter.arm(nativeEvents: [.keyboard(keyCode: 50)], edge: .up)
        #expect(!filter.handle(type: .keyDown, event: down))
        #expect(!filter.handle(type: .keyUp, event: up))
    }

    @Test func unpairedReleaseAndExpiredHoldPass() throws {
        var now = 0.0
        let filter = KeyboardEventSuppressor(uptime: { now })
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: false))
        filter.arm(nativeEvents: [.keyboard(keyCode: 50)], edge: .up)
        #expect(!filter.handle(type: .keyUp, event: up))
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        filter.arm(nativeEvents: [.keyboard(keyCode: 50)], edge: .down)
        #expect(filter.handle(type: .keyDown, event: down))
        now = 31
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(!filter.handle(type: .keyDown, event: down))
    }

    @Test func restartWizardClearsPriorValidationHistory() throws {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let binding = VoiceToolUserBinding(tool: .weixin, shortcut: .function,
            gestureMode: .hold, source: .manuallyConfirmed, validationState: .verified)
        values.set(try JSONEncoder().encode(binding), forKey: "onboarding.verifiedVoiceBinding")
        let settings = AppSettings(defaults: values)
        #expect(settings.verifiedVoiceToolBinding != nil)
        settings.completeOnboarding()
        settings.recordFirstUseEvent(.completed, step: .audio)
        settings.restartOnboarding()
        #expect(!settings.isOnboardingComplete)
        #expect(settings.firstUseEvents.isEmpty)
        #expect(settings.verifiedVoiceToolBinding == nil)
    }

    @Test func recorderIgnoresReleaseOfModifierHeldBeforeOpening() throws {
        var captured: [CustomKeyboardShortcut] = []
        let recorder = ShortcutCaptureMonitor(onCapture: { captured.append($0) },
            accessibilityTrusted: { true }, modifierIsPressed: { $0 == 55 }, dispatchCallback: { $0() })
        recorder.resetCaptureState()
        let command = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true))
        command.type = .flagsChanged
        command.flags = []
        #expect(recorder.handle(type: .flagsChanged, event: command))
        #expect(captured.isEmpty)
        command.flags = .maskCommand
        #expect(recorder.handle(type: .flagsChanged, event: command))
        #expect(captured.isEmpty)
        let x = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
        x.flags = .maskCommand
        #expect(recorder.handle(type: .keyDown, event: x))
        #expect(captured.count == 1)
        #expect(captured.first?.keyCode == 7)
    }

    @Test func mediaReleasePassesAfterFreshMediaDown() throws {
        let filter = KeyboardEventSuppressor()
        func event(_ state: Int) throws -> CGEvent {
            let ns = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: state << 8, data2: -1))
            return try #require(ns.cgEvent)
        }
        let down = try event(0xA), up = try event(0xB)
        let type = CGEventType(rawValue: 14)!
        filter.arm(nativeEvents: [.systemKey(type: 0)], edge: .down)
        #expect(filter.handle(type: type, event: down))
        filter.arm(nativeEvents: [.systemKey(type: 0)], edge: .up)
        #expect(!filter.handle(type: type, event: down))
        #expect(!filter.handle(type: type, event: up))
    }

    @Test func volumeActionsUseInjectedPoster() {
        var keys: [Int32] = []
        for action: ButtonAction in [.volumeUp, .volumeDown, .volumeMute, .playPause] {
            #expect(KeyboardInjector.send(action, accessibilityTrusted: { true }, systemKeyPoster: { keys.append($0) }))
        }
        #expect(keys == [0, 1, 7, 16])
    }

    @Test func mappingJournalSurvivesRestartAndOfflineRestore() {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let original = HIDUsageMapping(source: RemoteHIDKeyMappingPolicy.remoteVoiceKey.source, destination: 99)
        var mappings = [original]
        var online = true
        let provider = { () -> [RemoteHIDMappingService] in
            guard online else { return [] }
            return [.init(registryID: 123, readMappings: { mappings }, setMappings: { mappings = $0; return true })]
        }
        let first = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: values, bootID: "boot-test")
        #expect(first.apply())
        let restarted = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: values, bootID: "boot-test")
        online = false
        restarted.restore()
        online = true
        let reconnected = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: values, bootID: "boot-test")
        reconnected.restore()
        #expect(mappings == [original])
    }

    @Test func restorationPreservesLaterUserMappings() {
        let foreignVoice = HIDUsageMapping(source: RemoteHIDKeyMappingPolicy.remoteVoiceKey.source, destination: 101)
        let foreignPower = HIDUsageMapping(source: RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey.source, destination: 102)
        #expect(RemoteHIDKeyMappingPolicy.restoring(originalVoiceMapping: nil,
            originalPowerMapping: nil, in: [foreignVoice, foreignPower]) == [foreignVoice, foreignPower])
    }

    @Test func mappingJournalDoesNotCrossSystemBoots() {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let source = RemoteHIDKeyMappingPolicy.remoteVoiceKey.source
        var mappings = [HIDUsageMapping(source: source, destination: 99)]
        let provider = { [RemoteHIDMappingService(registryID: 123,
            readMappings: { mappings }, setMappings: { mappings = $0; return true })] }
        let previous = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: values, bootID: "old")
        #expect(previous.apply())
        mappings = [HIDUsageMapping(source: source, destination: 42)]
        let nextBoot = RemoteHIDKeyMapper(serviceProvider: provider, recoveryDefaults: values, bootID: "new")
        #expect(nextBoot.apply())
        nextBoot.restore()
        #expect(mappings == [HIDUsageMapping(source: source, destination: 42)])
    }

    @Test func oneShotAndCancelledTimersReleaseCallbackCaptures() async throws {
        var probe: Probe? = Probe()
        weak let observed = probe
        let handle = DispatchHIDRemoteScheduler().schedule(afterMilliseconds: 0, repeatingEveryMilliseconds: nil) { [retained = probe!] in
            withExtendedLifetime(retained) {}
        }
        probe = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(observed == nil)
        withExtendedLifetime(handle) {}
        var second: Probe? = Probe()
        weak let secondObserved = second
        var task: HIDRemoteScheduledTask? = DispatchHIDRemoteScheduler().schedule(afterMilliseconds: 1000, repeatingEveryMilliseconds: 10) { [retained = second!] in
            withExtendedLifetime(retained) {}
        }
        second = nil
        withExtendedLifetime(task) {}
        task = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(secondObserved == nil)
    }
}
