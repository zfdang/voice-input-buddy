import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Onboarding remote selection") @MainActor
struct OnboardingRemoteSelectionTests {
    @Test(arguments: [OnboardingControlSource.xiaomiRemote, .chromecastRemote])
    func selectsTheOnlyConnectedRemoteMatchingTheChosenFamily(source: OnboardingControlSource) throws {
        let name = "onboarding-selection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let expected = source == .xiaomiRemote ? xiaomi : google
        settings.selectRemoteProfile(source == .xiaomiRemote ? google : xiaomi)
        settings.onboardingControlSource = source
        settings.setOnboardingStep(.remote)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.connectedRemoteProfileIDs = [xiaomi, google]
        model.selectOnboardingRemoteIfNeeded()
        #expect(settings.selectedRemoteProfileID == expected)
    }

    @Test func waitsForAConnectionAndDoesNotGuessBetweenMultipleMatchingRemotes() throws {
        let name = "onboarding-selection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .rc001)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(google)
        settings.onboardingControlSource = .xiaomiRemote
        settings.setOnboardingStep(.remote)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.selectOnboardingRemoteIfNeeded()
        #expect(settings.selectedRemoteProfileID == google)
        model.connectedRemoteProfileIDs = [first, second, google]
        model.selectOnboardingRemoteIfNeeded()
        #expect(settings.selectedRemoteProfileID == google)
        settings.selectRemoteProfile(second)
        model.selectOnboardingRemoteIfNeeded()
        #expect(settings.selectedRemoteProfileID == second)
        model.connectedRemoteProfileIDs = [first, google]
        model.selectOnboardingRemoteIfNeeded()
        #expect(settings.selectedRemoteProfileID == first)
    }

    @Test func explicitUnsupportedDeviceSelectionSurvivesConnectedRemotePreselection() throws {
        let name = "onboarding-unsupported-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.setOnboardingStep(.remoteAvailability)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.connectedRemoteProfileIDs = [xiaomi]
        let view = OnboardingView(model: model, permissionOverrides: .allGranted)
        view.routeConnectedPhysicalRemoteIfNeeded()
        #expect(settings.onboardingDevice == .xiaomi)
        view.selectDevice(.siriRemote)
        view.routeConnectedPhysicalRemoteIfNeeded()
        #expect(settings.onboardingDevice == .siriRemote)
        #expect(settings.onboardingControlSource == .unselected)
        #expect(!view.canContinue)
        view.continueFlow()
        #expect(settings.onboardingStep == .remoteAvailability)
        #expect(settings.onboardingDevice == .siriRemote)
        view.selectDevice(.xiaomi)
        #expect(view.canContinue)
    }

    @Test func otherStepsKeepTheCurrentDeviceSelection() throws {
        let name = "onboarding-selection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(google)
        settings.onboardingControlSource = .xiaomiRemote
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.connectedRemoteProfileIDs = [xiaomi]
        for step in OnboardingStep.visibleCases where step != .remote {
            settings.setOnboardingStep(step)
            model.selectOnboardingRemoteIfNeeded()
            #expect(settings.selectedRemoteProfileID == google)
        }
    }
}
