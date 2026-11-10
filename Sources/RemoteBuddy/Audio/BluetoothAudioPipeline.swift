import Foundation

/// Decoder mutation belongs exclusively to queue. The lock protects admission,
/// connection generation and diagnostic snapshots; it never spans decoding or a
/// callback. Normal stop preserves preceding audio and event order; reset cancels
/// all work from the old connection. No CoreBluetooth or settings objects cross.
final class BluetoothAudioPipeline: @unchecked Sendable {
    typealias Delivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let queue: DispatchQueue
    private let deliver: Delivery
    private let decoder = ATVVAudioDecoder()
    private let lock = NSLock()
    private let maximumPendingBytes: Int
    private var generation: UInt64 = 0
    private var active = false
    private var pendingBytes = 0
    private var pendingStreamEvents = 0
    private var fragmentBytes = 0

    init(queue: DispatchQueue = DispatchQueue(label: "RemoteBuddy.bluetoothAudio", qos: .userInitiated),
         maximumPendingBytes: Int = 4_000,
         deliver: @escaping Delivery = { action in DispatchQueue.main.async { action() } }) {
        self.queue = queue
        self.maximumPendingBytes = maximumPendingBytes
        self.deliver = deliver
    }

    var isStreaming: Bool { lock.withLock { active } }
    var hasPendingVoiceWork: Bool {
        lock.withLock { active || pendingBytes > 0 || pendingStreamEvents > 0 }
    }
    var pendingByteCount: Int { lock.withLock { fragmentBytes } }
    private func isCurrent(_ token: UInt64) -> Bool { lock.withLock { generation == token } }

    @discardableResult
    func beginStream(onStart: @escaping @MainActor @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !active else { lock.unlock(); return false }
        active = true
        pendingStreamEvents += 1
        let token = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(token) else { return }
            decoder.beginStream()
            deliver { [self] in
                guard finishStreamEvent(token) else { return }
                onStart()
            }
        }
        return true
    }

    func endStream(
        frameSize: Int = 120,
        gainDB: Double = 10,
        onDecoded: (@MainActor @Sendable ([Int16]) -> Void)? = nil,
        onStop: @escaping @MainActor @Sendable () -> Void
    ) {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        pendingStreamEvents += 1
        let token = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(token) else { return }
            let tailSamples = decoder.flush(frameSize: frameSize, gainDB: gainDB)
            decoder.reset()
            lock.withLock { if generation == token { fragmentBytes = 0 } }
            deliver { [self] in
                guard finishStreamEvent(token) else { return }
                if let tailSamples, let onDecoded {
                    onDecoded(tailSamples)
                }
                onStop()
            }
        }
    }

    private func finishStreamEvent(_ token: UInt64) -> Bool {
        lock.withLock {
            guard generation == token else { return false }
            pendingStreamEvents -= 1
            return true
        }
    }

    /// Connection cancellation discards pending audio, unlike an ordered stop.
    func reset(peripheral: Bool = false) {
        lock.withLock {
            generation &+= 1
            active = false
            pendingBytes = 0
            pendingStreamEvents = 0
            fragmentBytes = 0
        }
        queue.async { [self] in
            if peripheral { decoder.resetPeripheral() } else { decoder.reset() }
        }
    }

    func configureFormat(lowNibbleFirst: Bool) {
        queue.async { [self] in decoder.configureFormat(lowNibbleFirst: lowNibbleFirst) }
    }

    func synchronize(predictor: Int, stepIndex: Int) {
        let token = lock.withLock { generation }
        queue.async { [self] in
            guard isCurrent(token) else { return }
            decoder.synchronize(predictor: predictor, stepIndex: stepIndex)
        }
    }

    @discardableResult
    func append(_ data: Data, frameSize: Int, gainDB: Double,
                onDecoded: @escaping @MainActor @Sendable ([Int16]) -> Void) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        guard active, data.count <= maximumPendingBytes - pendingBytes else { lock.unlock(); return false }
        pendingBytes += data.count
        let token = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(token) else { return }
            let batches = decoder.append(data, frameSize: frameSize, gainDB: gainDB)
            lock.withLock { if generation == token { fragmentBytes = decoder.pendingByteCount } }
            deliver { [self] in
                guard isCurrent(token) else { return }
                lock.withLock { pendingBytes -= data.count }
                for samples in batches {
                    guard isCurrent(token) else { return }
                    onDecoded(samples)
                }
            }
        }
        return true
    }
}
