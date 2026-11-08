import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Shared permission polling")
struct PermissionPollingTests {
    @Test func subscribersShareOneTimerAndLastCancellationStopsIt() {
        let clock = ControlledTestScheduler()
        var granted = true
        var evaluations = 0
        var firstValues: [Bool] = []
        var secondValues: [Bool] = []
        let poll = HIDPermissionPoll(scheduler: clock,
            permissionEvaluator: { evaluations += 1; return granted }, logger: { _ in })
        let first = poll.subscribe { firstValues.append($0) }
        var second: HIDPermissionPoll.Subscription? = poll.subscribe { secondValues.append($0) }
        #expect(clock.activeCount == 1)
        clock.fire(afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds)
        #expect(evaluations == 1)
        #expect(firstValues == [true] && secondValues == [true])
        first.cancel()
        first.cancel()
        granted = false
        clock.fire(afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds)
        #expect(evaluations == 2)
        #expect(firstValues == [true] && secondValues == [true, false])
        #expect(second != nil)
        second = nil
        #expect(clock.activeCount == 0)
        clock.tasks[0].fire(includingCancelled: true)
        #expect(evaluations == 2)
        let restarted = poll.subscribe { firstValues.append($0) }
        #expect(clock.activeCount == 1)
        clock.fire(afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds)
        #expect(firstValues == [true, false])
        restarted.cancel()
    }

    @Test func subscriberCanCancelItselfWithoutLockReentry() {
        let clock = ControlledTestScheduler()
        let poll = HIDPermissionPoll(scheduler: clock, permissionEvaluator: { false }, logger: { _ in })
        var calls = 0
        var subscription: HIDPermissionPoll.Subscription?
        subscription = poll.subscribe { _ in calls += 1; subscription?.cancel() }
        clock.fire(afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds)
        #expect(calls == 1)
        #expect(clock.activeCount == 0)
        clock.tasks[0].fire(includingCancelled: true)
        #expect(calls == 1)
        subscription = nil
    }

    @Test func subscriptionKeepsOwnerAliveUntilCancelledThenReleasesIt() {
        let clock = ControlledTestScheduler()
        var poll: HIDPermissionPoll? = HIDPermissionPoll(scheduler: clock,
            permissionEvaluator: { true }, logger: { _ in })
        weak let owner = poll
        let subscription = poll!.subscribe { _ in }
        poll = nil
        #expect(owner != nil)
        subscription.cancel()
        #expect(owner == nil)
        #expect(clock.activeCount == 0)
    }

    @Test func acknowledgedWriteIgnoresStaleTimeoutFromPreviousCommand() {
        let clock = ControlledTestScheduler()
        var sent: [Data] = []
        var failures = 0
        let queue = AcknowledgedBluetoothWriteQueue(scheduler: clock,
            send: { sent.append($0) }, onFailure: { failures += 1 })
        #expect(queue.enqueue(Data([1])))
        #expect(queue.enqueue(Data([2])))
        let firstTimeout = clock.tasks[0]
        queue.acknowledge(success: true)
        #expect(sent == [Data([1]), Data([2])])
        firstTimeout.fire(includingCancelled: true)
        #expect(failures == 0)
        #expect(clock.activeCount == 1)
        clock.fire(afterMilliseconds: 5_000)
        #expect(failures == 1)
        firstTimeout.fire(includingCancelled: true)
        #expect(failures == 1)
        #expect(queue.enqueue(Data([3])))
        queue.acknowledge(success: true)
        #expect(clock.activeCount == 0)
    }
}
