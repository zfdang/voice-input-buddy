import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Voice destination asynchronous boundaries")
@MainActor
struct DestinationCoordinationTests {
    private func field(_ app: String = "editor", editable: Bool = true, identity: String = "old") -> VoiceInputDestinationSnapshot {
        VoiceInputDestinationSnapshot(bundleIdentifier: app, role: editable ? "AXTextArea" : "AXButton",
            subrole: "", enabled: true, editable: editable, protectedContent: false,
            semanticText: "Composer", focusIdentity: identity)
    }

    @Test func initialSnapshotDefersActionAndWaiterUntilCaptured() {
        let clock = ControlledTestScheduler()
        var queries: [(VoiceInputDestinationSnapshot) -> Void] = []
        var actions: [UInt64] = []
        var results: [VoiceInputDestinationWaitResult] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule,
            snapshot: { Issue.record("Must not read initial focus synchronously"); return field() },
            querySnapshot: { queries.append($0) })
        let request = coordinator.beginTargetSwitch(intent: .shortcut) { actions.append($0) }
        _ = coordinator.waitUntilReady { results.append($0) }
        #expect(actions.isEmpty)
        #expect(queries.count == 1)
        queries[0](field())
        #expect(actions == [request])
        #expect(queries.count == 2)
        queries[1](field(identity: "new"))
        #expect(results == [.ready])
    }

    @Test func staleOrTimedOutInitialSnapshotsNeverDispatchActions() {
        let clock = ControlledTestScheduler()
        var queries: [(VoiceInputDestinationSnapshot) -> Void] = []
        var actions: [UInt64] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule,
            querySnapshot: { queries.append($0) })
        coordinator.beginTargetSwitch(intent: .shortcut) { actions.append($0) }
        coordinator.beginTargetSwitch(intent: .shortcut) { actions.append($0) }
        queries[0](field())
        #expect(actions.isEmpty)
        clock.fire(afterMilliseconds: 5000)
        queries[1](field())
        #expect(actions.isEmpty)
    }

    @Test func directAsyncValidationPublishesResultBeforeCompletionAndIgnoresLateReplies() {
        for sensitive in [false, true] {
            let clock = ControlledTestScheduler()
            var replies: [(VoiceInputDestinationSnapshot) -> Void] = []
            var states: [VoiceInputDestinationState] = []
            var results: [VoiceInputDestinationWaitResult] = []
            let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule,
                querySnapshot: { replies.append($0) }, onStateChange: { states.append($0) })
            _ = coordinator.waitUntilReady {
                #expect(states.count == 1)
                results.append($0)
            }
            let snapshot = VoiceInputDestinationSnapshot(bundleIdentifier: "editor", role: "AXTextArea", subrole: "",
                enabled: true, editable: true, protectedContent: sensitive, semanticText: "Composer")
            replies[0](snapshot)
            #expect(states == [sensitive ? .cancelled(.sensitiveDestination) : .ready])
            #expect(results == [sensitive ? .cancelled(.sensitiveDestination) : .ready])
            replies[0](snapshot)
            for task in clock.tasks { task.fire(includingCancelled: true) }
            #expect(states.count == 1 && results.count == 1)
        }
    }

    @Test func directAsyncTimeoutPublishesOnceAndCancellationStaysSilent() {
        for cancelled in [false, true] {
            let clock = ControlledTestScheduler()
            var replies: [(VoiceInputDestinationSnapshot) -> Void] = []
            var states: [VoiceInputDestinationState] = []
            var results: [VoiceInputDestinationWaitResult] = []
            let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule,
                querySnapshot: { replies.append($0) }, onStateChange: { states.append($0) })
            let waiting = coordinator.waitUntilReady { results.append($0) }
            if cancelled, case let .waiting(task) = waiting { task.cancel() }
            clock.fire(afterMilliseconds: 5000)
            replies[0](field())
            for task in clock.tasks { task.fire(includingCancelled: true) }
            #expect(states == (cancelled ? [] : [.cancelled(.timedOut)]))
            #expect(results == (cancelled ? [] : [.cancelled(.timedOut)]))
        }
    }

    @Test func applicationSwitchWaitsForEditableDestinationAndCompletesOnce() {
        let clock = ControlledTestScheduler()
        var current = field()
        var results: [VoiceInputDestinationWaitResult] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule, snapshot: { current })
        coordinator.beginTargetSwitch(intent: .application(bundleIdentifier: "target"))
        _ = coordinator.waitUntilReady { results.append($0) }
        current = field("target", editable: false)
        clock.fire(afterMilliseconds: 50)
        #expect(results.isEmpty)
        current = field("target", identity: "new")
        clock.fire(afterMilliseconds: 50)
        #expect(results == [.ready])
        for task in clock.tasks { task.fire(includingCancelled: true) }
        #expect(results == [.ready])
    }

    @Test func leavingObservedTargetCancelsInsteadOfAdoptingAnotherApp() {
        let clock = ControlledTestScheduler()
        var current = field()
        var results: [VoiceInputDestinationWaitResult] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule, snapshot: { current })
        coordinator.beginTargetSwitch(intent: .application(bundleIdentifier: "target"))
        _ = coordinator.waitUntilReady { results.append($0) }
        current = field("target", editable: false)
        clock.fire(afterMilliseconds: 50)
        current = field("unrelated", identity: "new")
        clock.fire(afterMilliseconds: 50)
        #expect(results == [.cancelled(.targetChanged)])
    }

    @Test func shortcutCannotReuseOldEditableFieldUntilFocusChanges() {
        let clock = ControlledTestScheduler()
        var current = field()
        var results: [VoiceInputDestinationWaitResult] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule, snapshot: { current })
        coordinator.beginTargetSwitch(intent: .shortcut)
        _ = coordinator.waitUntilReady { results.append($0) }
        clock.fire(afterMilliseconds: 50)
        #expect(results.isEmpty)
        current = field(identity: "new")
        clock.fire(afterMilliseconds: 50)
        #expect(results == [.ready])
    }

    @Test func oldTimeoutAndOldWaiterCancellationCannotCancelNewRequest() throws {
        let clock = ControlledTestScheduler()
        var current = field()
        var oldResults: [VoiceInputDestinationWaitResult] = []
        var newResults: [VoiceInputDestinationWaitResult] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule, snapshot: { current })
        coordinator.beginTargetSwitch(intent: .application(bundleIdentifier: "first"))
        let oldWait = coordinator.waitUntilReady { oldResults.append($0) }
        guard case let .waiting(oldToken) = oldWait else { Issue.record("Expected pending request"); return }
        let timeout = try #require(clock.tasks.first(where: { $0.delay == 5_000 }))
        coordinator.beginTargetSwitch(intent: .application(bundleIdentifier: "second"))
        _ = coordinator.waitUntilReady { newResults.append($0) }
        #expect(oldResults == [.cancelled(.superseded)])
        timeout.fire(includingCancelled: true)
        oldToken.cancel()
        #expect(newResults.isEmpty)
        current = field("second", identity: "new")
        clock.fire(afterMilliseconds: 50)
        #expect(newResults == [.ready])
        #expect(clock.activeCount == 0)
    }

    @Test func timeoutDeliversOnceAndLateFocusCompletionIsIgnored() {
        let clock = ControlledTestScheduler()
        var results: [VoiceInputDestinationWaitResult] = []
        let coordinator = VoiceInputDestinationCoordinator(schedule: clock.voiceSchedule, snapshot: { field() })
        let request = coordinator.beginTargetSwitch(intent: .focusInput)
        _ = coordinator.waitUntilReady { results.append($0) }
        clock.fire(afterMilliseconds: 5_000)
        coordinator.completeFocusOperation(requestID: request, succeeded: true)
        coordinator.shutdown()
        for task in clock.tasks { task.fire(includingCancelled: true) }
        #expect(results == [.cancelled(.timedOut)])
        #expect(clock.activeCount == 0)
    }
}
