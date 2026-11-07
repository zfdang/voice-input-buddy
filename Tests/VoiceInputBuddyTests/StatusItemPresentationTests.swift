import AppKit
import Testing
@testable import VoiceInputBuddy

@Suite("Menu bar presentation")
struct StatusItemPresentationTests {
    @Test @MainActor func connectionStatesUseSystemTintAndDisconnectedAppearance() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        for (state, disabled) in [(StatusItemPresentation.disconnected, true), (.connected, false), (.streaming, false)] {
            state.apply(to: button, description: state.rawValue)
            #expect(button.image?.isTemplate == true)
            #expect(button.image?.size == NSSize(width: 22, height: 22))
            #expect(button.appearsDisabled == disabled)
        }
        #expect(StatusItemPresentation.resolve(physicalConnected: true, isStreaming: false) == .connected)
    }
}
