import Foundation

enum VoiceKeyCompatibilityWarning: Equatable {
    case karabiner
    case otherInputTool

    var messageKey: String {
        switch self {
        case .karabiner:
            return "connection.voice_key_compatibility.karabiner_detail"
        case .otherInputTool:
            return "connection.voice_key_compatibility.other_detail"
        }
    }
}
