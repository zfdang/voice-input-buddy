import Foundation

enum BuddyMicrophoneDevicePolicy {
    static let deviceUID = "BuddyMic2ch_UID"
    static let deviceName = "Remote Buddy Mic"

    static func device(in devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        // A display name can be shared by unrelated devices; only the driver UID proves identity.
        devices.first { $0.uid == deviceUID }
    }

    static func status(in devices: [AudioDeviceInfo]) -> LocalizedMessage {
        if let device = device(in: devices) {
            return LocalizedMessage("audio.compatibility.device_detected", arguments: [device.name])
        }
        return LocalizedMessage("audio.compatibility.device_not_detected", arguments: [deviceName])
    }
}
