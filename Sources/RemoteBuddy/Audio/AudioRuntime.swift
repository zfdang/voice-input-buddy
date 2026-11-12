import CoreAudio
import Foundation

/// Owns audio resources and asynchronous recovery lifetimes. State is main-queue
/// confined; engine work and HAL notifications keep their dedicated queues.
@MainActor
final class AudioRuntime {
    typealias AudioHardwareListenerRemover = (
        inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    let output = VirtualAudioOutput()
    let preparationQueue = DispatchQueue(label: "RemoteBuddy.audioPreparation", qos: .userInitiated)
    var configurationGeneration: UInt64 = 0
    var startupGeneration: UInt64 = 0
    var deviceRefreshGeneration: UInt64 = 0
    var startupPending = false
    var testToneStartupPending = false
    var hardwareListenerRemover: AudioHardwareListenerRemover = { address, queue, listener in
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }
    var devicePropertyListenerRemover: (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus = { objectID, address, queue, listener in
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
    }
    let hardwareListenerQueue = DispatchQueue(label: "RemoteBuddy.audioHardware")
    var observedHardwareAddresses: [AudioObjectPropertyAddress] = []
    var observedDeviceProperties: [(objectID: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    var recoveryWorkItem: DispatchWorkItem?
    var recoveryGeneration: UInt64 = 0
    var recoveryCoalescingState = AudioRecoveryCoalescingState()
    var virtualAudioReleaseGeneration: UInt64 = 0
    var pendingVirtualAudioRelease: (generation: UInt64, reason: String)?
    var suspensionState = SystemAudioSuspensionState()

    private(set) var registeredListener: AudioObjectPropertyListenerBlock?

    func retainHardwareListener(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        registeredListener = listener
    }

    func stopObservingHardware() {
        guard let listener = registeredListener else { return }
        for var address in observedHardwareAddresses {
            _ = hardwareListenerRemover(&address, hardwareListenerQueue, listener)
        }
        observedHardwareAddresses.removeAll()
        stopObservingVirtualDevice()
        registeredListener = nil
    }

    func stopObservingVirtualDevice() {
        guard let listener = registeredListener else {
            observedDeviceProperties.removeAll()
            return
        }
        for (objectID, var address) in observedDeviceProperties {
            _ = devicePropertyListenerRemover(objectID, &address, hardwareListenerQueue, listener)
        }
        observedDeviceProperties.removeAll()
    }

    func invalidatePendingWork() {
        startupGeneration &+= 1
        deviceRefreshGeneration &+= 1
        configurationGeneration &+= 1
        startupPending = false
        testToneStartupPending = false
        recoveryGeneration &+= 1
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        recoveryCoalescingState.reset()
        virtualAudioReleaseGeneration &+= 1
        pendingVirtualAudioRelease = nil
        suspensionState = SystemAudioSuspensionState()
    }

    isolated deinit {
        invalidatePendingWork()
        stopObservingHardware()
    }
}
