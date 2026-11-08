import CoreAudio

/// Repairs only observed mute/low-volume states and verifies the device afterward.
enum VirtualAudioAudibilityRepair {
    static func run(read: () -> VirtualAudioDeviceAudibilitySnapshot,
                    writeMute: (AudioObjectPropertyScope, UInt32) -> Bool,
                    writeVolume: (AudioObjectPropertyScope, Float32) -> Bool
    ) -> VirtualAudioDeviceAudibilityRepairResult {
        let before = read()
        var result = VirtualAudioDeviceAudibilityRepairResult(applicable: true, before: before, after: before)
        for (scope, observation) in [(kAudioDevicePropertyScopeOutput, before.output),
                                     (kAudioDevicePropertyScopeInput, before.input)] {
            if VirtualAudioDeviceLevelPolicy.requiresUnmute(mute: observation.mute) {
                result.unmuteAttempted = true
                if !writeMute(scope, 0) { result.writeFailed = true }
            }
            if VirtualAudioDeviceLevelPolicy.requiresVolumeRestore(volume: observation.volume) {
                result.volumeRestoreAttempted = true
                if !writeVolume(scope, 1) { result.writeFailed = true }
            }
        }
        result.after = read()
        return result
    }
}
