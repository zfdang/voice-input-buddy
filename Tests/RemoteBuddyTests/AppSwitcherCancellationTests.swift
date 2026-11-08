import CoreGraphics
import Testing
@testable import RemoteBuddy

@Suite("App switcher cancellation")
struct AppSwitcherCancellationTests {
    @Test(arguments: [false, true])
    func cancelSendsEscapeBeforeReleasingCommandWhileConfirmOnlyReleases(cancel: Bool) {
        var events: [(CGKeyCode, Bool, CGEventFlags)] = []
        let session = KeyboardInjector.AppSwitcherSession(keyStatePoster: { code, down, flags in
            events.append((code, down, flags)); return true
        })
        #expect(session.trigger())
        events.removeAll()
        #expect(cancel ? session.cancel() : session.confirm())
        #expect(events.map { $0.0 } == (cancel ? [53, 53, 55] : [55]))
        #expect(events.map { $0.1 } == (cancel ? [true, false, false] : [false]))
        if cancel { #expect(events[0].2 == .maskCommand && events[1].2 == .maskCommand) }
        #expect(events.last?.2 == [])
        #expect(!session.isActive)
        let count = events.count
        #expect(session.cancel())
        #expect(events.count == count)
    }
}
