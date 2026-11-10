import Foundation
import Testing
@testable import RemoteBuddy

private final class LifecycleLoginController: LoginItemControlling {
    var status: LoginItemRegistrationStatus = .notRegistered
    var fail = true
    func register() throws {
        if fail { throw NSError(domain: "test", code: 1) }
        status = .enabled
    }
    func unregister() throws { status = .notRegistered }
    func openLoginItemsSettings() {}
}

@Suite("Session recovery regressions")
@MainActor
struct SessionRecoveryRegressionTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "lifecycle-" + UUID().uuidString)! }

    @Test func releaseRetriesWithoutAnotherVoiceEventAndOnlyThenCompletes() {
        let clock = ControlledTestScheduler()
        var canRelease = false
        var completions = 0
        let session = VoiceFnTapSessionController(startDelay: 0, tapDuration: 0.1,
            schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { down in down || canRelease }, enqueueAudio: { _ in },
            drainAudio: { _, done in done() }, onFailure: { _ in })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 100)
        session.setEnabled(false) { _ in completions += 1 }
        #expect(completions == 0)
        #expect(session.requiresCleanupBeforeMapping)
        canRelease = true
        clock.advance(to: 1200)
        #expect(completions == 1)
        #expect(!session.requiresCleanupBeforeMapping)
        clock.advance(to: 4000)
        #expect(completions == 1)
    }

    @Test func failedReleaseBacksOffWithOneTimerAndResetsAfterRecovery() {
        let clock = ControlledTestScheduler()
        var canRelease = false
        let session = VoiceFnTapSessionController(startDelay: 0, tapDuration: 0.1,
            schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { down in down || canRelease }, enqueueAudio: { _ in },
            drainAudio: { _, done in done() }, onFailure: { _ in })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 100)
        for due: UInt64 in [1100, 3100, 7100] {
            let pending = clock.tasks.filter { $0.action != nil }
            #expect(pending.count == 1)
            #expect(pending.first?.due == due)
            clock.advance(to: due)
        }
        #expect(session.releaseRecoveryBlocked)
        #expect(session.requiresCleanupBeforeMapping)
        #expect(clock.tasks.allSatisfy { $0.action == nil })
        canRelease = true
        session.retryCleanupAfterPermissionRecovery()
        clock.advance(to: 121100)
        #expect(!session.requiresCleanupBeforeMapping)
        #expect(clock.tasks.allSatisfy { $0.action == nil })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 121100)
        canRelease = false
        clock.advance(to: 121200)
        #expect(clock.tasks.filter { $0.action != nil }.map(\.due) == [122200])
        canRelease = true
        clock.advance(to: 122200)
    }

    @Test func exhaustedReleaseRetriesAnswerFailureWithoutPretendingCleanupSucceeded() {
        let clock = ControlledTestScheduler()
        var allowRelease = false
        var answers: [Bool] = []
        let session = VoiceFnTapSessionController(startDelay: 0, tapDuration: 0.1,
            schedule: clock.voiceSchedule, setFunctionKeyPressed: { $0 || allowRelease },
            enqueueAudio: { _ in }, drainAudio: { _, completion in completion() }, onFailure: { _ in })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 100)
        session.setEnabled(false) { answers.append($0) }
        clock.advance(to: 7100)
        #expect(answers == [false])
        #expect(session.requiresCleanupBeforeMapping)
        #expect(session.releaseRecoveryBlocked)
        #expect(clock.tasks.allSatisfy { $0.action == nil })
        clock.advance(to: 100000)
        #expect(answers == [false])
        session.setEnabled(false) { answers.append($0) }
        #expect(answers == [false, false])
        allowRelease = true
        session.retryCleanupAfterPermissionRecovery()
        #expect(!session.requiresCleanupBeforeMapping)
        session.setEnabled(false) { answers.append($0) }
        #expect(answers == [false, false, true])
    }

    @Test func successfulExplicitReleaseClearsExhaustedRecoveryGate() {
        let clock = ControlledTestScheduler()
        var allowRelease = false
        var answers: [Bool] = []
        let session = VoiceFnTapSessionController(startDelay: 0, tapDuration: 0.1,
            schedule: clock.voiceSchedule, setFunctionKeyPressed: { $0 || allowRelease },
            enqueueAudio: { _ in }, drainAudio: { _, done in done() }, onFailure: { _ in })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 100)
        session.setEnabled(false) { answers.append($0) }
        clock.advance(to: 7100)
        #expect(session.releaseRecoveryBlocked)
        #expect(answers == [false])
        allowRelease = true
        // Explicit cleanup also retries key-up, without the permission-recovery entry point.
        session.setEnabled(false) { answers.append($0) }
        #expect(!session.releaseRecoveryBlocked)
        #expect(!session.requiresCleanupBeforeMapping)
        #expect(answers == [false, true])
        #expect(clock.tasks.allSatisfy { $0.action == nil })
    }

    @Test func unmappedHIDUsageDoesNotAllocateRecoveryTimer() {
        let clock = ControlledTestScheduler()
        let monitor = HIDRemoteMonitor(settings: AppSettings(defaults: defaults()),
            profileID: nil, scheduler: clock, runtimePermissions: { true },
            actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: UUID())
        monitor.handleSimulatedReport(reportID: 1, data: Data([0xff, 0xff]))
        #expect(clock.tasks.allSatisfy { $0.action == nil })
        monitor.disconnectSimulatedDevice()
    }

    @Test(arguments: [ButtonAction.arrowRight, .commandCopy])
    func everyHeldUsageExpiresEvenForRepeatsAndGestures(action: ButtonAction) {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        settings.setAction(action, for: .right)
        if action == .commandCopy {
            settings.setBaseBinding(.init(action: .commandCopy, shortcut: nil), for: .right, trigger: .longPress, profileID: nil)
        }
        let profile = UUID()
        var presses = 0, releases = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .press { presses += 1 } else { releases += 1 }
            return false
        }
        monitor.connectSimulatedDevice(fingerprint: "test", profileID: profile)
        let usage = RemoteButton.right.hidUsage
        let report = Data([UInt8(usage & 255), UInt8(usage >> 8)])
        monitor.handleSimulatedReport(reportID: 1, data: report)
        clock.advance(to: HIDRemoteTiming.missingReleaseTimeoutMilliseconds)
        #expect(releases == 1)
        // Stuck report without physical release is suppressed to prevent press-release cycle
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(presses == 1)
        // Physical release arrives, clearing suppression
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        // Subsequent new physical press is accepted
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(presses == 2)
        monitor.disconnectSimulatedDevice()
    }

    @Test func repeatedReportsWhileHeldDoNotInterruptHeldButton() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        let profile = UUID()
        var presses = 0, releases = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .press { presses += 1 } else { releases += 1 }
            return false
        }
        monitor.connectSimulatedDevice(fingerprint: "hold-test", profileID: profile)
        let usage = RemoteButton.ok.hidUsage
        let report = Data([UInt8(usage & 255), UInt8(usage >> 8)])
        // Initial press
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(presses == 1)
        #expect(releases == 0)
        // Advance clock while remote continues sending held reports
        clock.advance(to: 500)
        monitor.handleSimulatedReport(reportID: 1, data: report)
        clock.advance(to: 1000)
        monitor.handleSimulatedReport(reportID: 1, data: report)
        // Must NOT emit spurious release or new press edges during hold
        #expect(presses == 1)
        #expect(releases == 0)
        // Physical release report arrives
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(presses == 1)
        #expect(releases == 1)
        monitor.disconnectSimulatedDevice()
    }

    @Test func staleUsageExpiryTimerDoesNotCancelSubsequentPressToken() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        let profile = UUID()
        var presses = 0, releases = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .press { presses += 1 } else { releases += 1 }
            return false
        }
        monitor.connectSimulatedDevice(fingerprint: "token-expiry-test", profileID: profile)
        let usage = RemoteButton.ok.hidUsage
        let report = Data([UInt8(usage & 255), UInt8(usage >> 8)])

        // First press at t=0 (expiry scheduled for t=8000)
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(presses == 1)
        #expect(releases == 0)

        // Advance to t=7000 and release button
        clock.advance(to: 7000)
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(presses == 1)
        #expect(releases == 1)

        // Second press at t=7500 (new token issued, new expiry scheduled for t=15500)
        clock.advance(to: 7500)
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(presses == 2)
        #expect(releases == 1)

        // Advance to t=8500 (where the first timer would have fired at t=8000)
        clock.advance(to: 8500)
        // Must NOT expire the second press because token was updated
        #expect(presses == 2)
        #expect(releases == 1)

        // Advance to t=15500: the second press's timer expires
        clock.advance(to: 15500)
        #expect(presses == 2)
        #expect(releases == 2)

        monitor.disconnectSimulatedDevice()
    }

    @Test func hidMonitorContextWeakBoxGuardsAgainstDeallocatedMonitorCallback() {
        var monitor: HIDRemoteMonitor? = HIDRemoteMonitor(
            settings: AppSettings(defaults: defaults()),
            profileID: UUID(),
            scheduler: ControlledTestScheduler(),
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in }
        )
        let context = HIDMonitorContext(monitor!)
        #expect(context.monitor != nil)
        monitor = nil
        // After deallocation of monitor, weak reference is safely cleared
        #expect(context.monitor == nil)
    }

    @Test func rejectedVoiceRequestsLogTheirActualReason() {
        let clock = ControlledTestScheduler()
        var logs: [String] = []
        let session = VoiceFnTapSessionController(startDelay: 0,
            schedule: clock.voiceSchedule, setFunctionKeyPressed: { _ in true },
            enqueueAudio: { _ in }, drainAudio: { _, done in done() },
            onFailure: { _ in }, logger: { logs.append($0) })
        #expect(!session.startVoice())
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 0)
        #expect(!session.startVoice())
        session.suspend()
        #expect(!session.startVoice())
        #expect(logs.contains("VOICE FN TAP start rejected reason=disabled"))
        #expect(logs.contains("VOICE FN TAP start rejected reason=key_held"))
        #expect(logs.contains("VOICE FN TAP start rejected reason=suspended"))
    }

    @Test func manualUpdateCheckCancelsInformationDeadlineAndWaitsForUpdater() {
        let clock = ControlledTestScheduler()
        let store = UpdateInformationStore(userDefaults: defaults(), checkingTimeout: 1, schedule: clock.voiceSchedule)
        store.beginChecking()
        clock.advance(to: 500)
        store.beginChecking(timeoutEnabled: false)
        clock.advance(to: 180000)
        #expect(store.state == .checking)
        #expect(clock.tasks.allSatisfy { $0.action == nil })
        store.setUpToDate()
        #expect(store.state == .upToDate)
    }

    @Test func sensitiveMetadataIsRejectedByBothDestinationPolicies() {
        for term in ["password", "passcode", "secret", "api key", "apikey", "token", "credit card",
                     "密码", "口令", "密钥", "令牌", "信用卡"] {
            let snapshot = VoiceInputDestinationSnapshot(bundleIdentifier: "test", role: "AXTextField", subrole: "",
                enabled: true, editable: true, protectedContent: false, semanticText: term.uppercased())
            #expect(snapshot.isSensitiveDestination)
            #expect(!snapshot.isSafeEditableDestination)
        }
    }

    @Test func destroyingSessionReleasesHeldKeyAndCancelsDelayedTap() {
        let clock = ControlledTestScheduler()
        var events: [Bool] = []
        var session: VoiceFnTapSessionController? = VoiceFnTapSessionController(startDelay: 0,
            schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { events.append($0); return true }, enqueueAudio: { _ in },
            drainAudio: { _, done in done() }, onFailure: { _ in })
        weak let observed = session
        session!.setEnabled(true)
        #expect(session!.startVoice())
        clock.advance(to: 0)
        #expect(events == [true])
        session = nil
        #expect(observed == nil)
        #expect(events == [true, false])
        clock.advance(to: 4000)
        #expect(events == [true, false])
    }

    @Test func missingButtonReleaseDoesNotLatchForever() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.setAction(.disabled, for: .power, trigger: .longPress)
        let monitor = HIDRemoteMonitor(settings: settings, scheduler: clock,
            runtimePermissions: { true }, diagnosticLogger: { _ in })
        #expect(monitor.shouldAcceptRawPress(button: .power, action: .commandCopy))
        #expect(!monitor.shouldAcceptRawPress(button: .power, action: .commandCopy))
        clock.advance(to: 7999)
        #expect(!monitor.shouldAcceptRawPress(button: .power, action: .commandCopy))
        clock.advance(to: 8000)
        #expect(monitor.shouldAcceptRawPress(button: .power, action: .commandCopy))
        monitor.stop()
    }

    @Test func continuousHeldReportsSurviveBeyondEightSecondsAndRecoverAfterLossOfSignal() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        var releaseCount = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .release { releaseCount += 1 }
            return true
        }
        monitor.connectSimulatedDevice(fingerprint: "test-device", profileID: profile, isSeized: true)
        let usage = RemoteButton.power.hidUsage
        let reportData = Data([UInt8(usage & 255), UInt8(usage >> 8)])

        // Initial press at t=0
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(releaseCount == 0)

        // Continuous reports received past 8 seconds up to 10 seconds
        for time: UInt64 in [1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000] {
            clock.advance(to: time)
            monitor.handleSimulatedReport(reportID: 1, data: reportData)
            #expect(releaseCount == 0, "Hold must not be prematurely interrupted at t=\(time)")
        }

        // Past 10s, remote goes silent (loss of signal / dropped release)
        clock.advance(to: 17999)
        #expect(releaseCount == 0, "Recovery must wait full 8000ms after last received report")

        // At 18000ms (10000 + 8000ms), missing-release recovery triggers cleanly
        clock.advance(to: 18000)
        #expect(releaseCount == 1)
        monitor.stop()
    }

    @Test func continuousHeldReportsSurviveBeyondEightSecondsAndReleasePromptly() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        var releaseCount = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .release { releaseCount += 1 }
            return true
        }
        monitor.connectSimulatedDevice(fingerprint: "test-device", profileID: profile, isSeized: true)
        let usage = RemoteButton.power.hidUsage
        let reportData = Data([UInt8(usage & 255), UInt8(usage >> 8)])

        // Initial press
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(releaseCount == 0)

        // Continuous reports past 8 seconds
        for time: UInt64 in [1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000] {
            clock.advance(to: time)
            monitor.handleSimulatedReport(reportID: 1, data: reportData)
            #expect(releaseCount == 0)
        }

        // Explicit physical release arrives at 10500ms
        clock.advance(to: 10500)
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(releaseCount == 1)

        // Advance to 25000ms; verify no duplicate synthetic release
        clock.advance(to: 25000)
        #expect(releaseCount == 1)
        monitor.stop()
    }

    @Test func missingReleaseRecoverySuppressesRepeatedReportsUntilPhysicalRelease() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        var pressCount = 0
        var releaseCount = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .press { pressCount += 1 }
            if phase == .release { releaseCount += 1 }
            return true
        }
        monitor.connectSimulatedDevice(fingerprint: "test-device", profileID: profile, isSeized: true)
        let usage = RemoteButton.power.hidUsage
        let reportData = Data([UInt8(usage & 255), UInt8(usage >> 8)])

        // Initial press at t=0
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(pressCount == 1)
        #expect(releaseCount == 0)

        // Remote drops release, goes silent. Recovery fires at t=8000
        clock.advance(to: 8000)
        #expect(pressCount == 1)
        #expect(releaseCount == 1)

        // Device buffer sends repeated report with the same usage while physically still stuck
        clock.advance(to: 9000)
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(pressCount == 1, "Stuck report must not trigger new press cycle")
        #expect(releaseCount == 1)

        clock.advance(to: 17000)
        #expect(pressCount == 1)
        #expect(releaseCount == 1)

        // Physical release arrives (empty report)
        clock.advance(to: 18000)
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(pressCount == 1)
        #expect(releaseCount == 1)

        // Next legitimate physical press arrives
        clock.advance(to: 19000)
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(pressCount == 2, "New press after physical release must be cleanly accepted")
        #expect(releaseCount == 1)

        monitor.stop()
    }

    @Test func continuousHeldReportsExceedingHardCeilingAreForceReleasedAndSuppressed() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = true
        var releaseCount = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profile, scheduler: clock,
            runtimePermissions: { true }, diagnosticLogger: { _ in })
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .release { releaseCount += 1 }
            return true
        }
        monitor.connectSimulatedDevice(fingerprint: "test-device", profileID: profile, isSeized: true)
        let usage = RemoteButton.power.hidUsage
        let reportData = Data([UInt8(usage & 255), UInt8(usage >> 8)])

        // Press at t=0
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(releaseCount == 0)

        // Continuous reports arriving every 5s up to 55s
        for time: UInt64 in stride(from: 5000, through: 55000, by: 5000) {
            clock.advance(to: time)
            monitor.handleSimulatedReport(reportID: 1, data: reportData)
            #expect(releaseCount == 0, "Hold must not be prematurely released at t=\(time)")
        }

        // Advance to 60000ms: hard ceiling (60s) triggers force recovery
        clock.advance(to: 60000)
        #expect(releaseCount == 1, "Hard ceiling watchdog must fire at 60s")

        // Continued reports beyond 60s must be suppressed
        clock.advance(to: 61000)
        monitor.handleSimulatedReport(reportID: 1, data: reportData)
        #expect(releaseCount == 1)

        // Physical release clears suppression
        clock.advance(to: 62000)
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0]))
        #expect(releaseCount == 1)

        monitor.stop()
    }

    @Test func backOnlyModeSustainsContinuousHoldAndRecoversAfterSilence() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.customMappingEnabled = false
        var performedActions: [ConfiguredButtonAction] = []
        var releaseCount = 0
        let profile = UUID()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profile,
            scheduler: clock,
            runtimePermissions: { true },
            actionPerformer: { button, trigger, action in
                if button == .back && trigger == .singleClick {
                    performedActions.append(action)
                }
                return true
            },
            diagnosticLogger: { _ in }
        )
        monitor.onRuntimeButton = { _, _, phase in
            if phase == .release { releaseCount += 1 }
            return true
        }
        monitor.connectSimulatedDevice(fingerprint: "test-device", profileID: profile, isSeized: true)
        let usage = RemoteButton.back.hidUsage
        let reportData = Data([UInt8(usage & 255), UInt8(usage >> 8)])

        // First press in back-only mode
        monitor.handleSimulatedBackOnlyReport(reportID: 1, data: reportData)
        #expect(performedActions.count == 1)
        #expect(performedActions.first?.action == .deleteBackward)
        #expect(releaseCount == 0)

        // Continuous reports past 8 seconds up to 10 seconds
        for time: UInt64 in [1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000] {
            clock.advance(to: time)
            monitor.handleSimulatedBackOnlyReport(reportID: 1, data: reportData)
            #expect(performedActions.count == 1, "Repeated held back-only report must not duplicate delete action")
            #expect(releaseCount == 0, "Back-only hold must survive beyond 8 seconds with continuous reports")
        }

        // Silent for 8000ms after last report at 10000ms
        clock.advance(to: 18000)
        #expect(releaseCount == 1, "Missing release recovery must fire 8000ms after silence")

        // Continued stuck reports must be suppressed
        clock.advance(to: 19000)
        monitor.handleSimulatedBackOnlyReport(reportID: 1, data: reportData)
        #expect(performedActions.count == 1, "Stuck report after recovery must be suppressed")
        #expect(releaseCount == 1)

        // Physical release arrives
        clock.advance(to: 20000)
        monitor.handleSimulatedBackOnlyReport(reportID: 1, data: Data([0, 0]))
        #expect(performedActions.count == 1)
        #expect(releaseCount == 1)

        // Next press works
        clock.advance(to: 21000)
        monitor.handleSimulatedBackOnlyReport(reportID: 1, data: reportData)
        #expect(performedActions.count == 2)

        monitor.stop()
    }

    @Test func rawPressAfterExplicitReleaseIsAcceptedPromptly() {
        let clock = ControlledTestScheduler()
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        settings.setAction(.disabled, for: .back, trigger: .longPress)
        settings.setAction(.disabled, for: .back, trigger: .doubleClick)
        let monitor = HIDRemoteMonitor(settings: settings, scheduler: clock,
            runtimePermissions: { true }, diagnosticLogger: { _ in })

        // First press: accepted
        #expect(monitor.shouldAcceptRawPress(button: .back, action: .escape))

        // Duplicate press without explicit release: rejected
        #expect(!monitor.shouldAcceptRawPress(button: .back, action: .escape))

        // Explicit release occurs, scheduling stable release window
        monitor.scheduleNonRepeatableRelease(for: .back)

        // Rapid second press within 600 ms window: accepted promptly
        clock.advance(to: 150)
        #expect(monitor.shouldAcceptRawPress(button: .back, action: .escape))

        // Unreleased repeat after second press: rejected
        #expect(!monitor.shouldAcceptRawPress(button: .back, action: .escape))

        monitor.stop()
    }

    @Test func foregroundRefreshPreservesLoginFailureUntilRetry() {
        let controller = LifecycleLoginController()
        let service = LoginItemService(controller: controller)
        service.setEnabled(true)
        #expect(service.didFailToUpdate)
        service.refresh()
        #expect(service.didFailToUpdate)
        controller.fail = false
        service.setEnabled(true)
        #expect(service.isEnabled)
        #expect(!service.didFailToUpdate)
    }

    @Test func abandonedUpdateCheckExpiresButCompletedResultDoesNot() {
        let clock = ControlledTestScheduler()
        let store = UpdateInformationStore(userDefaults: defaults(), checkingTimeout: 1, schedule: clock.voiceSchedule)
        store.beginChecking()
        clock.advance(to: 1000)
        #expect(store.state == .unavailable)
        store.beginChecking()
        store.setAvailable(displayVersion: "v26-10-12.073", buildVersion: "73", fallbackDescription: nil)
        clock.advance(to: 3000)
        guard case .available = store.state else { Issue.record("Deadline replaced completed result"); return }
        store.beginChecking()
        store.setUpToDate()
        clock.advance(to: 5000)
        #expect(store.state == .upToDate)
    }

    @Test func sparkleLaunchAloneDoesNotSkipFirstUseWizard() {
        let prefs = defaults()
        let settings = AppSettings(defaults: prefs)
        _ = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "73", sparkleHadLaunchedBefore: true)
        #expect(!settings.isOnboardingComplete)
    }

    @Test func savedPreferencesDoNotBypassIncompleteOnboarding() {
        let prefs = defaults()
        prefs.set(10.0, forKey: "gainDB")
        let settings = AppSettings(defaults: prefs)
        _ = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "73", sparkleHadLaunchedBefore: false)
        #expect(!settings.isOnboardingComplete)
    }

    @Test func directTypingRejectsProtectedFieldsButAllowsSearch() {
        func coordinator(protected: Bool, text: String) -> VoiceInputDestinationCoordinator {
            VoiceInputDestinationCoordinator(snapshot: {
                VoiceInputDestinationSnapshot(bundleIdentifier: "test", role: "AXTextField", subrole: "",
                    enabled: true, editable: true, protectedContent: protected, semanticText: text)
            })
        }
        if case .cancelled(.sensitiveDestination) = coordinator(protected: true, text: "").waitUntilReady(completion: { _ in }) {} else { Issue.record("Protected destination accepted") }
        if case .cancelled(.sensitiveDestination) = coordinator(protected: false, text: "Password").waitUntilReady(completion: { _ in }) {} else { Issue.record("Password destination accepted") }
        if case .immediate = coordinator(protected: false, text: "Search").waitUntilReady(completion: { _ in }) {} else { Issue.record("Explicit search typing rejected") }
    }

}
