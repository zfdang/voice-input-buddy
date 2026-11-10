import Foundation

struct OnboardingVoiceConfigurationSnapshot: Codable {
    let voiceKeyMode: VoiceKeyMode
    let voiceFnTapModeEnabled: Bool
    let chromecastVoiceMode: ChromecastVoiceMode
}
