import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Accessibility frame scoring")
@MainActor
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

    @Test func secureFieldsAreRejectedWithoutRelyingOnTheirNames() {
        for (subrole, protectedContent) in [("AXSecureTextField", false), ("", true)] {
            let field = KeyboardInjector.AccessibilityTextCandidate(role: "AXTextField",
                subrole: subrole, protectedContent: protectedContent,
                identifier: "composer", title: "Message", description: "", help: "", placeholder: "",
                context: "chat", frame: window, enabled: true)
            #expect(KeyboardInjector.composerCandidateScore(field, windowFrame: window) == nil)
            #expect(KeyboardInjector.recordedAccessibilityCandidateScore(field,
                target: .init(role: "AXTextField", identifier: "composer", title: "Message", description: "",
                    help: "", placeholder: "", context: "chat", windowTitle: "", normalizedFrame: nil),
                windowTitle: "", windowFrame: window) == nil)
        }
    }

    @Test(arguments: [1e300, -1e300, Double.greatestFiniteMagnitude])
    func serializedExtremeFramesCannotCrashSemanticMatching(coordinate: Double) throws {
        let profile = CustomApplicationProfile(displayName: "Example", bundleIdentifier: "com.example.editor",
            applicationPath: "", focusStrategy: .recordedAccessibility,
            accessibilityTarget: target(.init(x: coordinate, y: coordinate, width: 0.5, height: 0.2)))
        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CustomApplicationProfile.self, from: encoded)
        let restored = try #require(decoded.accessibilityTarget)
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(candidate,
            target: restored, windowTitle: "", windowFrame: window) == 500)
    }

    @Test func normalFrameRankingRetainsItsGeometryBonus() {
        let matching = target(.init(x: 0.1, y: 0.2, width: 0.5, height: 0.2))
        let distant = target(.init(x: 10, y: 10, width: 0.5, height: 0.2))
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(candidate,
            target: matching, windowTitle: "", windowFrame: window) == 620)
        #expect(KeyboardInjector.recordedAccessibilityCandidateScore(candidate,
            target: distant, windowTitle: "", windowFrame: window) == 500)
    }

    @Test func weChatFocusPointRequiresMinimumWindowDimensions() {
        // Window too small -> nil
        #expect(KeyboardInjector.weChatComposerFocusPoint(windowFrame: CGRect(x: 0, y: 0, width: 699, height: 500)) == nil)
        #expect(KeyboardInjector.weChatComposerFocusPoint(windowFrame: CGRect(x: 0, y: 0, width: 700, height: 499)) == nil)

        // Valid window dimensions -> calculated point based on ratios
        let frame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let point = KeyboardInjector.weChatComposerFocusPoint(windowFrame: frame)
        #expect(point != nil)
        #expect(point?.x == 100 + 1000 * 0.68)
        #expect(point?.y == 200 + 800 * 0.85)
    }

    @Test func weChatWindowFrameSelectionFiltersAndPrefersLargestWindow() {
        let windows: [(title: String, frame: CGRect)] = [
            ("Finder", CGRect(x: 0, y: 0, width: 1200, height: 800)),
            ("微信", CGRect(x: 0, y: 0, width: 500, height: 400)), // Too small
            ("微信", CGRect(x: 0, y: 0, width: 800, height: 600)),
            ("微信", CGRect(x: 0, y: 0, width: 1000, height: 800)), // Largest valid
            ("Other", CGRect(x: 0, y: 0, width: 2000, height: 1000))
        ]
        let selected = KeyboardInjector.weChatComposerWindowFrame(windows)
        #expect(selected == CGRect(x: 0, y: 0, width: 1000, height: 800))

        // English title WeChat also accepted
        let englishWindows: [(title: String, frame: CGRect)] = [
            ("WeChat", CGRect(x: 50, y: 50, width: 900, height: 700))
        ]
        #expect(KeyboardInjector.weChatComposerWindowFrame(englishWindows) == CGRect(x: 50, y: 50, width: 900, height: 700))
    }

    @Test func weChatComposerFallbackIsRestrictedToWeChatBundleID() {
        #expect(KeyboardInjector.usesWeChatComposerFallback(bundleIdentifier: "com.tencent.xinWeChat"))
        #expect(!KeyboardInjector.usesWeChatComposerFallback(bundleIdentifier: "com.apple.Safari"))
        #expect(!KeyboardInjector.usesWeChatComposerFallback(bundleIdentifier: nil))
    }
}
