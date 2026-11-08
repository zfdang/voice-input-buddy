import CoreAudio
import Foundation

struct VirtualAudioDeviceLevelObservation: Equatable {
    var mute: Bool?
    var volume: Float32?

    var requiresAudibilityRepair: Bool {
        VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: mute) ||
            VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: volume)
    }
}

struct VirtualAudioDeviceAudibilitySnapshot: Equatable {
    var output = VirtualAudioDeviceLevelObservation()
    var input = VirtualAudioDeviceLevelObservation()

    var requiresAudibilityRepair: Bool {
        output.requiresAudibilityRepair || input.requiresAudibilityRepair
    }

    var hasObservation: Bool {
        output.mute != nil || output.volume != nil || input.mute != nil || input.volume != nil
    }

    var diagnostic: String {
        "output_mute=\(Self.optionalBoolean(output.mute)) " +
            "output_volume_scalar=\(Self.optionalScalar(output.volume)) " +
            "output_volume_low=\(Self.optionalBoolean(output.volume.map { VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: $0) })) " +
            "input_mute=\(Self.optionalBoolean(input.mute)) " +
            "input_volume_scalar=\(Self.optionalScalar(input.volume)) " +
            "input_volume_low=\(Self.optionalBoolean(input.volume.map { VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: $0) })) " +
            "minimum_volume_scalar=\(VirtualAudioDeviceLevelPolicy.minimumUsableVolume)"
    }

    private static func optionalBoolean(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private static func optionalScalar(_ value: Float32?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        let rounded = (Double(value) * 1_000).rounded() / 1_000
        return String(rounded)
    }
}

struct VirtualAudioDeviceAudibilityRepairResult: Equatable {
    var applicable = false
    var before = VirtualAudioDeviceAudibilitySnapshot()
    var after = VirtualAudioDeviceAudibilitySnapshot()
    var unmuteAttempted = false
    var volumeRestoreAttempted = false
    var writeFailed = false

    var isReady: Bool {
        !applicable || (
            !after.requiresAudibilityRepair &&
                (!before.requiresAudibilityRepair || after.hasObservation)
        )
    }
}

enum VirtualAudioDeviceLevelPolicy {
    static let minimumUsableVolume: Float32 = 0.2

    static func requiresUnmute(mute: Bool?) -> Bool {
        mute == true
    }

    static func requiresVolumeRestore(volume: Float32?) -> Bool {
        guard let volume, volume.isFinite else { return false }
        return volume < minimumUsableVolume
    }
}

extension VirtualAudioDeviceDiagnosticKind {
    static func classify(_ device: AudioDeviceInfo?) -> Self {
        guard let device else { return .unavailable }
        if device.uid == BuddyMicrophoneDevicePolicy.deviceUID {
            return .buddyMic
        }
        if device.uid == "BlackHole2ch_UID" {
            return .blackHole2ch
        }
        return .other
    }
}

extension VirtualAudioOutputDiagnosticSnapshot {
    var configurationHealthy: Bool {
        VirtualAudioHealthPolicy.isConfigurationHealthy(
            hasSelectedDevice: selectedDeviceKind != .unavailable,
            engineRunning: engineRunning,
            playerPlaying: playerPlaying,
            boundToSelectedDevice: boundToSelectedDevice == true
        )
    }
}

