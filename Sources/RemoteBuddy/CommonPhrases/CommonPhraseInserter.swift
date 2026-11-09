import AppKit

/// Inserts using AXSelectedText or a temporary clipboard paste after validating
/// public focus metadata. Target text is never read.
final class CommonPhraseInserter {
    enum WriteResult {
        case inserted
        case pasteSubmitted
        case failed(String)
    }
    typealias Writer = (String, pid_t, @escaping (WriteResult) -> Void) -> Void

    private struct Request {
        let operationID: UInt64
        let start: TimeInterval
        let text: String
        let processID: pid_t
        let completion: (String) -> Void
    }
    private let write: Writer
    private let logger: (String) -> Void
    private var queue: [Request] = []
    private var busy = false
    private var operation: UInt64 = 0

    init(write: @escaping Writer = { text, processID, completion in
        writeUsingAvailableRoute(text, processID: processID, completion: completion)
    }, logger: @escaping (String) -> Void = AppLogger.shared.write) {
        self.write = write
        self.logger = logger
    }

    func insert(_ text: String, into processID: pid_t, completion: @escaping (String) -> Void) {
        operation &+= 1
        logger("COMMON_PHRASES INSERT operation_id=\(operation) phase=requested")
        queue.append(Request(operationID: operation, start: ProcessInfo.processInfo.systemUptime,
            text: text, processID: processID, completion: completion))
        drain()
    }

