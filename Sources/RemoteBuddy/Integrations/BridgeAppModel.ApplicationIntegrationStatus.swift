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

    func clearApplicationIntegrationStatus() {
        applicationIntegrationStatusGeneration &+= 1
        applicationIntegrationStatusExpiry?.cancel()
        applicationIntegrationStatusExpiry = nil
        applicationIntegrationStatus = nil
    }
}
