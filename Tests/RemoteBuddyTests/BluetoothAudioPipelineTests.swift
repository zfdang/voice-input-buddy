import Foundation
import Testing
@testable import RemoteBuddy

private final class AudioDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { actions.append(action) } }
    @MainActor func run() {
        let pending = lock.withLock { let result = actions; actions.removeAll(); return result }
        pending.forEach { $0() }
    }
}

@Suite("Background Bluetooth audio ordering") @MainActor
struct BluetoothAudioPipelineTests {
    @Test func queuedStartAndStopKeepConfigurationBusyUntilDelivery() throws {
        let queue = DispatchQueue(label: "test.audio.busy")
        let deliveries = AudioDeliveries()
        let pipeline = BluetoothAudioPipeline(queue: queue, deliver: { deliveries.enqueue($0) })
        let name = "pending-audio-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        let bridge = BluetoothRemoteBridge(settings: model.settings, delegate: model, audioPipeline: pipeline)
        model.connections.bridges[UUID()] = bridge
        #expect(!model.isVoiceConfigurationBusy)
        #expect(pipeline.beginStream {})
        pipeline.endStream {}
        queue.sync {}
        #expect(!pipeline.isStreaming)
        #expect(model.isVoiceConfigurationBusy)
        #expect(model.hasActiveVirtualAudioSource)
        #expect(!model.canAcceptNewVoiceSession(from: .chromecast))
        #expect(model.canAcceptNewVoiceSession(from: .bluetooth))
        #expect(model.shouldKeepVirtualAudioActive)
        deliveries.run()
        #expect(!pipeline.hasPendingVoiceWork)
        #expect(!model.isVoiceConfigurationBusy)
        #expect(pipeline.beginStream { Issue.record("Cancelled start delivered") })
        pipeline.endStream { Issue.record("Cancelled stop delivered") }
        queue.sync {}
        pipeline.reset()
        #expect(!model.isVoiceConfigurationBusy)
        deliveries.run()
        #expect(!pipeline.hasPendingVoiceWork)
    }

