import Foundation

enum ATVVProtocol {
    static let serviceUUID = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"
    static let transmitUUID = "AB5E0002-5A21-4F05-BC7D-AF01F617B664"
    static let audioUUID = "AB5E0003-5A21-4F05-BC7D-AF01F617B664"
    static let controlUUID = "AB5E0004-5A21-4F05-BC7D-AF01F617B664"

    static let getCapabilitiesV10 = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])

    static func supportsAudio(sampleRate: Double) -> Bool {
        sampleRate == 16_000
    }

    static func supportsFrameSize(_ size: Int) -> Bool { (1...512).contains(size) }

    static func microphoneOpen(version: UInt16, codec: UInt8) -> Data {
        if version >= 0x0100 {
            return Data([0x0C, 0x00])
        }
        return Data([0x0C, 0x00, codec])
    }

    static func microphoneClose(version: UInt16, sessionID: UInt8) -> Data {
        if version >= 0x0100 {
            return Data([0x0D, sessionID])
        }
        return Data([0x0D])
    }

    static func microphoneExtend(version: UInt16, sessionID: UInt8) -> Data? {
        guard version >= 0x0100 else { return nil }
        return Data([0x0E, sessionID])
    }
}

struct ATVVCapabilities: Equatable {
    let version: UInt16
    let codecs: UInt8
    let interaction: UInt8
    let frameSize: Int
    let selectedCodec: UInt8
    let sampleRate: Double

    static func parse(_ data: Data, allowingLegacyLayout: Bool = true) -> ATVVCapabilities? {
        let bytes = Array(data)
        guard bytes.count >= 7, bytes[0] == 0x0B else { return nil }

        let version = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        var codecs: UInt8
        var interaction: UInt8

        if version >= 0x0100 {
            codecs = bytes[3]
            interaction = bytes[4]
            if allowingLegacyLayout, codecs == 0, bytes.count >= 9, bytes[4] & 0x03 != 0 {
                codecs = bytes[4]
                interaction = 0x03
            }
        } else {
            guard bytes.count >= 9 else { return nil }
            codecs = bytes[4]
            interaction = 0
        }

        let frameSize = Int(bytes[5]) << 8 | Int(bytes[6])
        let selectedCodec: UInt8 = codecs & 0x02 != 0 ? 0x02 : 0x01
        return ATVVCapabilities(
            version: version,
            codecs: codecs,
            interaction: interaction,
            frameSize: frameSize == 0 ? 120 : frameSize,
            selectedCodec: selectedCodec,
            sampleRate: selectedCodec == 0x02 ? 16_000 : 8_000
        )
    }
}

final class IMAADPCMDecoder {
    private static let stepTable = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
        1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8]

    private(set) var predictor = 0
    private(set) var stepIndex = 0

    // RC001/RC003 (firmware 2671) encode high-nibble-first; ARN9 firmware
    // encodes low-nibble-first. Default stays high-first; the bridge flips
    // this once the 2A24 model number identifies an ARN9 remote.
    var lowNibbleFirst = false

    func reset(predictor: Int = 0, stepIndex: Int = 0) {
        self.predictor = min(32_767, max(-32_768, predictor))
        self.stepIndex = min(88, max(0, stepIndex))
    }

    func decode(_ data: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count * 2)
        for byte in data {
            if lowNibbleFirst {
                samples.append(decodeNibble(Int(byte & 0x0F)))
                samples.append(decodeNibble(Int(byte >> 4)))
            } else {
                samples.append(decodeNibble(Int(byte >> 4)))
                samples.append(decodeNibble(Int(byte & 0x0F)))
            }
        }
        return samples
    }

    private func decodeNibble(_ nibble: Int) -> Int16 {
        let step = Self.stepTable[stepIndex]
        var difference = step >> 3
        if nibble & 1 != 0 { difference += step >> 2 }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 4 != 0 { difference += step }

        predictor += nibble & 8 != 0 ? -difference : difference
        predictor = min(32_767, max(-32_768, predictor))
        stepIndex += Self.indexTable[nibble & 7]
        stepIndex = min(88, max(0, stepIndex))
        return Int16(predictor)
    }
}

final class PCMPostprocessor {
    private var previous: Int?
    private var preceding: Int?

    func reset() {
        previous = nil
        preceding = nil
    }

    // Causal binomial FIR, with one-sample delay. History crosses BLE frame boundaries.
    func process(_ input: [Int16], gainDB: Double) -> [Int16] {
        let finiteGainDB = gainDB.isFinite ? gainDB : 0
        let gain = pow(10.0, min(24.0, max(-24.0, finiteGainDB)) / 20.0)
        return input.map { sample in
            let value = Int(sample)
            let last = previous ?? value
            let beforeLast = preceding ?? last
            let filtered = (beforeLast + 2 * last + value) >> 2
            preceding = last
            previous = value
            let scaled = Int((Double(filtered) * gain).rounded())
            return Int16(min(32_767, max(-32_768, scaled)))
        }
    }
}

/// A control sync arriving during a partial frame takes effect at the next boundary.
final class ATVVAudioDecoder {
    func configureFormat(lowNibbleFirst: Bool) {
        decoder.lowNibbleFirst = lowNibbleFirst
    }

    func resetPeripheral() {
        reset()
        configureFormat(lowNibbleFirst: false)
    }

    private(set) var isStreaming = false

    @discardableResult
    func beginStream() -> Bool {
        guard !isStreaming else { return false }
        reset()
        isStreaming = true
        return true
    }

    let decoder = IMAADPCMDecoder()
    private var accumulator = FrameAccumulator()
    private let postprocessor = PCMPostprocessor()
    private var pendingSync: (predictor: Int, stepIndex: Int)?
    private var framesBeforeSync = 0
    var pendingByteCount: Int { accumulator.pending.count }

    func synchronize(predictor: Int, stepIndex: Int) {
        pendingSync = (predictor, stepIndex)
        framesBeforeSync = accumulator.pending.isEmpty ? 0 : 1
    }

    func reset() {
        isStreaming = false
        accumulator.reset()
        pendingSync = nil
        framesBeforeSync = 0
        decoder.reset()
        postprocessor.reset()
    }

    func append(_ data: Data, frameSize: Int, gainDB: Double) -> [[Int16]] {
        accumulator.append(data, frameSize: frameSize).map { frame in
            if let sync = pendingSync, framesBeforeSync == 0 {
                decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex)
                pendingSync = nil
            }
            if framesBeforeSync > 0 { framesBeforeSync -= 1 }
            return postprocessor.process(decoder.decode(frame), gainDB: gainDB)
        }
    }
}

struct FrameAccumulator {
    private(set) var pending = Data()

    mutating func append(_ data: Data, frameSize: Int) -> [Data] {
        guard ATVVProtocol.supportsFrameSize(frameSize) else { return [] }
        pending.append(data)
        guard pending.count >= frameSize else { return [] }
        var frames: [Data] = []
        var offset = pending.startIndex
        while pending.endIndex - offset >= frameSize {
            let end = offset + frameSize
            frames.append(pending.subdata(in: offset..<end))
            offset = end
        }
        // Copy only after consuming frames, rebasing the remainder without an
        // intermediate Array or retaining the consumed batch's storage.
        pending = offset == pending.endIndex ? Data() : pending.subdata(in: offset..<pending.endIndex)
        return frames
    }

    mutating func reset() {
        pending = Data()
    }
}
