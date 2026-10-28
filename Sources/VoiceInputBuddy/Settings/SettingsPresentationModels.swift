import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case connection
    case integration
    case mapping
    case commonPhrases
    case permissions
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .connection: return "settings.section.connection"
        case .integration: return "settings.section.integration"
        case .mapping: return "settings.section.buttons"
        case .commonPhrases: return "common_phrases.title"
        case .permissions: return "settings.section.permissions"
        case .about: return "settings.section.settings"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "link"
        case .integration: return "text.bubble"
        case .mapping: return "keyboard"
        case .commonPhrases: return "text.quote"
        case .permissions: return "shield.lefthalf.filled"
        case .about: return "gearshape"
        }
    }
}

enum SettingsPermissionKind {
    case bluetooth
    case inputMonitoring
    case accessibility
}

struct SystemPermissionOverrides: Equatable, Sendable {
    var bluetooth: CBManagerAuthorization?
    var inputMonitoring: Bool?
    var accessibility: Bool?

    static let allGranted = SystemPermissionOverrides(
        bluetooth: .allowedAlways,
        inputMonitoring: true,
        accessibility: true
    )
}

enum SettingsPermissionAction: Equatable {
    case request
    case openSystemSettings(String)

    var titleKey: String {
        switch self {
        case .request:
            "permission.action.request"
        case .openSystemSettings:
            "permission.action.open_settings"
        }
    }
}

struct SettingsDiagnosticSnapshot: Equatable {
    let appVersion: String
    let bluetoothGranted: Bool
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let runtimeLogAvailable: Bool

    var summary: String {
        [
            "VoiceInputBuddy settings diagnostics",
            "app_version=\(appVersion)",
            "permission_bluetooth=\(bluetoothGranted)",
            "permission_input_monitoring=\(inputMonitoringGranted)",
            "permission_accessibility=\(accessibilityGranted)",
            "runtime_log_available=\(runtimeLogAvailable)",
        ].joined(separator: "\n")
    }

    var auditLog: String {
        "SETTINGS DIAGNOSTICS copied permission_bluetooth=\(bluetoothGranted) " +
            "permission_input_monitoring=\(inputMonitoringGranted) " +
            "permission_accessibility=\(accessibilityGranted)"
    }
}

enum RemoteBatteryPresentationPolicy {
    static func shouldShowBattery(
        model: RemoteModel,
        level: Int?,
        powerState: RemotePowerState?
    ) -> Bool {
        // Chromecast 不宣告电池能力，界面不得显示永远是「未知」的电量位。
        guard !model.isChromecastRemote else { return false }
        guard model.isAppleSiriRemote else { return true }
        guard level == nil else { return true }
        return powerState == .charging || powerState == .externalPower
    }
}

enum SettingsPageBehavior {
    static let sidebarWidth: CGFloat = 108
    static let sidebarDividerWidth: CGFloat = 1
    static var contentLeadingInset: CGFloat { sidebarWidth + sidebarDividerWidth }

    static let sidebarTopDragHeight: CGFloat = 5

    static let sidebarSectionOrder: [SettingsSection] = [
        .connection,
        .mapping,
        .integration,
        .permissions,
        .about,
    ]

    static func sidebarSections() -> [SettingsSection] {
        sidebarSectionOrder
    }

    static func initialSection(requestedSection: SettingsSection?) -> SettingsSection {
        requestedSection ?? sidebarSectionOrder.first ?? .about
    }

    @MainActor static func beginDeviceSetup(settings: AppSettings) {
        settings.allowForgottenRemotesForSetup()
        settings.preserveCompletedOnboarding()
        settings.onboardingPurpose = settings.canDismissOnboarding ? .addDevice : .initialSetup
        settings.discardOnboardingVoiceTrial()
        settings.onboardingDevice = nil
        settings.onboardingControlSource = .unselected
        settings.onboardingRemoteAvailability = .unselected
        settings.onboardingCompletedVersion = 0
        settings.onboardingStep = .remoteAvailability
    }

    @MainActor static func beginIntegrationSetup(tool: OnboardingVoiceTool, settings: AppSettings) {
        settings.preserveCompletedOnboarding()
        settings.discardOnboardingVoiceTrial()
        settings.onboardingPurpose = settings.canDismissOnboarding ? .integration : .initialSetup
        settings.onboardingCompletedVersion = 0
        settings.setOnboardingVoiceTool(tool)
        if !tool.supportsHoldVoiceRecording {
            settings.voiceFnTapModeEnabled = true
        }
        settings.setOnboardingStep(settings.onboardingPurpose.steps[0])
    }

    static func visibleSection(for requestedSection: SettingsSection) -> SettingsSection {
        requestedSection
    }

