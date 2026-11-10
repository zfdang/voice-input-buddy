import Foundation
import Testing
@testable import RemoteBuddy

@Suite("App launch tracking and completed update detection")
@MainActor
struct LaunchTrackingTests {
    @Test func detectsUpdateWhenBuildNumberIncreases() throws {
        let name = "launch-tracking-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        // First launch on build 80
        let firstLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: false)
        #expect(!firstLaunch)

        // Same build launch
        let sameLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: false)
        #expect(!sameLaunch)

        // Upgrade to build 81
        let upgradeLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "81", sparkleHadLaunchedBefore: false)
        #expect(upgradeLaunch)

        // Downgrade to build 79
        let downgradeLaunch = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "79", sparkleHadLaunchedBefore: false)
        #expect(!downgradeLaunch)
    }

    @Test func detectsCompletedUpdateOnFirstRunIfSparkleHadLaunchedBefore() throws {
        let name = "sparkle-migration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        let completed = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: true)
        #expect(completed)
    }

    @Test func unifiedBindingPriorityResolvesDeviceSpecificOverGlobalOverDefault() throws {
        let name = "unified-priority-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)

        let deviceID = UUID()
        // 1. Initially returns default action
        let initial = settings.configuredBaseAction(for: .volumeUp, trigger: .singleClick, profileID: deviceID)
        #expect(initial.action == AppSettings.defaultBindings[.volumeUp])

        // 2. Set global binding (profileID: nil)
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .playPause, shortcut: nil),
            for: .volumeUp,
            trigger: .singleClick,
            profileID: nil
        )
        let withGlobal = settings.configuredBaseAction(for: .volumeUp, trigger: .singleClick, profileID: deviceID)
        #expect(withGlobal.action == .playPause)

        // 3. Set device-specific binding
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .showDesktop, shortcut: nil),
            for: .volumeUp,
            trigger: .singleClick,
            profileID: deviceID
        )
        let withDeviceSpecific = settings.configuredBaseAction(for: .volumeUp, trigger: .singleClick, profileID: deviceID)
        #expect(withDeviceSpecific.action == .showDesktop)

        // Other device still gets global binding
        let otherDevice = UUID()
        let otherResolved = settings.configuredBaseAction(for: .volumeUp, trigger: .singleClick, profileID: otherDevice)
        #expect(otherResolved.action == .playPause)
    }
}
