import Testing
@testable import RemoteBuddy

@Suite("Voice playback capacity")
struct VoicePlaybackCapacityTests {
    @Test func burstAndDriftCannotExceedHalfASecond() {
        #expect(VoicePlaybackQueueCapacity.admits(pending: 0, incoming: 8_000))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 8_000, incoming: 1))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 0, incoming: Int.max))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: Int.max, incoming: 320))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 0, incoming: 0))
        #expect(VoicePlaybackQueueCapacity.admits(pending: 7_680, incoming: 320))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 7_681, incoming: 320))
        // Playback makes room again without tearing down the engine/session.
        #expect(VoicePlaybackQueueCapacity.admits(pending: 7_360, incoming: 320))
    }
    @Test func preRollHasASeparateBoundWithoutExpandingTheLiveQueue() {
        #expect(VoicePlaybackQueueCapacity.admits(pending: 0, incoming: 80_000, isPreRoll: true))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 0, incoming: 80_001, isPreRoll: true))
        #expect(VoicePlaybackQueueCapacity.admits(pending: 80_000, incoming: 8_000, pendingPreRoll: 80_000))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 88_000, incoming: 1, pendingPreRoll: 80_000))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 80_000, incoming: 1, pendingPreRoll: 80_000, isPreRoll: true))
        #expect(VoicePlaybackQueueCapacity.admits(pending: 87_680, incoming: 320, pendingPreRoll: 80_000))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 0, incoming: Int.max, isPreRoll: true))
    }

    @Test func consumingPreRollMakesRoomForLiveSpeechWithoutDroppingIt() {
        var pending = 80_000
        var preRoll = 80_000
        let reserved = 80_000
        for _ in 0..<10 {
            #expect(VoicePlaybackQueueCapacity.admits(pending: pending, incoming: 8_000,
                pendingPreRoll: preRoll, preRollBudget: reserved))
            pending += 8_000
            // One pre-roll chunk finishes every half second. Live arrivals must
            // retain the same room even though pending-preRoll remains unchanged.
            pending -= 8_000
            preRoll = max(0, preRoll - 8_000)
        }
        #expect(preRoll == 0)
        #expect(VoicePlaybackQueueCapacity.admits(pending: pending, incoming: 8_000,
            preRollBudget: reserved))
        #expect(!VoicePlaybackQueueCapacity.admits(pending: 88_000, incoming: 1, preRollBudget: reserved))
    }

    @Test(arguments: [12_000, 32_000, 80_000]) func preRollChunksPreserveEverySampleInOrder(count: Int) {
        let samples = (0..<count).map { Int16($0 % 32_767) }
        let chunks = VoicePlaybackQueueCapacity.chunks(samples)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 8_000 })
        #expect(chunks.flatMap { $0 } == samples)
    }
}
