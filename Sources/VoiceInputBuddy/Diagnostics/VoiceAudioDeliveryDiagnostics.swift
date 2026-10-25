import Darwin
import Foundation

enum VirtualAudioDeviceDiagnosticKind: String, Equatable {
    case buddyMic = "buddy_mic"
    case blackHole2ch = "blackhole_2ch"
    case other
    case unavailable
}

struct VirtualAudioPlaybackCounters: Equatable {
    var scheduledBuffers = 0
    var scheduledSamples = 0
    var playedBuffers = 0
    var playedSamples = 0
    var interruptedBuffers = 0
    var interruptedSamples = 0
}

struct VirtualAudioOutputDiagnosticSnapshot: Equatable {
    var selectedDeviceKind: VirtualAudioDeviceDiagnosticKind = .unavailable
    var actualDeviceKind: VirtualAudioDeviceDiagnosticKind = .unavailable
    var engineRunning = false
    var playerPlaying = false
    var boundToSelectedDevice: Bool?
    var audibilityHealthy = true
    var pendingBuffers = 0
    var pendingSamples = 0
    var counters = VirtualAudioPlaybackCounters()
}

enum VoiceAudioDeliveryRoute: String, Equatable {
    case none
    case virtualAudioDirect = "virtual_audio_direct"
    case virtualAudioViaFnTap = "virtual_audio_via_fn_tap"
}

enum VoiceAudioDeliveryResult: String, Equatable {
    case unavailable
    case receiving
    case noSamples = "no_samples"
    case outputNotReady = "output_not_ready"
    case routeMismatch = "route_mismatch"
    case enqueueFailed = "enqueue_failed"
    case playbackInterrupted = "playback_interrupted"
    case playbackPending = "playback_pending"
    case playbackIncomplete = "playback_incomplete"
    case deliveredToSelectedDevice = "delivered_to_selected_device"

    var isConfirmedFailure: Bool {
        switch self {
        case .enqueueFailed, .playbackInterrupted:
            return true
        case .unavailable, .receiving, .noSamples, .outputNotReady, .routeMismatch, .playbackPending,
             .playbackIncomplete, .deliveredToSelectedDevice:
            return false
        }
    }
}

struct VoiceAudioDeliveryDiagnostic: Equatable {
    var generation = 0
    var source = "none"
    var route: VoiceAudioDeliveryRoute = .none
    var sessionEnded = false
    var receivedBatches = 0
    var receivedSamples = 0
    var enqueueFailures = 0
    var outputAtStart = VirtualAudioOutputDiagnosticSnapshot()
    var outputAtObservation = VirtualAudioOutputDiagnosticSnapshot()
    var countersAtStart = VirtualAudioPlaybackCounters()

    var scheduledBuffers: Int {
        max(0, outputAtObservation.counters.scheduledBuffers - countersAtStart.scheduledBuffers)
    }

    var scheduledSamples: Int {
        max(0, outputAtObservation.counters.scheduledSamples - countersAtStart.scheduledSamples)
    }

    var playedBuffers: Int {
        max(0, outputAtObservation.counters.playedBuffers - countersAtStart.playedBuffers)
    }

    var playedSamples: Int {
        max(0, outputAtObservation.counters.playedSamples - countersAtStart.playedSamples)
    }

    var interruptedBuffers: Int {
        max(0, outputAtObservation.counters.interruptedBuffers - countersAtStart.interruptedBuffers)
    }

    var interruptedSamples: Int {
        max(0, outputAtObservation.counters.interruptedSamples - countersAtStart.interruptedSamples)
    }

    var result: VoiceAudioDeliveryResult {
        VoiceAudioDeliveryPolicy.result(for: self)
    }

    mutating func observeOutput(_ snapshot: VirtualAudioOutputDiagnosticSnapshot) {
        // A fully delivered, ended session is historical evidence. Normal idle
        // teardown must not replace its verified route with an absent engine.
        guard result != .deliveredToSelectedDevice else { return }
        outputAtObservation = snapshot
    }
}

enum VoiceAudioDeliveryPolicy {
    static func result(for diagnostic: VoiceAudioDeliveryDiagnostic) -> VoiceAudioDeliveryResult {
        guard diagnostic.generation > 0 else { return .unavailable }
        guard diagnostic.receivedSamples > 0 else {
            return diagnostic.sessionEnded ? .noSamples : .receiving
        }
        guard diagnostic.enqueueFailures == 0 else { return .enqueueFailed }
        guard diagnostic.interruptedSamples == 0 else { return .playbackInterrupted }
        // Voice activation can precede asynchronous output configuration. The start
        // snapshot is historical evidence, not a permanent failure verdict.
        guard diagnostic.outputAtObservation.selectedDeviceKind != .unavailable,
              diagnostic.outputAtObservation.engineRunning,
              diagnostic.outputAtObservation.playerPlaying
        else { return .outputNotReady }
        guard diagnostic.outputAtObservation.boundToSelectedDevice == true else { return .routeMismatch }
        guard diagnostic.sessionEnded else { return .receiving }
        guard diagnostic.scheduledSamples >= diagnostic.receivedSamples else {
            return .playbackIncomplete
        }
        guard diagnostic.outputAtObservation.pendingSamples == 0 else { return .playbackPending }
        guard diagnostic.playedSamples >= diagnostic.receivedSamples else {
            return .playbackIncomplete
        }
        return .deliveredToSelectedDevice
    }
}

