import Foundation

extension BridgeAppModel {
    /// Per-attempt feedback is independent of the persistent voice shortcut status.
    /// Results expire so reopening settings never presents an old attempt as current.
    func recordApplicationIntegrationStatus(_ state: ApplicationIntegrationPreparationState) {
        clearApplicationIntegrationStatus()
        applicationIntegrationStatus = state
        guard state != .waiting else { return }
        let generation = applicationIntegrationStatusGeneration
        applicationIntegrationStatusExpiry = scheduleApplicationIntegrationStatus(15) { [weak self] in
            guard let self, self.applicationIntegrationStatusGeneration == generation else { return }
            self.clearApplicationIntegrationStatus()
        }
    }

    /// Only the actual key-post result can promote preparing feedback to triggered.
    func completeApplicationIntegrationVoiceTrigger(started: Bool) {
        guard let state = applicationIntegrationStatus else { return }
        switch state {
        case .voiceTriggered, .voiceTriggeredPreserved, .voiceTriggeredWithoutFocus, .cancelled: return
        default: break
        }
        if !started {
            recordApplicationIntegrationStatus(.cancelled(.actionFailed))
            return
        }
        switch state {
        case .ready: recordApplicationIntegrationStatus(.voiceTriggered)
        case .preserved: recordApplicationIntegrationStatus(.voiceTriggeredPreserved)
        case .unavailable, .focusTimedOut: recordApplicationIntegrationStatus(.voiceTriggeredWithoutFocus)
        default: break // Stop pulses and repeated callbacks do not start a new attempt.
        }
    }

    func clearApplicationIntegrationStatus() {
        applicationIntegrationStatusGeneration &+= 1
        applicationIntegrationStatusExpiry?.cancel()
        applicationIntegrationStatusExpiry = nil
        applicationIntegrationStatus = nil
    }
}
