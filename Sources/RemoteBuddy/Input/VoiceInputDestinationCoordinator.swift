import AppKit
import ApplicationServices
import Foundation

enum VoiceInputDestinationCancellation: String, Equatable {
    case actionFailed = "action_failed"
    case superseded
    case targetChanged = "target_changed"
    case sensitiveDestination = "sensitive_destination"
    case timedOut = "timed_out"
}

enum VoiceInputDestinationWaitResult: Equatable {
    case ready
    case cancelled(VoiceInputDestinationCancellation)
}

enum VoiceInputDestinationWait {
    case immediate
    case cancelled(VoiceInputDestinationCancellation)
    case waiting(ScheduledOperation)
}

enum VoiceInputDestinationState: Equatable {
    case waiting
    case ready
    case cancelled(VoiceInputDestinationCancellation)
}

enum VoiceInputDestinationIntent: Equatable {
    case application(bundleIdentifier: String)
    case shortcut
    case focusInput

    static func resolve(
        configured: ConfiguredButtonAction,
        applicationProfile: CustomApplicationProfile?
    ) -> VoiceInputDestinationIntent? {
        if let application = configured.action.presetApplication {
            return .application(bundleIdentifier: application.bundleIdentifier)
        }
        if configured.action == .openCustomApplication, let applicationProfile {
            return .application(bundleIdentifier: applicationProfile.bundleIdentifier)
        }
        if configured.action == .focusInput { return .focusInput }
        if configured.action == .customShortcut, configured.shortcut != nil {
            return .shortcut
        }
        return nil
    }
}

struct VoiceInputDestinationSnapshot: Equatable {
    let bundleIdentifier: String?
    let role: String
    let subrole: String
    let enabled: Bool
    let editable: Bool
    let protectedContent: Bool
    let secureInputEnabled: Bool
    let semanticText: String
    let focusIdentity: String

    init(
        bundleIdentifier: String?,
        role: String,
        subrole: String,
        enabled: Bool,
        editable: Bool,
        protectedContent: Bool,
        semanticText: String,
        focusIdentity: String = "",
        secureInputEnabled: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
        self.enabled = enabled
        self.editable = editable
        self.protectedContent = protectedContent
        self.secureInputEnabled = secureInputEnabled
        self.semanticText = semanticText
        self.focusIdentity = focusIdentity
    }

    private static let sensitiveTerms = [
        "password", "passcode", "secret", "api key", "apikey", "token", "credit card",
        "密码", "口令", "密钥", "令牌", "信用卡", "银行卡", "借记卡",
    ]
    private static let nonEditingTerms = [
        "search", "find", "filter", "address bar", "settings", "preferences", "command palette",
        "搜索", "查找", "筛选", "设置", "偏好",
    ]

    var isSensitiveDestination: Bool {
        if secureInputEnabled || protectedContent || role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        let text = semanticText.lowercased()
        return Self.sensitiveTerms.contains(where: text.contains)
    }

