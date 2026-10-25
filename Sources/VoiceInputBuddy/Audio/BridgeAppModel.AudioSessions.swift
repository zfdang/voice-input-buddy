import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    var readyBluetoothBridgeCount: Int {
        connections.readyCount
    }

    var shouldKeepVirtualAudioActive: Bool {
        // A connected remote is not an audio source. Keep the engine only while
        // delivering voice, preparing a tone, or finishing buffered Fn-tap audio.
        hasActiveVirtualAudioSource || voiceSession.pendingStart.identifier != nil ||
            voiceFnTapSession.hasPendingAudioSession || audio.testToneStartupPending || longRecordingRequested
    }

    var hasPendingBluetoothVoiceWork: Bool {
        connections.bridges.values.contains { $0.hasPendingVoiceWork } ||
            connections.discoveryBridge?.hasPendingVoiceWork == true
    }

    var hasActiveVirtualAudioSource: Bool {
        voiceSession.isActive || isPlayingTestTone || hasPendingBluetoothVoiceWork
    }

    func resumeVirtualAudioOutputIfNeeded(reason: String) {
        guard shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_skipped reason=\(reason) required=false " +
                    "ready_bridges=\(readyBluetoothBridgeCount) selected=\(!settings.selectedAudioDeviceUID.isEmpty)"
            )
            return
        }
        cancelVirtualAudioReleaseIfPending(trigger: "resume_\(reason)")
        guard !settings.selectedAudioDeviceUID.isEmpty else {
            AppLogger.shared.write("SYSTEM AUDIO resume_skipped reason=\(reason) selected=false")
            return
        }
        let deviceForAudibility = audio.output.actualDevice
            ?? audio.output.selectedDevice
            ?? audioDevices.first(where: { $0.uid == settings.selectedAudioDeviceUID })
        let audibilityHealthy = !CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: deviceForAudibility).requiresAudibilityRepair
        isAudioOutputReady = audio.output.isReadyForTestTone && audibilityHealthy
        guard !isAudioOutputReady else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_skipped reason=\(reason) already_ready=true " +
                    "state={\(audio.output.diagnosticState())}"
            )
            return
        }
        configureVirtualAudioOutput(reason: reason) { [weak self] configured in
            guard let self else { return }
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_completed reason=\(reason) configured=\(configured) " +
                    "selected_available=\(self.selectedAudioDeviceIsAvailable) " +
                    "state={\(self.audio.output.diagnosticState())}"
            )
        }
    }

    /// The configured destination survives idle teardown and asynchronous engine startup.
    var integrationAudioDeviceStatus: LocalizedMessage {
        if audio.startupPending { return LocalizedMessage("audio.compatibility.checking") }
        return BuddyMicrophoneDevicePolicy.status(in: audioDevices)
    }

    var selectedAudioDeviceIsAvailable: Bool {
        let selectedUID = settings.selectedAudioDeviceUID
        return !selectedUID.isEmpty && audioDevices.contains { $0.uid == selectedUID }
    }

    func releaseVirtualAudioOutputIfUnused(reason: String) {
        guard !shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "AUDIO RELEASE skipped reason=\(reason) still_required=true " +
                    "system_suspended=\(audio.suspensionState.isSuspended) " +
                    "bluetooth_voice=\(voiceSession.isActive) " +
                    "test_tone=\(isPlayingTestTone)"
            )
            return
        }
        guard audio.pendingVirtualAudioRelease == nil else { return }
        let pendingVoiceBufferCount = audio.output.pendingVoiceBufferCountForDiagnostics
        guard VirtualAudioConnectionLifecyclePolicy.shouldScheduleRelease(
            hasPendingRelease: audio.pendingVirtualAudioRelease != nil,
            hasAllocatedOutputResources: audio.output.hasAllocatedOutputResources,
            pendingVoiceBufferCount: pendingVoiceBufferCount
        ) else {
            isAudioOutputReady = false
            testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            return
        }
        audio.virtualAudioReleaseGeneration &+= 1
        let generation = audio.virtualAudioReleaseGeneration
        audio.pendingVirtualAudioRelease = (generation, reason)
        AppLogger.shared.write(
            "AUDIO RELEASE requested reason=\(reason) generation=\(generation) " +
                "system_suspended=\(audio.suspensionState.isSuspended) " +
                "pending_buffers=\(pendingVoiceBufferCount) " +
                "state={\(audio.output.diagnosticState())}"
        )
        audio.output.endSessionAfterDraining(
            source: "audio_release",
            operationID: generation,
            maximumDelay: audio.output.pendingPlaybackDuration + 0.75
        ) { [weak self] outcome in
            guard let self else { return }
            guard self.audio.virtualAudioReleaseGeneration == generation else {
                return
            }
            self.audio.pendingVirtualAudioRelease = nil
            guard !self.shouldKeepVirtualAudioActive else {
                AppLogger.shared.write(
                    "AUDIO RELEASE cancelled reason=\(reason) generation=\(generation) " +
                        "cause=required_again system_suspended=\(self.audio.suspensionState.isSuspended) " +
                        "bluetooth_voice=\(self.voiceSession.isActive) " +
                        "test_tone=\(self.isPlayingTestTone)"
                )
                return
            }
            self.preserveCompletedVoiceAudioDelivery()
            self.audio.output.stop()
            self.isAudioOutputReady = false
            self.testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            AppLogger.shared.write(
                "AUDIO RELEASE completed reason=\(reason) completion=\(outcome.rawValue) generation=\(generation) " +
                    "system_suspended=\(self.audio.suspensionState.isSuspended) " +
                    "ready_bridges=\(self.readyBluetoothBridgeCount) " +
                    "state={\(self.audio.output.diagnosticState())}"
            )
        }
    }

    func cancelVirtualAudioReleaseIfPending(
        trigger: String,
        cause: String = "required_again"
    ) {
        guard let pendingRelease = audio.pendingVirtualAudioRelease else { return }
        audio.virtualAudioReleaseGeneration &+= 1
        self.audio.pendingVirtualAudioRelease = nil
        audio.output.cancelPendingDrain()
        AppLogger.shared.write(
            "AUDIO RELEASE cancelled reason=\(pendingRelease.reason) " +
                "generation=\(pendingRelease.generation) " +
                "current_generation=\(audio.virtualAudioReleaseGeneration) cause=\(cause) " +
                "trigger=\(trigger) system_suspended=\(audio.suspensionState.isSuspended) " +
                "ready_bridges=\(readyBluetoothBridgeCount) " +
                "bluetooth_voice=\(voiceSession.isActive) " +
                "test_tone=\(isPlayingTestTone)"
        )
    }

}
