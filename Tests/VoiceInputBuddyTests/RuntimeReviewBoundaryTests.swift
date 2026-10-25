import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Secure input and runtime review boundaries")
@MainActor
struct RuntimeReviewBoundaryTests {
    private func field(secure: Bool) -> VoiceInputDestinationSnapshot {
        VoiceInputDestinationSnapshot(bundleIdentifier: "editor", role: "AXTextArea", subrole: "",
            enabled: true, editable: true, protectedContent: false, semanticText: "Composer",
            secureInputEnabled: secure)
    }

    @Test func secureInputWithoutAXMarkersRejectsDirectAndPendingDestinations() {
        #expect(field(secure: true).isSensitiveDestination)
        #expect(!field(secure: true).isSafeEditableDestination)
        let direct = VoiceInputDestinationCoordinator(snapshot: { field(secure: true) })
        let result = direct.waitUntilReady { _ in Issue.record("Direct validation should be synchronous in this test") }
        guard case .cancelled(.sensitiveDestination) = result else {
            Issue.record("Secure Input was accepted"); return
        }
        for intent in [VoiceInputDestinationIntent.application(bundleIdentifier: "editor"), .shortcut, .focusInput] {
            let clock = ControlledTestScheduler()
            var current = field(secure: false)
            let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule, snapshot: { current })
            let id = coordinator.beginTargetSwitch(intent: intent)
            coordinator.completeFocusOperation(requestID: id, succeeded: true)
            current = field(secure: true)
            guard case .cancelled(.sensitiveDestination) = coordinator.waitUntilReady(completion: { _ in }) else {
                Issue.record("Pending destination accepted Secure Input"); continue
            }
        }
    }

    @Test func secureInputBlocksNewVoiceKeyDownButAllowsCleanup() {
        for mode in VoiceKeyMode.allCases {
            var edges: [Bool] = []
            let post: KeyboardInjector.KeyStatePoster = { _, down, _ in edges.append(down); return true }
            #expect(!KeyboardInjector.setVoiceKeyPressed(mode, isPressed: true,
                accessibilityTrusted: { true }, keyStatePoster: post, secureInputEnabled: { true }))
            #expect(edges.isEmpty)
            #expect(KeyboardInjector.setVoiceKeyPressed(mode, isPressed: false,
                accessibilityTrusted: { true }, keyStatePoster: post, secureInputEnabled: { true }))
            #expect(edges == [false])
        }
    }

    @Test func physicalModifiersSurviveSyntheticModifierRelease() throws {
        let down = try #require(KeyboardInjector.makeMarkedKeyEvent(code: 55, isDown: true,
            flags: .maskCommand, marker: KeyboardInjector.orderedVoiceEventMarker, hardwareFlags: { .maskShift }))
        #expect(down.type == .flagsChanged)
        #expect(down.flags.contains([.maskShift, .maskCommand]))
        let up = try #require(KeyboardInjector.makeMarkedKeyEvent(code: 55, isDown: false,
            flags: [], marker: KeyboardInjector.orderedVoiceEventMarker, hardwareFlags: { .maskShift }))
        #expect(up.type == .flagsChanged)
        #expect(up.flags == .maskShift)
        #expect(up.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.orderedVoiceEventMarker)
        // A private source gets its own table ID rather than the enum's -1 sentinel.
        #expect(up.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.hidSystemState.rawValue))
        #expect(up.getIntegerValueField(.eventSourceStateID) == down.getIntegerValueField(.eventSourceStateID))
    }

    @Test func functionKeyTapsReleaseEvenWhenHIDStillReportsThePostedFnFlag() throws {
        let inherited: CGEventFlags = [.maskSecondaryFn, .maskShift]
        var edges: [Bool] = []
        for _ in 0..<3 { // Double start followed by a single stop.
            for down in [true, false] {
                let event = try #require(KeyboardInjector.makeMarkedKeyEvent(
                    code: VoiceKeyMode.function.keyCode, isDown: down,
                    flags: down ? .maskSecondaryFn : [],
                    marker: KeyboardInjector.orderedVoiceEventMarker,
                    hardwareFlags: { inherited }
                ))
                #expect(event.type == .flagsChanged)
                #expect(event.flags.contains(.maskShift))
                edges.append(event.flags.contains(.maskSecondaryFn))
            }
        }
        #expect(edges == [true, false, true, false, true, false])
    }

    @Test func progressRefreshesWriteTimeoutWhileRepeatedPumpsDoNot() throws {
        let clock = ControlledTestScheduler()
        var budget = 0
        var sent: [Data] = []
        var failures = 0
        let queue = FlowControlledBluetoothWriteQueue(scheduler: clock, canSend: { budget > 0 },
            send: { sent.append($0); budget -= 1 }, onFailure: { failures += 1 })
        for value: UInt8 in [1, 2, 3] { #expect(queue.enqueue(Data([value]))) }
        let old = try #require(clock.tasks.first)
        budget = 1
        queue.pump()
        #expect(sent == [Data([1])])
        #expect(old.cancelled)
        #expect(clock.tasks.count == 2)
        old.fire(includingCancelled: true)
        #expect(failures == 0)
        queue.pump()
        #expect(clock.tasks.count == 2)
        clock.tasks[1].fire()
        #expect(failures == 1)
    }

    @Test func scanningWatchdogRechecksConnectedDevicesAndIgnoresStaleCycles() throws {
        let clock = ControlledTestScheduler()
        let watchdog = BluetoothScanWatchdog(scheduler: clock)
        var rediscoveries = 0
        watchdog.arm(isCurrent: { true }, rediscover: { rediscoveries += 1 })
        let old = try #require(clock.tasks.first)
        watchdog.arm(isCurrent: { true }, rediscover: { rediscoveries += 1 })
        old.fire(includingCancelled: true)
        #expect(rediscoveries == 0)
        clock.fire(afterMilliseconds: 20_000)
        #expect(rediscoveries == 1)
        watchdog.arm(isCurrent: { true }, rediscover: { rediscoveries += 1 })
        watchdog.cancel()
        clock.tasks.last?.fire(includingCancelled: true)
        #expect(rediscoveries == 1)
    }

    @Test func genericSwitcherHoldsCommandAndRepeatedTriggersExtendItsLifetime() throws {
        let clock = ControlledTestScheduler()
        var edges: [(CGKeyCode, Bool)] = []
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, _ in
            edges.append((code, down)); return true
        })
        #expect(session.triggerTemporarily(schedule: clock.voiceSchedule))
        let old = try #require(clock.tasks.first)
        #expect(session.isActive)
        #expect(edges.map { $0.0 } == [55, 48, 48])
        #expect(session.triggerTemporarily(schedule: clock.voiceSchedule))
        old.fire(includingCancelled: true)
        #expect(session.isActive)
        clock.fire(afterMilliseconds: 1000)
        #expect(!session.isActive)
        #expect(edges.last?.0 == 55 && edges.last?.1 == false)
        let forwarded = KeyboardInjector.AppSwitcherSession(keyStatePoster: { _, _, _ in true })
        #expect(KeyboardInjector.send(.appSwitcher, accessibilityTrusted: { true },
            keyPoster: { _, _ in Issue.record("Switcher must use a held session") }, appSwitcherSession: forwarded))
        #expect(forwarded.isActive)
        #expect(forwarded.cancel())
    }

    @Test func failedSwitcherReleaseKeepsOwnershipUntilCleanupCanSucceed() {
        let clock = ControlledTestScheduler()
        var canRelease = false
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, _ in
            code != 55 || down || canRelease
        })
        #expect(session.triggerTemporarily(schedule: clock.voiceSchedule))
        clock.fire(afterMilliseconds: 1000)
        #expect(session.isActive)
        canRelease = true
        #expect(session.confirm())
        #expect(!session.isActive)
    }

    @Test func malformedHALBufferCountsCannotReadOutsideReturnedData() {
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        list.initialize(to: AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)))
        defer { list.deinitialize(count: 1); list.deallocate() }
        let size = MemoryLayout<AudioBufferList>.size
        #expect(CoreAudioDeviceCatalog.channelCount(in: list, byteCount: size, allocatedByteCount: size) == 2)
        #expect(CoreAudioDeviceCatalog.channelCount(in: list, byteCount: 4, allocatedByteCount: size) == 0)
        #expect(CoreAudioDeviceCatalog.channelCount(in: list, byteCount: size + 1, allocatedByteCount: size) == 0)
        list.pointee.mNumberBuffers = 2
        #expect(CoreAudioDeviceCatalog.channelCount(in: list, byteCount: size, allocatedByteCount: size) == 0)
    }

    @Test func childExpansionStopsBeforeMoreIPCWhenTimeOrNodeBudgetIsExhausted() {
        var time: TimeInterval = 0
        var roles = 0
        var frames = 0
        var budget = AccessibilityTraversalBudget(maximumNodes: 100, maximumDuration: 1, uptime: { time })
        let result = KeyboardInjector.accessibilityChildPriority(role: {
            roles += 1
            time = 2
            return "AXTextArea"
        }, frame: { frames += 1; return nil }, windowFrame: nil, budget: &budget)
        #expect(result == nil)
        #expect(roles == 1 && frames == 0)
        time = 0
        budget = AccessibilityTraversalBudget(maximumNodes: 1, uptime: { time })
        let first = KeyboardInjector.accessibilityChildPriority(role: { "AXTextArea" }, frame: { nil },
            windowFrame: nil, budget: &budget)
        #expect(first != nil)
        let second = KeyboardInjector.accessibilityChildPriority(role: { roles += 1; return "AXTextArea" },
            frame: { frames += 1; return nil }, windowFrame: nil, budget: &budget)
        #expect(second == nil)
        #expect(roles == 1 && frames == 0)
    }

    @Test func testToneCompletionAlwaysReturnsOnMainThread() async {
        for callbackType in [AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack, .dataConsumed] {
            let played: Bool = await withCheckedContinuation { continuation in
                let callback = VirtualAudioOutput.testToneCompletion {
                    #expect(Thread.isMainThread)
                    continuation.resume(returning: $0)
                }
                DispatchQueue.global().async { callback(callbackType) }
            }
            #expect(played == (callbackType == .dataPlayedBack))
        }
    }

    @Test func bankCardMetadataIsSensitiveAcrossInsertionAndVoiceDestinations() {
        for text in ["银行卡号码", "借记卡", "信用卡"] {
            #expect(!CommonPhraseInserter.permitsInsertion(role: "AXTextField", subrole: "",
                enabled: true, protectedContent: false, identifier: text))
            #expect(VoiceInputDestinationSnapshot(bundleIdentifier: "editor", role: "AXTextField", subrole: "",
                enabled: true, editable: true, protectedContent: false, semanticText: text).isSensitiveDestination)
        }
    }
}
