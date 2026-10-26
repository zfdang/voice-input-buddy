import AppKit
import Carbon
import CoreBluetooth
import AudioExceptionGuard
import Testing
@testable import VoiceInputBuddy

@Suite("Runtime audit regressions")
@MainActor
struct RuntimeAuditRegressionTests {
    @Test func disabledNativeFilterDefersTerminalOwnerNotification() throws {
        let filter = KeyboardEventSuppressor()
        var notifications = 0
        filter.onSystemDisabled = { notifications += 1 }
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(!filter.handle(type: .tapDisabledByTimeout, event: event))
        #expect(notifications == 0)
        #expect(!filter.isRunning)
    }

    @Test func unavailableInputSourceServicesReturnNil() {
        #expect(OnboardingInputSourceSwitcher.currentInputSourceID(copyCurrent: { nil }) == nil)
        #expect(OnboardingInputSourceSwitcher.inputSource(withID: "test", createList: { nil }) == nil)
        #expect(OnboardingInputSourceSwitcher.inputSource(withID: "test", createList: {
            Unmanaged.passRetained(["invalid", NSNull(), 7] as CFArray)
        }) == nil)
    }

    @Test func virtualModifierEdgesUseFlagsChangedWhileOrdinaryKeysKeepDownAndUp() {
        for code: CGKeyCode in [54, 55, 56, 57, 58, 59, 60, 61, 62, 63] {
            #expect(KeyboardInjector.keyEventType(code: code, isDown: true) == .flagsChanged)
            #expect(KeyboardInjector.keyEventType(code: code, isDown: false) == .flagsChanged)
        }
        #expect(KeyboardInjector.keyEventType(code: 0, isDown: true) == .keyDown)
        #expect(KeyboardInjector.keyEventType(code: 0, isDown: false) == .keyUp)
    }

    @Test func controlWritesPreferAcknowledgmentsAndRejectNonWritableCharacteristics() {
        #expect(BluetoothRemoteBridge.controlWriteType(for: [.write, .writeWithoutResponse]) == .withResponse)
        #expect(BluetoothRemoteBridge.controlWriteType(for: [.write]) == .withResponse)
        #expect(BluetoothRemoteBridge.controlWriteType(for: [.writeWithoutResponse]) == .withoutResponse)
        #expect(BluetoothRemoteBridge.controlWriteType(for: [.notify]) == nil)
    }

    @Test func streamedFramesStayOrderedAndRebasedAcrossLongSessions() {
        var accumulator = FrameAccumulator()
        var frames: [Data] = []
        for index in 0..<10_000 {
            let value = UInt8(index % 251)
            // Simulate a BLE payload delivered as a slice rather than a fresh Data.
            let payload = Data([255, value, value, value, value]).dropFirst()
            frames += accumulator.append(payload, frameSize: 7)
            #expect(accumulator.pending.startIndex == 0)
            #expect(accumulator.pending.count < 7)
        }
        #expect(frames.allSatisfy { $0.startIndex == 0 && $0.count == 7 })
        let actual = frames.flatMap(Array.init) + Array(accumulator.pending)
        let expected = (0..<10_000).flatMap { Array(repeating: UInt8($0 % 251), count: 4) }
        #expect(actual == expected)
    }

    @Test func signedPCMEndpointsStayInUnitRange() {
        #expect(PCMNormalization.sample(.min) == -1)
        #expect(PCMNormalization.sample(.max) < 1)
        #expect(PCMNormalization.sample(0) == 0)
    }

    @Test func emptyReleaseReportsReleaseKeysOnlyOnTheirKnownInterface() {
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data()) == [])
        #expect(RemoteHIDReportParser.usages(reportID: 2, data: Data()) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data([1])) == nil)
    }

    @Test func shortReportsWithOptionalIDsPreservePressesAndReleases() {
        let reports: [[UInt8]] = [[0x42, 0], [0x42, 0, 0x43, 0], [0, 0]]
        for usages in reports {
            #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data([1] + usages)) ==
                RemoteHIDReportParser.usages(reportID: 1, data: Data(usages)))
        }
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data([1])) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 1, data: Data([2, 0x42, 0])) == nil)
        #expect(RemoteHIDReportParser.usages(reportID: 2, data: Data([1, 0x42, 0])) == nil)
    }

    @Test func objectiveCExceptionsBecomeAudioFailureResults() {
        #expect(VoiceInputBuddyTryAudioOperation {})
        let accepted = VoiceInputBuddyTryAudioOperation {
            NSException(name: .invalidArgumentException, reason: "simulated audio failure", userInfo: nil).raise()
        }
        #expect(!accepted)
    }

    @Test func blockedBluetoothWritesResumeInOrderAndResetDiscardsStaleWork() {
        let scheduler = ControlledTestScheduler()
        var budget = 0
        var sent: [Data] = []
        var failures = 0
        let queue = FlowControlledBluetoothWriteQueue(scheduler: scheduler, canSend: { budget > 0 },
            send: { budget -= 1; sent.append($0) }, onFailure: { failures += 1 })
        #expect(queue.enqueue(Data([1])))
        #expect(queue.enqueue(Data([2])))
        #expect(sent.isEmpty)
        budget = 1
        queue.pump()
        #expect(sent == [Data([1])])
        budget = 1
        queue.pump()
        #expect(sent == [Data([1]), Data([2])])
        scheduler.tasks[0].fire(includingCancelled: true)
        #expect(failures == 0)
        #expect(queue.enqueue(Data([3])))
        queue.reset()
        budget = 1
        queue.pump()
        scheduler.tasks.last?.fire(includingCancelled: true)
        #expect(sent.count == 2)
        #expect(failures == 0)
    }

    @Test func blockedBluetoothQueueIsBoundedAndExpires() {
        let scheduler = ControlledTestScheduler()
        var failures = 0
        let queue = FlowControlledBluetoothWriteQueue(scheduler: scheduler, canSend: { false },
            send: { _ in Issue.record("Blocked peripheral received a write") }, onFailure: { failures += 1 })
        for _ in 0..<32 { #expect(queue.enqueue(Data([1]))) }
        #expect(!queue.enqueue(Data([2])))
        scheduler.fire(afterMilliseconds: 5_000)
        #expect(failures == 1)
        #expect(queue.enqueue(Data([3])))
    }

    @Test func newOfflineRemoteSubscriptionRestartsSharedScan() {
        var starts = 0
        var stops = 0
        var observed: [Int] = []
        let scans = BluetoothScanSubscriptions<Int>(start: { starts += 1 }, stop: { stops += 1 })
        let first = scans.subscribe { observed.append($0) }
        let second = scans.subscribe { observed.append($0) }
        #expect(starts == 2)
        scans.publish(7)
        #expect(observed == [7, 7])
        scans.unsubscribe(first)
        #expect(stops == 1)
        scans.unsubscribe(second)
        scans.unsubscribe(second)
        #expect(stops == 2)
        #expect(!scans.hasObservers)
    }

    @Test func disconnectWatchdogRecoversLostCallbacksAndIgnoresCancelledAttempts() {
        let scheduler = ControlledTestScheduler()
        let watchdog = BluetoothDisconnectWatchdog(scheduler: scheduler)
        var recovered = 0
        watchdog.arm(isCurrent: { true }, onTimeout: { recovered += 1 })
        let stale = scheduler.tasks[0]
        watchdog.arm(isCurrent: { true }, onTimeout: { recovered += 1 })
        stale.fire(includingCancelled: true)
        #expect(recovered == 0)
        scheduler.fire(afterMilliseconds: 5_000)
        #expect(recovered == 1)
        watchdog.arm(isCurrent: { true }, onTimeout: { recovered += 1 })
        watchdog.cancel()
        scheduler.tasks.last?.fire(includingCancelled: true)
        #expect(recovered == 1)
    }

    @Test func eventTapRecoveryBacksOffStopsRepeatedFailuresAndIgnoresOldPorts() {
        var time: TimeInterval = 0
        var deferred: [(TimeInterval, () -> Void)] = []
        var current = true
        var enables = 0
        var stops = 0
        let recovery = EventTapRecovery(now: { time }, dispatch: { deferred.append(($0, $1)) })
        for _ in 0..<6 {
            recovery.recover(type: .tapDisabledByTimeout, isCurrent: { current },
                permissionsGranted: { true }, enable: { enables += 1; return true }, stop: { stops += 1 })
            time += deferred.last!.0
            deferred.last!.1()
        }
        #expect(deferred.map(\.0) == [0.5, 1, 2, 4, 8, 8])
        #expect(enables == 5 && stops == 1)
        time += 31
        recovery.recover(type: .tapDisabledByTimeout, isCurrent: { current },
            permissionsGranted: { true }, enable: { enables += 1; return true }, stop: { stops += 1 })
        #expect(deferred.last?.0 == 0.5)
        current = false
        deferred.last!.1()
        #expect(enables == 5 && stops == 1)
    }

    @Test func disablingDuringStartCompletesFullStartAndStopPulses() {
        let scheduler = ControlledTestScheduler()
        var keys: [Bool] = []
        var completed = false
        let session = VoiceFnTapSessionController(startDelay: 0,
            schedule: scheduler.voiceSchedule, setFunctionKeyPressed: { keys.append($0); return true },
            enqueueAudio: { _ in Issue.record("Cancelled start delivered audio") },
            drainAudio: { _, done in done() }, onFailure: { _ in Issue.record("Cleanup failed") })
        session.setEnabled(true)
        #expect(session.startVoice())
        scheduler.fire(afterMilliseconds: 0)
        #expect(keys == [true])
        session.setEnabled(false) { completed = $0 }
        #expect(keys == [true])
        #expect(!completed)
        scheduler.fire(afterMilliseconds: 120)
        #expect(keys == [true, false, true])
        scheduler.tasks.last { $0.delay == 120 && !$0.cancelled }?.fire()
        #expect(keys == [true, false, true, false])
        #expect(completed)
    }

    @Test func lateAsyncDestinationResultCannotStartACancelledVoiceSession() {
        var replies: [(VoiceInputDestinationSnapshot) -> Void] = []
        var results: [VoiceInputDestinationWaitResult] = []
        let scheduler = ControlledTestScheduler()
        let coordinator = VoiceInputDestinationCoordinator(schedule: scheduler.voiceSchedule,
            querySnapshot: { replies.append($0) })
        let result = coordinator.waitUntilReady { results.append($0) }
        guard case let .waiting(task) = result else { Issue.record("Probe did not wait"); return }
        task.cancel()
        replies[0](.init(bundleIdentifier: "test", role: "AXTextField", subrole: "",
            enabled: true, editable: true, protectedContent: false, semanticText: ""))
        #expect(results.isEmpty)
    }

    @Test func shutdownKeepsTheStopPulsePressedUntilItsScheduledRelease() {
        let scheduler = ControlledTestScheduler()
        var keys: [Bool] = []
        let session = VoiceFnTapSessionController(startDelay: 0, schedule: scheduler.voiceSchedule,
            setFunctionKeyPressed: { keys.append($0); return true }, enqueueAudio: { _ in },
            drainAudio: { _, done in done() }, onFailure: { _ in Issue.record("Shutdown failed") })
        session.setEnabled(true)
        #expect(session.startVoice())
        scheduler.fire(afterMilliseconds: 0)
        scheduler.fire(afterMilliseconds: 120)
        session.shutdown()
        #expect(keys == [true, false, true])
        #expect(session.requiresCleanupBeforeMapping)
        session.shutdown()
        #expect(keys == [true, false, true])
        scheduler.tasks.last { $0.delay == 120 && !$0.cancelled }?.fire()
        #expect(keys == [true, false, true, false])
        #expect(!session.requiresCleanupBeforeMapping)
    }
}
