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
    case general
    case applicationIntegration
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .connection: return "settings.section.connection"
        case .integration: return "settings.section.integration"
        case .mapping: return "settings.section.buttons"
        case .commonPhrases: return "common_phrases.title"
        case .permissions: return "settings.section.permissions"
        case .general: return "settings.section.general"
        case .applicationIntegration: return "application_integration.title"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "appletvremote.gen4"
        case .integration: return "waveform"
        case .mapping: return "keyboard"
        case .commonPhrases: return "text.quote"
        case .permissions: return "lock.shield"
        case .general: return "slider.horizontal.3"
        case .applicationIntegration: return "cursorarrow.click"
        case .about: return "info.circle"
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
    let appBuild: String
    let macosVersion: String
    let architecture: String
    let isRosetta: Bool
    let bluetoothGranted: Bool
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let remoteConnected: Bool
    let remoteModel: String
    let virtualMicrophoneReady: Bool
    let audioOutputReady: Bool
    let voiceTool: String
    let voiceKeyMode: String
    let runtimeLogAvailable: Bool
    let runtimeLogPath: String
    let runtimeLogSizeBytes: Int64?
    let runtimePermissionIssue: String
    let runtimePermissionIssueUpdatedAt: Date?
    let runtimePermissionDiagnosisTrigger: String
    let connectionStatusKey: String
    let hidStatusKey: String
    let generatedAt: Date

    init(
        appVersion: String,
        appBuild: String = "1",
        macosVersion: String = FirstUseDiagnosticSnapshot.systemVersion,
        architecture: String = FirstUseDiagnosticSnapshot.architecture,
        isRosetta: Bool = FirstUseDiagnosticSnapshot.runningUnderRosetta == "true",
        bluetoothGranted: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        remoteConnected: Bool = false,
        remoteModel: String = "none",
        virtualMicrophoneReady: Bool = false,
        audioOutputReady: Bool = false,
        voiceTool: String = "unselected",
        voiceKeyMode: String = "press_and_hold",
        runtimeLogAvailable: Bool,
        runtimeLogPath: String = SettingsDiagnosticSnapshot.sanitizePath(AppLogger.shared.logURL.path),
        runtimeLogSizeBytes: Int64? = nil,
        runtimePermissionIssue: String = "none",
        runtimePermissionIssueUpdatedAt: Date? = nil,
        runtimePermissionDiagnosisTrigger: String = "none",
        connectionStatusKey: String = "unknown",
        hidStatusKey: String = "unknown",
        generatedAt: Date = Date()
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macosVersion = macosVersion
        self.architecture = architecture
        self.isRosetta = isRosetta
        self.bluetoothGranted = bluetoothGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
        self.remoteConnected = remoteConnected
        self.remoteModel = remoteModel
        self.virtualMicrophoneReady = virtualMicrophoneReady
        self.audioOutputReady = audioOutputReady
        self.voiceTool = voiceTool
        self.voiceKeyMode = voiceKeyMode
        self.runtimeLogAvailable = runtimeLogAvailable
        self.runtimeLogPath = Self.sanitizePath(runtimeLogPath)
        self.runtimeLogSizeBytes = runtimeLogSizeBytes
        self.runtimePermissionIssue = runtimePermissionIssue
        self.runtimePermissionIssueUpdatedAt = runtimePermissionIssueUpdatedAt
        self.runtimePermissionDiagnosisTrigger = runtimePermissionDiagnosisTrigger
        self.connectionStatusKey = connectionStatusKey
        self.hidStatusKey = hidStatusKey
        self.generatedAt = generatedAt
    }

    static func sanitizePath(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let normalizedHome = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !normalizedHome.isEmpty else { return text }
        var redacted = text.replacingOccurrences(of: normalizedHome + "/", with: "~/")
        if redacted == normalizedHome {
            return "~"
        }
        redacted = redacted.replacingOccurrences(of: "=\(normalizedHome) ", with: "=~ ")
        if redacted.hasSuffix("=\(normalizedHome)") {
            redacted = String(redacted.dropLast(normalizedHome.count)) + "~"
        }
        return redacted
    }

    var formattedLogSize: String {
        guard let bytes = runtimeLogSizeBytes else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    var summary: String {
        let lines: [String] = [
            "### Remote Buddy 运行环境与诊断信息 / Runtime Diagnostics",
            "- **应用版本 / App Version:** \(appVersion) (Build \(appBuild))",
            "- **系统版本 / macOS:** \(macosVersion) (\(architecture)\(isRosetta ? ", Rosetta" : ""))",
            "- **生成时间 / Generated At:** \(Self.timestamp(generatedAt))",
            "",
            "#### 系统权限状态 / Permissions",
            "- 蓝牙 / Bluetooth: \(bluetoothGranted ? "已授权 (Granted)" : "未授权 (Denied)")",
            "- 输入监控 / Input Monitoring: \(inputMonitoringGranted ? "已授权 (Granted)" : "未授权 (Denied)")",
            "- 辅助功能 / Accessibility: \(accessibilityGranted ? "已授权 (Granted)" : "未授权 (Denied)")",
            "- 运行时权限诊断 / Runtime Issue: \(runtimePermissionIssue)",
            "",
            "#### 设备与驱动 / Devices & Drivers",
            "- 遥控器连接 / Remote Connected: \(remoteConnected ? "已连接 (Yes)" : "未连接 (No)") [\(remoteModel)]",
            "- 虚拟麦克风驱动 / Virtual Mic Driver: \(virtualMicrophoneReady ? "已就绪 (Ready)" : "未就绪 (Not Ready)")",
            "- 音频输出 / Audio Output: \(audioOutputReady ? "已就绪 (Ready)" : "未就绪 (Not Ready)")",
            "",
            "#### 配置与集成 / Configuration",
            "- 语音工具 / Voice Tool: \(voiceTool)",
            "- 按键模式 / Voice Key Mode: \(voiceKeyMode)",
            "",
            "#### 诊断日志 / Runtime Logs",
            "- 日志文件状态 / Log Available: \(runtimeLogAvailable ? "存在 (\(formattedLogSize))" : "未找到 (Not Found)")",
            "- 本地路径 / Log Path: \(runtimeLogPath)",
            "- 隐私承诺 / Privacy Notice: 诊断日志仅保存在本机，永不上传，绝不含语音、转写文本或剪贴板等隐私数据 (Logs stay on this Mac, are never uploaded, and never contain audio, transcripts, or clipboard contents).",
            "",
            "```yaml",
            "# Machine-parseable diagnostics",
            "app_version: \"\(appVersion)\"",
            "app_build: \"\(appBuild)\"",
            "macos_version: \"\(macosVersion)\"",
            "architecture: \"\(architecture)\"",
            "rosetta: \(isRosetta)",
            "permission_bluetooth: \(bluetoothGranted)",
            "permission_input_monitoring: \(inputMonitoringGranted)",
            "permission_accessibility: \(accessibilityGranted)",
            "runtime_permission_issue: \"\(runtimePermissionIssue)\"",
            "runtime_permission_trigger: \"\(runtimePermissionDiagnosisTrigger)\"",
            "runtime_permission_updated_at: \"\(runtimePermissionIssueUpdatedAt.map(Self.timestamp) ?? "none")\"",
            "connection_status: \"\(connectionStatusKey)\"",
            "hid_status: \"\(hidStatusKey)\"",
            "remote_connected: \(remoteConnected)",
            "remote_model: \"\(remoteModel)\"",
            "virtual_microphone: \(virtualMicrophoneReady)",
            "audio_output: \(audioOutputReady)",
            "voice_tool: \"\(voiceTool)\"",
            "voice_key_mode: \"\(voiceKeyMode)\"",
            "runtime_log_available: \(runtimeLogAvailable)",
            "```"
        ]
        return lines.joined(separator: "\n")
    }

    var auditLog: String {
        "SETTINGS DIAGNOSTICS copied app_version=\(appVersion) " +
            "macos=\(macosVersion) arch=\(architecture) " +
            "bluetooth=\(bluetoothGranted) " +
            "input_monitoring=\(inputMonitoringGranted) " +
            "accessibility=\(accessibilityGranted) " +
            "remote_connected=\(remoteConnected) " +
            "remote_model=\(remoteModel)"
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
        .general,
        .permissions,
        .connection,
        .mapping,
        .integration,
        .applicationIntegration,
        .about,
    ]

    static func sidebarSections() -> [SettingsSection] {
        sidebarSectionOrder
    }

    static func initialSection(requestedSection: SettingsSection?) -> SettingsSection {
        requestedSection ?? sidebarSectionOrder.first ?? .about
    }

    @MainActor static func beginDeviceSetup(settings: AppSettings) {
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
        settings.synchronizeOnboardingRemoteWithSelectedProfile()
        settings.preserveCompletedOnboarding()
        settings.discardOnboardingVoiceTrial()
        settings.onboardingPurpose = settings.canDismissOnboarding && settings.onboardingControlSource != .unselected
            ? .integration : .initialSetup
        settings.onboardingCompletedVersion = 0
        settings.setOnboardingVoiceTool(tool)
        if !tool.supportsHoldVoiceRecording {
            settings.voiceFnTapModeEnabled = true
        }
        let start: OnboardingStep = settings.onboardingPurpose == .integration ? .voiceTool
            : (settings.canDismissOnboarding ? .remoteAvailability : .permissions)
        settings.setOnboardingStep(start)
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

enum MappingActionFilter: String, CaseIterable, Identifiable {
    case basicKeys
    case systemAndMedia
    case applications
    case commonPhrases
    case custom

    var id: String { rawValue }

    static var visibleCases: [Self] {
        [.basicKeys, .systemAndMedia, .applications, .commonPhrases, .custom]
    }

    var localizationKey: String {
        switch self {
        case .basicKeys: return ButtonActionCategory.basicKeys.localizationKey
        case .systemAndMedia: return ButtonActionCategory.systemAndMedia.localizationKey
        case .applications: return ButtonActionCategory.applications.localizationKey
        case .commonPhrases: return ButtonActionCategory.commonPhrases.localizationKey
        case .custom: return ButtonActionCategory.custom.localizationKey
        }
    }

    var category: ButtonActionCategory {
        switch self {
        case .basicKeys: return .basicKeys
        case .systemAndMedia: return .systemAndMedia
        case .applications: return .applications
        case .commonPhrases: return .commonPhrases
        case .custom: return .custom
        }
    }

    init(category: ButtonActionCategory) {
        switch category {
        case .basicKeys: self = .basicKeys
        case .systemAndMedia: self = .systemAndMedia
        case .applications: self = .applications
        case .commonPhrases: self = .commonPhrases
        case .custom: self = .custom
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
