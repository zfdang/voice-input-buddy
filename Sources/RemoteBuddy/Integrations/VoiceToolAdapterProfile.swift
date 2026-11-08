import Foundation

enum OnboardingVoiceTool: String, CaseIterable, Codable, Identifiable {
    case unselected
    case weixin
    case doubao
    case bageshuo
    case typeless
    case voicecursor
    case macosDictation = "macos_dictation"
    case other

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.voice_tool.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.voice_tool.\(rawValue).detail"
    }

    var preferredInputSourceID: String? {
        switch self {
        case .doubao:
            return "com.bytedance.inputmethod.doubaoime.pinyin"
        case .weixin:
            return "com.tencent.inputmethod.wetype.pinyin"
        case .unselected, .bageshuo, .typeless, .voicecursor, .macosDictation, .other:
            return nil
        }
    }

    var applicationBundleIdentifier: String? {
        switch self {
        case .bageshuo:
            return "com.bageshuo"
        case .typeless:
            return "now.typeless.desktop"
        case .unselected, .doubao, .weixin, .voicecursor, .macosDictation, .other:
            return nil
        }
    }

    var requiresFunctionKeySetup: Bool {
        preferredInputSourceID != nil
    }

    /// Fn taps that start one voice session. macOS Dictation uses "Press 🌐 Twice"
    /// to start and one Fn press to stop.
    var functionKeyStartTapCount: Int {
        self == .macosDictation ? 2 : 1
    }
}


struct VoiceToolAdapterProfile: Equatable {
    let tool: OnboardingVoiceTool
    let supportedModes: Set<VoiceGestureMode>
    let defaultShortcutByMode: [VoiceGestureMode: VoiceKeyMode]
    let recommendedMode: VoiceGestureMode?
    let installationProbe: VoiceToolInstallationProbe
    let evidenceState: VoiceToolEvidenceState

    static func profile(for tool: OnboardingVoiceTool) -> Self {
        switch tool {
        case .weixin:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .function, .toggle: .rightCommand],
                recommendedMode: .hold,
                installationProbe: .inputSource,
                evidenceState: .pending
            )
        case .doubao:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                defaultShortcutByMode: [.hold: .function, .toggle: .rightCommand],
                recommendedMode: .hold,
                installationProbe: .inputSource,
                evidenceState: .verified
            )
        case .bageshuo:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .applicationBundle,
                evidenceState: .verified
            )
        case .typeless:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .applicationBundle,
                evidenceState: .verified
            )
        case .macosDictation:
            return Self(
                tool: tool,
                supportedModes: [.toggle],
                defaultShortcutByMode: [.toggle: .function],
                recommendedMode: .toggle,
                installationProbe: .none,
                evidenceState: .pending
            )
        case .voicecursor, .other:
            return Self(
                tool: tool,
                supportedModes: [.hold, .toggle],
                // The third-party tool remains unobserved; Fn is only the
                // temporary Onboarding trigger and still requires the user's
                // real voice-text confirmation before it can be committed.
                defaultShortcutByMode: [.hold: .function, .toggle: .function],
                recommendedMode: .hold,
                installationProbe: .none,
                evidenceState: .unknown
            )
        case .unselected:
            return Self(
                tool: tool,
                supportedModes: [],
                defaultShortcutByMode: [:],
                recommendedMode: nil,
                installationProbe: .none,
                evidenceState: .unknown
            )
        }
    }
}

