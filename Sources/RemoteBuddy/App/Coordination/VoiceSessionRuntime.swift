import Foundation

/// Main-queue voice state. Ending an owner also discards audio waiting for it.
@MainActor
final class VoiceSessionRuntime {
    var commandAudio = CommandVoiceActivationAudioBuffer()
    var voiceSessionID: UUID?
    var voiceAudioDeliveryGeneration = 0
    var voiceAudioDeliveryDiagnostic = VoiceAudioDeliveryDiagnostic()
    var isActive = false
    var loggedBluetoothVoiceAudioDeviceIdentifier: UUID?
    let pendingStart = BluetoothPendingAudioStart()
    var stopRequested = false
    var activeDeviceIdentifier: UUID?
    var bluetoothVoiceTraceCounter: UInt64 = 0
    var activeBluetoothVoiceTraceID: UInt64?
    var bluetoothVoiceTraceStartedAt: Date?
    var bluetoothVoiceTraceModel: RemoteModel = .unknown
    var bluetoothVoiceDecodedBatchCount = 0
    var bluetoothVoiceDecodedSampleCount = 0
    var bluetoothVoiceEnqueueFailureCount = 0
    var bluetoothVoiceTraceRoute = "none"
    var bluetoothVoiceTailDiagnostics = BluetoothVoiceTailDiagnostics()

    func begin(deviceIdentifier: UUID) {
        commandAudio.cancel()
        activeDeviceIdentifier = deviceIdentifier
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        isActive = true
    }

    func end() {
        activeDeviceIdentifier = nil
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        isActive = false
        pendingStart.cancel()
        stopRequested = false
        commandAudio.cancel()
    }
}
