import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Button mapping default action resolution") @MainActor
struct ButtonMappingDefaultActionTests {
    private func withSettings(_ body: (AppSettings) throws -> Void) throws {
        let name = "default-actions-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(AppSettings(defaults: defaults))
    }

    @Test func defaultActionResolvesExpectedSingleClickPresets() throws {
        try withSettings { settings in
            #expect(settings.defaultAction(for: .power, trigger: .singleClick).action == .deleteBackward)
            #expect(settings.defaultAction(for: .ok, trigger: .singleClick).action == .returnKey)
            #expect(settings.defaultAction(for: .back, trigger: .singleClick).action == .escape)
            #expect(settings.defaultAction(for: .up, trigger: .singleClick).action == .arrowUp)
            #expect(settings.defaultAction(for: .down, trigger: .singleClick).action == .arrowDown)
            #expect(settings.defaultAction(for: .left, trigger: .singleClick).action == .arrowLeft)
            #expect(settings.defaultAction(for: .right, trigger: .singleClick).action == .arrowRight)
            #expect(settings.defaultAction(for: .volumeUp, trigger: .singleClick).action == .volumeUp)
            #expect(settings.defaultAction(for: .volumeDown, trigger: .singleClick).action == .volumeDown)
            #expect(settings.defaultAction(for: .mute, trigger: .singleClick).action == .volumeMute)
            #expect(settings.defaultAction(for: .home, trigger: .singleClick).action == .appSwitcher)
            #expect(settings.defaultAction(for: .menu, trigger: .singleClick).action == .contextMenu)
            #expect(settings.defaultAction(for: .tv, trigger: .singleClick).action == .playPause)
            #expect(settings.defaultAction(for: .playPause, trigger: .singleClick).action == .playPause)
        }
    }

    @Test func defaultActionReturnsDisabledForEveryDoubleClick() throws {
        try withSettings { settings in
            for button in RemoteButton.allCases {
                let action = settings.defaultAction(for: button, trigger: .doubleClick)
                #expect(action.action == .disabled)
                #expect(action.shortcut == nil)
                #expect(action.applicationProfileID == nil)
            }
        }
    }

    @Test func defaultActionReturnsExpectedLongPressOrRepeatActions() throws {
        try withSettings { settings in
            // OK long press returns commandReturn from defaultSecondaryBindings
            let okAction = settings.defaultAction(for: .ok, trigger: .longPress)
            #expect(okAction.action == .commandReturn)
            #expect(okAction.shortcut == nil)

            // Navigation, volume, and power return repeatSingleClick
            let repeatingButtons: [RemoteButton] = [.up, .down, .left, .right, .power, .volumeUp, .volumeDown]
            for button in repeatingButtons {
                let action = settings.defaultAction(for: button, trigger: .longPress)
                #expect(action.action == .repeatSingleClick)
            }

            // Other buttons return disabled for long press
            let nonRepeatingButtons: [RemoteButton] = [.back, .home, .menu, .tv, .playPause, .mute]
            for button in nonRepeatingButtons {
                let action = settings.defaultAction(for: button, trigger: .longPress)
                #expect(action.action == .disabled)
            }
        }
    }

    @Test func restoringSingleTriggerRestoresDefaultWithoutOverwritingOtherTriggers() throws {
        try withSettings { settings in
            // Customize menu button single click, double click, and long press
            settings.setAction(.playPause, for: .menu, trigger: .singleClick)
            settings.setAction(.volumeUp, for: .menu, trigger: .doubleClick)
            settings.setAction(.showDesktop, for: .menu, trigger: .longPress)

            // Restore only single click to default
            let defaultSingle = settings.defaultAction(for: .menu, trigger: .singleClick)
            settings.setBaseBinding(defaultSingle, for: .menu, trigger: .singleClick, profileID: settings.selectedRemoteProfileID)

            // Single click is restored to .contextMenu
            #expect(settings.configuredAction(for: .menu, trigger: .singleClick).action == .contextMenu)
            // Double click and long press retain user modifications
            #expect(settings.configuredAction(for: .menu, trigger: .doubleClick).action == .volumeUp)
            #expect(settings.configuredAction(for: .menu, trigger: .longPress).action == .showDesktop)
        }
    }

    @Test func resetAllBindingsRestoresDefaultsAcrossAllButtonsAndTriggers() throws {
        try withSettings { settings in
            // Modify various buttons
            settings.setAction(.showDesktop, for: .power, trigger: .singleClick)
            settings.setAction(.disabled, for: .ok, trigger: .longPress)
            settings.setAction(.commandCopy, for: .up, trigger: .singleClick)

            settings.resetBindings()

            // Verify power is back to deleteBackward, ok long press is commandReturn, up is arrowUp
            #expect(settings.configuredAction(for: .power, trigger: .singleClick).action == .deleteBackward)
            #expect(settings.configuredAction(for: .ok, trigger: .longPress).action == .commandReturn)
            #expect(settings.configuredAction(for: .up, trigger: .singleClick).action == .arrowUp)
            #expect(settings.configuredAction(for: .up, trigger: .longPress).action == .repeatSingleClick)
        }
    }

    @Test func unmappedButtonFallsBackToDisabledRatherThanFactoryDefault() throws {
        try withSettings { settings in
            // Remove power from buttonBindings and unifiedBaseBindings
            settings.unifiedBaseBindings.removeAll { $0.button == .power }
            settings.buttonBindings.removeValue(forKey: .power)
            // When not mapped in either unified or active bindings, it must return .disabled
            #expect(settings.configuredBaseAction(for: .power, trigger: .singleClick).action == .disabled)
        }
    }
}
