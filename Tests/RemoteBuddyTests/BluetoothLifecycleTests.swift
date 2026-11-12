import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth lifecycle")
struct BluetoothLifecycleTests {
    @Test func pendingCloseRejectsBothExplicitAndImplicitMicrophoneStarts() {
        #expect(ATVVSessionGate.canOpenMicrophone(phase: .ready(1), generation: 1,
            capabilitiesConfirmed: true, sampleRate: 16_000, microphoneClosePending: false))
        #expect(!ATVVSessionGate.canOpenMicrophone(phase: .ready(1), generation: 1,
            capabilitiesConfirmed: true, sampleRate: 16_000, microphoneClosePending: true))
    }

    @Test func systemSuspensionOnlyRestartsAnInterruptedConnectionCycle() {
        var readyState = BluetoothSystemSuspensionState()
        let didSuspendReady = readyState.suspend(phase: .ready(1))
        #expect(didSuspendReady)
        #expect(readyState.isSuspended)
        let didResumeReady = readyState.resume()
        let readyNeedsConnectionCycle = readyState.consumeConnectionCycleNeeded()
        #expect(didResumeReady)
        #expect(!readyNeedsConnectionCycle)
        #expect(!readyState.isSuspended)

        var scanningState = BluetoothSystemSuspensionState()
        let didSuspendScanning = scanningState.suspend(phase: .scanning(2))
        let didResumeScanning = scanningState.resume()
        let scanningNeedsConnectionCycle = scanningState.consumeConnectionCycleNeeded()
        #expect(didSuspendScanning)
        #expect(didResumeScanning)
        #expect(scanningNeedsConnectionCycle)

        var disconnectedWhileSleeping = BluetoothSystemSuspensionState()
        let didSuspendBeforeDisconnect = disconnectedWhileSleeping.suspend(phase: .ready(3))
        disconnectedWhileSleeping.markConnectionCycleNeeded()
        let didResumeAfterDisconnect = disconnectedWhileSleeping.resume()
        let disconnectNeedsConnectionCycle = disconnectedWhileSleeping.consumeConnectionCycleNeeded()
        #expect(didSuspendBeforeDisconnect)
        #expect(didResumeAfterDisconnect)
        #expect(disconnectNeedsConnectionCycle)
    }

    @Test func systemSuspensionTransitionsAreIdempotent() {
        var state = BluetoothSystemSuspensionState()

        let firstSuspend = state.suspend(phase: .waitingReconnect(4))
        let duplicateSuspend = state.suspend(phase: .ready(4))
        let firstResume = state.resume()
        let duplicateResume = state.resume()
        let firstConsume = state.consumeConnectionCycleNeeded()
        let duplicateConsume = state.consumeConnectionCycleNeeded()

        #expect(firstSuspend)
        #expect(!duplicateSuspend)
        #expect(firstResume)
        #expect(!duplicateResume)
        #expect(firstConsume)
        #expect(!duplicateConsume)
    }

    @Test func batteryPollingOnlyRunsWithoutAnActiveNotificationSubscription() {
        #expect(BluetoothBatteryPollingPolicy.interval == 300)
        #expect(BluetoothBatteryPollingPolicy.shouldPoll(
            supportsNotifications: false,
            isNotifying: false
        ))
        #expect(BluetoothBatteryPollingPolicy.shouldPoll(
            supportsNotifications: true,
            isNotifying: false
        ))
        #expect(!BluetoothBatteryPollingPolicy.shouldPoll(
            supportsNotifications: true,
            isNotifying: true
        ))
    }

    @Test func onlySystemWakeForcesBluetoothRecovery() {
        #expect(BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .systemDidWake,
            pendingSystemWake: false,
            started: true
        ))
        #expect(BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .screenDidWake,
            pendingSystemWake: true,
            started: true
        ))
        #expect(BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .sessionDidBecomeActive,
            pendingSystemWake: true,
            started: true
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .screenDidWake,
            pendingSystemWake: false,
            started: true
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .systemDidWake,
            pendingSystemWake: true,
            started: false
        ))
        #expect(!BluetoothWakeRecoveryPolicy.shouldForceReconnect(
            event: .screenDidWake,
            pendingSystemWake: true,
            started: false
        ))
    }

    @Test func sessionResumeRecoversVoiceLinkOnlyWhenNoBridgeIsReady() {
        // 同机多账户切回：有已配置的桥、一台都没就绪、没有活跃语音 → 需要主动恢复。
        #expect(BluetoothWakeRecoveryPolicy.shouldRecoverVoiceLinkAfterResume(
            started: true,
            configuredBridgeCount: 2,
            readyBridgeCount: 0,
            voiceLinkActive: false
        ))

        // 任一桥已就绪 → 完全空操作，不打断健康连接。
        #expect(!BluetoothWakeRecoveryPolicy.shouldRecoverVoiceLinkAfterResume(
            started: true,
            configuredBridgeCount: 2,
            readyBridgeCount: 1,
            voiceLinkActive: false
        ))

        // 正在进行的语音会话 → 不介入。
        #expect(!BluetoothWakeRecoveryPolicy.shouldRecoverVoiceLinkAfterResume(
            started: true,
            configuredBridgeCount: 2,
            readyBridgeCount: 0,
            voiceLinkActive: true
        ))

        // 没有已配置的桥 → 不凭空启动连接。
        #expect(!BluetoothWakeRecoveryPolicy.shouldRecoverVoiceLinkAfterResume(
            started: true,
            configuredBridgeCount: 0,
            readyBridgeCount: 0,
            voiceLinkActive: false
        ))

        // 未启动 → 不恢复。
        #expect(!BluetoothWakeRecoveryPolicy.shouldRecoverVoiceLinkAfterResume(
            started: false,
            configuredBridgeCount: 2,
            readyBridgeCount: 0,
            voiceLinkActive: false
        ))
    }

    @Test func everyBridgeFirstReadyReappliesHIDMappingsButDuplicateReadyDoesNot() {
        #expect(BridgeAppModel.shouldReapplyHIDSettings(
            previousState: nil,
            currentState: .ready("first")
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettings(
            previousState: .connecting,
            currentState: .ready("first")
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettings(
            previousState: .ready("first"),
            currentState: .ready("duplicate")
        ))
        #expect(!BridgeAppModel.shouldReapplyHIDSettings(
            previousState: .ready("first"),
            currentState: .reconnecting
        ))
        #expect(BridgeAppModel.shouldReapplyHIDSettings(
            previousState: .reconnecting,
            currentState: .ready("reconnected")
        ))

        let secondBridgePreviousState: BluetoothBridgeState? = nil
        #expect(BridgeAppModel.shouldReapplyHIDSettings(
            previousState: secondBridgePreviousState,
            currentState: .ready("second")
        ))
    }

    @Test func missingHIDServiceUsesFiniteReadyOnlyRecoveryDelays() {
        let delays = (0 ... 5).map {
            HIDMappingRecoveryPolicy.retryDelay(
                forAttempt: $0,
                started: true,
                readyBridgeCount: 1,
                hasMatchingServices: false
            )
        }

        #expect(delays == [0.5, 1, 2, 4, 8, nil])
        #expect(HIDMappingRecoveryPolicy.retryDelay(
            forAttempt: 0,
            started: false,
            readyBridgeCount: 1,
            hasMatchingServices: false
        ) == nil)
        #expect(HIDMappingRecoveryPolicy.retryDelay(
            forAttempt: 0,
            started: true,
            readyBridgeCount: 0,
            hasMatchingServices: false
        ) == nil)
        #expect(HIDMappingRecoveryPolicy.retryDelay(
            forAttempt: 0,
            started: true,
            readyBridgeCount: 1,
            hasMatchingServices: true
        ) == nil)
    }

    @Test func generationAndPhaseRejectStaleCallbacks() {
        let phase = BluetoothLifecyclePhase.connecting(1)
        #expect(phase.acceptsDidConnect(generation: 1))
        #expect(phase.acceptsDidFailToConnect(generation: 1))
        #expect(phase.acceptsDisconnect(generation: 1))
        #expect(!phase.acceptsDisconnect(generation: 2))
        #expect(!phase.acceptsDidConnect(generation: 2))
        #expect(BluetoothLifecyclePhase.disconnecting(1)
            .acceptsDidFailToConnect(generation: 1))
    }

    @Test func initializationCapabilitiesAndReadyAreDistinct() {
        #expect(BluetoothLifecyclePhase.discovering(1)
            .acceptsInitializationCallback(generation: 1))
        #expect(!BluetoothLifecyclePhase.discovering(1)
            .acceptsCapabilities(generation: 1))
        #expect(BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsCapabilities(generation: 1))
        #expect(!BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsProtocolData(generation: 1))
        #expect(BluetoothLifecyclePhase.ready(1)
            .acceptsProtocolData(generation: 1))
    }

    @Test func automaticReconnectBackoffDoublesAndCapsAtSixtySeconds() {
        var policy = BluetoothReconnectPolicy()

        let delays = (0 ..< 7).map { _ in
            policy.nextAutomaticDelay(
                bypassCachedTarget: false,
                jitterUnit: 0.5
            )
        }

        #expect(delays == [3, 6, 12, 24, 48, 60, 60])
        #expect(policy.consecutiveFailureCount == 7)
    }

    @Test func automaticReconnectJitterIsBoundedAndDeterministicForTests() {
        var firstLowJitterPolicy = BluetoothReconnectPolicy()
        var firstHighJitterPolicy = BluetoothReconnectPolicy()
        var lowJitterPolicy = BluetoothReconnectPolicy()
        var highJitterPolicy = BluetoothReconnectPolicy()
        var cappedLowJitterPolicy = BluetoothReconnectPolicy()
        var cappedHighJitterPolicy = BluetoothReconnectPolicy()

        let firstLowDelay = firstLowJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0
        )
        let firstHighDelay = firstHighJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 1
        )
        _ = lowJitterPolicy.nextAutomaticDelay(bypassCachedTarget: false, jitterUnit: 0.5)
        _ = highJitterPolicy.nextAutomaticDelay(bypassCachedTarget: false, jitterUnit: 0.5)

        let lowDelay = lowJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0
        )
        let highDelay = highJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 1
        )
        for _ in 0 ..< 5 {
            _ = cappedLowJitterPolicy.nextAutomaticDelay(
                bypassCachedTarget: false,
                jitterUnit: 0.5
            )
            _ = cappedHighJitterPolicy.nextAutomaticDelay(
                bypassCachedTarget: false,
                jitterUnit: 0.5
            )
        }
        let cappedLowDelay = cappedLowJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0
        )
        let cappedHighDelay = cappedHighJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 1
        )

        #expect(abs(firstLowDelay - 2.7) < 0.000_001)
        #expect(abs(firstHighDelay - 3.3) < 0.000_001)
        #expect(abs(lowDelay - 5.4) < 0.000_001)
        #expect(abs(highDelay - 6.6) < 0.000_001)
        #expect(abs(cappedLowDelay - 54) < 0.000_001)
        #expect(abs(cappedHighDelay - 60) < 0.000_001)
    }

    @Test func failedCachedTargetIsBypassedForOnlyOneDiscoveryPass() {
        var policy = BluetoothReconnectPolicy()
        #expect(policy.allowsCachedTargetRetrieval)

        let delay = policy.nextAutomaticDelay(
            bypassCachedTarget: true,
            jitterUnit: 0.5
        )

        #expect(delay == 3)
        #expect(!policy.allowsCachedTargetRetrieval)
        let firstPass = policy.consumeCachedTargetRetrievalPermission()
        #expect(!firstPass)
        #expect(policy.allowsCachedTargetRetrieval)
        let nextPass = policy.consumeCachedTargetRetrievalPermission()
        #expect(nextPass)
        _ = policy.nextAutomaticDelay(bypassCachedTarget: false, jitterUnit: 0.5)
        #expect(policy.allowsCachedTargetRetrieval)

        policy.reset()

        #expect(policy.consecutiveFailureCount == 0)
        #expect(policy.allowsCachedTargetRetrieval)
        #expect(policy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0.5
        ) == 3)
    }

    @Test func poweredOffCancelsWaitingReconnectUntilBluetoothReturns() {
        let generation: UInt64 = 7
        let poweredOff = BluetoothCentralRecoveryPolicy.transition(
            from: .waitingReconnect(generation),
            generation: generation,
            event: .poweredOff,
            shouldRun: true
        )

        #expect(poweredOff == BluetoothCentralRecoveryTransition(
            phase: .waitingBluetoothPower(generation),
            shouldCancelScheduledReconnect: true,
            shouldDiscover: false,
            shouldStartFreshConnectionCycle: false,
            shouldReleaseCentral: false
        ))

        let poweredOn = BluetoothCentralRecoveryPolicy.transition(
            from: poweredOff.phase,
            generation: generation,
            event: .poweredOn,
            shouldRun: true
        )

        #expect(poweredOn == BluetoothCentralRecoveryTransition(
            phase: .stopped,
            shouldCancelScheduledReconnect: true,
            shouldDiscover: false,
            shouldStartFreshConnectionCycle: true,
            shouldReleaseCentral: false
        ))
    }

    @Test func resettingOrDirectPowerRecoveryClearsTheCapturedWait() {
        let generation: UInt64 = 9
        let resetting = BluetoothCentralRecoveryPolicy.transition(
            from: .waitingReconnect(generation),
            generation: generation,
            event: .resetting,
            shouldRun: true
        )
        let poweredOn = BluetoothCentralRecoveryPolicy.transition(
            from: .waitingReconnect(generation),
            generation: generation,
            event: .poweredOn,
            shouldRun: true
        )

        #expect(resetting == BluetoothCentralRecoveryTransition(
            phase: .waitingBluetoothPower(generation),
            shouldCancelScheduledReconnect: true,
            shouldDiscover: false,
            shouldStartFreshConnectionCycle: false,
            shouldReleaseCentral: false
        ))
        #expect(poweredOn == BluetoothCentralRecoveryTransition(
            phase: .stopped,
            shouldCancelScheduledReconnect: true,
            shouldDiscover: false,
            shouldStartFreshConnectionCycle: true,
            shouldReleaseCentral: false
        ))
    }

    @Test func stoppedBridgeReleasesTheRetainedManagerAcrossPowerChanges() {
        let generation: UInt64 = 10

        for event in [BluetoothCentralRecoveryEvent.poweredOff, .resetting, .poweredOn] {
            let transition = BluetoothCentralRecoveryPolicy.transition(
                from: .disconnecting(generation),
                generation: generation,
                event: event,
                shouldRun: false
            )

            #expect(transition == BluetoothCentralRecoveryTransition(
                phase: .stopped,
                shouldCancelScheduledReconnect: true,
                shouldDiscover: false,
                shouldStartFreshConnectionCycle: false,
                shouldReleaseCentral: true
            ))
        }
    }

    @Test(arguments: [BluetoothLifecyclePhase.waitingReconnect(12), .ready(12), .connecting(12), .awaitingCapabilities(12)])
    func unavailableBluetoothCancelsReconnectAndReleasesTheManager(phase: BluetoothLifecyclePhase) {
        let generation: UInt64 = 12

        for event in [BluetoothCentralRecoveryEvent.unauthorized, .unsupported] {
            let transition = BluetoothCentralRecoveryPolicy.transition(
                from: phase,
                generation: generation,
                event: event,
                shouldRun: true
            )

            #expect(transition == BluetoothCentralRecoveryTransition(
                phase: .stopped,
                shouldCancelScheduledReconnect: true,
                shouldDiscover: false,
                shouldStartFreshConnectionCycle: false,
                shouldReleaseCentral: true
            ))
        }
    }

    @Test func freshCycleBoundaryRejectsCallbacksFromTheFinishedAttempt() {
        let finishedGeneration: UInt64 = 11
        let recovery = BluetoothCentralRecoveryPolicy.transition(
            from: .waitingReconnect(finishedGeneration),
            generation: finishedGeneration,
            event: .poweredOn,
            shouldRun: true
        )

        #expect(recovery.shouldStartFreshConnectionCycle)
        #expect(!recovery.shouldDiscover)

        let freshPhase = BluetoothLifecyclePhase.scanning(finishedGeneration + 1)
        #expect(!freshPhase.acceptsDidConnect(generation: finishedGeneration))
        #expect(!freshPhase.acceptsDidFailToConnect(generation: finishedGeneration))
        #expect(!freshPhase.acceptsDisconnect(generation: finishedGeneration))
    }

    @Test func readyTransitionGatesOnGoogleOrDisModelResolution() {
        // Capabilities not confirmed -> never ready
        #expect(!ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: false,
            isGoogleCandidate: false,
            googleReady: false,
            modelFormatResolved: false
        ))
        #expect(!ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: false,
            isGoogleCandidate: false,
            googleReady: true,
            modelFormatResolved: true
        ))

        // Non-Google candidate requires modelFormatResolved before ready
        #expect(!ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: true,
            isGoogleCandidate: false,
            googleReady: false,
            modelFormatResolved: false
        ))
        #expect(!ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: true,
            isGoogleCandidate: false,
            googleReady: true,
            modelFormatResolved: false
        ))
        #expect(ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: true,
            isGoogleCandidate: false,
            googleReady: false,
            modelFormatResolved: true
        ))

        // Google candidate requires googleReady, regardless of modelFormatResolved
        #expect(!ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: true,
            isGoogleCandidate: true,
            googleReady: false,
            modelFormatResolved: true
        ))
        #expect(ATVVSessionGate.canTransitionToReady(
            capabilitiesConfirmed: true,
            isGoogleCandidate: true,
            googleReady: true,
            modelFormatResolved: false
        ))
    }

    @Test func microphoneRequiresConfirmed16kReadySession() {
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .awaitingCapabilities(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: false,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 8_000
        ))
        #expect(ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
    }

    @Test func stoppedStreamSuppressionUsesElapsedUptime() {
        #expect(ATVVSessionGate.shouldIgnoreAudioAfterStop(stoppedAt: 1_000, now: 1_000.29))
        #expect(!ATVVSessionGate.shouldIgnoreAudioAfterStop(stoppedAt: 1_000, now: 1_000.31))
        #expect(!ATVVSessionGate.shouldIgnoreAudioAfterStop(stoppedAt: nil, now: 1_000))

        let t1Cooldown = ATVVSessionGate.audioAfterStopCooldown(isT1Candidate: true)
        #expect(t1Cooldown == 0.8)
        #expect(ATVVSessionGate.audioAfterStopCooldown(isT1Candidate: false) == 0.3)
        #expect(ATVVSessionGate.shouldIgnoreAudioAfterStop(stoppedAt: 1_000, now: 1_000.309, cooldown: t1Cooldown))
        #expect(!ATVVSessionGate.shouldIgnoreAudioAfterStop(stoppedAt: 1_000, now: 1_000.81, cooldown: t1Cooldown))
    }

    @Test func t1SecondPressOpenRequestClosesOnlyWhileStreaming() {
        #expect(ATVVSessionGate.shouldCloseStreamingOnRemoteOpenRequest(isT1Candidate: true, isStreaming: true))
        #expect(!ATVVSessionGate.shouldCloseStreamingOnRemoteOpenRequest(isT1Candidate: true, isStreaming: false))
        #expect(!ATVVSessionGate.shouldCloseStreamingOnRemoteOpenRequest(isT1Candidate: false, isStreaming: true))
    }

    @Test func directRemoteStreamIsAllowedUnlessAHostOpenWasJustCancelled() {
        let now = TimeInterval(1_000)

        #expect(ATVVSessionGate.cancelledOpenUptime(
            microphoneOpened: false,
            streaming: false,
            now: now
        ) == nil)
        #expect(ATVVSessionGate.cancelledOpenUptime(
            microphoneOpened: true,
            streaming: true,
            now: now
        ) == nil)

        let cancelledAt = ATVVSessionGate.cancelledOpenUptime(
            microphoneOpened: true,
            streaming: false,
            now: now
        )
        #expect(cancelledAt == now)
        #expect(ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledAt,
            now: now + 1
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: nil,
            now: now
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledAt,
            now: now + 2
        ))
    }

    @Test func nameMatcherAcceptsApprovedCandidateNames() {
        #expect(XiaomiVoiceRemoteNameMatcher.matches("MI RC"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("mi rc"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("  MI RC  "))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2 pro"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙语音遥控器"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches(" 小米蓝牙语音遥控器 "))
    }

    @Test func nameMatcherRejectsBlankNilAndSimilarNonTargetNames() {
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(nil))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(""))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("   "))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("Mi Mouse"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙遥控器"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("MI RC2"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("小米"))
    }
}
