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
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 320 })
        #expect(chunks.flatMap { $0 } == samples)
    }

    @Test(arguments: [12_480, 12_720, 80_000])
    func preRollPlaybackCallbackLatencyDoesNotRejectLiveSpeech(count: Int) {
        // Reproduce the observed ~0.78-s startup backlog, 15-ms live packets,
        // and a 60-ms delay before dataPlayedBack reports reusable capacity.
        // With half-second chunks this rejects four consecutive live packets.
        let latency = 960
        var pending = count
        var preRoll = count
        var playbackEnd = 0
        var completions: [(at: Int, samples: Int, preRoll: Bool)] = []
        for chunk in VoicePlaybackQueueCapacity.chunks(Array(repeating: Int16(0), count: count)) {
            playbackEnd += chunk.count
            completions.append((playbackEnd + latency, chunk.count, true))
        }
        var rejected = 0
        var receivedLive = 0
        var scheduledLive = 0
        for arrival in stride(from: 240, through: count + 32_000, by: 240) {
            for completed in completions where completed.at <= arrival {
                pending -= completed.samples
                if completed.preRoll { preRoll -= completed.samples }
            }
            completions.removeAll { $0.at <= arrival }
            receivedLive += 240
            guard VoicePlaybackQueueCapacity.admits(pending: pending, incoming: 240,
                pendingPreRoll: preRoll, preRollBudget: count) else {
                rejected += 1
                continue
            }
            pending += 240
            scheduledLive += 240
            playbackEnd = max(playbackEnd, arrival) + 240
            completions.append((playbackEnd + latency, 240, false))
            #expect(pending <= VoicePlaybackQueueCapacity.maximumSamples + count)
        }
        #expect(rejected == 0)
        #expect(scheduledLive == receivedLive)
        #expect(pending == completions.reduce(0) { $0 + $1.samples })
    }
}
