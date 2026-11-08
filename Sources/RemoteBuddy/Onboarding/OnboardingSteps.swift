import Foundation

enum OnboardingStep: String, CaseIterable, Codable {
    case voiceTool
    case remoteAvailability
    case permissions
    case remote
    case audio
    case voiceTest
    case controls
    case complete

    /// Match the main navigation: environment, connection, buttons, then integration.
    static let visibleCases: [Self] = [
        .permissions, .remoteAvailability, .remote, .controls, .audio, .voiceTool,
        .voiceTest, .complete,
    ]

    var requiresRuntime: Bool {
        switch self {
        case .remoteAvailability:
            return false
        case .permissions, .remote, .audio, .voiceTool, .voiceTest, .controls, .complete:
            return true
        }
    }

    var previous: OnboardingStep? {
        let step = self
        guard let index = Self.visibleCases.firstIndex(of: step), index > 0 else { return nil }
        return Self.visibleCases[index - 1]
    }

    var next: OnboardingStep? {
        let step = self
        guard let index = Self.visibleCases.firstIndex(of: step), index + 1 < Self.visibleCases.count else {
            return nil
        }
        return Self.visibleCases[index + 1]
    }
}

enum OnboardingPurpose: String, Codable {
    case initialSetup
    case addDevice
    case integration

    var steps: [OnboardingStep] {
        switch self {
        case .initialSetup: return OnboardingStep.visibleCases
        case .addDevice: return [.remoteAvailability, .remote, .controls, .complete]
        case .integration: return [.voiceTool, .voiceTest, .complete]
        }
    }

    func previousStep(before step: OnboardingStep) -> OnboardingStep? {
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    func nextStep(after step: OnboardingStep) -> OnboardingStep? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    func progress(at step: OnboardingStep) -> Double {
        guard let index = steps.firstIndex(of: step), steps.count > 1 else { return 0 }
        return Double(index) / Double(steps.count - 1)
    }
}

enum OnboardingRemoteAvailability: String, CaseIterable, Codable, Identifiable {
    case unselected
    case hasRemote = "has_remote"
    case noRemote = "no_remote"

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.remote_availability.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.remote_availability.\(rawValue).detail"
    }
}

enum OnboardingControlMethod: String, CaseIterable, Codable, Identifiable {
    case unselected
    case physicalRemote = "physical_remote"

    var id: String { rawValue }

    var titleKey: String {
        "onboarding.control_method.\(rawValue).title"
    }

    var detailKey: String {
        "onboarding.control_method.\(rawValue).detail"
    }

    var requiresBluetoothPermission: Bool {
        self != .unselected
    }

    var requiresInputMonitoringPermission: Bool {
        self != .unselected
    }

}


enum OnboardingControlSource: String, CaseIterable, Codable, Identifiable {
    case unselected
    case xiaomiRemote = "xiaomi_remote"
    case siriRemote = "siri_remote"
    case chromecastRemote = "chromecast_remote"

    var id: String { rawValue }

    var titleKey: String { "onboarding.control_source.\(rawValue).title" }
    var detailKey: String { "onboarding.control_source.\(rawValue).detail" }

    var supportedGestureModes: Set<VoiceGestureMode> {
        switch self {
        case .unselected:
            return []
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return [.hold]
        }
    }

    var controlMethod: OnboardingControlMethod {
        switch self {
        case .xiaomiRemote, .siriRemote, .chromecastRemote:
            return .physicalRemote
        case .unselected:
            return .unselected
        }
    }

    static func defaultSource(for method: OnboardingControlMethod) -> Self {
        switch method {
        case .physicalRemote: return .xiaomiRemote
        case .unselected: return .unselected
        }
    }
}

/// During the ordinary-button check, Onboarding observes fresh input events but must
/// never execute mappings that the user configured before starting (or rerunning) the flow.

enum OnboardingAppleRemoteGeneration: String, Codable, CaseIterable, Identifiable {
    case generation6 = "generation_6"
    case generation7 = "generation_7"

    var id: String { rawValue }

    var titleKey: String { "onboarding.control_source.apple_remote.\(rawValue).title" }

    var model: RemoteModel {
        switch self {
        case .generation6: return .appleSiriRemoteA2540
        case .generation7: return .appleSiriRemoteA2854
        }
    }
}

