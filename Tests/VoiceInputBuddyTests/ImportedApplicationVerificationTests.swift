import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("Imported application verification")
struct ImportedApplicationVerificationTests {
    @Test func importedRecordedTargetsRequireLocalVerificationAcrossRestarts() throws {
        let name = "import-verification-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let target = AccessibilityFocusTarget(role: "AXTextArea", identifier: "composer", title: "",
            description: "", help: "", placeholder: "", context: "", windowTitle: "", normalizedFrame: nil)
        let recorded = CustomApplicationProfile(displayName: "Recorded", bundleIdentifier: "example.recorded",
            applicationPath: "", focusStrategy: .recordedAccessibility, accessibilityTarget: target)
        let otherRecorded = CustomApplicationProfile(displayName: "Other", bundleIdentifier: "example.other",
            applicationPath: "", focusStrategy: .recordedAccessibility, accessibilityTarget: target)
        let plain = CustomApplicationProfile(displayName: "Plain", bundleIdentifier: "example.plain", applicationPath: "")
        settings.customApplicationProfiles = [recorded, otherRecorded, plain]
        let data = try settings.exportedConfigurationData()
        try settings.importConfiguration(from: data)
        #expect(settings.portableApplicationRequiresVerification(recorded))
        #expect(!settings.portableApplicationRequiresVerification(plain))
        let restarted = AppSettings(defaults: defaults)
        #expect(restarted.portableApplicationRequiresVerification(recorded))
        restarted.markPortableApplicationVerified(recorded.id)
        #expect(!restarted.portableApplicationRequiresVerification(recorded))
        #expect(restarted.portableApplicationRequiresVerification(otherRecorded))
        try restarted.importConfiguration(from: data)
        #expect(restarted.portableApplicationRequiresVerification(recorded))

        var partial = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        partial.removeValue(forKey: "customApplicationProfiles")
        try restarted.importConfiguration(from: JSONSerialization.data(withJSONObject: partial))
        #expect(restarted.portableApplicationRequiresVerification(recorded))
        partial["customApplicationProfiles"] = []
        try restarted.importConfiguration(from: JSONSerialization.data(withJSONObject: partial))
        #expect(restarted.portablePendingApplications.isEmpty)
    }
}
