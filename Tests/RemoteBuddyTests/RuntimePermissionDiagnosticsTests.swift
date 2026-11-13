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
            ) == "button_mapping.error.not_permitted"
        )
        #expect(
            HIDRemoteMonitor.deviceOpenFailureMessageKey(
                result: kIOReturnNotPermitted,
                karabinerElementsInstalled: true
            ) == "button_mapping.error.not_permitted"
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

    @Test func diagnosisDetectsDesyncedPermissionsVsGenuineDenials() {
        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: "connection.status.searching",
                hidStatusKey: "button_mapping.status.connected",
                hidFilterStartFailed: false
            ) == nil
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: "bluetooth.status.permission_denied",
                hidStatusKey: "button_mapping.error.not_permitted",
                hidFilterStartFailed: true
            ) == .permissionDesynced(
                signals: ["bluetooth_unauthorized", "hid_open_not_permitted", "hid_filter_start_failed"]
            )
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: false,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: "bluetooth.status.permission_denied",
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterStartFailed: false
            ) == .bluetoothPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: false,
                accessibilityGranted: true,
                connectionStatusKey: "connection.status.searching",
                hidStatusKey: "button_mapping.error.not_permitted",
                hidFilterStartFailed: false
            ) == .inputMonitoringPermissionDenied
        )

        #expect(
            RuntimePermissionDiagnosisPolicy.diagnose(
                bluetoothGranted: true,
                inputMonitoringGranted: true,
                accessibilityGranted: true,
                connectionStatusKey: "bluetooth.status.off",
                hidStatusKey: "button_mapping.status.waiting_for_device",
                hidFilterStartFailed: false
            ) == .bluetoothUnavailable(statusKey: "bluetooth.status.off")
        )
    }

    @Test func firstUseContextSurfacesPermissionDesyncBeforeRemoteNotFound() {
        let capabilities = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            remoteConnected: false,
            remoteButtonObserved: false
        )
        let issue = RuntimePermissionIssue.permissionDesynced(signals: ["bluetooth_unauthorized"])
        let context = FirstUseDiagnosticContext(
            step: .remote,
            controlMethod: .physicalRemote,
            capabilities: capabilities,
            hasSelectedAudioUID: false,
            runtimePermissionIssue: issue
        )

        #expect(context.failureReason == .permissionDesynced)
        #expect(context.failureReason?.recoveryStep == .permissions)

        let snapshot = FirstUseDiagnosticSnapshot(
            appVersion: "1.0",
            appBuild: "718",
            systemMajorVersion: 15,
            architecture: "arm64",
            voiceTool: .unselected,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            context: context,
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
            bluetoothStatus: "bluetooth.status.permission_denied",
            buttonStatus: "button_mapping.error.not_permitted",
            audioStatus: "audio.output.none_selected",
            events: [],
            appLanguage: "en"
        )

        #expect(snapshot.redactedText.contains("failure=permission.desynced"))
        #expect(snapshot.redactedText.contains("runtime_permission_issue=permission_desynced(bluetooth_unauthorized)"))
    }

    @Test func appModelUpdatesRuntimePermissionIssueAndRelaunchChecksAppBundle() throws {
        let suiteName = "runtime-perm-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = BridgeAppModel(
            settings: AppSettings(defaults: defaults),
            permissionSnapshotProvider: {
                HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
            }
        )
        model.connectionStatus = LocalizedMessage("bluetooth.status.permission_denied")
        model.hidStatus = LocalizedMessage("button_mapping.error.not_permitted")
        model.hidFilterStartFailed = true
        model.refreshRuntimePermissionDiagnosis(trigger: "unit_test", bluetoothGranted: true)

        #expect(
            model.runtimePermissionIssue == .permissionDesynced(
                signals: ["bluetooth_unauthorized", "hid_open_not_permitted", "hid_filter_start_failed"]
            )
        )

        model.connectionStatus = LocalizedMessage("connection.status.connected_to_device")
        model.hidStatus = LocalizedMessage("button_mapping.status.connected")
        model.hidFilterStartFailed = false
        model.refreshRuntimePermissionDiagnosis(trigger: "unit_test_clear", bluetoothGranted: true)
        #expect(model.runtimePermissionIssue == nil)

        let tempAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteBuddyTest-\(UUID().uuidString).app")
        #expect(!BridgeAppModel.canRelaunchAppBundle(tempAppURL))
        try FileManager.default.createDirectory(at: tempAppURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempAppURL) }
        #expect(BridgeAppModel.canRelaunchAppBundle(tempAppURL))
        #expect(!BridgeAppModel.canRelaunchAppBundle(FileManager.default.temporaryDirectory))
    }

    @Test func settingsDiagnosticSnapshotIncludesRuntimePermissionFields() {
        let snapshot = SettingsDiagnosticSnapshot(
            appVersion: "1.0",
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            runtimeLogAvailable: true,
            runtimePermissionIssue: "permission_desynced(bluetooth_unauthorized)",
            connectionStatusKey: "bluetooth.status.permission_denied",
            hidStatusKey: "button_mapping.error.not_permitted"
        )
        let summary = snapshot.summary
        #expect(summary.contains("permission_desynced(bluetooth_unauthorized)"))
        #expect(summary.contains("connection_status: \"bluetooth.status.permission_denied\""))
        #expect(summary.contains("hid_status: \"button_mapping.error.not_permitted\""))
    }

    @Test func newPermissionAndDiagnosticLocalizationKeysExistInEnglishAndChinese() throws {
        let suiteName = "locale-runtime-perm-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalizationStore(settings: AppSettings(defaults: defaults))

        let keys = [
            "button_mapping.error.not_permitted",
            "permission.desync.banner.title",
            "permission.desync.banner.detail",
            "permission.desync.action.restart",
            "permission.desync.action.open_settings",
            "onboarding.recovery.permission.desynced.title",
            "onboarding.recovery.permission.desynced.detail",
            "onboarding.recovery.permission.desynced.action",
            "onboarding.recovery.permission.desynced.open_settings",
            "onboarding.remote.permission_desync.title",
            "onboarding.remote.permission_desync.detail",
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
