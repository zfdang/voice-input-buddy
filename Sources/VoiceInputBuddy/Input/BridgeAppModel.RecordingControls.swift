import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func toggleLongRecording() -> Bool {
        if longRecordingRequested {
            stopLongRecording(reason: "button_toggle")
            return true
        }
        guard isConnected,
              !voiceSession.isActive,
              longRecordingCloseTimer == nil,
              let bridge = selectedBluetoothBridge
        else {
            AppLogger.shared.write(
                "LONG RECORDING rejected connected=\(isConnected) audio_ready=\(isAudioOutputReady) " +
                    "bluetooth_voice=\(voiceSession.isActive)"
            )
            return false
        }
        longRecordingGeneration &+= 1
        let generation = longRecordingGeneration
        longRecordingBridge = bridge
        longRecordingRequested = true
        if !audio.output.isReadyForTestTone {
            ensureVirtualAudioOutputReady(reason: "long_recording_start") { [weak self] ready in
                guard let self, self.longRecordingRequested,
                      self.longRecordingGeneration == generation else { return }
                _ = self.startLongRecordingAfterAudioReady(ready, generation: generation)
            }
            return true
        }
        return startLongRecordingAfterAudioReady(true, generation: generation)
    }

    @discardableResult
    func startLongRecordingAfterAudioReady(_ ready: Bool, generation: UInt64) -> Bool {
        guard longRecordingRequested, longRecordingGeneration == generation else { return false }
        guard ready, isConnected, !voiceSession.isActive else {
            finishLongRecording(reason: "audio_not_ready")
            return false
        }
        guard let bridge = longRecordingBridge,
              bridge.requestMicrophoneOpen()
        else {
            finishLongRecording(reason: "open_rejected")
            return false
        }
        scheduleLongRecordingOpenTimeout(generation: generation)
        AppLogger.shared.write("LONG RECORDING opening generation=\(generation)")
        return true
    }

    private func scheduleLongRecordingOpenTimeout(generation: UInt64) {
        longRecordingOpenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingOpenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingRequested,
                  self.longRecordingGeneration == generation,
                  !self.voiceSession.isActive
            else { return }
            self.stopLongRecording(reason: "open_timeout")
        }
        longRecordingOpenTimer = timer
        timer.resume()
    }

    func stopLongRecording(reason: String) {
        guard longRecordingRequested else { return }
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        let bridge = longRecordingBridge
        let closeWritten = bridge?.requestMicrophoneClose() ?? false
        if voiceSession.isActive,
           BluetoothVoiceDeviceOwnershipPolicy.matches(bridge?.deviceIdentifier, active: voiceSession.activeDeviceIdentifier) {
            scheduleLongRecordingCloseTimeout(generation: longRecordingGeneration)
        } else {
            longRecordingBridge = nil
        }
        releaseVirtualAudioOutputIfUnused(reason: "long_recording_stopped")
        AppLogger.shared.write(
            "LONG RECORDING stopping reason=\(reason) close_written=\(closeWritten)"
        )
    }

    private func scheduleLongRecordingCloseTimeout(generation: UInt64) {
        longRecordingCloseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingCloseTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingGeneration == generation,
                  !self.longRecordingRequested,
                  self.voiceSession.isActive,
                  let bridge = self.longRecordingBridge,
                  BluetoothVoiceDeviceOwnershipPolicy.matches(bridge.deviceIdentifier, active: self.voiceSession.activeDeviceIdentifier)
            else { return }
            self.longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_timeout reconnecting=true")
            bridge.reconnectNow()
        }
        longRecordingCloseTimer = timer
        timer.resume()
    }

    func finishLongRecording(reason: String) {
        longRecordingBridge = nil
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        releaseVirtualAudioOutputIfUnused(reason: "long_recording_finished")
        AppLogger.shared.write("LONG RECORDING finished reason=\(reason)")
    }

    private func cancelLongRecordingTimers() {
        longRecordingOpenTimer?.cancel()
        longRecordingOpenTimer = nil
        longRecordingCloseTimer?.cancel()
        longRecordingCloseTimer = nil
    }

    func scheduleRC003VoiceExtensionOpenTimeout(generation: UInt64) {
        rc003VoiceExtensionOpenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.rc003VoiceExtensionOpenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.rc003VoiceExtensionActive,
                  self.rc003VoiceExtensionAwaitingReopen,
                  self.rc003VoiceExtensionGeneration == generation
            else { return }
            self.finishRC003VoiceExtensionTest(reason: "reopen_timeout")
        }
        rc003VoiceExtensionOpenTimer = timer
        timer.resume()
    }

    func scheduleRC003VoiceExtensionDeadline(generation: UInt64) {
        rc003VoiceExtensionDeadlineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.rc003VoiceExtensionMaximumDuration)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.rc003VoiceExtensionActive,
                  self.rc003VoiceExtensionGeneration == generation
            else { return }
            self.finishRC003VoiceExtensionTest(reason: "safe_timeout")
        }
        rc003VoiceExtensionDeadlineTimer = timer
        timer.resume()
    }

    func startRC003VoiceExtensionTimer() {
        guard rc003VoiceExtensionTimer == nil,
              rc003VoiceExtensionActive,
              !rc003VoiceExtensionAwaitingReopen,
              rc003VoiceExtensionDidReceiveAudio,
              let bridge = rc003VoiceExtensionBridge
        else { return }
        let generation = rc003VoiceExtensionGeneration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.rc003VoiceExtensionInterval,
            repeating: Self.rc003VoiceExtensionInterval
        )
        timer.setEventHandler { [weak self, weak bridge] in
            guard let self,
                  let bridge,
                  self.rc003VoiceExtensionActive,
                  !self.rc003VoiceExtensionAwaitingReopen,
                  self.rc003VoiceExtensionGeneration == generation,
                  self.rc003VoiceExtensionDidReceiveAudio
            else { return }
            guard bridge.requestMicrophoneExtend() else {
                AppLogger.shared.write("RC003 EXTENSION MIC_EXTEND failed")
                self.finishRC003VoiceExtensionTest(reason: "extend_rejected")
                return
            }
            AppLogger.shared.write("RC003 EXTENSION MIC_EXTEND sent")
        }
        rc003VoiceExtensionTimer = timer
        timer.resume()
    }

    func finishRC003VoiceExtensionTest(reason: String) {
        guard rc003VoiceExtensionActive || rc003VoiceExtensionAwaitingReopen else { return }
        let bridge = rc003VoiceExtensionBridge
        let wasStreaming = voiceSession.isActive
        rc003VoiceExtensionActive = false
        rc003VoiceExtensionAwaitingReopen = false
        rc003VoiceExtensionDidReceiveAudio = false
        rc003VoiceExtensionGeneration &+= 1
        rc003VoiceExtensionTimer?.cancel()
        rc003VoiceExtensionTimer = nil
        rc003VoiceExtensionOpenTimer?.cancel()
        rc003VoiceExtensionOpenTimer = nil
        rc003VoiceExtensionDeadlineTimer?.cancel()
        rc003VoiceExtensionDeadlineTimer = nil
        rc003VoiceExtensionBridge = nil
        if wasStreaming {
            _ = bridge?.requestMicrophoneClose()
            AppLogger.shared.write("RC003 EXTENSION stopping reason=\(reason) close_requested=true")
            return
        }
        voiceSession.activeDeviceIdentifier = nil
        voiceSession.isActive = false
        _ = voiceFnTapSession.stopVoice()
        releaseVoiceKeyIfNeeded(owner: .bluetooth, forceSoftware: false)
        endVoiceSessionIfNeeded(flushAudio: true)
        AppLogger.shared.write("RC003 EXTENSION finished reason=\(reason)")
    }
}