    var isSafeEditableDestination: Bool {
        guard enabled, editable, !isSensitiveDestination else { return false }
        guard role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" else {
            return false
        }
        let text = semanticText.lowercased()
        return !Self.nonEditingTerms.contains(where: text.contains)
    }

    static func system() -> VoiceInputDestinationSnapshot {
        let secureInputEnabled = SecureInputMonitor.isEnabled()
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard AXIsProcessTrusted() else {
            return empty(bundleIdentifier: frontmostBundleIdentifier, secureInputEnabled: secureInputEnabled)
        }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else {
            return empty(bundleIdentifier: frontmostBundleIdentifier, secureInputEnabled: secureInputEnabled)
        }

        var processIdentifier: pid_t = 0
        let focusedBundleIdentifier: String?
        if AXUIElementGetPid(focusedElement, &processIdentifier) == .success {
            focusedBundleIdentifier = NSRunningApplication(
                processIdentifier: processIdentifier
            )?.bundleIdentifier
        } else {
            focusedBundleIdentifier = nil
        }
        let attributes = AccessibilityMessaging.attributes(focusedElement, keys: [
            kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute,
            kAXEnabledAttribute, "AXEditable", "AXProtectedContent",
        ])
        let role = attributes[kAXRoleAttribute] as? String ?? ""
        let subrole = attributes[kAXSubroleAttribute] as? String ?? ""
        let semanticText = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXHelpAttribute, kAXPlaceholderValueAttribute].compactMap { attributes[$0] as? String }.joined(separator: " ")
        let roleIsEditable = role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"
        return VoiceInputDestinationSnapshot(
            bundleIdentifier: focusedBundleIdentifier ?? frontmostBundleIdentifier,
            role: role, subrole: subrole,
            enabled: attributes[kAXEnabledAttribute] as? Bool ?? true,
            editable: attributes["AXEditable"] as? Bool ?? roleIsEditable,
            protectedContent: attributes["AXProtectedContent"] as? Bool ?? false,
            semanticText: semanticText,
            focusIdentity: "\(processIdentifier):\(CFHash(focusedElement))",
            secureInputEnabled: secureInputEnabled || SecureInputMonitor.isEnabled()
        )
    }

    private static func empty(bundleIdentifier: String?, secureInputEnabled: Bool) -> VoiceInputDestinationSnapshot {
        VoiceInputDestinationSnapshot(
            bundleIdentifier: bundleIdentifier,
            role: "",
            subrole: "",
            enabled: false,
            editable: false,
            protectedContent: false,
            semanticText: "", secureInputEnabled: secureInputEnabled
        )
    }

    private static func axElement(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        AccessibilityMessaging.prepareQueries()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

}

/// Runtime state and snapshot completions are confined to the main queue.
final class VoiceInputDestinationCoordinator {
    typealias Scheduler = OperationScheduler
    typealias SnapshotProvider = () -> VoiceInputDestinationSnapshot
    typealias AsyncSnapshotProvider = (@escaping (VoiceInputDestinationSnapshot) -> Void) -> Void

    private struct PendingRequest {
        let id: UInt64
        let intent: VoiceInputDestinationIntent
        var initialBundleIdentifier: String?
        var initialFocusIdentity: String
        var initialWasSafeEditable: Bool
        var initialSnapshotCaptured = false
        var adoptedShortcutBundleIdentifier: String?
        var observedExpectedApplication = false
        var focusOperationCompleted = false
        var waiter: ((VoiceInputDestinationWaitResult) -> Void)?
    }

    private enum Evaluation {
        case waiting
        case ready
        case cancelled(VoiceInputDestinationCancellation)
    }

    private let pollInterval: TimeInterval
    private let maximumWait: TimeInterval
    private let schedule: Scheduler
    private let snapshot: SnapshotProvider
    private let querySnapshot: AsyncSnapshotProvider
    private let usesAsyncSnapshots: Bool
    private var directValidationGeneration: UInt64 = 0
    private let onStateChange: (VoiceInputDestinationState) -> Void
    private var generation: UInt64 = 0
    private var pendingRequest: PendingRequest?
    private var timeoutTask: ScheduledOperation?
    private var pollTask: ScheduledOperation?

    init(
        pollInterval: TimeInterval = 0.05,
        maximumWait: TimeInterval = 5,
        schedule: @escaping Scheduler = ScheduledOperation.mainQueue,
        snapshot: SnapshotProvider? = nil,
        querySnapshot: AsyncSnapshotProvider? = nil,
        onStateChange: @escaping (VoiceInputDestinationState) -> Void = { _ in }
    ) {
        self.pollInterval = pollInterval
        self.maximumWait = maximumWait
        self.schedule = schedule
        self.snapshot = snapshot ?? VoiceInputDestinationSnapshot.system
        usesAsyncSnapshots = snapshot == nil || querySnapshot != nil
        if let querySnapshot {
            self.querySnapshot = querySnapshot
        } else if let snapshot {
            self.querySnapshot = { completion in completion(snapshot()) }
        } else {
            self.querySnapshot = { completion in
                AccessibilityMessaging.queryQueue.async {
                    let value = VoiceInputDestinationSnapshot.system()
                    DispatchQueue.main.async { completion(value) }
                }
            }
        }
        self.onStateChange = onStateChange
    }

