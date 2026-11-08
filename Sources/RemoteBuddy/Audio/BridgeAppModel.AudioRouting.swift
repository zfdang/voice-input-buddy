import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

extension BridgeAppModel {
    func refreshAudioDevices() {
        audio.deviceRefreshGeneration &+= 1
        let generation = audio.deviceRefreshGeneration
        AppLogger.shared.write("AUDIO DEVICES refresh_requested id=\(generation)")
        audio.preparationQueue.async { [weak self] in
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let diagnostic = Self.audioDevicesDiagnostic(devices)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.started,
                      self.audio.deviceRefreshGeneration == generation
                else { return }
                self.publishAudioDevices(devices)
                AppLogger.shared.write("AUDIO DEVICES refreshed id=\(generation) \(diagnostic)")
            }
        }
    }

    func startAudioSubsystem() {
        audio.startupGeneration &+= 1
        let generation = audio.startupGeneration
        audio.startupPending = true
        AppLogger.shared.write("AUDIO STARTUP scheduled id=\(generation)")
        // Device enumeration is the only work on this queue. Route ownership is decided
        // on the main actor after enumeration, using the user's current selection.
        audio.preparationQueue.async { [weak self] in
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let diagnostic = Self.audioDevicesDiagnostic(devices)
            AppLogger.shared.write("AUDIO DEVICES startup id=\(generation) \(diagnostic)")
            DispatchQueue.main.async { [weak self] in
                self?.prepareAudioStartup(generation: generation, devices: devices)
            }
        }
    }

    func prepareAudioStartup(generation: UInt64, devices: [AudioDeviceInfo],
        configureOutput: ((String, @escaping (Bool) -> Void) -> Void)? = nil) {
        guard started, audio.startupGeneration == generation else { return }
        audio.configurationGeneration &+= 1
        let configurationGeneration = audio.configurationGeneration
        if audio.suspensionState.reasons.contains(.systemSleeping) {
            finishAudioStartup(generation: generation, configurationGeneration: configurationGeneration,
                configured: false, devices: devices)
            return
        }
        let configure = configureOutput ?? { self.audio.output.configureAsync(deviceUID: $0, completion: $1) }
        configureAudioOutputWithRetry(deviceUID: settings.selectedAudioDeviceUID,
            generation: configurationGeneration, configure: configure) { [weak self] configured in
            DispatchQueue.main.async { [weak self] in
                self?.finishAudioStartup(generation: generation,
                    configurationGeneration: configurationGeneration, configured: configured,
                    devices: devices)
            }
        }
    }

    func finishAudioStartup(generation: UInt64, configurationGeneration: UInt64,
        configured: Bool, devices: [AudioDeviceInfo]) {
        // stop() owns teardown. An old completion must never tear down a newer route.
        guard started, audio.startupGeneration == generation else { return }
        if audio.configurationGeneration == configurationGeneration {
            audioStatus = audio.output.status
            isAudioOutputReady = audio.output.isReadyForTestTone
            isAudioOutputVerified = configured
            testToneStatus = isAudioOutputReady
                ? LocalizedMessage("audio.test_tone.ready")
                : LocalizedMessage("audio.output.none_or_unavailable")
        }
        audio.startupPending = false
        publishAudioDevices(devices)
        startObservingAudioHardware()
        releaseVirtualAudioOutputIfUnused(reason: "startup_complete")
        startBluetoothConnections()
        AppLogger.shared.write(
            "AUDIO REBIND finished reason=startup success=\(configured) status=\(audioStatus.key) " +
                "state={\(audio.output.diagnosticState())}"
        )
    }

    private func publishAudioDevices(_ devices: [AudioDeviceInfo]) {
        audioDevices = devices
        buddyMicrophoneStatus = BuddyMicrophoneDevicePolicy.status(in: devices)
    }

    nonisolated private static func audioDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        "outputs={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(devices))} " +
            CoreAudioDeviceCatalog.routeDiagnostic()
    }

    @MainActor func openVirtualMicrophoneSetupInstructions(using localization: LocalizationStore) {
        guard let instructions = localization.localizedURL(
            forResource: "VirtualMicrophoneSetup",
            withExtension: "md"
        ) else {
            return
        }
        NSWorkspace.shared.open(instructions)
    }

    func applyAudioSettings(
        reason: String = "settings_change",
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        stopLongRecording(reason: "audio_reconfigure")
        guard shouldKeepVirtualAudioActive else {
            releaseVirtualAudioOutputIfUnused(reason: reason)
            completion(false)
            return
        }
        configureVirtualAudioOutput(reason: reason, completion: completion)
    }

    func handleSystemAudioLifecycle(_ event: SystemAudioLifecycleEvent) {
        let changed = audio.suspensionState.apply(event)
        AppLogger.shared.write(
            "SYSTEM AUDIO event=\(event.rawValue) changed=\(changed) " +
                "suspended=\(audio.suspensionState.isSuspended) " +
                "reasons=\(audio.suspensionState.diagnostic) started=\(started) " +
                "ready_bridges=\(readyBluetoothBridgeCount) " +
                "configured_bridges=\(connections.bridges.count) " +
                "discovery_bridge=\(connections.discoveryBridge != nil) " +
                "bluetooth_voice=\(voiceSession.isActive) " +
                "" +
                "test_tone=\(isPlayingTestTone) audio_ready=\(isAudioOutputReady)"
        )
        guard started, changed else { return }
        setBluetoothSystemSuspended(
            audio.suspensionState.isSuspended,
            reason: event.rawValue
        )
        if event == .sessionDidResignActive {
            commonPhrases.close(reason: "session_inactive")
            stopHIDMonitors()
            hidMonitoringInterrupted = true
        }
        if event == .systemWillSleep || event == .sessionDidResignActive {
            suspendActiveAudio(reason: event.rawValue)
            return
        }
        guard !audio.startupPending else {
            AppLogger.shared.write(
                "SYSTEM AUDIO lifecycle_deferred event=\(event.rawValue) cause=audio_startup_pending " +
                    "suspended=\(audio.suspensionState.isSuspended)"
            )
            if !audio.suspensionState.isSuspended {
                resumeBluetoothConnectionCyclesIfNeeded(reason: event.rawValue)
            }
            return
        }

        if event.isSuspending {
            if hasActiveVirtualAudioSource {
                AppLogger.shared.write(
                    "SYSTEM AUDIO suspend_deferred event=\(event.rawValue) " +
                        "bluetooth_voice=\(voiceSession.isActive) " +
                        "" +
                        "test_tone=\(isPlayingTestTone)"
                )
                return
            }
            releaseVirtualAudioOutputIfUnused(reason: "system_\(event.rawValue)")
            return
        }

        guard !audio.suspensionState.isSuspended else {
            AppLogger.shared.write(
                "SYSTEM AUDIO resume_deferred event=\(event.rawValue) " +
                    "remaining_reasons=\(audio.suspensionState.diagnostic)"
            )
            return
        }
        if hidMonitoringInterrupted { applyHIDSettings() }
        resumeVirtualAudioOutputIfNeeded(reason: "system_\(event.rawValue)")
        if BluetoothWakeRecoveryPolicy.shouldForceReconnect(event: event, started: started) {
            recoverBluetoothVoiceLink(reason: "system_wake")
        } else if BluetoothWakeRecoveryPolicy.shouldRecoverVoiceLinkAfterResume(
            started: started,
            configuredBridgeCount: connections.bridges.count,
            readyBridgeCount: readyBluetoothBridgeCount,
            voiceLinkActive: hasActiveVirtualAudioSource
        ) {
            AppLogger.shared.write(
                "SYSTEM AUDIO voice_link_recovery event=\(event.rawValue) " +
                    "cause=no_ready_bridge ready_bridges=0 " +
                    "configured_bridges=\(connections.bridges.count) " +
                    "discovery_bridge=\(connections.discoveryBridge != nil) " +
                    "audio_ready=\(isAudioOutputReady)"
            )
            recoverBluetoothVoiceLink(reason: "session_activated")
        }
        resumeBluetoothConnectionCyclesIfNeeded(reason: event.rawValue)
    }

    private func suspendActiveAudio(reason: String) {
        for bridge in connections.bridges.values { _ = bridge.requestMicrophoneClose() }
        _ = connections.discoveryBridge?.requestMicrophoneClose()
        // Hardware sleep cannot be deferred for an active voice source.
        audio.configurationGeneration &+= 1
        cancelVirtualAudioReleaseIfPending(trigger: "system_sleep")
        stopLongRecording(reason: "system_sleep")
        finishRC003VoiceExtensionTest(reason: "system_sleep")
        cancelTestToneIfNeeded(statusMessage: LocalizedMessage("audio.test_tone.cancelled_device_changed"),
            logReason: "system_sleep")
        voiceSession.pendingStart.cancel()
        voiceSession.stopRequested = false
        voiceSession.isActive = false
        voiceSession.activeDeviceIdentifier = nil
        voiceSession.commandAudio.cancel()
        voiceFnTapSession.suspend()
        releaseVoiceKeyIfNeeded()
        endVoiceSessionIfNeeded()
        audio.output.stop()
        isAudioOutputReady = false
        testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
        AppLogger.shared.write("SYSTEM AUDIO suspended event=\(reason) active_sessions_ended=true")
    }

    func configureVirtualAudioOutput(
        reason: String,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        cancelVirtualAudioReleaseIfPending(trigger: "rebind_\(reason)")
        audio.virtualAudioReleaseGeneration &+= 1
        audio.configurationGeneration &+= 1
        let generation = audio.configurationGeneration
        let deviceUID = settings.selectedAudioDeviceUID
        AppLogger.shared.write("AUDIO REBIND begin reason=\(reason) state={\(audio.output.diagnosticState())}")
        if reason != "test_tone" {
            cancelTestToneIfNeeded(
                statusMessage: LocalizedMessage("audio.test_tone.cancelled_device_changed"),
                logReason: "device_reconfigure"
            )
        }
        configureAudioOutputWithRetry(deviceUID: deviceUID, generation: generation) { [weak self] configured in
            DispatchQueue.main.async {
                guard let self,
                      self.started,
                      self.audio.configurationGeneration == generation
                else {
                    completion(false)
                    return
                }
                self.audioStatus = self.audio.output.status
                self.isAudioOutputReady = self.audio.output.isReadyForTestTone
                self.isAudioOutputVerified = configured
                self.testToneStatus = self.isAudioOutputReady
                    ? LocalizedMessage("audio.test_tone.ready")
                    : LocalizedMessage("audio.output.none_or_unavailable")
                AppLogger.shared.write(
                    "AUDIO REBIND finished reason=\(reason) success=\(configured) status=\(self.audioStatus.key) " +
                        "ready=\(self.isAudioOutputReady) selected_available=\(self.selectedAudioDeviceIsAvailable) " +
                        "state={\(self.audio.output.diagnosticState())}"
                )
                self.updateVirtualAudioDeviceObservation()
                completion(configured)
                // Demand may have ended while HAL configuration was in flight.
                self.releaseVirtualAudioOutputIfUnused(reason: "rebind_complete_\(reason)")
            }
        }
    }

    /// A HAL route can still be settling immediately after launch or reconnect.
    /// Retry once, without requiring the user to repeat integration. A newer
    /// configuration, shutdown or idle release always takes precedence.
    func configureAudioOutputWithRetry(
        deviceUID: String,
        generation: UInt64,
        configure: ((String, @escaping (Bool) -> Void) -> Void)? = nil,
        scheduleRetry: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: action))
        },
        completion: @escaping (Bool) -> Void
    ) {
        let configure = configure ?? { self.audio.output.configureAsync(deviceUID: $0, completion: $1) }
        func attempt(retriesRemaining: Int) {
            guard self.started, self.audio.configurationGeneration == generation,
                  !self.isTerminating else { completion(false); return }
            configure(deviceUID) { [weak self] configured in
                DispatchQueue.main.async {
                    guard let self, self.started,
                          self.audio.configurationGeneration == generation,
                          !self.isTerminating else { completion(false); return }
                    guard !configured, retriesRemaining > 0, !deviceUID.isEmpty,
                          !self.audio.suspensionState.isSuspended,
                          self.audio.startupPending || self.shouldKeepVirtualAudioActive
                    else { completion(configured); return }
                    AppLogger.shared.write("AUDIO CONFIGURE retry_scheduled generation=\(generation) delay_ms=250 remaining=\(retriesRemaining)")
                    scheduleRetry(0.25) { [weak self] in
                        guard let self, self.started,
                              self.audio.configurationGeneration == generation,
                              !self.isTerminating, !self.audio.suspensionState.isSuspended,
                              self.audio.startupPending || self.shouldKeepVirtualAudioActive
                        else { completion(false); return }
                        attempt(retriesRemaining: retriesRemaining - 1)
                    }
                }
            }
        }
        attempt(retriesRemaining: 1)
    }

    @discardableResult
    func ensureVirtualAudioOutputReady(reason: String) -> Bool {
        if audio.output.isReadyForTestTone {
            if let device = audio.output.actualDevice ?? audio.output.selectedDevice ?? audioDevices.first(where: { $0.uid == settings.selectedAudioDeviceUID }) {
                let snapshot = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: device)
                if !snapshot.requiresAudibilityRepair {
                    isAudioOutputReady = true
                    AppLogger.shared.write(
                        "AUDIO HEALTH ready reason=\(reason) state={\(audio.output.diagnosticState())}"
                    )
                    return true
                }
            } else {
                isAudioOutputReady = true
                AppLogger.shared.write(
                    "AUDIO HEALTH ready reason=\(reason) state={\(audio.output.diagnosticState())}"
                )
                return true
            }
        }
        isAudioOutputReady = false
        AppLogger.shared.write(
            "AUDIO HEALTH stale reason=\(reason) state={\(audio.output.diagnosticState())}"
        )
        configureVirtualAudioOutput(reason: reason)
        return false
    }

    func ensureVirtualAudioOutputReady(
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        if audio.output.isReadyForTestTone {
            if let device = audio.output.actualDevice ?? audio.output.selectedDevice ?? audioDevices.first(where: { $0.uid == settings.selectedAudioDeviceUID }) {
                let snapshot = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: device)
                if !snapshot.requiresAudibilityRepair {
                    isAudioOutputReady = true
                    completion(true)
                    return
                }
            } else {
                isAudioOutputReady = true
                completion(true)
                return
            }
        }
        isAudioOutputReady = false
        AppLogger.shared.write(
            "AUDIO HEALTH stale reason=\(reason) state={\(audio.output.diagnosticState())}"
        )
        configureVirtualAudioOutput(reason: reason, completion: completion)
    }

    func updateVirtualAudioDeviceObservation() {
        audio.stopObservingVirtualDevice()
        guard let listener = audio.registeredListener else { return }
        guard let device = audio.output.actualDevice ?? audio.output.selectedDevice ?? audioDevices.first(where: { $0.uid == settings.selectedAudioDeviceUID }) else { return }
        let deviceID = device.id
        guard deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 else { return }

        let propertyConfigs: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput),
            (kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput),
            (kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        ]

        for (selector, scope) in propertyConfigs {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            let result = AudioObjectAddPropertyListenerBlock(
                deviceID,
                &address,
                audio.hardwareListenerQueue,
                listener
            )
            if result == noErr {
                audio.observedDeviceProperties.append((objectID: deviceID, address: address))
            } else {
                AppLogger.shared.write(
                    "AUDIO RECOVERY device_listener_failed selector=\(selector) scope=\(scope) " +
                        AppLogger.errorFields(domain: "os_status", code: Int(result))
                )
            }
        }
    }

    private func startObservingAudioHardware() {
        guard audio.observedHardwareAddresses.isEmpty else { return }
        audio.retainHardwareListener(audioHardwareListener)
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let result = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audio.hardwareListenerQueue,
                audioHardwareListener
            )
            if result == noErr {
                audio.observedHardwareAddresses.append(address)
            } else {
                AppLogger.shared.write(
                    "AUDIO RECOVERY listener_failed selector=\(selector) " +
                        AppLogger.errorFields(domain: "os_status", code: Int(result))
                )
            }
        }
        updateVirtualAudioDeviceObservation()
        AppLogger.shared.write("AUDIO ROUTE_MONITOR started properties=\(Self.audioHardwarePropertyNames(for: audio.observedHardwareAddresses))")
    }

    func stopObservingAudioHardware() {
        if !audio.observedHardwareAddresses.isEmpty {
            AppLogger.shared.write("AUDIO ROUTE_MONITOR stopped properties=\(Self.audioHardwarePropertyNames(for: audio.observedHardwareAddresses))")
        }
        audio.stopObservingHardware()
    }

    func scheduleAudioRecovery(reason: String, details: String = "",
        schedule: ((TimeInterval, DispatchWorkItem) -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            guard !self.settings.selectedAudioDeviceUID.isEmpty else {
                AppLogger.shared.write("AUDIO RECOVERY ignored reason=\(reason) detail=\(details) no_selected_device")
                return
            }
            guard !AudioHardwareChangeProperties(details: details).affectsOnlyDefaultInput else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) explicit_output_unchanged"
                )
                return
            }
            let deviceForAudibility = self.audio.output.actualDevice
                ?? self.audio.output.selectedDevice
                ?? self.audioDevices.first(where: { $0.uid == self.settings.selectedAudioDeviceUID })
            let audibility = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: deviceForAudibility)
            let configurationHealthy = self.audio.output.isConfigurationHealthyForDiagnostics && !audibility.requiresAudibilityRepair
            if details.contains("device_mute") || details.contains("device_volume") {
                self.isAudioOutputReady = false
            }
            guard !VirtualAudioRecoveryPolicy.shouldIgnoreDefaultSystemOutputChange(
                details: details,
                configurationHealthy: configurationHealthy
            ) else {
                self.refreshAudioDevices()
                if configurationHealthy {
                    self.isAudioOutputReady = true
                }
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) " +
                        "explicit_output_healthy=true state={\(self.audio.output.diagnosticState())}"
                )
                return
            }
            guard self.shouldKeepVirtualAudioActive else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) virtual_audio_inactive"
                )
                return
            }
            self.audio.recoveryCoalescingState.recordEvent(reason: reason)
            let urgent = self.hasActiveVirtualAudioSource && !configurationHealthy
            // Keep the first bounded recovery instead of extending its deadline for
            // every HAL notification. A stopped active stream bypasses the delay.
            if self.audio.recoveryWorkItem != nil && !urgent { return }
            self.audio.recoveryGeneration &+= 1
            let generation = self.audio.recoveryGeneration
            self.audio.recoveryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.started,
                      self.audio.recoveryGeneration == generation
                else { return }
                self.audio.preparationQueue.async { [weak self] in
                    let devices = CoreAudioDeviceCatalog.outputDevices()
                    DispatchQueue.main.async { [weak self] in
                        self?.completeAudioRecoveryDeviceRefresh(generation: generation, reason: reason,
                            details: details, devices: devices)
                    }
                }
            }
            self.audio.recoveryWorkItem = work
            if let schedule { schedule(urgent ? 0 : 1, work) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + (urgent ? 0 : 1), execute: work) }
        }
    }

    func completeAudioRecoveryDeviceRefresh(generation: UInt64, reason: String, details: String,
        devices: [AudioDeviceInfo], outputSnapshot: VirtualAudioOutputDiagnosticSnapshot? = nil,
        configureOutput: ((@escaping (Bool) -> Void) -> Void)? = nil
    ) {
        guard started, audio.recoveryGeneration == generation else { return }
        self.publishAudioDevices(devices)
        let selectedDeviceAvailable = self.selectedAudioDeviceIsAvailable
        let startedAtUptime = ProcessInfo.processInfo.systemUptime
        let coalesced = self.audio.recoveryCoalescingState.consumePendingEvents()
        let effectiveReason = coalesced.includesHardwareChange
            ? "hardware_change"
            : reason
        AppLogger.shared.write(
            "AUDIO RECOVERY operation_id=\(generation) phase=started result=pending " +
                "requested_reason=\(reason) effective_reason=\(effectiveReason) " +
                "detail=\(details) coalesced_events=\(coalesced.count) " +
                "includes_hardware_change=\(coalesced.includesHardwareChange)"
        )
        if selectedDeviceAvailable {
            let snapshot = outputSnapshot ?? self.audio.output.diagnosticSnapshot()
            let deviceForAudibility = self.audio.output.actualDevice
                ?? self.audio.output.selectedDevice
                ?? self.audioDevices.first(where: { $0.uid == self.settings.selectedAudioDeviceUID })
            let audibility = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(for: deviceForAudibility)
            let audibilityHealthy = snapshot.audibilityHealthy && !audibility.requiresAudibilityRepair
            let configurationHealthy = snapshot.engineRunning &&
                snapshot.playerPlaying &&
                snapshot.boundToSelectedDevice == true &&
                audibilityHealthy
            guard self.audioRecoveryNeeded(
                engineNotificationOnly: reason == "engine_configuration_change" && !coalesced.includesHardwareChange,
                boundToSelectedDevice: snapshot.boundToSelectedDevice,
                configurationHealthy: configurationHealthy,
                hasActiveAudioSource: self.hasActiveVirtualAudioSource,
                pendingVoiceBufferCount: snapshot.pendingBuffers
            ) else {
                if configurationHealthy {
                    self.isAudioOutputReady = true
                }
                let ignoredReason = configurationHealthy
                    ? "configuration_healthy"
                    : "still_bound_idle"
                AppLogger.shared.write(
                    "AUDIO RECOVERY operation_id=\(generation) phase=completed result=ignored " +
                        "reason=\(effectiveReason) decision=\(ignoredReason) " +
                        "detail=\(details) coalesced_events=\(coalesced.count) " +
                        "includes_hardware_change=\(coalesced.includesHardwareChange) " +
                        "active_audio=\(self.hasActiveVirtualAudioSource) " +
                        "pending_buffers=\(snapshot.pendingBuffers) pending_samples=\(snapshot.pendingSamples) " +
                        "engine_running=\(snapshot.engineRunning) player_playing=\(snapshot.playerPlaying) " +
                        "bound_to_selected=\(self.optionalDiagnosticBool(snapshot.boundToSelectedDevice)) " +
                        "audibility_healthy=\(audibilityHealthy) " +
                        "elapsed_ms=\(self.elapsedMilliseconds(since: startedAtUptime)) " +
                        "state={\(self.audio.output.diagnosticState())}"
                )
                self.audio.recoveryWorkItem = nil
                return
            }
        }
        AppLogger.shared.write(
            "AUDIO RECOVERY operation_id=\(generation) phase=applying result=pending " +
                "reason=\(effectiveReason) detail=\(details) " +
                "coalesced_events=\(coalesced.count) " +
                "includes_hardware_change=\(coalesced.includesHardwareChange) " +
                "state={\(self.audio.output.diagnosticState())}"
        )
        let apply = configureOutput ?? { self.applyAudioSettings(reason: "recovery_\(effectiveReason)", completion: $0) }
        apply { [weak self] _ in
            guard let self,
                  self.audio.recoveryGeneration == generation
            else { return }
            let completedSnapshot = self.audio.output.diagnosticSnapshot()
            let completedAudibility = CoreAudioDeviceCatalog.virtualAudioAudibilitySnapshot(
                for: self.audio.output.actualDevice ?? self.audio.output.selectedDevice
            )
            let ready = completedSnapshot.engineRunning &&
                completedSnapshot.playerPlaying &&
                completedSnapshot.boundToSelectedDevice == true &&
                !completedAudibility.requiresAudibilityRepair
            self.isAudioOutputReady = ready
            AppLogger.shared.write(
                "AUDIO RECOVERY operation_id=\(generation) phase=completed " +
                    "result=\(ready ? "ready" : "degraded") reason=\(effectiveReason) " +
                    "engine_running=\(completedSnapshot.engineRunning) " +
                    "player_playing=\(completedSnapshot.playerPlaying) " +
                    "bound_to_selected=\(self.optionalDiagnosticBool(completedSnapshot.boundToSelectedDevice)) " +
                    "audibility_healthy=\(!completedAudibility.requiresAudibilityRepair) " +
                    "pending_buffers=\(completedSnapshot.pendingBuffers) " +
                    "pending_samples=\(completedSnapshot.pendingSamples) " +
                    "elapsed_ms=\(self.elapsedMilliseconds(since: startedAtUptime)) " +
                    "state={\(self.audio.output.diagnosticState())}"
            )
            self.audio.recoveryWorkItem = nil
        }
    }

    func audioRecoveryNeeded(
        engineNotificationOnly: Bool,
        boundToSelectedDevice: Bool?,
        configurationHealthy: Bool,
        hasActiveAudioSource: Bool,
        pendingVoiceBufferCount: Int
    ) -> Bool {
        if configurationHealthy { return false }
        if !engineNotificationOnly { return true }
        return AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: boundToSelectedDevice,
            configurationHealthy: configurationHealthy,
            hasActiveAudioSource: hasActiveAudioSource,
            pendingVoiceBufferCount: pendingVoiceBufferCount)
    }

    nonisolated static func audioHardwarePropertyNames(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> String {
        guard count > 0 else { return "none" }
        return (0..<Int(count))
            .map { audioHardwarePropertyName(addresses[$0].mSelector) }
            .joined(separator: ",")
    }

    nonisolated static func audioHardwarePropertyNames(
        for addresses: [AudioObjectPropertyAddress]
    ) -> String {
        addresses.map { audioHardwarePropertyName($0.mSelector) }.joined(separator: ",")
    }

    nonisolated private static func audioHardwarePropertyName(
        _ selector: AudioObjectPropertySelector
    ) -> String {
        switch selector {
        case kAudioHardwarePropertyDevices:
            return "devices"
        case kAudioHardwarePropertyDefaultInputDevice:
            return "default_input"
        case kAudioHardwarePropertyDefaultOutputDevice:
            return "default_output"
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            return "default_system_output"
        case kAudioDevicePropertyMute:
            return "device_mute"
        case kAudioDevicePropertyVolumeScalar:
            return "device_volume"
        case kAudioDevicePropertyDeviceIsAlive:
            return "device_is_alive"
        default:
            return "selector_\(selector)"
        }
    }

    var canSendTestTone: Bool {
        TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone || audio.testToneStartupPending
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone || audio.testToneStartupPending
        ) else {
            if isStreaming {
                testToneStatus = LocalizedMessage("audio.test_tone.blocked_voice_active")
                AppLogger.shared.write("AUDIO TEST_TONE rejected_streaming")
            } else if isPlayingTestTone || audio.testToneStartupPending {
                testToneStatus = LocalizedMessage("audio.test_tone.already_playing")
            } else {
                testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            }
            return
        }

        cancelVirtualAudioReleaseIfPending(trigger: "test_tone_start")
        if !audio.output.isReadyForTestTone {
            audio.testToneStartupPending = true
            let generation = testToneGeneration
            ensureVirtualAudioOutputReady(reason: "test_tone") { [weak self] ready in
                guard let self, self.testToneGeneration == generation else { return }
                self.audio.testToneStartupPending = false
                self.startTestToneAfterAudioReady(ready)
                self.releaseVirtualAudioOutputIfUnused(reason: "test_tone_prepared")
            }
            return
        }
        startTestToneAfterAudioReady(true)
    }

    func startTestToneAfterAudioReady(_ ready: Bool) {
        // A voice start or another tone may win while configuration is in flight.
        guard !isPlayingTestTone else { return }
        guard !isStreaming, !hasActiveVirtualAudioSource else {
            testToneStatus = LocalizedMessage("audio.test_tone.blocked_voice_active")
            return
        }
        guard canSendTestTone else {
            testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            return
        }
        guard ready else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_configure_failed")
            return
        }
        testToneGeneration &+= 1
        let generation = testToneGeneration
        let started = audio.output.playTestTone { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTestToneCompletion(generation: generation, finished: finished)
            }
        }
        guard started else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_start_failed")
            return
        }
        isPlayingTestTone = true
        testToneStatus = LocalizedMessage("audio.test_tone.playing")
        AppLogger.shared.write("AUDIO TEST_TONE played")
    }

    private func handleTestToneCompletion(generation: Int, finished: Bool) {
        guard generation == testToneGeneration, isPlayingTestTone else { return }
        isPlayingTestTone = false
        testToneStatus = LocalizedMessage(finished ? "audio.test_tone.completed" : "audio.test_tone.cancelled")
        AppLogger.shared.write("AUDIO TEST_TONE \(finished ? "finished" : "cut_short")")
        releaseVirtualAudioOutputIfUnused(reason: "test_tone_finished")
    }

    func cancelTestToneIfNeeded(statusMessage: LocalizedMessage, logReason: String) {
        guard isPlayingTestTone || audio.testToneStartupPending else { return }
        audio.testToneStartupPending = false
        testToneGeneration &+= 1
        isPlayingTestTone = false
        audio.output.cancelTestTone()
        testToneStatus = statusMessage
        AppLogger.shared.write("AUDIO TEST_TONE cancelled reason=\(logReason)")
    }
}
