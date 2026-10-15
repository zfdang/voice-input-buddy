import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

extension KeyboardInjector {
    private static let manualAccessibilityLock = NSLock()
    private static var manualAccessibilityLoggedProcesses: Set<pid_t> = []
    static func manualAccessibilityResultName(_ result: AXError) -> String {
        switch result {
        case .success: return "success"
        case .attributeUnsupported: return "attribute_unsupported"
        case .cannotComplete: return "cannot_complete"
        case .invalidUIElement: return "invalid_element"
        case .apiDisabled: return "api_disabled"
        case .notImplemented: return "not_implemented"
        default: return "error_\(result.rawValue)"
        }
    }

    /// The fallback only runs when the Chromium attribute is unsupported, so the
    /// log has to name which attribute actually answered.
    static func manualAccessibilityResultToken(primary: AXError, fallback: AXError?) -> String {
        guard let fallback else { return manualAccessibilityResultName(primary) }
        return "fallback_enhanced_\(manualAccessibilityResultName(fallback))"
    }

    /// The fallback answer wins whenever it was attempted, because the primary
    /// attribute was unsupported by that app.
    static func manualAccessibilityEffectiveResult(
        primary: AXError,
        fallback: AXError?
    ) -> AXError {
        if primary == .success { return .success }
        return fallback ?? primary
    }

    /// The attribute is set on every attempt because it is idempotent, but only
    /// the first attempt and the attempt that finally builds the tree carry new
    /// information; the retries in between would repeat the same reason.
    static func shouldLogManualAccessibility(
        result: AXError,
        attempt: Int,
        alreadyLoggedSuccess: Bool
    ) -> Bool {
        if attempt == 0 { return true }
        return result == .success && !alreadyLoggedSuccess
    }

