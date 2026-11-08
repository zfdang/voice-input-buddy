import CoreAudio

/// Device audibility writes cannot change the system's default audio routes.
enum CoreAudioDevicePropertyWriter {
    typealias Writer = (AudioObjectID, UnsafePointer<AudioObjectPropertyAddress>, UInt32,
                       UnsafeRawPointer?, UInt32, UnsafeRawPointer) -> OSStatus

    static func write<Value>(_ value: Value, to objectID: AudioObjectID,
                             address: inout AudioObjectPropertyAddress,
                             writer: Writer = { AudioObjectSetPropertyData($0, $1, $2, $3, $4, $5) }) -> Bool {
        guard objectID != AudioObjectID(kAudioObjectSystemObject),
              objectID != AudioObjectID(kAudioObjectUnknown),
              [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar].contains(address.mSelector)
        else { return false }
        var mutableValue = value
        return withUnsafePointer(to: &mutableValue) {
            writer(objectID, &address, 0, nil, UInt32(MemoryLayout<Value>.size), $0) == noErr
        }
    }
}
