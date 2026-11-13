import AppKit
import Combine
import Foundation

/// Foreground integrations are opt-in and independent of application-launch button mappings.
enum ApplicationIntegration: String, CaseIterable, Identifiable {
    case weChat, antigravity, chatGPT

    var id: String { rawValue }
    var bundleIdentifier: String {
        switch self {
        case .chatGPT: return "com.openai.codex"
        case .antigravity: return "com.google.antigravity"
        case .weChat: return "com.tencent.xinWeChat"
        }
    }
    var title: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .antigravity: return "Antigravity"
        case .weChat: return "WeChat"
        }
    }
    var detailKey: String { "application_integration.\(rawValue).detail" }

    static func matching(_ bundleIdentifier: String?) -> Self? {
        // Both current unified desktop and standalone ChatGPT installations are supported.
        if bundleIdentifier == "com.openai.chat" { return .chatGPT }
        return allCases.first { $0.bundleIdentifier == bundleIdentifier }
    }
}

enum ApplicationIntegrationPreparationState: Equatable {
    case waiting, ready, unavailable, focusTimedOut, voiceTriggered, voiceTriggeredWithoutFocus
    case cancelled(VoiceInputDestinationCancellation)
}

@MainActor
final class ApplicationIntegrationController {
    typealias Focuser = (ApplicationIntegration, pid_t, @escaping (Bool) -> Void) -> ScheduledOperation
    private let settings: AppSettings
    private let notifications: NotificationCenter
    private let frontmost: () -> (bundleIdentifier: String?, pid: pid_t)?
    private let focus: Focuser
    private let onStateChange: (ApplicationIntegrationPreparationState) -> Void
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?
    private var pendingFocus: ScheduledOperation?
    private var started = false
    private let schedule: OperationScheduler
    private var generation: UInt64 = 0
    private var pendingCompletion: ((VoiceInputDestinationWaitResult) -> Void)?
    private var deadline: ScheduledOperation?
    private var pendingBundleIdentifier: String?

    init(settings: AppSettings,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: @escaping () -> (bundleIdentifier: String?, pid: pid_t)? = {
             NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier, $0.processIdentifier) }
         },
         focus: @escaping Focuser = KeyboardInjector.focusIntegratedApplication,
         schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue,
         onStateChange: @escaping (ApplicationIntegrationPreparationState) -> Void = { _ in }) {
        self.settings = settings
        self.notifications = notifications
        self.frontmost = frontmost
        self.focus = focus
        self.schedule = schedule
        self.onStateChange = onStateChange
    }

    func start() {
        guard !started else { return }
        started = true
        // Application activation only cancels work; it never initiates focusing.
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPending(reason: .targetChanged) }
            })
        }
        settingsSubscription = settings.$enabledApplicationIntegrations.dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.cancelPending() }
    }

    /// Focus is optional. A failed/expired attempt is reported and voice continues
    /// in the same application; release, app changes, and shutdown still cancel.
    func prepareForVoiceInput(completion: @escaping (VoiceInputDestinationWaitResult) -> Void) -> VoiceInputDestinationWait {
        cancelPending()
        guard started, let application = frontmost(),
              let integration = ApplicationIntegration.matching(application.bundleIdentifier),
              settings.isApplicationIntegrationEnabled(integration) else { return .immediate }
        generation &+= 1
        let requestID = generation
        pendingCompletion = completion
        pendingBundleIdentifier = application.bundleIdentifier
        onStateChange(.waiting)
        let finishFocus: (Bool, Bool) -> Void = { [weak self] focused, timedOut in
            guard let self, self.generation == requestID, self.pendingCompletion != nil else { return }
            let current = self.frontmost()
            if current?.pid != application.pid || current?.bundleIdentifier != application.bundleIdentifier {
                self.finish(requestID: requestID, result: .cancelled(.targetChanged))
            } else {
                self.finish(requestID: requestID, result: .ready,
                    focusStatus: focused ? .ready : (timedOut ? .focusTimedOut : .unavailable))
            }
        }
        deadline = schedule(VoiceInputPreparationSequence.maximumFocusWait) { finishFocus(false, true) }
        let task = focus(integration, application.pid) { finishFocus($0, false) }
        if generation == requestID, pendingCompletion != nil { pendingFocus = task }
        else { task.cancel() }
        return .waiting(.mainQueueCancellation { [weak self] in
            guard self?.generation == requestID else { return }
            self?.cancelPending()
        })
    }

    private func finish(requestID: UInt64, result: VoiceInputDestinationWaitResult,
                        focusStatus: ApplicationIntegrationPreparationState? = nil) {
        guard generation == requestID else { return }
        generation &+= 1
        let completion = pendingCompletion
        pendingCompletion = nil
        let focus = pendingFocus
        pendingFocus = nil
        deadline?.cancel()
        deadline = nil
        focus?.cancel()
        guard let completion else { return }
        let bundle = pendingBundleIdentifier ?? "unknown"
        pendingBundleIdentifier = nil
        switch result {
        case .ready:
            let state = focusStatus ?? .ready
            if state == .unavailable || state == .focusTimedOut {
                let reason = state == .focusTimedOut ? "timed_out" : "unavailable"
                AppLogger.shared.write("APP INTEGRATION continuing bundle=\(bundle) focus=\(reason)")
            }
            onStateChange(state)
        case let .cancelled(reason):
            AppLogger.shared.write("APP INTEGRATION cancelled bundle=\(bundle) reason=\(reason.rawValue)")
            onStateChange(.cancelled(reason))
        }
        completion(result)
    }

    func stop() {
        started = false
        cancelPending()
        observers.forEach(notifications.removeObserver)
        observers.removeAll()
        settingsSubscription = nil
    }

    func cancelPending(reason: VoiceInputDestinationCancellation = .superseded) {
        finish(requestID: generation, result: .cancelled(reason))
    }
}

extension AppSettings {
    func isApplicationIntegrationEnabled(_ application: ApplicationIntegration) -> Bool {
        enabledApplicationIntegrations.contains(application.rawValue)
    }

    func setApplicationIntegration(_ application: ApplicationIntegration, enabled: Bool) {
        if enabled { enabledApplicationIntegrations.insert(application.rawValue) }
        else { enabledApplicationIntegrations.remove(application.rawValue) }
    }

    func setAllApplicationIntegrations(enabled: Bool) {
        enabledApplicationIntegrations = enabled ? Set(ApplicationIntegration.allCases.map(\.rawValue)) : []
    }
}

/// Per-attempt feedback shown in App Integrations; separate from shortcut configuration.
enum ApplicationIntegrationStatus {
    static func messageKey(_ state: ApplicationIntegrationPreparationState) -> String {
        switch state {
        case .waiting: return "application_integration.status.waiting"
        case .ready: return "application_integration.status.ready"
        case .voiceTriggered: return "application_integration.status.triggered"
        case .voiceTriggeredWithoutFocus: return "application_integration.status.triggered_without_focus"
        case .unavailable: return "application_integration.status.failed"
        case .focusTimedOut: return "application_integration.status.focus_timed_out"
        case .cancelled(.timedOut): return "application_integration.status.timed_out"
        case .cancelled: return "application_integration.status.cancelled"
        }
    }
}
