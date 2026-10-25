import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Application termination")
@MainActor
struct ApplicationTerminationTests {
    @Test func acceptedQuitClosesVoiceAdmissionBeforeRuntimeTeardown() throws {
        let name = UUID().uuidString
        let values = try #require(UserDefaults(suiteName: name))
        defer { values.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: values))
        model.started = true
        defer { model.started = false }
        model.prepareForTermination()
        #expect(!model.canAcceptNewVoiceSession(from: .bluetooth))
        model.beginVoiceSessionIfNeeded()
        #expect(!model.isStreaming)
    }

    @Test func repeatedQuitAndReleaseCallbacksReplyExactlyOnce() {
        let coordinator = ApplicationTerminationCoordinator()
        var releases: [() -> Void] = []
        var replies = 0
        for _ in 0..<3 {
            coordinator.request(begin: { releases.append($0) }, reply: { replies += 1 })
        }
        #expect(coordinator.isTerminating)
        #expect(releases.count == 1)
        #expect(replies == 0)
        releases[0]()
        releases[0]()
        #expect(replies == 1)
    }
    @Test func missingCleanupReplyTimesOutExactlyOnceAndLateCompletionIsIgnored() {
        let clock = ControlledTestScheduler()
        let coordinator = ApplicationTerminationCoordinator(schedule: clock.voiceSchedule)
        var done: (() -> Void)?
        var replies = 0
        coordinator.request(timeout: 12, begin: { done = $0 }, reply: { replies += 1 })
        clock.advance(to: 11_999)
        #expect(replies == 0)
        clock.advance(to: 12_000)
        #expect(replies == 1)
        done?()
        #expect(replies == 1)
        #expect(clock.activeCount == 0)
    }

    @Test func quitAllowsNormalDrainFallbackBeforeItsFinalDeadline() {
        let clock = ControlledTestScheduler()
        let session = VoiceFnTapSessionController(schedule: clock.voiceSchedule,
            setFunctionKeyPressed: { _ in true }, enqueueAudio: { _ in },
            drainAudio: { _, _ in }, onFailure: { _ in Issue.record("Unexpected failure") },
            pendingPlaybackDuration: { 5 })
        session.setEnabled(true)
        #expect(session.startVoice())
        clock.advance(to: 270)
        let coordinator = ApplicationTerminationCoordinator(schedule: clock.voiceSchedule)
        var replies = 0
        coordinator.request(timeout: session.terminationTimeout,
            begin: { done in session.setEnabled(false) { _ in done() } }, reply: { replies += 1 })
        let watchdog = clock.tasks.first { $0.delay == UInt64((session.terminationTimeout * 1_000).rounded()) }
        clock.advance(to: 1_770)
        #expect(replies == 0)
        clock.runAll()
        #expect(session.phase == .idle)
        #expect(replies == 1)
        #expect(watchdog?.cancelled == true)
        watchdog?.fire(includingCancelled: true)
        #expect(replies == 1)
    }

    @Test func terminationRequestedFromRunLoopCompletesCleanly() async {
        let coordinator = ApplicationTerminationCoordinator()
        var replied = false
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    coordinator.request(
                        begin: { complete in
                            DispatchQueue.main.async {
                                complete()
                            }
                        },
                        reply: {
                            replied = true
                            continuation.resume()
                        }
                    )
                }
            }
        }
        #expect(replied)
        #expect(coordinator.isTerminating)
    }
}
