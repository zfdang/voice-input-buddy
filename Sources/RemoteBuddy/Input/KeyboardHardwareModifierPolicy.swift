import CoreGraphics

/// Navigation-key decoration is not evidence of an independently held Fn key.
enum KeyboardHardwareModifierPolicy {
    /// Mapped actions inherit physical shortcut modifiers, but never implicit
    /// navigation decoration. An explicitly configured Fn is added separately.
    static func mappedActionFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.subtracting([.maskSecondaryFn, .maskNumericPad])
    }

    static func currentForMappedAction() -> CGEventFlags {
        mappedActionFlags(current())
    }

    static func normalized(_ flags: CGEventFlags, fnKeyDown: Bool,
                           combinedFlags: CGEventFlags, combinedFnKeyDown: Bool) -> CGEventFlags {
        if flags.contains(.maskNumericPad) {
            // Suppressed native navigation can leave both HID Fn flags and key 63
            // stale after key-up. Require session evidence before inheriting Fn.
            // Only reconcile navigation decoration; ordinary hardware modifiers
            // and Fn without that decoration remain authoritative.
            let sessionHasFn = combinedFlags.contains(.maskSecondaryFn) || combinedFnKeyDown
            return sessionHasFn ? flags.union(.maskSecondaryFn) : flags.subtracting(.maskSecondaryFn)
        }
        return fnKeyDown ? flags.union(.maskSecondaryFn) : flags
    }

    static func current() -> CGEventFlags {
        normalized(CGEventSource.flagsState(.hidSystemState),
            fnKeyDown: CGEventSource.keyState(.hidSystemState, key: 63),
            combinedFlags: CGEventSource.flagsState(.combinedSessionState),
            combinedFnKeyDown: CGEventSource.keyState(.combinedSessionState, key: 63))
    }

    /// A fresh, read-only observation for intermittent paste failures. Queries
    /// are sequential, so these fields may differ from the flags that blocked paste.
    static func diagnosticSnapshot() -> String {
        let raw = CGEventSource.flagsState(.hidSystemState)
        let combined = CGEventSource.flagsState(.combinedSessionState)
        let fnDown = CGEventSource.keyState(.hidSystemState, key: 63)
        let combinedFnDown = CGEventSource.keyState(.combinedSessionState, key: 63)
        let effective = normalized(raw, fnKeyDown: fnDown,
            combinedFlags: combined, combinedFnKeyDown: combinedFnDown)
        let navigationKeys: [CGKeyCode] = [115, 116, 117, 119, 121, 123, 124, 125, 126]
        let held = navigationKeys.filter {
            CGEventSource.keyState(.hidSystemState, key: $0)
        }.map(String.init).joined(separator: ",")
        return "observed_raw_flags=\(raw.rawValue) observed_combined_flags=\(combined.rawValue) " +
            "observed_fn_key_down=\(fnDown) observed_combined_fn_key_down=\(combinedFnDown) " +
            "observed_effective_flags=\(effective.rawValue) " +
            "observed_navigation_keys=\(held.isEmpty ? "none" : held)"
    }
}
