import Foundation

enum VoiceGestureMode: String, CaseIterable, Codable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }
}

enum VoiceToolBindingSource: String, Codable {
    case documentedDefault = "documented_default"
    case userLearned = "user_learned"
    case manuallyConfirmed = "manually_confirmed"
}

enum VoiceToolBindingValidationState: String, Codable {
    case staged
    case verified
    case failed
}

enum VoiceToolEvidenceState: String, Codable {
    case verified
    case pending
    case stale
    case unknown
}

enum VoiceToolInstallationProbe: String, Codable {
    case inputSource
    case applicationBundle
    case none
}


struct VoiceToolUserBinding: Codable, Equatable {
    let tool: OnboardingVoiceTool
    let shortcut: VoiceKeyMode
    let gestureMode: VoiceGestureMode
    let source: VoiceToolBindingSource
    var validationState: VoiceToolBindingValidationState
    var verifiedToolVersion: String?
    var verifiedAt: Date?

    func verified(at date: Date = Date()) -> Self {
        var copy = self
        copy.validationState = .verified
        copy.verifiedAt = date
        return copy
    }
}

enum OnboardingVoiceBindingPreference: String, Codable {
    case documentedDefault = "documented_default"
    case learnCurrent = "learn_current"
}

