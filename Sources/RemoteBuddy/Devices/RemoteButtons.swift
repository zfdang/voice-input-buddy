import AppKit
import Foundation
import IOKit.hidsystem

enum RemoteButton: String, CaseIterable, Codable, Identifiable {
    case power
    case up
    case left
    case ok
    case right
    case down
    case back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu
    case tv
    case playPause = "play_pause"
    case mute
    /// Chromecast 遥控器专有按键。这三颗键在小米遥控器上不存在，因此不进 `xiaomiCases`。
    case youtube
    case netflix
    case input

    /// Buttons physically present on the Xiaomi RC001/RC003 layout.
    /// Siri Remote has its own private page and does not use this list.
    static let xiaomiCases: [RemoteButton] = [
        .power, .up, .left, .ok, .right, .down, .back,
        .volumeUp, .home, .volumeDown, .menu, .tv,
    ]

    var id: String { rawValue }

    var hidUsage: UInt16 {
        switch self {
        case .power: return 0x66
        case .up: return 0x52
        case .left: return 0x50
        case .ok: return 0x28
        case .right: return 0x4F
        case .down: return 0x51
        case .back: return 0xF1
        case .volumeUp: return 0x80
        case .home: return 0x4A
        case .volumeDown: return 0x81
        case .menu: return 0x65
        case .tv: return 0x35
        // Reserved values: these controls are decoded by the Siri Remote
        // adapter and are not part of Xiaomi HID discovery.
        case .playPause: return 0x1000
        case .mute: return 0x1001
        // Reserved values: decoded by the Chromecast adapter's own HID channel
        // (usage 0x0E/0x0F/0x11 in that remote's report), never by Xiaomi discovery.
        case .youtube: return 0x1002
        case .netflix: return 0x1003
        case .input: return 0x1004
        }
    }

    @MainActor
    func shortLabel(using localization: LocalizationStore) -> String {
        switch self {
        case .power: return localization.text("remote.button.short.power")
        case .up: return localization.text("remote.button.short.up")
        case .left: return localization.text("remote.button.short.left")
        case .ok: return "OK"
        case .right: return localization.text("remote.button.short.right")
        case .down: return localization.text("remote.button.short.down")
        case .back: return localization.text("remote.button.short.back")
        case .volumeUp: return "+"
        case .home: return localization.text("remote.button.short.home")
        case .volumeDown: return "−"
        case .menu: return localization.text("remote.button.short.menu")
        case .tv: return "TV"
        case .playPause: return localization.text("remote.button.short.play_pause")
        case .mute: return localization.text("remote.button.short.mute")
        case .youtube: return "YouTube"
        case .netflix: return "NETFLIX"
        case .input: return localization.text("remote.button.short.input")
        }
    }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .power: return localization.text("remote.button.full.power")
        case .up: return localization.text("remote.button.full.up")
        case .left: return localization.text("remote.button.full.left")
        case .ok: return localization.text("remote.button.full.ok")
        case .right: return localization.text("remote.button.full.right")
        case .down: return localization.text("remote.button.full.down")
        case .back: return localization.text("remote.button.full.back")
        case .volumeUp: return localization.text("remote.button.full.volume_up")
        case .home: return localization.text("remote.button.full.home")
        case .volumeDown: return localization.text("remote.button.full.volume_down")
        case .menu: return localization.text("remote.button.full.menu")
        case .tv: return localization.text("remote.button.full.tv")
        case .playPause: return localization.text("remote.button.full.play_pause")
        case .mute: return localization.text("remote.button.full.mute")
        case .youtube: return localization.text("remote.button.full.youtube")
        case .netflix: return localization.text("remote.button.full.netflix")
        case .input: return localization.text("remote.button.full.input")
        }
    }

    static let usageMap = Dictionary(
        uniqueKeysWithValues: (xiaomiCases + [.mute, .youtube, .netflix, .input]).map { ($0.hidUsage, $0) }
    )

    static func buttons(for usages: Set<UInt16>) -> Set<RemoteButton> {
        Set(usages.compactMap { usageMap[$0] })
    }

    var nativeEvent: RemoteNativeEvent? {
        switch self {
        case .ok: return .keyboard(keyCode: 36)
        // Measured on a real RC003 (2026-08-22): the TV key's keyboard
        // interface actually emits keyCode 10 (ISO §) with flags 0x100.
        // 50 was the historical value from the initial release and never
        // matched the hardware, so the suppressor missed the real event.
        case .tv: return .keyboard(keyCode: 10)
        case .home: return .keyboard(keyCode: 115)
        case .right: return .keyboard(keyCode: 124)
        case .left: return .keyboard(keyCode: 123)
        case .down: return .keyboard(keyCode: 125)
        case .up: return .keyboard(keyCode: 126)
        case .menu: return .keyboard(keyCode: 110)
        case .power: return .keyboard(keyCode: 90)
        case .volumeUp: return .systemKey(type: Int32(NX_KEYTYPE_SOUND_UP))
        case .volumeDown: return .systemKey(type: Int32(NX_KEYTYPE_SOUND_DOWN))
        case .back: return nil
        case .playPause: return .systemKey(type: Int32(NX_KEYTYPE_PLAY))
        case .mute: return .systemKey(type: Int32(NX_KEYTYPE_MUTE))
        // Chromecast 的三颗专有键在专属 HID 报告中读取，
        // 系统侧不会产生需要抑制的默认全局快捷键，因此无需拦截原生事件。
        case .youtube, .netflix, .input: return nil
        }
    }

    var nativeEvents: Set<RemoteNativeEvent> {
        guard let nativeEvent else { return [] }
        return self == .tv ? [nativeEvent, .keyboard(keyCode: 50)] : [nativeEvent]
    }
}

enum RemoteNativeEvent: Hashable {
    case keyboard(keyCode: UInt16)
    case systemKey(type: Int32)
}

enum RemoteEventEdge: Equatable {
    case down
    case up
}