    @Test func normalStopDrainsPriorFramesBeforeNextStart() {
        let queue = DispatchQueue(label: "test.audio.order")
        let deliveries = AudioDeliveries()
        let pipeline = BluetoothAudioPipeline(queue: queue, deliver: { deliveries.enqueue($0) })
        var events: [String] = []
        var audio: [[Int16]] = []
        let bytes = Data(repeating: 0x37, count: 120)
        for _ in 0..<2 {
            #expect(pipeline.beginStream { events.append("start") })
            #expect(!pipeline.beginStream { Issue.record("Duplicate start") })
            #expect(pipeline.append(bytes, frameSize: 120, gainDB: 0) { samples in
                events.append("audio"); audio.append(samples)
            })
            pipeline.endStream { events.append("stop") }
        }
        queue.sync {} // only worker computation completes; main delivery remains queued
        #expect(events.isEmpty)
        deliveries.run()
        #expect(events == ["start", "audio", "stop", "start", "audio", "stop"])
        let reference = ATVVAudioDecoder().append(bytes, frameSize: 120, gainDB: 0)
        #expect(audio == reference + reference)
    }

    @Test func connectionResetRejectsAlreadyComputedOldResultsAndResetsFormat() {
        let queue = DispatchQueue(label: "test.audio.cancel")
        let deliveries = AudioDeliveries()
        let pipeline = BluetoothAudioPipeline(queue: queue, deliver: { deliveries.enqueue($0) })
        let bytes = Data([0x12, 0x34, 0x56])
        pipeline.configureFormat(lowNibbleFirst: true)
        #expect(pipeline.beginStream { Issue.record("Old start delivered") })
        #expect(pipeline.append(bytes, frameSize: 3, gainDB: 0) { _ in Issue.record("Old audio delivered") })
        queue.sync {}
        pipeline.reset(peripheral: true)
        var results: [[Int16]] = []
        #expect(pipeline.beginStream {})
        #expect(pipeline.append(bytes, frameSize: 3, gainDB: 0) { results.append($0) })
        queue.sync {}
        deliveries.run()
        #expect(results == ATVVAudioDecoder().append(bytes, frameSize: 3, gainDB: 0))
    }

    @Test func backlogIncludesResultsAwaitingMainDeliveryAndResetReclaimsBudget() {
        let queue = DispatchQueue(label: "test.audio.bound")
        let deliveries = AudioDeliveries()
        let pipeline = BluetoothAudioPipeline(queue: queue, maximumPendingBytes: 120, deliver: { deliveries.enqueue($0) })
        let bytes = Data(repeating: 0x11, count: 120)
        #expect(pipeline.beginStream {})
        #expect(pipeline.append(bytes, frameSize: 120, gainDB: 0) { _ in })
        queue.sync {}
        #expect(!pipeline.append(bytes, frameSize: 120, gainDB: 0) { _ in })
        deliveries.run()
        #expect(pipeline.append(bytes, frameSize: 120, gainDB: 0) { _ in })
        pipeline.reset()
        #expect(pipeline.beginStream {})
        #expect(pipeline.append(bytes, frameSize: 120, gainDB: 0) { _ in })
        queue.sync {}
        deliveries.run()
    }

    @Test func endStreamFlushesResidualPartialFrame() {
        let queue = DispatchQueue(label: "test.audio.tail")
        let deliveries = AudioDeliveries()
        let pipeline = BluetoothAudioPipeline(queue: queue, deliver: { deliveries.enqueue($0) })
        var decodedSamples: [[Int16]] = []
        var stopped = false
        // Send 50 bytes (less than 120 bytes frameSize)
        let bytes = Data(repeating: 0x55, count: 50)
        #expect(pipeline.beginStream {})
        #expect(pipeline.append(bytes, frameSize: 120, gainDB: 0) { decodedSamples.append($0) })
        queue.sync {}
        #expect(pipeline.pendingByteCount == 50)
        pipeline.endStream(frameSize: 120, gainDB: 0, onDecoded: { samples in
            decodedSamples.append(samples)
        }, onStop: {
            stopped = true
        })
        queue.sync {}
        deliveries.run()
        #expect(stopped)
        #expect(decodedSamples.count == 1)
        #expect(decodedSamples.first?.count == 100) // 50 bytes decoded without zero-padding distortion
        #expect(pipeline.pendingByteCount == 0)

        // Second endStream invocation is a no-op and does not decode residual audio again
        var secondStop = false
        pipeline.endStream(frameSize: 120, gainDB: 0, onDecoded: { _ in
            #expect(Bool(false), "Second endStream should not yield decoded samples")
        }, onStop: {
            secondStop = true
        })
        queue.sync {}
        deliveries.run()
        #expect(!secondStop)
    }

    @Test func tailFramePartialDecodingProducesBoundedNonSaturatingSamples() {
        let queue = DispatchQueue(label: "test.audio.tail.saturation")
        let deliveries = AudioDeliveries()
        let pipeline = BluetoothAudioPipeline(queue: queue, deliver: { deliveries.enqueue($0) })
        var decodedSamples: [[Int16]] = []

        // Feed arbitrary partial frame with extreme nibbles
        let pattern = Data([0xFF, 0x00, 0xAA, 0x55, 0x77, 0x88, 0x11, 0xEE, 0x44, 0x99])
        #expect(pipeline.beginStream {})
        #expect(pipeline.append(pattern, frameSize: 120, gainDB: 12) { decodedSamples.append($0) })
        queue.sync {}
        #expect(pipeline.pendingByteCount == pattern.count)

        pipeline.endStream(frameSize: 120, gainDB: 12, onDecoded: { samples in
            decodedSamples.append(samples)
        }, onStop: {})
        queue.sync {}
        deliveries.run()

        #expect(decodedSamples.count == 1)
        guard let samples = decodedSamples.first else {
            Issue.record("Expected tail samples")
            return
        }
        #expect(samples.count == pattern.count * 2)
        let reference = ATVVAudioDecoder().append(pattern, frameSize: pattern.count, gainDB: 12).flatMap { $0 }
        #expect(samples == reference)
        let peak = samples.map { abs(Int32($0)) }.max() ?? 0
        #expect(peak > 0)
        #expect(peak < Int32(Int16.max))
    }
}
