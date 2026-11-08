import AppKit
import Foundation
import IOKit.hidsystem

enum ButtonTrigger: String, CaseIterable, Codable, Identifiable {
    case singleClick
    case doubleClick
    case longPress

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .singleClick: return localization.text("trigger.single_click")
        case .doubleClick: return localization.text("trigger.double_click")
        case .longPress: return localization.text("trigger.long_press")
        }
    }
}

struct ConfiguredButtonAction: Codable, Equatable {
    var action: ButtonAction
    var shortcut: CustomKeyboardShortcut?
    var applicationProfileID: UUID?

    init(
        action: ButtonAction,
        shortcut: CustomKeyboardShortcut?,
        applicationProfileID: UUID? = nil
    ) {
        self.action = action
        self.shortcut = shortcut
        self.applicationProfileID = applicationProfileID
    }

    static let disabled = ConfiguredButtonAction(action: .disabled, shortcut: nil)
}


enum ButtonActionCategory: String, CaseIterable, Identifiable {
    case basicKeys
    case systemAndMedia
    case custom
    case commonPhrases
    case applications

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .basicKeys: return "button_mapping.action_group.basic_keys"
        case .systemAndMedia: return "button_mapping.action_group.system_and_media"
        case .custom: return "button_mapping.action_group.custom"
        case .commonPhrases: return "common_phrases.title"
        case .applications: return "button_mapping.action_group.applications"
        }
    }
}

enum ButtonAction: String, CaseIterable, Codable, Identifiable {
    case disabled
    case escape
    case returnKey
    case commandReturn
    case shiftReturn
    case commandCopy
    case commandPaste
    case commandClose
    case commandQuit
    case commandCut
    case commandSelectAll
    case commandUndo
    case commandRedo
    case commandFind
    case commandSave
    case commandDelete
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case scrollUp
    case scrollDown
    case deleteBackward
    case showDesktop
    case contextMenu
    case appSwitcher
    case volumeUp
    case volumeDown
    case volumeMute
    case playPause
    case previousCommandLeft
    case nextCommandRight
    case customShortcut
    case repeatSingleClick
    case focusInput
    case openCustomApplication
    case toggleLongRecording
    case openCommonPhrases
    case openRemoteBuddy
    case openCodex
    case openClaude
    case openCmux
    case openWeChat
    case openCursor
    case openXcode
    case openSlack
    case openWeCom
    case openNeteaseMusic
    case openChrome
    case openSafari
    case openZed

