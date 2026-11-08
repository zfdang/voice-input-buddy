import Foundation

struct SystemAudioSuspensionState {
    private(set) var reasons = Set<SystemAudioSuspensionReason>()

    var isSuspended: Bool {
        !reasons.isEmpty
    }

    var diagnostic: String {
        let values = reasons.map(\.rawValue).sorted()
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }

    @discardableResult
    mutating func apply(_ event: SystemAudioLifecycleEvent) -> Bool {
        if event.isSuspending {
            return reasons.insert(event.suspensionReason).inserted
        }
        return reasons.remove(event.suspensionReason) != nil
    }
}

enum VirtualAudioConnectionLifecyclePolicy {
    static func shouldScheduleRelease(
        hasPendingRelease: Bool,
        hasAllocatedOutputResources: Bool,
        pendingVoiceBufferCount: Int
    ) -> Bool {
        !hasPendingRelease && (hasAllocatedOutputResources || pendingVoiceBufferCount > 0)
    }
}

/// Whether a debounced `AVAudioEngineConfigurationChange` still needs recovery.
///
/// Reconfiguring the engine emits the same notification as a real route failure. A correctly
/// bound but idle output can therefore create a self-sustaining rebind loop if the stopped engine
/// alone is treated as damage. Active delivery and queued tail audio are different: when either
/// exists, an unhealthy engine still has user audio to protect and must retain the existing
/// recovery behavior.
enum AudioEngineConfigurationChangePolicy {
    static func needsRecovery(
        boundToSelectedDevice: Bool?,
        configurationHealthy: Bool,
        hasActiveAudioSource: Bool,
        pendingVoiceBufferCount: Int
    ) -> Bool {
        guard boundToSelectedDevice == true else { return true }
        if configurationHealthy { return false }
        return hasActiveAudioSource || pendingVoiceBufferCount > 0
    }
}

enum VirtualAudioRecoveryPolicy {
    static func shouldIgnoreDefaultSystemOutputChange(
        details: String,
        configurationHealthy: Bool
    ) -> Bool {
        AudioHardwareChangeProperties(details: details).selectors == ["default_system_output"] && configurationHealthy
    }
}

enum VirtualAudioHealthPolicy {
    static func isPlaybackReady(
        hasSelectedDevice: Bool,
        engineRunning: Bool,
        playerPlaying: Bool
    ) -> Bool {
        hasSelectedDevice && engineRunning && playerPlaying
    }

    static func isConfigurationHealthy(
        hasSelectedDevice: Bool,
        engineRunning: Bool,
        playerPlaying: Bool,
        boundToSelectedDevice: Bool
    ) -> Bool {
        isPlaybackReady(
            hasSelectedDevice: hasSelectedDevice,
            engineRunning: engineRunning,
            playerPlaying: playerPlaying
        ) && boundToSelectedDevice
    }
}

