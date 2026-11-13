import AppKit
import Combine
import Foundation

/// Foreground integrations are opt-in and independent of application-launch button mappings.
enum ApplicationIntegration: String, CaseIterable, Identifiable {
    case weChat, antigravity, chatGPT

    var id: String { rawValue }
    var bundleIdentifier: String {
        switch self {
        case .chatGPT: return "com.openai.chat"
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
        // The current ChatGPT desktop installation retains the Codex bundle ID.
        if bundleIdentifier == "com.openai.codex" { return .chatGPT }
        return allCases.first { $0.bundleIdentifier == bundleIdentifier }
    }
}

@MainActor
final class ApplicationIntegrationController {
    typealias Focuser = (ApplicationIntegration, pid_t, @escaping (Bool) -> Void) -> ScheduledOperation
    private let settings: AppSettings
    private let notifications: NotificationCenter
    private let frontmost: () -> (bundleIdentifier: String?, pid: pid_t)?
    private let focus: Focuser
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?
    private var pendingFocus: ScheduledOperation?
    private var started = false
    private let schedule: OperationScheduler
    private var generation: UInt64 = 0
    private var pendingCompletion: ((VoiceInputDestinationWaitResult) -> Void)?
    private var deadline: ScheduledOperation?

    init(settings: AppSettings,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: @escaping () -> (bundleIdentifier: String?, pid: pid_t)? = {
             NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier, $0.processIdentifier) }
         },
         focus: @escaping Focuser = KeyboardInjector.focusIntegratedApplication,
         schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue) {
        self.settings = settings
        self.notifications = notifications
        self.frontmost = frontmost
        self.focus = focus
        self.schedule = schedule
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

    /// A voice trigger must wait until focus work has finished. An unavailable
    /// composer leaves the existing focus alone; cancellation must never trigger voice.
    func prepareForVoiceInput(completion: @escaping (VoiceInputDestinationWaitResult) -> Void) -> VoiceInputDestinationWait {
        cancelPending()
        guard started, let application = frontmost(),
              let integration = ApplicationIntegration.matching(application.bundleIdentifier),
              settings.isApplicationIntegrationEnabled(integration) else { return .immediate }
        generation &+= 1
        let requestID = generation
        pendingCompletion = completion
        deadline = schedule(4) { [weak self] in
            guard self?.generation == requestID else { return }
            self?.cancelPending(reason: .timedOut)
        }
        let task = focus(integration, application.pid) { [weak self] _ in
            guard let self, self.generation == requestID, self.pendingCompletion != nil else { return }
            let current = self.frontmost()
            self.finish(requestID: requestID, result:
                current?.pid == application.pid && current?.bundleIdentifier == application.bundleIdentifier
                    ? .ready : .cancelled(.targetChanged))
        }
        if generation == requestID, pendingCompletion != nil { pendingFocus = task }
        else { task.cancel() }
        return .waiting(.mainQueueCancellation { [weak self] in
            guard self?.generation == requestID else { return }
            self?.cancelPending()
        })
    }

    private func finish(requestID: UInt64, result: VoiceInputDestinationWaitResult) {
        guard generation == requestID else { return }
        generation &+= 1
        let completion = pendingCompletion
        pendingCompletion = nil
        let focus = pendingFocus
        pendingFocus = nil
        deadline?.cancel()
        deadline = nil
        focus?.cancel()
        completion?(result)
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