    @discardableResult
    func beginTargetSwitch(
        intent: VoiceInputDestinationIntent,
        onCaptured: @escaping (UInt64) -> Void = { _ in }
    ) -> UInt64 {
        cancelPending(reason: .superseded)
        generation &+= 1
        let requestID = generation
        pendingRequest = PendingRequest(
            id: requestID,
            intent: intent,
            initialBundleIdentifier: nil,
            initialFocusIdentity: "",
            initialWasSafeEditable: false
        )
        timeoutTask = schedule(maximumWait) { [weak self] in
            guard self?.pendingRequest?.id == requestID else { return }
            self?.cancelPending(reason: .timedOut)
        }
        AppLogger.shared.write("VOICE DESTINATION pending request=\(requestID) intent=\(intent.logValue)")
        querySnapshot { [weak self] initial in
            guard let self, self.pendingRequest?.id == requestID else { return }
            self.pendingRequest?.initialBundleIdentifier = initial.bundleIdentifier
            self.pendingRequest?.initialFocusIdentity = initial.focusIdentity
            self.pendingRequest?.initialWasSafeEditable = initial.isSafeEditableDestination
            self.pendingRequest?.initialSnapshotCaptured = true
            onCaptured(requestID)
            if self.pendingRequest?.id == requestID, self.pendingRequest?.waiter != nil {
                self.poll(requestID: requestID)
            }
        }
        return requestID
    }

    func completeFocusOperation(requestID: UInt64, succeeded: Bool) {
        guard pendingRequest?.id == requestID else { return }
        guard succeeded else { cancelPending(reason: .actionFailed); return }
        pendingRequest?.focusOperationCompleted = true
        if pendingRequest?.waiter != nil { poll(requestID: requestID) }
    }

    func cancel(requestID: UInt64, reason: VoiceInputDestinationCancellation) {
        guard pendingRequest?.id == requestID else { return }
        cancelPending(reason: reason)
    }

    func waitUntilReady(
        completion: @escaping (VoiceInputDestinationWaitResult) -> Void
    ) -> VoiceInputDestinationWait {
        if usesAsyncSnapshots { return waitForAsyncSnapshot(completion: completion) }
        guard var request = pendingRequest else {
            // Direct, explicit voice typing may target search fields or custom editors.
            // Protected/sensitive fields must still be refused without a pending launch.
            if snapshot().isSensitiveDestination {
                onStateChange(.cancelled(.sensitiveDestination))
                return .cancelled(.sensitiveDestination)
            }
            return .immediate
        }
        switch evaluate(snapshot(), request: &request) {
        case .ready:
            pendingRequest = request
            completePending(with: .ready)
            return .immediate
        case let .cancelled(reason):
            pendingRequest = request
            completePending(with: .cancelled(reason))
            return .cancelled(reason)
        case .waiting:
            request.waiter = completion
            pendingRequest = request
            onStateChange(.waiting)
            schedulePoll(requestID: request.id)
            return .waiting(ScheduledOperation.mainQueueCancellation { [weak self] in
                self?.removeWaiter(requestID: request.id)
            })
        }
    }

    func shutdown() {
        directValidationGeneration &+= 1
        cancelPending(reason: .superseded)
    }

    private func schedulePoll(requestID: UInt64) {
        pollTask?.cancel()
        pollTask = schedule(pollInterval) { [weak self] in
            self?.poll(requestID: requestID)
        }
    }

    private func waitForAsyncSnapshot(completion: @escaping (VoiceInputDestinationWaitResult) -> Void) -> VoiceInputDestinationWait {
        if var request = pendingRequest {
            request.waiter = completion
            pendingRequest = request
            onStateChange(.waiting)
            poll(requestID: request.id)
            return .waiting(ScheduledOperation.mainQueueCancellation { [weak self] in self?.removeWaiter(requestID: request.id) })
        }
        directValidationGeneration &+= 1
        let token = directValidationGeneration
        let deadline = schedule(maximumWait) { [weak self] in
            guard let self, self.directValidationGeneration == token else { return }
            self.directValidationGeneration &+= 1
            self.onStateChange(.cancelled(.timedOut))
            completion(.cancelled(.timedOut))
        }
        querySnapshot { [weak self] value in
            guard let self, self.directValidationGeneration == token else { return }
            self.directValidationGeneration &+= 1
            deadline.cancel()
            let result: VoiceInputDestinationWaitResult = value.isSensitiveDestination
                ? .cancelled(.sensitiveDestination) : .ready
            switch result {
            case .ready: self.onStateChange(.ready)
            case let .cancelled(reason): self.onStateChange(.cancelled(reason))
            }
            completion(result)
        }
        return .waiting(ScheduledOperation.mainQueueCancellation { [weak self] in
            deadline.cancel()
            if self?.directValidationGeneration == token { self?.directValidationGeneration &+= 1 }
        })
    }

