import CoreGraphics
import Testing
@testable import RemoteBuddy

@Suite("App switcher release recovery")
struct AppSwitcherReleaseRecoveryTests {
    @Test func failedReleaseRetriesAndOldTimersCannotReleaseANewSession() {
        let clock = ControlledTestScheduler()
        var releases = 0
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, _ in
            if code == 55 && !down { releases += 1; return releases >= 3 }
            return true
        })
        #expect(session.triggerTemporarily(schedule: clock.voiceSchedule))
        clock.advance(to: 1_000)
        #expect(session.isActive)
        #expect(!session.triggerTemporarily(schedule: clock.voiceSchedule))
        clock.advance(to: 1_150)
        #expect(!session.isActive)
        #expect(releases == 3)
        #expect(session.triggerTemporarily(schedule: clock.voiceSchedule))
        clock.tasks.filter { $0.cancelled }.forEach { $0.fire(includingCancelled: true) }
        #expect(session.isActive)
        #expect(session.confirm())
    }

    @Test func persistentFailureHasBoundedRetriesAndRetainsOwnership() {
        let clock = ControlledTestScheduler()
        var canRelease = false
        var releases = 0
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, _ in
            if code == 55 && !down { releases += 1; return canRelease }
            return true
        })
        #expect(session.triggerTemporarily(schedule: clock.voiceSchedule))
        clock.runAll()
        #expect(releases == 4)
        #expect(clock.activeCount == 0)
        #expect(session.isActive)
        canRelease = true
        #expect(session.confirm())
        #expect(!session.isActive)
    }

    @Test func failedTabStillOwnsAndRetriesItsCommandRelease() {
        let clock = ControlledTestScheduler()
        var releases = 0
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, _ in
            if code == 48 { return false }
            if code == 55 && !down { releases += 1; return releases > 1 }
            return true
        })
        #expect(!session.triggerTemporarily(schedule: clock.voiceSchedule))
        #expect(session.isActive)
        clock.runAll()
        #expect(releases == 2)
        #expect(!session.isActive)
    }
}
