import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

extension KeyboardInjector {
    static func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        if !flags.isEmpty {
            _ = ShortcutEventSequence.send(keyCode: code, modifiers: flags,
                hardwareFlags: KeyboardHardwareModifierPolicy.currentForMappedAction, eventPoster: ShortcutEventSequence.post)
            return
        }
        guard let down = makeMappedKeyEvent(code: code, isDown: true, flags: flags),
              let up = makeMappedKeyEvent(code: code, isDown: false, flags: flags)
        else { return }
        down.post(tap: .cghidEventTap)
        up.flags = flags.union(KeyboardHardwareModifierPolicy.currentForMappedAction())
        up.post(tap: .cghidEventTap)
    }

    static func postKeyState(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags
    ) -> Bool {
        guard let event = makeMappedKeyEvent(code: code, isDown: isDown, flags: flags)
        else { return false }
        AppLogger.shared.write(
            "MAPPED KEY EVENT key_code=\(code) edge=\(isDown ? "down" : "up") " +
                "modifier_flags=\(event.flags.rawValue) result=submitted target_response=unknown"
        )
        event.post(tap: .cghidEventTap)
        return true
    }

    static func postVoiceKeyState(code: CGKeyCode, isDown: Bool, flags: CGEventFlags) -> Bool {
        postMarkedKeyState(code: code, isDown: isDown, flags: flags, marker: orderedVoiceEventMarker)
    }

    static func makeMappedKeyEvent(
        code: CGKeyCode, isDown: Bool, flags: CGEventFlags,
        hardwareFlags: () -> CGEventFlags = KeyboardHardwareModifierPolicy.current
    ) -> CGEvent? {
        // The remote's native Home carries Fn even without numeric-pad flags.
        // Only the configured shortcut may add Fn to a mapped event.
        makeMarkedKeyEvent(code: code, isDown: isDown, flags: flags,
            marker: syntheticEventMarker,
            hardwareFlags: { KeyboardHardwareModifierPolicy.mappedActionFlags(hardwareFlags()) })
    }

    static func keyEventType(code: CGKeyCode, isDown: Bool) -> CGEventType {
        switch code {
        case 54...63: return .flagsChanged
        default: return isDown ? .keyDown : .keyUp
        }
    }

    private static let markedKeySource = CGEventSource(stateID: .privateState)

    static func makeMarkedKeyEvent(code: CGKeyCode, isDown: Bool, flags: CGEventFlags, marker: Int64,
                                   hardwareFlags: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) }) -> CGEvent? {
        guard let source = markedKeySource,
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        else { return nil }
        event.type = keyEventType(code: code, isDown: isDown)
        // Posting Fn down can make the HID snapshot retain Fn. Re-inheriting
        // that bit on key-up turns every tap into a continuous hold.
        let inheritedFlags = code == VoiceKeyMode.function.keyCode
            ? hardwareFlags().subtracting(.maskSecondaryFn) : hardwareFlags()
        event.flags = flags.union(inheritedFlags)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    private static func postMarkedKeyState(code: CGKeyCode, isDown: Bool,
                                          flags: CGEventFlags, marker: Int64) -> Bool {
        guard let event = makeMarkedKeyEvent(code: code, isDown: isDown, flags: flags, marker: marker)
        else { return false }
        AppLogger.shared.write(
            "VOICE KEY EVENT key_code=\(code) edge=\(isDown ? "down" : "up") " +
                "modifier_flags=\(event.flags.rawValue) result=submitted target_response=unknown"
        )
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Scroll events are delivered to the window under the event location, not
    /// to the focused application, so a remote press must aim at the frontmost
    /// window instead of wherever the mouse happens to rest.
    static func scrollTargetLocation(
        windowFrame: CGRect?,
        mouseLocation: CGPoint
    ) -> CGPoint {
        guard let windowFrame,
              windowFrame.width > 0,
              windowFrame.height > 0
        else { return mouseLocation }
        return CGPoint(x: windowFrame.midX, y: windowFrame.midY)
    }

    /// Picks the largest ordinary window of the given process from a
    /// `CGWindowListCopyWindowInfo` snapshot.
    static func frontmostWindowFrame(
        windowInfo: [[String: Any]],
        processIdentifier: pid_t
    ) -> CGRect? {
        windowInfo
            .filter { entry in
                guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                      owner.int32Value == processIdentifier,
                      let layer = entry[kCGWindowLayer as String] as? NSNumber,
                      layer.intValue == 0
                else { return false }
                return true
            }
            .compactMap { entry -> CGRect? in
                guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary else {
                    return nil
                }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    static func ordinaryWindowCount(
        windowInfo: [[String: Any]],
        processIdentifier: pid_t
    ) -> Int {
        windowInfo.reduce(into: 0) { count, entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0,
                  frame.height > 0
            else { return }
            count += 1
        }
    }

    static func applicationVisibilitySnapshot(
        bundleIdentifier: String
    ) -> ApplicationVisibilitySnapshot {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard let application = applications.first(where: { $0.isActive && !$0.isTerminated })
            ?? applications.first(where: { !$0.isTerminated })
        else {
            return ApplicationVisibilitySnapshot(
                bundleIdentifier: bundleIdentifier,
                processActive: false,
                processHidden: false,
                processTerminated: true,
                activationPolicy: "unknown",
                ordinaryWindowCount: 0,
                onscreenWindowCount: 0
            )
        }

        let allWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        let onscreenWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        let activationPolicy: String = switch application.activationPolicy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
        return ApplicationVisibilitySnapshot(
            bundleIdentifier: bundleIdentifier,
            processActive: application.isActive,
            processHidden: application.isHidden,
            processTerminated: application.isTerminated,
            activationPolicy: activationPolicy,
            ordinaryWindowCount: allWindows.map {
                ordinaryWindowCount(
                    windowInfo: $0,
                    processIdentifier: application.processIdentifier
                )
            },
            onscreenWindowCount: onscreenWindows.map {
                ordinaryWindowCount(
                    windowInfo: $0,
                    processIdentifier: application.processIdentifier
                )
            }
        )
    }

    private static func frontmostWindowFrame() -> CGRect? {
        guard let processIdentifier = NSWorkspace.shared
            .frontmostApplication?
            .processIdentifier
        else { return nil }
        // Scroll delivery runs on the input/main run loop. Query WindowServer,
        // never the target application's AX server, which may be unresponsive.
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return frontmostWindowFrame(
            windowInfo: windowInfo,
            processIdentifier: processIdentifier
        )
    }

    private static func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Positive `lines` scrolls the content toward the beginning of the
    /// conversation, so the up key shows earlier messages.
    static func postScrollWheel(lines: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .line,
                  wheelCount: 1,
                  wheel1: lines,
                  wheel2: 0,
                  wheel3: 0
              )
        else { return }
        event.location = scrollTargetLocation(
            windowFrame: frontmostWindowFrame(),
            mouseLocation: currentMouseLocation()
        )
        event.flags = KeyboardHardwareModifierPolicy.currentForMappedAction()
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    static func postSystemKey(type: Int32) {
        postSystemKey(type: type, isDown: true)
        postSystemKey(type: type, isDown: false)
    }

    static func postSystemKey(type: Int32, isDown: Bool) {
        let keyState = isDown ? 0xA : 0xB
        let data1 = Int((type << 16) | Int32(keyState << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        guard let cgEvent = event.cgEvent else { return }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