    func cancelPending() {
        let pending = queue
        queue.removeAll()
        for request in pending { request.completion("common_phrases.error.cancelled") }
    }

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let request = queue.removeFirst()
        write(request.text, request.processID) { [weak self] result in
            guard let self else { return }
            let message: String
            let status: String
            let reason: String
            switch result {
            case .inserted:
                message = "common_phrases.inserted"; status = "inserted"; reason = "ax_inserted"
            case .pasteSubmitted:
                message = "common_phrases.paste_submitted"; status = "event_submitted"; reason = "clipboard_paste"
            case let .failed(failure):
                message = "common_phrases.error." + failure; status = "failed"; reason = failure
            }
            self.logger("COMMON_PHRASES INSERT operation_id=\(request.operationID) phase=completed " +
                "result=\(status) reason=\(reason) " +
                "elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - request.start) * 1000))")
            self.busy = false
            request.completion(message)
            self.drain()
        }
    }

    private struct PasteTarget {
        let processID: pid_t
        let element: AXUIElement?
        let terminal: Bool
        let bundleIdentifier: String
    }

    static func prefersPaste(bundleIdentifier: String, electron: Bool, webContent: Bool) -> Bool {
        electron || webContent || isTerminal(bundleIdentifier) || bundleIdentifier == "com.sublimetext.4" ||
            ["com.openai.codex", "com.apple.Safari", "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
             "com.brave.Browser", "org.mozilla.firefox"].contains { bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".") }
    }

    static func isTerminal(_ bundleIdentifier: String) -> Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty", "com.mitchellh.ghostty", "app.getmoshi.desktop"]
            .contains(bundleIdentifier)
    }

    private static func writeUsingAvailableRoute(_ text: String, processID: pid_t,
                                                completion: @escaping (WriteResult) -> Void) {
        AccessibilityMessaging.queryQueue.async {
            func finish(_ failure: String?) { DispatchQueue.main.async { completion(failure.map { .failed($0) } ?? .inserted) } }
            guard canSubmit(to: processID) else { finish(submissionFailure(processID)); return }
            let app = NSRunningApplication(processIdentifier: processID)
            let bundleID = app?.bundleIdentifier ?? ""
            let terminal = isTerminal(bundleID)
            _ = KeyboardInjector.announceManualAccessibility(processIdentifier: processID,
                bundleIdentifier: bundleID, attempt: 0)
            let element = focusedElement(processID)
            let target = PasteTarget(processID: processID, element: element, terminal: terminal, bundleIdentifier: bundleID)
            guard let element else {
                if terminal { paste(text, target: target, completion: completion) }
                else { finish("input_unavailable") }
                return
            }
            guard safeField(element, target: target) else { finish("input_unavailable"); return }
            let electron = app?.bundleURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            } ?? false
            var webContent = false
            var ancestor: AXUIElement? = element
            var budget = AccessibilityTraversalBudget(maximumNodes: 8, maximumDuration: 0.15)
            while let current = ancestor, budget.admitNode() {
                let attributes = AccessibilityMessaging.attributes(current, keys: [kAXRoleAttribute, kAXParentAttribute])
                if attributes[kAXRoleAttribute] as? String == "AXWebArea" { webContent = true; break }
                ancestor = (attributes[kAXParentAttribute] as AnyObject?).flatMap {
                    CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
                }
            }
            var settable = DarwinBoolean(false)
            let writable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success
                && settable.boolValue
            if prefersPaste(bundleIdentifier: bundleID, electron: electron, webContent: webContent) || !writable {
                paste(text, target: target, completion: completion)
                return
            }
            guard validate(target) == nil else { finish("target_changed"); return }
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            // Never retry an ambiguous AX failure as a paste: the app may already
            // have inserted the phrase even when the IPC reply timed out.
            if result == .attributeUnsupported || result == .notImplemented {
                paste(text, target: target, completion: completion)
            } else { finish(result == .success ? nil : "input_unavailable") }
        }
    }

    private static func submissionFailure(_ processID: pid_t) -> String {
        KeyboardInjector.isAccessibilityTrusted ? "target_changed" : "accessibility_required"
    }

    private static func canSubmit(to processID: pid_t) -> Bool {
        KeyboardInjector.isAccessibilityTrusted && !SecureInputMonitor.isEnabled() &&
            processID != ProcessInfo.processInfo.processIdentifier &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }

    private static func focusedElement(_ processID: pid_t) -> AXUIElement? {
        AccessibilityMessaging.prepareQueries()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(processID),
            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    private static func safeField(_ element: AXUIElement, target: PasteTarget) -> Bool {
        let terminal = target.terminal
        let values = AccessibilityMessaging.attributes(element, keys: [kAXRoleAttribute, kAXSubroleAttribute,
            kAXEnabledAttribute, "AXProtectedContent", kAXIdentifierAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXSelectedTextRangeAttribute])
        let role = values[kAXRoleAttribute] as? String ?? ""
        let subrole = values[kAXSubroleAttribute] as? String ?? ""
        let semanticText = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXPlaceholderValueAttribute, kAXHelpAttribute]
            .compactMap { values[$0] as? String }.joined(separator: " ")
        // Sublime's custom editor exposes its standard window as the focused
        // element, not an AX text area. Require its enabled public Paste command
        // instead of rejecting the buffer for lacking a text-selection attribute.
        let windowEditor = permitsWindowEditor(bundleIdentifier: target.bundleIdentifier,
            role: role, subrole: subrole)
        guard !values.isEmpty, permitsInsertion(role: terminal || windowEditor ? kAXTextAreaRole : role,
            subrole: subrole, enabled: values[kAXEnabledAttribute] as? Bool ?? true,
            protectedContent: (values["AXProtectedContent"] as? Bool) ?? (values["AXProtectedContent"] as? NSNumber)?.boolValue ?? false,
            identifier: semanticText, secureInputEnabled: SecureInputMonitor.isEnabled()) else { return false }
        if windowEditor { return hasEnabledPasteCommand(processID: target.processID) }
        guard let value = values[kAXSelectedTextRangeAttribute], CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return terminal
        }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(unsafeBitCast(value as CFTypeRef, to: AXValue.self), .cfRange, &range) && range.length == 0
    }

    private static func validate(_ target: PasteTarget) -> String? {
        guard canSubmit(to: target.processID) else { return submissionFailure(target.processID) }
        let current = focusedElement(target.processID)
        if let original = target.element {
            guard let current, CFEqual(original, current) else { return "target_changed" }
        } else if !target.terminal { return "input_unavailable" }
        if let current, !safeField(current, target: target) { return "input_unavailable" }
        return nil
    }

    private static func paste(_ text: String, target: PasteTarget, completion: @escaping (WriteResult) -> Void) {
        DispatchQueue.main.async {
            CommonPhraseClipboardPaste.shared.paste(text, validate: { done in
                AccessibilityMessaging.queryQueue.async {
                    let failure = validate(target)
                    DispatchQueue.main.async { done(failure) }
                }
            }, canSubmit: { canSubmit(to: target.processID) }) { failure in
                completion(failure.map { .failed($0) } ?? .pasteSubmitted)
            }
        }
    }

    static func permitsWindowEditor(bundleIdentifier: String, role: String, subrole: String) -> Bool {
        bundleIdentifier == "com.sublimetext.4" && role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    private static func hasEnabledPasteCommand(processID: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(processID)
        let attributes = AccessibilityMessaging.attributes(app, keys: [kAXMenuBarAttribute])
        guard let value = attributes[kAXMenuBarAttribute], CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return false }
        var pending = [unsafeBitCast(value as CFTypeRef, to: AXUIElement.self)]
        var budget = AccessibilityTraversalBudget(maximumNodes: 120, maximumDuration: 0.35)
        while !pending.isEmpty, budget.admitNode() {
            let element = pending.removeFirst()
            let values = AccessibilityMessaging.attributes(element,
                keys: [kAXIdentifierAttribute, kAXEnabledAttribute, kAXChildrenAttribute])
            if values[kAXIdentifierAttribute] as? String == "paste:" {
                return values[kAXEnabledAttribute] as? Bool == true
            }
            if let children = values[kAXChildrenAttribute] as? [AXUIElement] { pending.append(contentsOf: children) }
        }
        return false
    }

    static func permitsInsertion(role: String, subrole: String, enabled: Bool,
                                 protectedContent: Bool, identifier: String, secureInputEnabled: Bool = false) -> Bool {
        !secureInputEnabled && enabled && !protectedContent && subrole != kAXSecureTextFieldSubrole &&
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) &&
            !["password", "passcode", "token", "secret", "apikey", "api_key", "api key",
              "credit card", "密码", "口令", "密钥", "令牌", "信用卡", "银行卡", "借记卡"].contains(where: identifier.lowercased().contains)
    }
}
