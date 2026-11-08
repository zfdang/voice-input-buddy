import Foundation

enum VoicePlaybackQueueCapacity {
    static let maximumSamples = 8_000
    static let maximumPreRollSamples = 80_000

    static func admits(pending: Int, incoming: Int, pendingPreRoll: Int = 0, isPreRoll: Bool = false,
        preRollBudget: Int = 0) -> Bool {
        guard pending >= 0, pendingPreRoll >= 0, pendingPreRoll <= pending,
              pendingPreRoll <= maximumPreRollSamples, incoming > 0 else { return false }
        guard (0...maximumPreRollSamples).contains(preRollBudget) else { return false }
        let budget = max(preRollBudget, pendingPreRoll)
        if isPreRoll {
            guard incoming <= maximumPreRollSamples - pendingPreRoll else { return false }
            return pending <= maximumSamples + max(budget, pendingPreRoll + incoming) - incoming
        }
        // A pre-roll backlog creates an equivalent live backlog while FIFO playback
        // consumes it. Keep that reservation until the entire queue drains.
        return pending <= maximumSamples + budget && incoming <= maximumSamples + budget - pending
    }

    static func chunks(_ samples: [Int16]) -> [[Int16]] {
        stride(from: 0, to: samples.count, by: maximumSamples).map {
            Array(samples[$0..<min(samples.count, $0 + maximumSamples)])
        }
    }
}

enum PCMNormalization {
    static func sample(_ value: Int16) -> Float {
        Float(value) / 32768.0
    }
}

