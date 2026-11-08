import Foundation

/// 语音手势模式。`toggle` 为本产品默认；`hold` 保留给习惯按住说话的用户。
enum ChromecastVoiceMode: String, CaseIterable, Codable, Identifiable {
    case toggle
    case hold

    var id: String { rawValue }

    static let productDefault: ChromecastVoiceMode = .toggle

    var localizationKey: String {
        switch self {
        case .toggle: return "chromecast.mode.toggle"
        case .hold: return "chromecast.mode.hold"
        }
    }

    var detailLocalizationKey: String {
        switch self {
        case .toggle: return "chromecast.mode.toggle.detail"
        case .hold: return "chromecast.mode.hold.detail"
        }
    }
}
