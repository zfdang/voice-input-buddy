import Foundation

struct CommandVoiceActivationAudioBuffer {
    let maximumSampleCount: Int
    var samples: [Int16] = []
    private(set) var isWaiting = false
    private var waitingMaximumSampleCount: Int = 0

    init(maximumSampleCount: Int = 8_000) {
        self.maximumSampleCount = maximumSampleCount
    }

    var bufferedSampleCount: Int {
        samples.count
    }

    mutating func begin(maximumSampleCount: Int? = nil) {
        waitingMaximumSampleCount = maximumSampleCount ?? self.maximumSampleCount
        samples.removeAll(keepingCapacity: true)
        isWaiting = true
    }

    mutating func appendIfWaiting(_ newSamples: [Int16]) -> Bool {
        guard isWaiting else { return false }
        samples.append(contentsOf: newSamples)
        if samples.count > waitingMaximumSampleCount {
            samples.removeFirst(samples.count - waitingMaximumSampleCount)
        }
        return true
    }

    mutating func drain() -> [Int16] {
        guard isWaiting else { return [] }
        isWaiting = false
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }

    mutating func cancel() {
        isWaiting = false
        samples.removeAll(keepingCapacity: true)
    }
}

