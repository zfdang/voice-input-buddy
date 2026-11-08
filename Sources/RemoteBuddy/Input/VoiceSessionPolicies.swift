import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

/// Identifies the live control/voice source, without collecting usage statistics.
enum RemoteInputSource: String, Codable, CaseIterable, Hashable {
    case bluetoothRemote = "bluetooth_remote"
    case unknown
}

struct MobileRemoteButtonObservation: Equatable {
    let source: RemoteInputSource
    let button: RemoteButton
}

enum BluetoothVoiceStopPolicy {
    /// Remote stop ends capture but must not discard PCM already scheduled for playback.
    static func shouldFlushAudio(handledByFnTapMode _: Bool) -> Bool {
        false
    }
}

enum VoiceKeyPendingDownPolicy {
    static func shouldRejectStart(
        streaming: Bool,
        pendingDown: Bool
    ) -> Bool {
        streaming && pendingDown
    }
}

enum VoiceKeySessionPreservationPolicy {
    static func shouldPreserveInputSourceSession(
        latchHeld: Bool,
        heldMode: VoiceKeyMode?,
        pendingMode: VoiceKeyMode?
    ) -> Bool {
        (latchHeld && heldMode != nil) || pendingMode != nil
    }
}

enum OrderedVoiceActivationPolicy {
    static func needsSoftwareFn(mode: VoiceKeyMode, fnTapEnabled: Bool,
                               preferredInputSourceID: String?) -> Bool {
        mode == .function && !fnTapEnabled && preferredInputSourceID != nil
    }
}

/// Events without a Bluetooth identity cannot own a voice session.
enum BluetoothVoiceDeviceOwnershipPolicy {
    static func matches(_ identifier: UUID?, active: UUID?) -> Bool {
        guard let identifier else { return false }
        return identifier == active
    }
}
