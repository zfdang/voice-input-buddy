import Foundation

/// Current prerequisites, independent of onboarding completion or an idle audio engine.
struct SettingsOverviewState: Equatable {
    let missingRequirementKeys: [String]
    let connectedRemoteNames: [String]
    let mappingEnabled: Bool
    let integrationTool: OnboardingVoiceTool

    var permissionsReady: Bool { missingRequirementKeys.isEmpty }
    var remoteReady: Bool { !connectedRemoteNames.isEmpty }
    var integrationReady: Bool { integrationTool != .unselected }

    init(bluetoothGranted: Bool, inputMonitoringGranted: Bool, accessibilityGranted: Bool,
         audioDevices: [AudioDeviceInfo], profiles: [RemoteDeviceProfile], connectedIDs: Set<UUID>,
         mappingEnabled: Bool, integrationTool: OnboardingVoiceTool,
         remoteName: (RemoteDeviceProfile) -> String) {
        var missing: [String] = []
        if !bluetoothGranted { missing.append("permission.bluetooth.title") }
        if !inputMonitoringGranted { missing.append("permission.input_monitoring.title") }
        if !accessibilityGranted { missing.append("permission.accessibility.title") }
        if !audioDevices.contains(where: {
            OnboardingAudioSelectionPolicy.isSupportedDevice(uid: $0.uid, name: $0.name)
        }) { missing.append("settings.driver.title") }
        missingRequirementKeys = missing
        connectedRemoteNames = profiles.filter { connectedIDs.contains($0.id) }.map(remoteName)
        self.mappingEnabled = mappingEnabled
        self.integrationTool = integrationTool
    }

    @MainActor func permissionsSummary(using localization: LocalizationStore) -> String {
        guard !permissionsReady else { return localization.text("settings.overview.ready") }
        return LocalizedMessage("settings.overview.missing_requirements", arguments: [
            Self.localizedList(missingRequirementKeys.map { localization.text($0) }, locale: localization.locale)
        ]).text(using: localization)
    }

    static func localizedList(_ values: [String], locale: Locale) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: values) ?? values.joined(separator: ", ")
    }

}
