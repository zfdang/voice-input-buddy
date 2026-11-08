import AppKit
import IOKit.hidsystem
import Testing
@testable import RemoteBuddy

@Suite("Native media key suppression")
struct MediaKeySuppressionTests {
    private func event(type: Int32, down: Bool) throws -> CGEvent {
        let value = (Int(type) << 16) | ((down ? 0xA : 0xB) << 8)
        let native = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: value, data2: -1))
        return try #require(native.cgEvent)
    }

    @Test(arguments: [
        (RemoteButton.volumeUp, Int32(NX_KEYTYPE_SOUND_UP)),
        (.volumeDown, Int32(NX_KEYTYPE_SOUND_DOWN)),
        (.mute, Int32(NX_KEYTYPE_MUTE)),
        (.playPause, Int32(NX_KEYTYPE_PLAY)),
    ])
    func mappedMediaKeyConsumesBothNativeEdges(pair: (RemoteButton, Int32)) throws {
        let filter = KeyboardEventSuppressor(uptime: { 0 })
        let systemDefined = try #require(CGEventType(rawValue: 14))
        filter.arm(button: pair.0, edge: .down)
        #expect(filter.handle(type: systemDefined, event: try event(type: pair.1, down: true)))
        filter.arm(button: pair.0, edge: .up)
        #expect(filter.handle(type: systemDefined, event: try event(type: pair.1, down: false)))
    }

    @Test func mediaMappingDoesNotSwallowBrightnessKeys() throws {
        let filter = KeyboardEventSuppressor(uptime: { 0 })
        let systemDefined = try #require(CGEventType(rawValue: 14))
        filter.arm(button: .mute, edge: .down)
        filter.arm(button: .playPause, edge: .down)
        for type in [Int32(NX_KEYTYPE_BRIGHTNESS_UP), Int32(NX_KEYTYPE_BRIGHTNESS_DOWN)] {
            #expect(!filter.handle(type: systemDefined, event: try event(type: type, down: true)))
            #expect(!filter.handle(type: systemDefined, event: try event(type: type, down: false)))
        }
    }
}
