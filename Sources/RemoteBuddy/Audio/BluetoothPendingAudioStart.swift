import Foundation

/// Owns an audio-configuration pre-roll for one device. Rejecting a different
/// device must not discard the original device's pending start.
final class BluetoothPendingAudioStart {
    private(set) var identifier: UUID?
    private(set) var operationID: UUID?
    var audio = CommandVoiceActivationAudioBuffer(maximumSampleCount: 32_000)

    @discardableResult
    func begin(for identifier: UUID) -> UUID {
        cancel()
        let operationID = UUID()
        self.identifier = identifier
        self.operationID = operationID
        audio.begin()
        return operationID
    }

    func matches(identifier: UUID, operationID: UUID) -> Bool {
        self.identifier == identifier && self.operationID == operationID
    }

    func drain() -> [Int16] {
        let samples = audio.drain()
        identifier = nil
        operationID = nil
        return samples
    }

    @discardableResult
    func cancel(ifOwnedBy identifier: UUID) -> Bool {
        guard self.identifier == identifier else { return false }
        cancel()
        return true
    }
    func cancel() {
        identifier = nil
        operationID = nil
        audio.cancel()
    }

}