    var id: String { rawValue }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .disabled: return localization.text("action.disabled")
        case .repeatSingleClick: return localization.text("action.repeat_single_click")
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .commandReturn: return "Command-Return"
        case .shiftReturn: return "Shift-Return"
        case .commandCopy: return "Command-C"
        case .commandPaste: return "Command-V"
        case .commandClose: return "Command-W"
        case .commandQuit: return "Command-Q"
        case .commandCut: return "Command-X"
        case .commandSelectAll: return "Command-A"
        case .commandUndo: return "Command-Z"
        case .commandRedo: return "Command-Shift-Z"
        case .commandFind: return "Command-F"
        case .commandSave: return "Command-S"
        case .commandDelete: return localization.text("action.command_delete")
        case .arrowUp: return localization.text("action.arrow_up")
        case .arrowDown: return localization.text("action.arrow_down")
        case .arrowLeft: return localization.text("action.arrow_left")
        case .arrowRight: return localization.text("action.arrow_right")
        case .scrollUp: return localization.text("action.scroll_up")
        case .scrollDown: return localization.text("action.scroll_down")
        case .deleteBackward: return localization.text("action.delete_backspace")
        case .showDesktop: return localization.text("action.show_desktop")
        case .contextMenu: return localization.text("action.context_menu")
        case .appSwitcher: return "Command-Tab"
        case .volumeUp: return localization.text("action.system_volume_up")
        case .volumeDown: return localization.text("action.system_volume_down")
        case .volumeMute: return localization.text("action.system_mute")
        case .playPause: return localization.text("action.play_pause")
        case .previousCommandLeft: return localization.text("action.previous_command_left")
        case .nextCommandRight: return localization.text("action.next_command_right")
        case .customShortcut: return localization.text("action.custom_shortcut")
        case .focusInput: return localization.text("action.focus_input")
        case .openCustomApplication: return localization.text("action.open_custom_application")
        case .openCommonPhrases: return localization.text("action.open_common_phrases")
        case .toggleLongRecording: return localization.text("action.toggle_long_recording")
        case .openRemoteBuddy: return localization.text("action.open_remote_mic")
        case .openCodex: return localization.text("action.open_codex")
        case .openClaude: return localization.text("action.open_claude")
        case .openCmux: return localization.text("action.open_cmux")
        case .openWeChat: return localization.text("action.open_wechat")
        case .openCursor: return localization.text("action.open_cursor")
        case .openXcode: return localization.text("action.open_xcode")
        case .openSlack: return localization.text("action.open_slack")
        case .openWeCom: return localization.text("action.open_wecom")
        case .openNeteaseMusic: return localization.text("action.open_netease_music")
        case .openChrome: return localization.text("action.open_chrome")
        case .openSafari: return localization.text("action.open_safari")
        case .openZed: return localization.text("action.open_zed")
        }
    }

    var presetApplication: PresetApplication? {
        switch self {
        case .openRemoteBuddy: return .remoteMic
        case .openCodex: return .codex
        case .openClaude: return .claude
        case .openCmux: return .cmux
        case .openWeChat: return .weChat
        case .openCursor: return .cursor
        case .openXcode: return .xcode
        case .openSlack: return .slack
        case .openWeCom: return .weCom
        case .openNeteaseMusic: return .neteaseMusic
        case .openChrome: return .chrome
        case .openSafari: return .safari
        case .openZed: return .zed
        default: return nil
        }
    }

    var category: ButtonActionCategory {
        if presetApplication != nil { return .applications }
        switch self {
        case .disabled, .escape, .returnKey, .commandReturn, .shiftReturn, .commandCopy,
             .commandPaste, .commandClose, .commandQuit, .commandCut, .commandSelectAll,
             .commandUndo, .commandRedo, .commandFind, .commandSave, .commandDelete,
             .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .scrollUp, .scrollDown,
             .deleteBackward:
            return .basicKeys
        case .showDesktop, .contextMenu, .appSwitcher, .volumeUp, .volumeDown, .volumeMute,
             .playPause, .previousCommandLeft, .nextCommandRight, .toggleLongRecording:
            return .systemAndMedia
        case .customShortcut, .focusInput, .repeatSingleClick:
            return .custom
        case .openCommonPhrases:
            return .commonPhrases
        case .openCustomApplication:
            return .applications
        case .openRemoteBuddy, .openCodex, .openClaude, .openCmux, .openWeChat, .openCursor,
             .openXcode, .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openSafari,
             .openZed:
            return .applications
        }
    }

    var isAppInternal: Bool {
        self == .toggleLongRecording || self == .openCommonPhrases
    }

    func isEnabled(experimentalContinuousRecordingEnabled: Bool) -> Bool {
        self != .toggleLongRecording || experimentalContinuousRecordingEnabled
    }

    static func pickerActions(
        installedBundleIdentifiers: Set<String>,
        current: ButtonAction,
        experimentalContinuousRecordingEnabled: Bool
    ) -> [ButtonAction] {
        let actions = allCases.filter { action in
            guard action.isEnabled(
                experimentalContinuousRecordingEnabled: experimentalContinuousRecordingEnabled
            ) else {
                return action == current
            }
            guard let application = action.presetApplication else { return true }
            return installedBundleIdentifiers.contains(application.bundleIdentifier) || action == current
        }
        return actions.filter { $0 != .openCustomApplication } +
            (actions.contains(.openCustomApplication) ? [.openCustomApplication] : [])
    }
}

