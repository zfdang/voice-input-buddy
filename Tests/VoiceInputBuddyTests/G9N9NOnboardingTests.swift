import Foundation
import Testing
@testable import VoiceInputBuddy

@Suite("G9N9N setup button reports")
struct G9N9NOnboardingTests {
    @Test func twoButtonReportsSatisfyExistingChecksWithoutBypassingVoiceOrPermissions() throws {
        var capabilities = OnboardingCapabilities(
            bluetoothGranted: true, inputMonitoringGranted: true,
            accessibilityGranted: true, remoteConnected: true
        )
        func allows(_ step: OnboardingStep, _ state: OnboardingCapabilities) -> Bool {
            OnboardingFlowPolicy.canContinue(from: step, voiceTool: .doubao,
                selectedDevice: .chromecastG9N9N, capabilities: state)
        }
        #expect(!allows(.remote, capabilities))

        // OK + Up produces a complete two-slot report, unlike an isolated key.
        var observed = try #require(G9N9NProtocol.usages(reportID: 1,
            data: Data([1, 7, 3]), descriptor: G9N9NProtocol.indexedConsumerDescriptor))
        #expect(observed == [RemoteButton.ok.hidUsage, RemoteButton.up.hidUsage])
        capabilities.remoteButtonObserved = !observed.isEmpty
        capabilities.testedRemoteButtonCount = observed.count
        #expect(allows(.remote, capabilities))
        #expect(!allows(.controls, capabilities))

        // A second pair adds Back, reaching the existing three-distinct-key gate.
        observed.formUnion(try #require(G9N9NProtocol.usages(reportID: 1,
            data: Data([1, 3, 11]), descriptor: G9N9NProtocol.indexedConsumerDescriptor)))
        capabilities.testedRemoteButtonCount = observed.count
        #expect(observed.count == 3)
        #expect(allows(.controls, capabilities))
        #expect(!allows(.voiceTest, capabilities))
        capabilities.accessibilityGranted = false
        #expect(!allows(.remote, capabilities))
        #expect(!allows(.controls, capabilities))
    }
}
