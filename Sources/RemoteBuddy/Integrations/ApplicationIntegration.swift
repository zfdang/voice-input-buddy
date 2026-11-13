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
    typealias Focuser = (ApplicationIntegration, pid_t) -> ScheduledOperation
    private let settings: AppSettings
    private let notifications: NotificationCenter
    private let frontmost: () -> (bundleIdentifier: String?, pid: pid_t)?
    private let focus: Focuser
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?
    private var pendingFocus: ScheduledOperation?
    private var started = false

    init(settings: AppSettings,
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: @escaping () -> (bundleIdentifier: String?, pid: pid_t)? = {
             NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier, $0.processIdentifier) }
         },
         focus: @escaping Focuser = KeyboardInjector.focusIntegratedApplication) {
        self.settings = settings
        self.notifications = notifications
        self.frontmost = frontmost
        self.focus = focus
    }

    func start() {
        guard !started else { return }
        started = true
        // Application activation only cancels work; it never initiates focusing.
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPending() }
            })
        }
        settingsSubscription = settings.$enabledApplicationIntegrations.dropFirst()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.cancelPending() }
    }

    func voiceInputStarted() {
        cancelPending()
        guard started, let application = frontmost(),
              let integration = ApplicationIntegration.matching(application.bundleIdentifier),
              settings.isApplicationIntegrationEnabled(integration) else { return }
        pendingFocus = focus(integration, application.pid)
    }

    func stop() {
        started = false
        cancelPending()
        observers.forEach(notifications.removeObserver)
        observers.removeAll()
        settingsSubscription = nil
    }

    func cancelPending() {
        pendingFocus?.cancel()
        pendingFocus = nil
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
