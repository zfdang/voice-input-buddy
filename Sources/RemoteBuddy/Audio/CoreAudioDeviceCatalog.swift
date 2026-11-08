import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}


enum CoreAudioDeviceCatalog {
    private static let propertyLock = NSRecursiveLock()

    private static let virtualAudioScopes: [AudioObjectPropertyScope] = [
        kAudioDevicePropertyScopeOutput,
        kAudioDevicePropertyScopeInput,
    ]

    static func outputDevices() -> [AudioDeviceInfo] {
        withPropertyLock {
            devicesLocked(scope: kAudioDevicePropertyScopeOutput)
        }
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        withPropertyLock {
            devicesLocked(scope: kAudioDevicePropertyScopeInput)
        }
    }

    private static func devicesLocked(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        let result = deviceIDs.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(-1) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard result == noErr else { return [] }

        var seenUIDs = Set<String>()
        return deviceIDs.compactMap { deviceID in
            guard channelCount(for: deviceID, scope: scope) > 0 else { return nil }
            return deviceInfo(for: deviceID)
        }
        .filter(shouldPresentToUser)
        .filter { seenUIDs.insert($0.uid).inserted }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// AVAudioEngine can publish a process-private aggregate while an engine is
    /// alive. It is a routing implementation detail, not a user-selectable
    /// device. Keep it out of settings and onboarding lists.
    static func shouldPresentToUser(_ device: AudioDeviceInfo) -> Bool {
        !device.uid.hasPrefix("CADefaultDeviceAggregate-")
    }

    static func deviceInfo(for deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        withPropertyLock {
            guard deviceID != kAudioObjectUnknown,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name)
        }
    }

    static func routeDiagnostic() -> String {
        withPropertyLock {
            let input = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
            let output = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
            let systemOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            return "default_input={\(deviceDiagnostic(input))} " +
                "default_output={\(deviceDiagnostic(output))} " +
                "default_system_output={\(deviceDiagnostic(systemOutput))}"
        }
    }

    static func outputDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        devices.map(deviceDiagnostic).joined(separator: " | ")
    }

    static func deviceDiagnostic(_ device: AudioDeviceInfo?) -> String {
        guard let device else { return "none" }
        return "name=\(device.name) id=\(device.id)"
    }

    static func virtualAudioAudibilitySnapshot(
        for device: AudioDeviceInfo?
    ) -> VirtualAudioDeviceAudibilitySnapshot {
        guard let device else { return .init() }
        let kind = VirtualAudioDeviceDiagnosticKind.classify(device)
        guard kind == .buddyMic || kind == .blackHole2ch else { return .init() }
        return withPropertyLock {
            virtualAudioAudibilitySnapshotLocked(for: device.id)
        }
    }

    static func ensureVirtualAudioDeviceAudible(
        _ device: AudioDeviceInfo
    ) -> VirtualAudioDeviceAudibilityRepairResult {
        let kind = VirtualAudioDeviceDiagnosticKind.classify(device)
        guard kind == .buddyMic else {
            return .init()
        }

        return withPropertyLock {
            VirtualAudioAudibilityRepair.run(
                read: { virtualAudioAudibilitySnapshotLocked(for: device.id) },
                writeMute: { scope, value in
                    setUInt32PropertyLocked(device.id, selector: kAudioDevicePropertyMute,
                                            scope: scope, value: value)
                },
                writeVolume: { scope, value in
                    setFloat32PropertyLocked(device.id, selector: kAudioDevicePropertyVolumeScalar,
                                             scope: scope, value: value)
                }
            )
        }
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return nil }
        return deviceInfo(for: deviceID)
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        // HAL transfers ownership of CFString properties to the caller.
        return value?.takeRetainedValue() as String?
    }

    private static func virtualAudioAudibilitySnapshotLocked(
        for deviceID: AudioDeviceID
    ) -> VirtualAudioDeviceAudibilitySnapshot {
        VirtualAudioDeviceAudibilitySnapshot(
            output: deviceLevelObservationLocked(
                for: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            ),
            input: deviceLevelObservationLocked(
                for: deviceID,
                scope: kAudioDevicePropertyScopeInput
            )
        )
    }

    private static func deviceLevelObservationLocked(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> VirtualAudioDeviceLevelObservation {
        VirtualAudioDeviceLevelObservation(
            mute: uint32PropertyLocked(
                deviceID,
                selector: kAudioDevicePropertyMute,
                scope: scope
            ).map { $0 != 0 },
            volume: float32PropertyLocked(
                deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: scope
            )
        )
    }

    private static func uint32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func float32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private static func setUInt32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(objectID, &address),
              AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        return CoreAudioDevicePropertyWriter.write(value, to: objectID, address: &address)
    }

    private static func setFloat32PropertyLocked(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: Float32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(objectID, &address),
              AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr,
              settable.boolValue
        else { return false }
        return CoreAudioDevicePropertyWriter.write(value, to: objectID, address: &address)
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        let allocatedSize = size
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        return channelCount(in: list, byteCount: Int(size), allocatedByteCount: Int(allocatedSize))
    }

    static func channelCount(in list: UnsafeMutablePointer<AudioBufferList>, byteCount: Int,
                             allocatedByteCount: Int) -> Int {
        guard byteCount <= allocatedByteCount, byteCount >= MemoryLayout<AudioBufferList>.size,
              let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers),
              Int(list.pointee.mNumberBuffers) <= (byteCount - bufferOffset) / MemoryLayout<AudioBuffer>.stride
        else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func withPropertyLock<T>(_ operation: () -> T) -> T {
        propertyLock.lock()
        defer { propertyLock.unlock() }
        return operation()
    }
}


struct AudioHardwareChangeProperties {
    let selectors: Set<String>
    init(details: String) {
        guard details.hasPrefix("properties=") else { selectors = []; return }
        selectors = Set(details.dropFirst("properties=".count).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    var affectsOnlyDefaultInput: Bool { selectors == ["default_input"] }
}
