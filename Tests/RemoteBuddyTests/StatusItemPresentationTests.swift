import AppKit
import Combine
import Testing
@testable import RemoteBuddy

@Suite("Menu bar presentation")
struct StatusItemPresentationTests {
    @Test @MainActor func connectionStatesUseSystemTintAndDisconnectedAppearance() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        for (state, disabled) in [(StatusItemPresentation.disconnected, true), (.connected, false), (.preparing, false), (.streaming, false)] {
            state.apply(to: button, description: state.rawValue)
            #expect(button.image?.isTemplate == true)
            #expect(button.image?.size == NSSize(width: 22, height: 22))
            #expect(button.appearsDisabled == disabled)
        }
        #expect(StatusItemPresentation.resolve(physicalConnected: true, isStreaming: false) == .connected)
    }

    @Test func preparingIsVisibleBeforeStreamingAndClearsOnCancellation() {
        let connected = CurrentValueSubject<Bool, Never>(true)
        let streaming = CurrentValueSubject<Bool, Never>(false)
        let preparing = CurrentValueSubject<Bool, Never>(false)
        var states: [StatusItemPresentation] = []
        let subscription = StatusItemPresentation.publisher(
            physicalConnected: connected.eraseToAnyPublisher(), isStreaming: streaming.eraseToAnyPublisher(),
            isPreparing: preparing.eraseToAnyPublisher()).sink { states.append($0) }
        defer { subscription.cancel() }
        preparing.send(true)
        #expect(states.last == .preparing)
        streaming.send(true)
        preparing.send(false)
        streaming.send(false)
        preparing.send(true)
        preparing.send(false)
        connected.send(false)
        #expect(states == [.connected, .preparing, .streaming, .connected, .preparing, .connected, .disconnected])
    }
}
