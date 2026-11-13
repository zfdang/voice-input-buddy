import Foundation
import IOKit
import Testing
@testable import RemoteBuddy

@Suite("Runtime permission & signature diagnostics")
@MainActor
struct RuntimePermissionDiagnosticsTests {
    @Test func hidDeviceOpenFailureMessageKeyHandlesNotPermittedAndExclusiveAccess() {
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnNotPermitted,
                karabinerElementsInstalled: false
            ) == HIDStatusKeys.notPermitted
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnNotPermitted,
                karabinerElementsInstalled: true
            ) == HIDStatusKeys.notPermitted
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnExclusiveAccess,
                karabinerElementsInstalled: false
            ) == "button_mapping.error.exclusive_access"
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnExclusiveAccess,
                karabinerElementsInstalled: true
            ) == "button_mapping.error.exclusive_access.karabiner"
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnError,
                karabinerElementsInstalled: false
            ) == nil
        )
    }

    @Test func diagnosisIgnoresUninitializedOrUnusedPermissionsWithoutRuntimeFailure() {
        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: false,
                accessibilityGranted: false,
                connectionStatusKey: "bluetooth.status.initializing",
                hidStatusKey: "button_mapping.status.disabled",
                hidFilterFailure: .none
            ) == nil
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: false,
                accessibilityGranted: true,
                connectionStatusKey: "connection.status.searching",
                hidStatusKey: "button_mapping.status.system_managed",
                hidFilterFailure: .none
            ) == nil
        )

        // Transient Bluetooth resetting should not flash a banner.
        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: "bluetooth.status.resetting",
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterFailure: .none
            ) == nil
        )
    }

    @Test func diagnosisDetectsDesyncedSignalsGenuineRuntimeDenialsAndPreferredSettingsURLs() {
        let combinedDesync = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            connectionStatusKey: BluetoothStatusKeys.permissionDenied,
            hidStatusKey: HIDStatusKeys.notPermitted,
            hidFilterFailure: .tapCreateFailed
        )
        #expect(
            combinedDesync == .permissionDesynced(
                signals: ["bluetooth_unauthorized", "hid_open_not_permitted", "hid_filter_tap_create_failed"]
            )
        )
        #expect(
            combinedDesync?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy"
        )

        let bluetoothOnlyDesync = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            connectionStatusKey: BluetoothStatusKeys.permissionDenied,
            hidStatusKey: "button_mapping.status.connected",
            hidFilterFailure: .none
        )
        #expect(bluetoothOnlyDesync == .permissionDesynced(signals: ["bluetooth_unauthorized"]))
        #expect(
            bluetoothOnlyDesync?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        )

        let systemDisabledDesync = RuntimePermissionDiagnosisPolicy.diagnose(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            connectionStatusKey: "connection.status.connected_to_device",
            hidStatusKey: HIDStatusKeys.interrupted,
            hidFilterFailure: .systemDisabled
        )
        #expect(systemDisabledDesync == .permissionDesynced(signals: ["hid_filter_system_disabled"]))
        #expect(
            systemDisabledDesync?.preferredPrivacySettingsURLString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: BluetoothStatusKeys.permissionDenied,
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterFailure: .none
            ) == .bluetoothPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: false,
                accessibilityGranted: true,
                connectionStatusKey: "connection.status.searching",
                hidStatusKey: HIDStatusKeys.notPermitted,
                hidFilterFailure: .none
            ) == .inputMonitoringPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: BluetoothStatusKeys.off,
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterFailure: .none
            ) == .bluetoothUnavailable(statusKey: BluetoothStatusKeys.off)
        )
    }

    @Test func keyboardSuppressorTracksTapCreationFailureOnlyWhenPermissionsGranted() {
        var granted = false
        var startResult = false
        let deniedSuppressor = KeyboardEventSuppressor(
            permissionsGranted: { granted },
            tapOperations: .init(
                start: { startResult },
                stop: {},
                isEnabled: { false }
            )
        )
        #expect(!deniedSuppressor.start())
        #expect(!deniedSuppressor.didTapCreationFailDespitePermissions)

        granted = true
        #expect(!deniedSuppressor.start())
        #expect(deniedSuppressor.didTapCreationFailDespitePermissions)

        startResult = true
        #expect(deniedSuppressor.start())
        #expect(!deniedSuppressor.didTapCreationFailDespitePermissions)

        deniedSuppressor.stop()
        #expect(!deniedSuppressor.didTapCreationFailDespitePermissions)
    }

    @Test func appModelDetectsSystemDisabledEventTapAsDesyncEvenWhenPermissionsReportGranted() throws {
        let suiteName = "runtime-perm-tap-disabled-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = BridgeAppModel(
            settings: AppSettings(defaults: defaults),
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.hidEventSuppressor.onSystemDisabled?()

        #expect(model.hidStatus.key == HIDStatusKeys.interrupted)
        #expect(model.hidFilterFailureState == .systemDisabled)
        #expect(model.runtimePermissionIssue == .permissionDesynced(signals: ["hid_filter_system_disabled"]))
        #expect(model.runtimePermissionIssueUpdatedAt != nil)
        #expect(model.runtimePermissionDiagnosisTrigger == "hid_filter_disabled")

        model.hidFilterFailureState = .none
        model.hidStatus = LocalizedMessage("button_mapping.status.connected")
        model.refreshRuntimePermissionDiagnosis(trigger: "recovered", bluetoothGranted: true)
        #expect(model.runtimePermissionIssue == nil)
        #expect(model.runtimePermissionIssueUpdatedAt == nil)
        #expect(model.runtimePermissionDiagnosisTrigger == nil)
    }

    @Test func firstUseContextChecksStaticPermissionsOnPermissionsStepAndDesyncOnRemoteStep() {
        let ungranted = OnboardingCapabilities(
            bluetoothGranted: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: false,
            remoteButtonObserved: false
        )
        let permissionsContext = FirstUseDiagnosticContext(
            step: .permissions,
            controlMethod: .physicalRemote,
            capabilities: ungranted,
            hasSelectedAudioUID: false,
            runtimePermissionIssue: .permissionDesynced(signals: ["hid_filter_system_disabled"])
        )
        #expect(permissionsContext.failureReason == .bluetoothPermissionDenied)

        let granted = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: false,
            remoteButtonObserved: false
        )
        let issue = RuntimePermissionIssue.permissionDesynced(signals: ["bluetooth_unauthorized"])
        let remoteContext = FirstUseDiagnosticContext(
            step: .remote,
            controlMethod: .physicalRemote,
            capabilities: granted,
            hasSelectedAudioUID: false,
            runtimePermissionIssue: issue
        )

        #expect(remoteContext.failureReason == .permissionDesynced)
        #expect(remoteContext.failureReason?.recoveryStep == .permissions)

        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: "1.0",
            appBuild: "718",
            systemMajorVersion: 15,
            architecture: "arm64",
            voiceTool: .unselected,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            context: remoteContext,
            voiceAttempt: FirstUseVoiceAttemptDiagnostic(
                attemptID: 0,
                phase: .idle,
                triggerPath: "none",
                triggerReady: false,
                editorMounted: false,
                windowKeyAtStart: false,
                firstResponderAtStart: false,
                firstResponderAtEnd: false,
                focusLost: false,
                firstSampleLatencyMilliseconds: nil,
                sessionDurationMilliseconds: nil,
                transcriptWaitMilliseconds: nil,
                result: .none
            ),
            bluetoothStatus: BluetoothStatusKeys.permissionDenied,
            buttonStatus: HIDStatusKeys.notPermitted,
            audioStatus: "audio.output.none_selected",
            events: [],
            appLanguage: "en"
        )

        #expect(snapshot.redactedText.contains("failure=permission.desynced"))
        #expect(snapshot.redactedText.contains("runtime_permission_issue=permission_desynced(bluetooth_unauthorized)"))
    }

    @Test func relaunchApplicationValidatesBundleTerminationAndProcessLaunch() throws {
        let suiteName = "runtime-perm-relaunch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        var launchedCalls: [(executable: String, arguments: [String])] = []
        var terminateCount = 0

        let nonAppResult = model.relaunchApplication(
            bundleURL: FileManager.default.temporaryDirectory,
            pid: 4242,
            launchProcess: { exe, args in launchedCalls.append((exe, args)) },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(!nonAppResult)
        #expect(launchedCalls.isEmpty)
        #expect(terminateCount == 0)

        let tempAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteBuddyTest-\(UUID().uuidString).app")
        #expect(!BridgeAppModel.canRelaunchAppBundle(tempAppURL))
        try FileManager.default.createDirectory(at: tempAppURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempAppURL) }
        #expect(BridgeAppModel.canRelaunchAppBundle(tempAppURL))

        struct SimulatedLaunchFailure: Error {}
        let failedLaunch = model.relaunchApplication(
            bundleURL: tempAppURL,
            pid: 4242,
            launchProcess: { _, _ in throw SimulatedLaunchFailure() },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(!failedLaunch)
        #expect(terminateCount == 0)

        let succeededLaunch = model.relaunchApplication(
            bundleURL: tempAppURL,
            pid: 4242,
            launchProcess: { exe, args in launchedCalls.append((exe, args)) },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(succeededLaunch)
        #expect(launchedCalls.count == 1)
        #expect(launchedCalls[0].executable == "/bin/sh")
        #expect(launchedCalls[0].arguments.contains("4242"))
        #expect(launchedCalls[0].arguments.contains(tempAppURL.path))
        #expect(terminateCount == 1)

        model.prepareForTermination()
        let terminatingRelaunch = model.relaunchApplication(
            bundleURL: tempAppURL,
            pid: 4242,
            launchProcess: { exe, args in launchedCalls.append((exe, args)) },
            terminateHandler: { terminateCount += 1 }
        )
        #expect(!terminatingRelaunch)
        #expect(launchedCalls.count == 1)
        #expect(terminateCount == 1)
    }

    @Test func settingsDiagnosticSnapshotIncludesRuntimePermissionFields() {
        let updatedAt = Date(timeIntervalSince1970: 1_763_000_000)
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.0",
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            runtimeLogAvailable: true,
            runtimePermissionIssue: "permission_desynced(bluetooth_unauthorized)",
            runtimePermissionIssueUpdatedAt: updatedAt,
            runtimePermissionDiagnosisTrigger: "hid_filter_disabled",
            connectionStatusKey: BluetoothStatusKeys.permissionDenied,
            hidStatusKey: HIDStatusKeys.notPermitted
        )
        let summary = snapshot.summary
        #expect(summary.contains("permission_desynced(bluetooth_unauthorized)"))
        #expect(summary.contains("runtime_permission_trigger: \"hid_filter_disabled\""))
        #expect(summary.contains("runtime_permission_updated_at: \"2025-11-13T"))
        #expect(summary.contains("connection_status: \"bluetooth.status.permission_denied\""))
        #expect(summary.contains("hid_status: \"button_mapping.error.not_permitted\""))
    }

    @Test func newPermissionAndDiagnosticLocalizationKeysExistInEnglishAndChinese() throws {
        let suiteName = "locale-runtime-perm-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))

        let keys = [
            HIDStatusKeys.notPermitted,
            "permission.desync.banner.title",
            "permission.desync.banner.detail",
            "permission.desync.banner.detail.with_restart",
            "permission.desync.action.restart",
            "permission.desync.action.open_settings",
            "permission.desync.restart_confirm.title",
            "permission.desync.restart_confirm.message",
            "onboarding.recovery.permission.desynced.title",
            "onboarding.recovery.permission.desynced.detail",
            "onboarding.recovery.permission.desynced.detail.with_restart",
            "onboarding.remote.permission_desync.title",
            "onboarding.remote.permission_desync.detail",
            "onboarding.remote.permission_desync.detail.with_restart",
            "onboarding.remote.bluetooth_denied.title",
            "onboarding.remote.bluetooth_denied.detail",
            "onboarding.remote.input_not_permitted.title",
            "onboarding.remote.input_not_permitted.detail",
            "onboarding.remote.bluetooth_unavailable.detail"
        ]

        for key in keys {
            store.select(.english)
            let en = store.text(key)
            store.select(.simplifiedChinese)
            let zh = store.text(key)
            #expect(en != key)
            #expect(zh != key)
            #expect(en != zh)
        }
    }
}
