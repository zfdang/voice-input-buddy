import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Accessibility frame scoring")
struct AccessibilityFrameScoringTests {
    private let candidate = KeyboardInjector.AccessibilityTextCandidate(
        role: "AXTextArea", identifier: "composer", title: "", description: "",
        help: "", placeholder: "", context: "",
        frame: CGRect(x: 10, y: 20, width: 50, height: 20), enabled: true)
    private let window = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func target(_ frame: NormalizedAccessibilityFrame?) -> AccessibilityFocusTarget {
        .init(role: "AXTextArea", identifier: "composer", title: "", description: "",
            help: "", placeholder: "", context: "", windowTitle: "", normalizedFrame: frame)
    }

    @Test(arguments: [1e300, -1e300, Double.greatestFiniteMagnitude])
    func importedExtremeFramesCannotCrashSemanticMatching(coordinate: Double) throws {
        let name = "frame-scoring-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let profile = CustomApplicationProfile(displayName: "Example", bundleIdentifier: "com.example.editor",
            applicationPath: "", focusStrategy: .recordedAccessibility,
            accessibilityTarget: target(.init(x: coordinate, y: coordinate, width: 0.5, height: 0.2)))
        settings.customApplicationProfiles = [profile]
        let exported = try settings.exportedConfigurationData()
        try settings.importConfiguration(from: exported)
        let imported = try #require(settings.customApplicationProfiles.first?.accessibilityTarget)
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(candidate,
            target: imported, windowTitle: "", windowFrame: window) == 500)
    }

    @Test func normalFrameRankingRetainsItsGeometryBonus() {
        let matching = target(.init(x: 0.1, y: 0.2, width: 0.5, height: 0.2))
        let distant = target(.init(x: 10, y: 10, width: 0.5, height: 0.2))
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(candidate,
            target: matching, windowTitle: "", windowFrame: window) == 620)
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(candidate,
            target: distant, windowTitle: "", windowFrame: window) == 500)
    }
}