    static func showsUpdateBadge(
        for section: SettingsSection,
        hasUnseenUpdate: Bool
    ) -> Bool {
        section == .about && hasUnseenUpdate
    }

    static func marksUpdateAsSeen(whenSelecting section: SettingsSection) -> Bool {
        section == .about
    }

    static func permissionAction(
        for permission: SettingsPermissionKind,
        isGranted: Bool
    ) -> SettingsPermissionAction {
        switch permission {
        case .bluetooth:
            .openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .inputMonitoring:
            isGranted
                ? .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                )
                : .request
        case .accessibility:
            isGranted
                ? .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                : .request
        }
    }

    static func perform(
        _ action: SettingsPermissionAction,
        requestPermission: () -> Void,
        openSystemSettings: (String) -> Void
    ) {
        switch action {
        case .request:
            requestPermission()
        case let .openSystemSettings(url):
            openSystemSettings(url)
        }
    }

    static func copyDiagnosticSummary(
        _ snapshot: SettingsDiagnosticSnapshot,
        writeToPasteboard: (String) -> Void,
        writeAuditLog: (String) -> Void
    ) {
        writeToPasteboard(snapshot.summary)
        writeAuditLog(snapshot.auditLog)
    }
}


enum PermissionVisualState {
    case granted
    case pending

    @MainActor
    func title(using localization: LocalizationStore) -> String {
        switch self {
        case .granted: return localization.text("permission.status.enabled")
        case .pending: return localization.text("permission.status.pending")
        }
    }

    var tint: Color {
        switch self {
        case .granted: return .green
        case .pending: return .orange
        }
    }
}

struct ShortcutEditingTarget: Identifiable, Equatable {
    let button: RemoteButton
    let trigger: ButtonTrigger

    var id: String { "\(button.rawValue)-\(trigger.rawValue)" }
}

struct ShortcutCaptureFeedback: Equatable {
    enum Result: Equatable {
        case succeeded
        case failed(ShortcutCaptureStartFailure)
    }

    let contextID: String
    let result: Result
}

enum CustomApplicationLearningState: Equatable {
    case recording
    case succeeded
    case failed
    case applicationMissing
    case openFailed

    var messageKey: String {
        switch self {
        case .recording: return "custom_application.accessibility.learning"
        case .succeeded: return "custom_application.accessibility.learn_succeeded"
        case .failed: return "custom_application.accessibility.learn_failed"
        case .applicationMissing: return "custom_application.error.not_installed"
        case .openFailed: return "custom_application.error.open_failed"
        }
    }

    var tint: Color {
        switch self {
        case .recording: return .orange
        case .succeeded: return .green
        case .failed, .applicationMissing, .openFailed: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .recording: return "timer"
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .applicationMissing, .openFailed: return "exclamationmark.triangle.fill"
        }
    }
}

struct ConfigurationStatus {
    let message: LocalizedMessage
    let tint: Color
    let systemImage: String
}

enum MappingActionFilter: String, CaseIterable, Identifiable {
    case all
    case basicKeys
    case systemAndMedia
    case custom
    case commonPhrases
    case applications

    var id: String { rawValue }

    static var visibleCases: [Self] {
        [.basicKeys, .systemAndMedia, .custom, .commonPhrases, .applications]
    }

    var localizationKey: String {
        switch self {
        case .all: return "button_mapping.action_filter.all"
        case .basicKeys: return ButtonActionCategory.basicKeys.localizationKey
        case .systemAndMedia: return ButtonActionCategory.systemAndMedia.localizationKey
        case .custom: return ButtonActionCategory.custom.localizationKey
        case .commonPhrases: return ButtonActionCategory.commonPhrases.localizationKey
        case .applications: return ButtonActionCategory.applications.localizationKey
        }
    }

    func includes(_ category: ButtonActionCategory) -> Bool {
        switch self {
        case .all:
            return true
        case .basicKeys:
            return category == .basicKeys
        case .systemAndMedia:
            return category == .systemAndMedia
        case .custom:
            return category == .custom
        case .commonPhrases:
            return category == .commonPhrases
        case .applications:
            return category == .applications
        }
    }
}

enum MappingSelectionPolicy {
    static func selection(
        current: RemoteButton,
        activeButtons: Set<RemoteButton>,
        isLocked: Bool
    ) -> RemoteButton {
        guard !isLocked else { return current }
        return RemoteButton.allCases.first(where: activeButtons.contains) ?? current
    }
}

enum MappingPermissionPolicy {
    static func requiresPrompt(
        enabled: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        enabled && (!inputMonitoringGranted || !accessibilityGranted)
    }
}
