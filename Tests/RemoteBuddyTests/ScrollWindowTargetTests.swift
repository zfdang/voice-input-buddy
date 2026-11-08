import CoreGraphics
import Testing
@testable import RemoteBuddy

@Suite("Scroll window targeting")
struct ScrollWindowTargetTests {
    @Test func windowServerSnapshotTargetsTheFrontmostProcessWithoutAX() {
        func window(_ pid: Int, _ layer: Int, _ frame: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let result = KeyboardInjector.frontmostWindowFrame(windowInfo: [
            window(42, 0, frame), window(99, 0, CGRect(x: 0, y: 0, width: 2000, height: 2000)),
            window(42, 1, CGRect(x: 0, y: 0, width: 2000, height: 2000))
        ], processIdentifier: 42)
        #expect(result == frame)
        #expect(KeyboardInjector.scrollTargetLocation(windowFrame: result, mouseLocation: .zero)
            == CGPoint(x: 300, y: 350))
        #expect(KeyboardInjector.scrollTargetLocation(windowFrame: nil, mouseLocation: .init(x: 5, y: 6))
            == CGPoint(x: 5, y: 6))
    }
}