    @discardableResult
    static func announceManualAccessibility(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        attempt: Int
    ) -> Bool {
        AccessibilityMessaging.prepareQueries()
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let primary = AXUIElementSetAttributeValue(
            applicationElement,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        var fallback: AXError?
        if primary == .attributeUnsupported {
            fallback = AXUIElementSetAttributeValue(
                applicationElement,
                enhancedUserInterfaceAttribute as CFString,
                kCFBooleanTrue
            )
        }
        let result = manualAccessibilityEffectiveResult(primary: primary, fallback: fallback)

        manualAccessibilityLock.lock()
        let alreadyLoggedSuccess = manualAccessibilityLoggedProcesses.contains(processIdentifier)
        let shouldLog = shouldLogManualAccessibility(
            result: result,
            attempt: attempt,
            alreadyLoggedSuccess: alreadyLoggedSuccess
        )
        if result == .success {
            if manualAccessibilityLoggedProcesses.count >= 64 {
                manualAccessibilityLoggedProcesses.removeAll()
            }
            manualAccessibilityLoggedProcesses.insert(processIdentifier)
        }
        manualAccessibilityLock.unlock()

        if shouldLog {
            AppLogger.shared.write(
                "APP FOCUS manual_accessibility bundle=\(bundleIdentifier) " +
                    "attempt=\(attempt) " +
                    "result=\(manualAccessibilityResultToken(primary: primary, fallback: fallback))"
            )
        }
        return result == .success
    }

    static func applicationIsFrontmost(_ processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    static func focusComposer(
        processIdentifier: pid_t,
        emitDiagnostics: Bool = false
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var windowCount = 0
        var candidateCount = 0
        var eligibleCount = 0
        var excludedSensitiveCount = 0
        for window in applicationWindows(applicationElement) {
            windowCount += 1
            let candidates = accessibilityTextCandidates(in: window)
            candidateCount += candidates.count
            for candidate in candidates.map(\.snapshot) {
                let semanticText = [
                    candidate.identifier,
                    candidate.title,
                    candidate.description,
                    candidate.help,
                    candidate.placeholder,
                    candidate.context,
                ].joined(separator: " ").lowercased()
                if composerCandidateScore(candidate, windowFrame: axFrame(window)) != nil {
                    eligibleCount += 1
                } else if containsSensitiveAccessibilityTerms(semanticText) {
                    excludedSensitiveCount += 1
                }
            }
            guard let candidateIndex = bestComposerCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            if focusAccessibilityElement(
                candidates[candidateIndex].element,
                applicationElement: applicationElement
            ) {
                return true
            }
        }
        if emitDiagnostics {
            AppLogger.shared.write(
                "APP FOCUS scan bundle=\(NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier ?? "unknown") " +
                    "windows=\(windowCount) candidates=\(candidateCount) eligible=\(eligibleCount) " +
                    "excluded_sensitive=\(excludedSensitiveCount)"
            )
        }
        return false
    }

    static func weChatComposerFocusPoint(windowFrame: CGRect) -> CGPoint? {
        guard windowFrame.width >= 700, windowFrame.height >= 500 else { return nil }
        return CGPoint(
            x: windowFrame.minX + windowFrame.width * weChatComposerHorizontalRatio,
            y: windowFrame.minY + windowFrame.height * weChatComposerVerticalRatio
        )
    }

    static func usesWeChatComposerFallback(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == weChatBundleIdentifier
    }

    static func weChatComposerWindowFrame(
        _ windows: [(title: String, frame: CGRect)]
    ) -> CGRect? {
        windows
            .filter {
                ($0.title == "微信" || $0.title == "WeChat") &&
                    weChatComposerFocusPoint(windowFrame: $0.frame) != nil
            }
            .map(\.frame)
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    static func focusWeChatComposer(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let frame = weChatComposerWindowFrame(
            applicationWindows(applicationElement).compactMap { window in
                guard let frame = axFrame(window) else { return nil }
                return (
                    title: axString(window, attribute: kAXTitleAttribute),
                    frame: frame
                )
            }
        ),
              let point = weChatComposerFocusPoint(windowFrame: frame),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              )
        else { return false }
        let previousPointerLocation = CGEvent(source: nil)?.location
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if let previousPointerLocation,
           let restore = CGEvent(
               mouseEventSource: source,
               mouseType: .mouseMoved,
               mouseCursorPosition: previousPointerLocation,
               mouseButton: .left
           ) {
            restore.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            restore.post(tap: .cghidEventTap)
        }
        return true
    }

    static func captureFocusedAccessibilityTargetAsync(
        bundleIdentifier: String, completion: @escaping (AccessibilityFocusTarget?) -> Void
    ) {
        focusQueue.async {
            let target = captureFocusedAccessibilityTarget(bundleIdentifier: bundleIdentifier)
            DispatchQueue.main.async { completion(target) }
        }
    }

    static func captureFocusedAccessibilityTarget(
        bundleIdentifier: String
    ) -> AccessibilityFocusTarget? {
        guard isAccessibilityTrusted else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier == bundleIdentifier
        else { return nil }

        let role = axString(focusedElement, attribute: kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField",
              axBool(focusedElement, attribute: kAXEnabledAttribute) ?? true
        else { return nil }

        var contextParts: [String] = []
        var current = axElement(focusedElement, attribute: kAXParentAttribute)
        var window = axElement(focusedElement, attribute: kAXWindowAttribute)
        var ancestorCount = 0
        while let element = current, ancestorCount < 8 {
            let semanticText = axSemanticText(element)
            if !semanticText.isEmpty {
                contextParts.append(semanticText)
            }
            if axString(element, attribute: kAXRoleAttribute) == "AXWindow" {
                window = window ?? element
                break
            }
            current = axElement(element, attribute: kAXParentAttribute)
            ancestorCount += 1
        }

        let context = String(contextParts.joined(separator: " ").suffix(512))
        let target = AccessibilityFocusTarget(
            role: role,
            identifier: axString(focusedElement, attribute: kAXIdentifierAttribute),
            title: axString(focusedElement, attribute: kAXTitleAttribute),
            description: axString(focusedElement, attribute: kAXDescriptionAttribute),
            help: axString(focusedElement, attribute: kAXHelpAttribute),
            placeholder: axString(focusedElement, attribute: kAXPlaceholderValueAttribute),
            context: context,
            windowTitle: window.map { axString($0, attribute: kAXTitleAttribute) } ?? "",
            normalizedFrame: normalizedAccessibilityFrame(
                elementFrame: axFrame(focusedElement),
                windowFrame: window.flatMap(axFrame)
            )
        )
        let semanticText = [
            target.identifier,
            target.title,
            target.description,
            target.help,
            target.placeholder,
            target.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText),
              !semanticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return target
    }

    static func focusRecordedAccessibilityTarget(
        _ target: AccessibilityFocusTarget,
        processIdentifier: pid_t
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var ranked: [(element: AXUIElement, score: Int)] = []
        for window in applicationWindows(applicationElement) {
            let windowFrame = axFrame(window)
            let windowTitle = axString(window, attribute: kAXTitleAttribute)
            for candidate in accessibilityTextCandidates(in: window) {
                guard let score = recordedAccessibilityCandidateScore(
                    candidate.snapshot,
                    target: target,
                    windowTitle: windowTitle,
                    windowFrame: windowFrame
                ) else { continue }
                ranked.append((candidate.element, score))
            }
        }
        ranked.sort { $0.score > $1.score }
        guard let best = ranked.first,
              ranked.dropFirst().first.map({ best.score - $0.score >= 40 }) ?? true
        else { return false }
        return focusAccessibilityElement(
            best.element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: true
        )
    }

    static func recordedAccessibilityCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        target: AccessibilityFocusTarget,
        windowTitle: String,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == target.role else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText) else { return nil }

        var score = 0
        var strongMatches = 0
        if semanticValuesMatch(candidate.identifier, target.identifier) {
            score += 500
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.placeholder, target.placeholder) {
            score += 220
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.title, target.title) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.description, target.description) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.help, target.help) {
            score += 100
            strongMatches += 1
        }
        if semanticValuesMatch(windowTitle, target.windowTitle) {
            score += 100
        }

