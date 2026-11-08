import AppKit
import Foundation
import IOKit.hidsystem

struct CustomKeyboardShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command, .function,
    ]
    private static let leftControlMask = UInt(NX_DEVICELCTLKEYMASK)
    private static let rightControlMask = UInt(NX_DEVICERCTLKEYMASK)
    private static let leftOptionMask = UInt(NX_DEVICELALTKEYMASK)
    private static let rightOptionMask = UInt(NX_DEVICERALTKEYMASK)
    private static let leftShiftMask = UInt(NX_DEVICELSHIFTKEYMASK)
    private static let rightShiftMask = UInt(NX_DEVICERSHIFTKEYMASK)
    private static let leftCommandMask = UInt(NX_DEVICELCMDKEYMASK)
    private static let rightCommandMask = UInt(NX_DEVICERCMDKEYMASK)
    private static let controlDeviceModifiers = NSEvent.ModifierFlags(
        rawValue: leftControlMask | rightControlMask
    )
    private static let optionDeviceModifiers = NSEvent.ModifierFlags(
        rawValue: leftOptionMask | rightOptionMask
    )
    private static let shiftDeviceModifiers = NSEvent.ModifierFlags(
        rawValue: leftShiftMask | rightShiftMask
    )
    private static let commandDeviceModifiers = NSEvent.ModifierFlags(
        rawValue: leftCommandMask | rightCommandMask
    )
    private static let deviceModifiers = controlDeviceModifiers
        .union(optionDeviceModifiers)
        .union(shiftDeviceModifiers)
        .union(commandDeviceModifiers)

    let keyCode: UInt16
    let modifierFlagsRawValue: UInt
    let keyLabel: String

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifierFlagsRawValue = Self.normalizedModifierFlags(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ).rawValue
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            keyLabel: Self.keyLabel(for: event)
        )
    }

    var modifierFlags: NSEvent.ModifierFlags {
        Self.normalizedModifierFlags(
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
        )
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.function) { flags.insert(.maskSecondaryFn) }
        flags.formUnion(CGEventFlags(rawValue: UInt64(
            modifierFlags.intersection(Self.deviceModifiers).rawValue
        )))
        return flags
    }

    var standaloneModifier: StandaloneKeyboardModifier? {
        StandaloneKeyboardModifier.matching(self)
    }

    private static func normalizedModifierFlags(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        var normalized = modifierFlags.intersection(Self.supportedModifiers)
        if normalized.contains(.control) {
            normalized.formUnion(modifierFlags.intersection(controlDeviceModifiers))
        }
        if normalized.contains(.option) {
            normalized.formUnion(modifierFlags.intersection(optionDeviceModifiers))
        }
        if normalized.contains(.shift) {
            normalized.formUnion(modifierFlags.intersection(shiftDeviceModifiers))
        }
        if normalized.contains(.command) {
            normalized.formUnion(modifierFlags.intersection(commandDeviceModifiers))
        }
        if (123...126).contains(keyCode) {
            normalized.remove(.function)
        }
        return normalized
    }

    @MainActor
    func displayName(using localization: LocalizationStore) -> String {
        if let standaloneModifier {
            return standaloneModifier.displayName(using: localization)
        }
        var result = ""
        if modifierFlags.contains(.control) {
            result += sidedSymbol(
                "⌃", leftMask: Self.leftControlMask, rightMask: Self.rightControlMask,
                using: localization
            )
        }
        if modifierFlags.contains(.option) {
            result += sidedSymbol(
                "⌥", leftMask: Self.leftOptionMask, rightMask: Self.rightOptionMask,
                using: localization
            )
        }
        if modifierFlags.contains(.shift) {
            result += sidedSymbol(
                "⇧", leftMask: Self.leftShiftMask, rightMask: Self.rightShiftMask,
                using: localization
            )
        }
        if modifierFlags.contains(.command) {
            result += sidedSymbol(
                "⌘", leftMask: Self.leftCommandMask, rightMask: Self.rightCommandMask,
                using: localization
            )
        }
        if modifierFlags.contains(.function) { result += "fn " }
        return result + localizedKeyLabel(using: localization)
    }

    /// Compact macOS-style representation used by the mapping UI.
    @MainActor
    func visualDisplayName(using localization: LocalizationStore) -> String {
        if let standaloneModifier {
            return standaloneModifier.symbol
        }
        var result = ""
        if modifierFlags.contains(.control) {
            result += sidedSymbol(
                "⌃", leftMask: Self.leftControlMask, rightMask: Self.rightControlMask,
                using: localization
            )
        }
        if modifierFlags.contains(.option) {
            result += sidedSymbol(
                "⌥", leftMask: Self.leftOptionMask, rightMask: Self.rightOptionMask,
                using: localization
            )
        }
        if modifierFlags.contains(.shift) {
            result += sidedSymbol(
                "⇧", leftMask: Self.leftShiftMask, rightMask: Self.rightShiftMask,
                using: localization
            )
        }
        if modifierFlags.contains(.command) {
            result += sidedSymbol(
                "⌘", leftMask: Self.leftCommandMask, rightMask: Self.rightCommandMask,
                using: localization
            )
        }
        if modifierFlags.contains(.function) { result += "fn " }
        return result + visualKeyLabel
    }

    /// Full keyboard wording used by tooltips and accessibility labels.
    @MainActor
    func detailedDisplayName(using localization: LocalizationStore) -> String {
        if let standaloneModifier {
            return standaloneModifier.displayName(using: localization)
        }
        var parts: [String] = []
        if modifierFlags.contains(.control) {
            parts.append(detailedModifierName(
                "shortcut.modifier.control",
                leftMask: Self.leftControlMask,
                rightMask: Self.rightControlMask,
                using: localization
            ))
        }
        if modifierFlags.contains(.option) {
            parts.append(detailedModifierName(
                "shortcut.modifier.option",
                leftMask: Self.leftOptionMask,
                rightMask: Self.rightOptionMask,
                using: localization
            ))
        }
        if modifierFlags.contains(.shift) {
            parts.append(detailedModifierName(
                "shortcut.modifier.shift",
                leftMask: Self.leftShiftMask,
                rightMask: Self.rightShiftMask,
                using: localization
            ))
        }
        if modifierFlags.contains(.command) {
            parts.append(detailedModifierName(
                "shortcut.modifier.command",
                leftMask: Self.leftCommandMask,
                rightMask: Self.rightCommandMask,
                using: localization
            ))
        }
        if modifierFlags.contains(.function) { parts.append(localization.text("shortcut.modifier.function")) }
        parts.append(detailedKeyLabel(using: localization))
        return parts.joined(separator: " + ")
    }

    @MainActor
    private func sidedSymbol(
        _ symbol: String,
        leftMask: UInt,
        rightMask: UInt,
        using localization: LocalizationStore
    ) -> String {
        sidePrefix(leftMask: leftMask, rightMask: rightMask, using: localization) + symbol
    }

    @MainActor
    private func sidePrefix(
        leftMask: UInt,
        rightMask: UInt,
        using localization: LocalizationStore
    ) -> String {
        if modifierFlagsRawValue & rightMask != 0 {
            return localization.text("keyboard.modifier.right")
        }
        if modifierFlagsRawValue & leftMask != 0 {
            return localization.text("keyboard.modifier.left")
        }
        return ""
    }

    @MainActor
    private func detailedModifierName(
        _ localizationKey: String,
        leftMask: UInt,
        rightMask: UInt,
        using localization: LocalizationStore
    ) -> String {
        let name = localization.text(localizationKey)
        let prefix = sidePrefix(leftMask: leftMask, rightMask: rightMask, using: localization)
        return prefix.isEmpty ? name : "\(prefix) \(name)"
    }

    private var visualKeyLabel: String {
        switch keyCode {
        case 36: return "⏎"
        case 48: return "⇥"
        case 49: return "␠"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 117: return "⌦"
        default: return keyLabel
        }
    }

    @MainActor
    private func detailedKeyLabel(using localization: LocalizationStore) -> String {
        switch keyCode {
        case 36: return localization.text("keyboard.key.return")
        case 48: return localization.text("keyboard.key.tab")
        case 49: return localization.text("keyboard.key.space")
        case 51: return localization.text("keyboard.key.delete")
        case 53: return localization.text("keyboard.key.escape")
        case 76: return localization.text("keyboard.key.enter")
        case 123: return localization.text("keyboard.key.left")
        case 124: return localization.text("keyboard.key.right")
        case 125: return localization.text("keyboard.key.down")
        case 126: return localization.text("keyboard.key.up")
        default: return localizedKeyLabel(using: localization)
        }
    }

    @MainActor
    private func localizedKeyLabel(using localization: LocalizationStore) -> String {
        switch keyCode {
        case 36: return localization.text("keyboard.key.return")
        case 48: return localization.text("keyboard.key.tab")
        case 49: return localization.text("keyboard.key.space")
        case 71: return localization.text("keyboard.key.clear")
        case 76: return localization.text("keyboard.key.enter")
        case 114: return localization.text("keyboard.key.help")
        case 115: return localization.text("keyboard.key.home")
        case 116: return localization.text("keyboard.key.page_up")
        case 119: return localization.text("keyboard.key.end")
        case 121: return localization.text("keyboard.key.page_down")
        default:
            if keyLabel.hasPrefix("Key Code ") || keyLabel.hasPrefix("键码 ") {
                return String(
                    format: localization.text("keyboard.key_code"),
                    locale: localization.locale,
                    arguments: [String(keyCode)]
                )
            }
            return keyLabel
        }
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 64: return "F17"
        case 71: return "Clear"
        case 76: return "Enter"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "Key Code \(event.keyCode)" : characters.uppercased()
        }
    }
}

