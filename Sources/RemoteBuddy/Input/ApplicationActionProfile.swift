import AppKit
import Foundation
import IOKit.hidsystem

enum CustomApplicationFocusStrategy: String, Codable, CaseIterable, Identifiable {
    case none
    case keyboardShortcut
    case recordedAccessibility

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .none: return localization.text("custom_application.focus.none")
        case .keyboardShortcut: return localization.text("custom_application.focus.shortcut")
        case .recordedAccessibility: return localization.text("custom_application.focus.recorded")
        }
    }
}

struct NormalizedAccessibilityFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AccessibilityFocusTarget: Codable, Equatable {
    let role: String
    let identifier: String
    let title: String
    let description: String
    let help: String
    let placeholder: String
    let context: String
    let windowTitle: String
    let normalizedFrame: NormalizedAccessibilityFrame?
}

struct CustomApplicationProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    var bundleIdentifier: String
    var applicationPath: String
    var focusStrategy: CustomApplicationFocusStrategy
    var focusShortcut: CustomKeyboardShortcut?
    var accessibilityTarget: AccessibilityFocusTarget?

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String,
        applicationPath: String,
        focusStrategy: CustomApplicationFocusStrategy = .none,
        focusShortcut: CustomKeyboardShortcut? = nil,
        accessibilityTarget: AccessibilityFocusTarget? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
        self.focusStrategy = focusStrategy
        self.focusShortcut = focusShortcut
        self.accessibilityTarget = accessibilityTarget
    }
}

enum ApplicationFocusStrategy: Equatable {
    case accessibilityComposer
    case cmuxSurfaceAPI
}

enum PresetApplication: String, CaseIterable, Identifiable {
    case remoteMic
    case codex
    case claude
    case cmux
    case weChat
    case cursor
    case xcode
    case slack
    case weCom
    case neteaseMusic
    case chrome
    case safari
    case zed

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .remoteMic: return localization.text("app.name")
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cmux: return "cmux"
        case .weChat: return localization.text("application.wechat")
        case .cursor: return "Cursor"
        case .xcode: return "Xcode"
        case .slack: return "Slack"
        case .weCom: return localization.text("application.wecom")
        case .neteaseMusic: return localization.text("application.netease_music")
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .zed: return "Zed"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .remoteMic: return "com.zfdang.RemoteBuddy"
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .cmux: return "com.cmuxterm.app"
        case .weChat: return "com.tencent.xinWeChat"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .xcode: return "com.apple.dt.Xcode"
        case .slack: return "com.tinyspeck.slackmacgap"
        case .weCom: return "com.tencent.WeWorkMac"
        case .neteaseMusic: return "com.netease.163music"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .zed: return "dev.zed.Zed"
        }
    }

    var focusStrategy: ApplicationFocusStrategy? {
        switch self {
        case .codex, .claude: return .accessibilityComposer
        case .cmux: return .cmuxSurfaceAPI
        default: return nil
        }
    }

    static var installedBundleIdentifiers: Set<String> {
        var identifiers: Set<String> = [remoteMic.bundleIdentifier]
        identifiers.formUnion(allCases.compactMap { application in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier)
                .map { _ in application.bundleIdentifier }
        })
        return identifiers
    }
}

