import Testing
@testable import RemoteBuddy

@Suite("Product runtime boundaries")
struct RetiredRuntimeBoundaryTests {
    @Test func retiredTransportValuesAreNotAcceptedAsConfiguration() {
        for value in ["iphone_app", "web_remote"] {
            #expect(OnboardingControlMethod(rawValue: value) == nil)
        }
        for value in ["apple_companion", "web_remote"] {
            #expect(OnboardingControlSource(rawValue: value) == nil)
        }
        #expect(OnboardingControlMethod.physicalRemote.requiresBluetoothPermission)
        #expect(OnboardingBuildCapabilities.availableControlSources == [.xiaomiRemote, .chromecastRemote])
    }
}