        let contextSimilarity = accessibilityContextSimilarity(candidate.context, target.context)
        score += Int(contextSimilarity * 180)
        if contextSimilarity >= 0.5 {
            strongMatches += 1
        }

        if let targetFrame = target.normalizedFrame,
           let candidateFrame = normalizedAccessibilityFrame(
               elementFrame: candidate.frame,
               windowFrame: windowFrame
           )
        {
            let distance = abs(targetFrame.x - candidateFrame.x) +
                abs(targetFrame.y - candidateFrame.y) +
                abs(targetFrame.width - candidateFrame.width) +
                abs(targetFrame.height - candidateFrame.height)
            // Geometry contributes at most 120 points. Distant or overflowing
            // coordinates contribute nothing; never convert an unbounded Double
            // from imported metadata or AX geometry to Int.
            if distance.isFinite, distance < 1 {
                score += 120 - Int(distance * 120)
            }
        }

        guard strongMatches > 0 else { return nil }
        return score >= 180 ? score : nil
    }

    private static func normalizedAccessibilityFrame(
        elementFrame: CGRect?,
        windowFrame: CGRect?
    ) -> NormalizedAccessibilityFrame? {
        guard let elementFrame, let windowFrame,
              windowFrame.width > 0, windowFrame.height > 0
        else { return nil }
        return NormalizedAccessibilityFrame(
            x: (elementFrame.minX - windowFrame.minX) / windowFrame.width,
            y: (elementFrame.minY - windowFrame.minY) / windowFrame.height,
            width: elementFrame.width / windowFrame.width,
            height: elementFrame.height / windowFrame.height
        )
    }

    private static func semanticValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return min(lhs.count, rhs.count) >= 4 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    private static func accessibilityContextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = accessibilityTokens(lhs)
        let right = accessibilityTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }

    private static func accessibilityTokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased().components(
                separatedBy: CharacterSet.alphanumerics.inverted
            ).filter { $0.count >= 2 }
        )
    }

    private static func containsSensitiveAccessibilityTerms(_ value: String) -> Bool {
        let value = value.lowercased()
        let terms = [
            "password", "passcode", "secret", "api key", "apikey", "token", "credit card",
            "密码", "口令", "密钥", "令牌", "银行卡", "借记卡", "信用卡",
        ]
        return terms.contains(where: value.contains)
    }

    private static func applicationWindows(_ applicationElement: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in [
            axElement(applicationElement, attribute: kAXFocusedWindowAttribute),
            axElement(applicationElement, attribute: kAXMainWindowAttribute),
        ].compactMap({ $0 }) + axElements(applicationElement, attribute: kAXWindowsAttribute) {
            if !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        return windows
    }

    private static func accessibilityTextCandidates(
        in window: AXUIElement
    ) -> [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] {
        struct PendingElement {
            let element: AXUIElement
            let context: String
            let selectedContext: Bool
        }

        let windowFrame = axFrame(window)
        var stack = [PendingElement(
            element: window,
            context: axSemanticText(window),
            selectedContext: axBool(window, attribute: kAXSelectedAttribute) ?? false
        )]
        var visitedElements: [CFHashCode: [AXUIElement]] = [CFHash(window): [window]]
        var budget = AccessibilityTraversalBudget(maximumNodes: maximumAccessibilityTraversalCount)
        var candidates: [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] = []

        guard budget.admitNode() else { return [] }
        while let current = stack.popLast(), budget.hasTimeRemaining {
            let ownContext = axSemanticText(current.element)
            let combinedContext = [current.context, ownContext]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let role = axString(current.element, attribute: kAXRoleAttribute)
            let frame = axFrame(current.element)
            let selectedContext = current.selectedContext ||
                (axBool(current.element, attribute: kAXSelectedAttribute) ?? false)

            if role == "AXTextArea" || role == "AXTextField" {
                candidates.append((
                    current.element,
                    AccessibilityTextCandidate(
                        role: role,
                        identifier: axString(current.element, attribute: kAXIdentifierAttribute),
                        title: axString(current.element, attribute: kAXTitleAttribute),
                        description: axString(current.element, attribute: kAXDescriptionAttribute),
                        help: axString(current.element, attribute: kAXHelpAttribute),
                        placeholder: axString(current.element, attribute: kAXPlaceholderValueAttribute),
                        context: combinedContext,
                        frame: frame,
                        enabled: axBool(current.element, attribute: kAXEnabledAttribute) ?? true,
                        focused: axBool(current.element, attribute: kAXFocusedAttribute) ?? false,
                        selectedContext: selectedContext
                    )
                ))
            }

            let childContext = String(combinedContext.suffix(512))
            var children: [(element: AXUIElement, priority: Int)] = []
            for attribute in accessibilityChildAttributes {
                guard budget.hasTimeRemaining else { break }
                for child in axElements(current.element, attribute: attribute) {
                    let hash = CFHash(child)
                    if visitedElements[hash]?.contains(where: { CFEqual($0, child) }) == true {
                        continue
                    }
                    guard let priority = accessibilityChildPriority(
                        role: { axString(child, attribute: kAXRoleAttribute) }, frame: { axFrame(child) },
                        windowFrame: windowFrame, budget: &budget) else { break }
                    visitedElements[hash, default: []].append(child)
                    children.append((child, priority))
                }
            }
            // Sorting is local; every child query was admitted under the same budget.
            children.sort { $0.priority < $1.priority }
            stack.append(contentsOf: children.map {
                PendingElement(element: $0.element, context: childContext, selectedContext: selectedContext)
            })
        }
        return candidates
    }

    static func accessibilityChildPriority(role: () -> String, frame: () -> CGRect?,
                                           windowFrame: CGRect?, budget: inout AccessibilityTraversalBudget) -> Int? {
        guard budget.admitNode() else { return nil }
        let roleValue = role()
        guard budget.hasTimeRemaining else { return nil }
        return accessibilityTraversalPriority(role: roleValue, frame: frame(), windowFrame: windowFrame)
    }

    static func accessibilityTraversalPriority(
        role: String,
        frame: CGRect?,
        windowFrame: CGRect?
    ) -> Int {
        var priority = role == "AXTextArea" || role == "AXTextField" ? 1_000_000 : 0
        guard let frame, let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else {
            return priority
        }
        if frame.intersects(windowFrame) {
            priority += 100_000
        }
        let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
        priority += Int(max(0, min(1, verticalPosition)) * 10_000)
        return priority
    }

    private static func focusAccessibilityElement(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool = false
    ) -> Bool {
        if accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        ) {
            return true
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        )
        if accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        ) {
            return true
        }
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
    }

    private static func accessibilityElementIsFocused(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        let applicationFocusedElementMatches = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { CFEqual($0, element) }
        return accessibilityFocusIsConfirmed(
            elementFocused: axBool(element, attribute: kAXFocusedAttribute) == true,
            applicationFocusedElementMatches: applicationFocusedElementMatches,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
    }

    static func accessibilityFocusIsConfirmed(
        elementFocused: Bool,
        applicationFocusedElementMatches: Bool?,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        if requiresApplicationFocusedElement {
            return applicationFocusedElementMatches == true
        }
        return elementFocused || applicationFocusedElementMatches == true
    }

    static func bestComposerCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = composerCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func composerCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == "AXTextArea" || candidate.role == "AXTextField" else {
            return nil
        }

        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()

        let excludedTerms = [
            "title", "rename", "api key", "apikey", "token", "password", "secret",
            "command palette", "address bar", "approval", "permission", "code editor", "monaco",
            "标题", "重命名", "密钥", "令牌", "密码", "审批", "权限", "代码编辑器",
        ]
        guard !excludedTerms.contains(where: semanticText.contains) else { return nil }

        let strongTerms = [
            "composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
            "message-input", "message_input", "prompt input", "message input",
            "消息输入", "输入消息", "发送消息",
        ]
        let supportingTerms = [
            "message", "prompt", "reply", "ask claude", "ask anything", "chat", "提问", "回复",
        ]
        let explicitlyAllowedTerms = [
            "search", "find", "filter", "settings", "preferences", "terminal", "console", "shell", "xterm",
            "搜索", "查找", "筛选", "设置", "偏好", "终端", "控制台",
        ]
        let hasStrongSemanticMatch = strongTerms.contains(where: semanticText.contains)
        let hasSupportingSemanticMatch = supportingTerms.contains(where: semanticText.contains)
        let hasExplicitlyAllowedMatch = explicitlyAllowedTerms.contains(where: semanticText.contains)
        guard candidate.role == "AXTextArea" || hasStrongSemanticMatch || hasSupportingSemanticMatch ||
                hasExplicitlyAllowedMatch else {
            return nil
        }

        var score = candidate.role == "AXTextArea" ? 50 : 0
        if hasStrongSemanticMatch {
            score += 120
        } else if hasSupportingSemanticMatch {
            score += 70
        } else if hasExplicitlyAllowedMatch {
            score += 80
        }

        if let frame = candidate.frame {
            if frame.width >= 280 { score += 25 }
            if (24...500).contains(frame.height) { score += 10 }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                if frame.width / windowFrame.width >= 0.45 { score += 30 }
                let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
                if verticalPosition >= 0.55 {
                    score += 20
                } else if verticalPosition <= 0.25 {
                    score -= 15
                }
            }
        }

        return score >= 80 ? score : nil
    }

    static func focusCmuxTerminal(
        processIdentifier: pid_t,
        keyPoster: KeyPoster
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var terminalFrame: CGRect?
        for window in applicationWindows(applicationElement) {
            let candidates = accessibilityTextCandidates(in: window)
            guard let candidateIndex = bestCmuxTerminalCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            terminalFrame = terminalFrame ?? candidates[candidateIndex].snapshot.frame
            if focusAccessibilityElement(
                candidates[candidateIndex].element,
                applicationElement: applicationElement,
                requiresApplicationFocusedElement: true
            ) {
                return true
            }
        }

        let focusedElementSnapshot = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { focusedElement in
            (
                role: axString(focusedElement, attribute: kAXRoleAttribute),
                frame: axFrame(focusedElement)
            )
        }
        if let keyCode = cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: focusedElementSnapshot?.role,
            focusedFrame: focusedElementSnapshot?.frame,
            terminalFrame: terminalFrame
        ) {
            keyPoster(keyCode, [.maskCommand, .maskShift])
        }
        return false
    }

    static func cmuxFocusRecoveryShortcutKeyCode(
        focusedRole: String?,
        focusedFrame: CGRect?,
        terminalFrame: CGRect?
    ) -> CGKeyCode? {
        if let focusedFrame, let terminalFrame,
           focusedFrame.minX >= terminalFrame.maxX {
            return 14 // Cmd+Shift+E: cmux Toggle Right Sidebar Focus returns to the terminal.
        }
        switch focusedRole {
        case "AXTextArea", "AXTextField":
            return 0 // Cmd+Shift+A: cmux Focus TextBox Input toggles back to the terminal.
        case nil, "", "AXApplication", "AXWindow":
            return nil
        default:
            return nil // Left-sidebar and other controls are recovered by the scheduled surface.focus retry.
        }
    }

    static func cmuxTerminalIsApplicationFocused(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let focusedElement = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return false }
        return applicationWindows(applicationElement).contains { window in
            accessibilityTextCandidates(in: window).contains { candidate in
                cmuxTerminalCandidateScore(candidate.snapshot, windowFrame: axFrame(window)) != nil &&
                    CFEqual(candidate.element, focusedElement)
            }
        }
    }

    static func bestCmuxTerminalCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = cmuxTerminalCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func cmuxTerminalCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == "AXTextArea" else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()
        guard semanticText.contains("terminal content area") else { return nil }

        var score = 200
        if candidate.focused { score += 1_000 }
        if candidate.selectedContext { score += 500 }
        if let frame = candidate.frame {
            score += min(100, Int(frame.width * frame.height / 10_000))
            if let windowFrame, frame.intersects(windowFrame) { score += 100 }
        }
        return score
    }

    @discardableResult
    static func focusCmux(
        applicationURL: URL,
        cliURL: URL? = nil,
        runner: CmuxCommandRunner = runCmuxCommand,
        canContinue: () -> Bool = { true },
        terminalFocuser: (String) -> Bool = { _ in true }
    ) -> Bool {
        guard canContinue() else { return false }
        guard let cliURL = cliURL ?? cmuxCLIURL(applicationURL: applicationURL) else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=cli_unavailable")
            return false
        }

        let currentResult = runner(cliURL, ["rpc", "surface.current", "{}"], 1)
        guard !currentResult.timedOut, currentResult.terminationStatus == 0 else {
            let reason = currentResult.timedOut ? "current_timeout" : "current_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return false
        }
        guard canContinue() else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: currentResult.standardOutput) as? [String: Any],
              let surfaceID = payload["surface_id"] as? String,
              UUID(uuidString: surfaceID) != nil,
              let surfaceType = (payload["surface_type"] as? String) ?? (payload["type"] as? String),
              surfaceType.caseInsensitiveCompare("terminal") == .orderedSame
        else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=no_current_terminal")
            return false
        }

        guard let focusParameters = try? JSONSerialization.data(
            withJSONObject: ["surface_id": surfaceID],
            options: [.sortedKeys]
        ), let focusJSON = String(data: focusParameters, encoding: .utf8) else {
            return false
        }
        guard canContinue() else { return false }

        let focusResult = runner(cliURL, ["rpc", "surface.focus", focusJSON], 1)
        guard !focusResult.timedOut, focusResult.terminationStatus == 0 else {
            let reason = focusResult.timedOut ? "focus_timeout" : "focus_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return false
        }
        guard canContinue() else { return false }
        return terminalFocuser(surfaceID)
    }

    static func cmuxCLIURL(
        applicationURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [
            applicationURL.appendingPathComponent("Contents/bin/cmux"),
            applicationURL.appendingPathComponent("Contents/Resources/bin/cmux"),
        ]
        candidates.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("cmux") })
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/cmux"),
            URL(fileURLWithPath: "/usr/local/bin/cmux"),
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runCmuxCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> CmuxCommandResult {
        BoundedCommandRunner.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }

    static func axAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        AccessibilityMessaging.prepareQueries()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String {
        axAttribute(element, attribute: attribute) as? String ?? ""
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        axAttribute(element, attribute: attribute) as? Bool
    }

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = axAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = axAttribute(element, attribute: attribute) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axAttribute(element, attribute: kAXPositionAttribute),
              let sizeValue = axAttribute(element, attribute: kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func axSemanticText(_ element: AXUIElement) -> String {
        [
            axString(element, attribute: kAXIdentifierAttribute),
            axString(element, attribute: kAXTitleAttribute),
            axString(element, attribute: kAXDescriptionAttribute),
            axString(element, attribute: kAXHelpAttribute),
            axString(element, attribute: kAXPlaceholderValueAttribute),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

}