    private func poll(requestID: UInt64) {
        guard pendingRequest?.id == requestID, pendingRequest?.initialSnapshotCaptured == true else { return }
        querySnapshot { [weak self] value in
            guard let self, var request = self.pendingRequest, request.id == requestID else { return }
            switch self.evaluate(value, request: &request) {
            case .waiting:
                self.pendingRequest = request
                self.schedulePoll(requestID: requestID)
            case .ready:
                self.pendingRequest = request
                self.completePending(with: .ready)
            case let .cancelled(reason):
                self.pendingRequest = request
                self.completePending(with: .cancelled(reason))
            }
        }
    }

    private func evaluate(
        _ current: VoiceInputDestinationSnapshot,
        request: inout PendingRequest
    ) -> Evaluation {
        guard request.initialSnapshotCaptured else { return .waiting }
        if current.isSensitiveDestination { return .cancelled(.sensitiveDestination) }
        switch request.intent {
        case let .application(expectedBundleIdentifier):
            if current.bundleIdentifier == expectedBundleIdentifier {
                request.observedExpectedApplication = true
                return current.isSafeEditableDestination ? .ready : .waiting
            }
            if request.observedExpectedApplication {
                return .cancelled(.targetChanged)
            }
            return .waiting

        case .focusInput:
            guard request.focusOperationCompleted else { return .waiting }
            guard current.bundleIdentifier == request.initialBundleIdentifier else {
                return .cancelled(.targetChanged)
            }
            return current.isSafeEditableDestination ? .ready : .waiting

        case .shortcut:
            if let adopted = request.adoptedShortcutBundleIdentifier {
                guard current.bundleIdentifier == adopted else {
                    return .cancelled(.targetChanged)
                }
                return current.isSafeEditableDestination ? .ready : .waiting
            }
            if current.bundleIdentifier != request.initialBundleIdentifier,
               let currentBundleIdentifier = current.bundleIdentifier {
                request.adoptedShortcutBundleIdentifier = currentBundleIdentifier
                return current.isSafeEditableDestination ? .ready : .waiting
            }
            guard current.isSafeEditableDestination else { return .waiting }
            if request.initialWasSafeEditable,
               current.focusIdentity == request.initialFocusIdentity {
                return .waiting
            }
            return .ready
        }
    }

    private func completePending(with result: VoiceInputDestinationWaitResult) {
        guard let request = pendingRequest else { return }
        let waiter = request.waiter
        timeoutTask?.cancel()
        timeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        pendingRequest = nil
        switch result {
        case .ready:
            AppLogger.shared.write("VOICE DESTINATION ready request=\(request.id)")
            onStateChange(.ready)
        case let .cancelled(reason):
            AppLogger.shared.write(
                "VOICE DESTINATION cancelled request=\(request.id) reason=\(reason.rawValue)"
            )
            if waiter != nil {
                onStateChange(.cancelled(reason))
            }
        }
        waiter?(result)
    }

    private func cancelPending(reason: VoiceInputDestinationCancellation) {
        guard pendingRequest != nil else { return }
        completePending(with: .cancelled(reason))
    }

    private func removeWaiter(requestID: UInt64) {
        guard pendingRequest?.id == requestID else { return }
        cancelPending(reason: .superseded)
    }
}

private extension VoiceInputDestinationIntent {
    var logValue: String {
        switch self {
        case let .application(bundleIdentifier): return "application:\(bundleIdentifier)"
        case .shortcut: return "shortcut"
        case .focusInput: return "focus_input"
        }
    }
}
