/// Product scope, separate from the catalog admitting validated hardware connections.
/// Adapter readiness is separate from allowing a device to be selected for setup.
enum RemoteSetupDevice: String, CaseIterable, Identifiable {
    case xiaomi
    case chromecastG9N9N
    case googleStreamerGY3LE
    case siriRemote

    var id: String { rawValue }
    var titleKey: String { "remote.catalog.\(rawValue).title" }

    /// Selection can precede adapter readiness; connection validation remains mandatory.
    var onboardingSource: OnboardingControlSource? {
        switch self {
        case .xiaomi: return .xiaomiRemote
        case .chromecastG9N9N, .googleStreamerGY3LE: return .chromecastRemote
        case .siriRemote: return nil
        }
    }

    var canStartSetup: Bool { onboardingSource != nil }

    static func device(for source: OnboardingControlSource) -> Self? {
        allCases.first { $0.onboardingSource == source }
    }

    /// Original schematic artwork; not a photograph or evidence of device support.
    var illustrationResource: String {
        switch self {
        case .xiaomi: return "BuddyRemoteIllustration"
        case .chromecastG9N9N: return "ChromecastG9N9NIllustration"
        case .googleStreamerGY3LE: return "GoogleStreamerGY3LEIllustration"
        case .siriRemote: return "SiriRemoteA2854Illustration"
        }
    }

    var icon: String {
        self == .siriRemote ? "appletvremote.gen4.fill" : "antenna.radiowaves.left.and.right"
    }

    /// Google manufacturer model numbers, not player models or seller compatibility labels.
    var googleHardwareModelNumber: String? {
        switch self {
        case .chromecastG9N9N: return "G9N9N"
        case .googleStreamerGY3LE: return "GY3LE"
        case .xiaomi, .siriRemote: return nil
        }
    }
}
