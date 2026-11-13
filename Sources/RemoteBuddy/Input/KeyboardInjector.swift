import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum KeyboardInjector {
    typealias ApplicationOpener = (
        URL,
        PresetApplication,
        @escaping (pid_t?, Error?) -> Void
    ) -> Void
    typealias ApplicationFocuser = (URL, PresetApplication, pid_t, UInt64) -> Void
    typealias CustomApplicationOpener = (
        URL,
        CustomApplicationProfile,
        @escaping (pid_t?, Error?) -> Void
    ) -> Void
    typealias CustomApplicationFocuser = (CustomApplicationProfile, pid_t, UInt64) -> Void
    typealias CmuxCommandRunner = (URL, [String], TimeInterval) -> CmuxCommandResult
    typealias KeyPoster = (CGKeyCode, CGEventFlags) -> Void
    typealias KeyStatePoster = (CGKeyCode, Bool, CGEventFlags) -> Bool
    typealias ScrollPoster = (Int32) -> Void
    typealias SystemKeyPoster = (Int32) -> Void

    struct ApplicationVisibilitySnapshot: Equatable {
        let bundleIdentifier: String
        let processActive: Bool?
        let processHidden: Bool?
        let processTerminated: Bool?
        let activationPolicy: String
        let ordinaryWindowCount: Int?
        let onscreenWindowCount: Int?

        var hasVisibleWindow: Bool? {
            onscreenWindowCount.map { $0 > 0 }
        }

        var isUserVisible: Bool? {
            guard let processActive,
                  let processHidden,
                  let processTerminated,
                  let onscreenWindowCount
            else { return nil }
            return processActive && !processHidden && !processTerminated && onscreenWindowCount > 0
        }
    }

    private static let transientAppSwitcher = AppSwitcherSession()

    final class AppSwitcherSession {
        private let keyStatePoster: KeyStatePoster
        private var diagnosticLogger: ((String) -> Void)?
        private(set) var isActive = false
        private var releaseTask: ScheduledOperation?
        private var releaseGeneration: UInt64 = 0
        private var releaseAttempts = 0
        private var scheduleRelease: OperationScheduler = ScheduledOperation.mainQueue

        init(keyStatePoster: @escaping KeyStatePoster = KeyboardInjector.postKeyState) {
            self.keyStatePoster = keyStatePoster
        }

        func setDiagnosticLogger(_ logger: @escaping (String) -> Void) {
            diagnosticLogger = logger
        }

        private func post(
            _ keyCode: CGKeyCode,
            isDown: Bool,
            flags: CGEventFlags,
            role: String
        ) -> Bool {
            let result = keyStatePoster(keyCode, isDown, flags)
            diagnosticLogger?(
                "role=\(role) key_code=\(keyCode) edge=\(isDown ? "down" : "up") " +
                    "command=\(flags.contains(.maskCommand)) success=\(result)"
            )
            return result
        }

        @discardableResult
        func trigger() -> Bool {
            if isActive {
                guard releaseAttempts == 0 else { return false }
                return postTab()
            }

            guard post(leftCommandKeyCode, isDown: true, flags: .maskCommand, role: "command") else {
                return false
            }
            isActive = true
            guard postTab() else {
                _ = releaseCommandKey()
                return false
            }
            return true
        }

        /// One-shot mappings hold Command briefly so the switcher can appear;
        /// repeated triggers extend the hold and cycle the same session.
        @discardableResult
        func triggerTemporarily(
            schedule: OperationScheduler? = nil
        ) -> Bool {
            if let schedule { scheduleRelease = schedule }
            guard trigger() else { return false }
            releaseGeneration &+= 1
            let generation = releaseGeneration
            releaseTask?.cancel()
            releaseTask = scheduleRelease(1) { [weak self] in
                guard let self, self.releaseGeneration == generation else { return }
                _ = self.confirm()
            }
            return true
        }

        @discardableResult
        func cancel() -> Bool {
            guard isActive else { return true }
            // Releasing Command confirms the selection. Escape must dismiss the
            // native switcher while Command is still held before we release it.
            let pressed = post(53, isDown: true, flags: .maskCommand, role: "cancel")
            let released = post(53, isDown: false, flags: .maskCommand, role: "cancel")
            let commandReleased = releaseCommandKey()
            return pressed && released && commandReleased
        }

        @discardableResult
        func confirm() -> Bool {
            releaseCommandKey()
        }

        private func releaseCommandKey() -> Bool {
            releaseGeneration &+= 1
            releaseTask?.cancel()
            releaseTask = nil
            guard isActive else { return true }
            let released = post(leftCommandKeyCode, isDown: false, flags: [], role: "command")
            isActive = !released
            if released {
                releaseAttempts = 0
            } else {
                releaseAttempts += 1
                if releaseAttempts < 4 {
                    let generation = releaseGeneration
                    let delay = 0.05 * pow(2, Double(releaseAttempts - 1))
                    releaseTask = scheduleRelease(delay) { [weak self] in
                        guard let self, self.releaseGeneration == generation else { return }
                        _ = self.releaseCommandKey()
                    }
                } else {
                    diagnosticLogger?("command_release_blocked attempts=\(releaseAttempts)")
                }
            }
            return released
        }

        @discardableResult
        func moveSelection(left: Bool) -> Bool {
            guard isActive else { return false }
            let keyCode: CGKeyCode = left ? 123 : 124
            let pressed = post(keyCode, isDown: true, flags: .maskCommand, role: "selection")
            let released = post(keyCode, isDown: false, flags: .maskCommand, role: "selection")
            return pressed && released
        }

        private func postTab() -> Bool {
            let pressed = post(48, isDown: true, flags: .maskCommand, role: "tab")
            let released = post(48, isDown: false, flags: .maskCommand, role: "tab")
            return pressed && released
        }
    }

    struct AccessibilityTextCandidate: Equatable {
        let subrole: String
        let protectedContent: Bool
        let role: String
        let identifier: String
        let title: String
        let description: String
        let help: String
        let placeholder: String
        let context: String
        let frame: CGRect?
        let enabled: Bool
        let focused: Bool
        let selectedContext: Bool
        let hasWorkBuddyComposerControls: Bool

        init(
            role: String,
            subrole: String = "",
            protectedContent: Bool = false,
            identifier: String,
            title: String,
            description: String,
            help: String,
            placeholder: String,
            context: String,
            frame: CGRect?,
            enabled: Bool,
            focused: Bool = false,
            selectedContext: Bool = false,
            hasWorkBuddyComposerControls: Bool = false
        ) {
            self.subrole = subrole
            self.protectedContent = protectedContent
            self.role = role
            self.identifier = identifier
            self.title = title
            self.description = description
            self.help = help
            self.placeholder = placeholder
            self.context = context
            self.frame = frame
            self.enabled = enabled
            self.focused = focused
            self.selectedContext = selectedContext
            self.hasWorkBuddyComposerControls = hasWorkBuddyComposerControls
        }
    }

    struct CmuxCommandResult: Equatable {
        let terminationStatus: Int32
        let standardOutput: Data
        let timedOut: Bool
    }

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let orderedVoiceEventMarker: Int64 = 0x5849_4156

    static func isSyntheticEvent(_ event: CGEvent) -> Bool {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        return isSyntheticEventMarker(marker)
    }
    static func isSyntheticEventMarker(_ marker: Int64) -> Bool {
        marker == syntheticEventMarker || marker == orderedVoiceEventMarker
    }
    static let contextualMenuKeyCode: CGKeyCode = 110
    static let functionKeyCode: CGKeyCode = 63
    static let leftCommandKeyCode: CGKeyCode = 55
    static let rightCommandKeyCode: CGKeyCode = 54
    /// Undocumented framework-specific attributes retained for explicit focus
    /// actions. Automatic voice integrations never set these attributes.
    /// Web content shells only build the accessibility tree once an assistive
    /// client announces itself, so the composer scan finds an empty shell until
    /// one of these attributes is set. `AXManualAccessibility` is the Chromium
    /// and Electron convention and is tried first, because the
    /// `AXEnhancedUserInterface` attribute is known to distort windows
    /// and animations on some Electron versions. Shells that are not Chromium
    /// based answer `attributeUnsupported` for the first attribute and only
    /// respond to the fallback attribute, so it is used as a fallback for exactly
    /// those apps.
    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    /// The web content tree needs about one to two seconds after the attribute
    /// is set, so the composer scan keeps retrying for longer than that.
    static let composerFocusMaximumAttempts = 12
    static let composerFocusRetryMilliseconds = 250
    static let weChatBundleIdentifier = "com.tencent.xinWeChat"
    static let weChatComposerHorizontalRatio = 0.68
    static let weChatComposerVerticalRatio = 0.85
    /// One scroll action moves the conversation by this many lines; the 100ms
    /// repeat interval turns a held D-pad key into a steady scroll.
    static let scrollLineCount: Int32 = 3
    private static let focusRequests = ApplicationFocusRequestGate()
    private static let frontmostFocusRequests = ApplicationFocusRequestGate()
    static let focusQueue = DispatchQueue(
        label: "RemoteBuddy.application-focus",
        qos: .userInitiated
    )
    static let accessibilityChildAttributes = [
        "AXChildrenInNavigationOrder",
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXChildrenAttribute,
    ]
    static let maximumAccessibilityTraversalCount = 5_000

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func setFunctionKeyPressed(
        _ isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postVoiceKeyState
    ) -> Bool {
        setVoiceKeyPressed(
            .function,
            isPressed: isPressed,
            accessibilityTrusted: accessibilityTrusted,
            keyStatePoster: keyStatePoster
        )
    }

    @discardableResult
    static func setVoiceKeyPressed(
        _ mode: VoiceKeyMode,
        isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postVoiceKeyState,
        secureInputEnabled: () -> Bool = SecureInputMonitor.isEnabled
    ) -> Bool {
        guard !isPressed || !secureInputEnabled() else { return false }
        guard accessibilityTrusted() else { return false }
        let flags = isPressed ? mode.eventFlags : []
        return keyStatePoster(
            mode.keyCode,
            isPressed,
            flags
        )
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        shortcut: CustomKeyboardShortcut? = nil,
        applicationProfile: CustomApplicationProfile? = nil,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = openApplication,
        applicationFocuser: @escaping ApplicationFocuser = focusApplication,
        customApplicationURL: (CustomApplicationProfile) -> URL? = resolveCustomApplicationURL,
        customApplicationOpener: CustomApplicationOpener = openCustomApplication,
        customApplicationFocuser: @escaping CustomApplicationFocuser = focusCustomApplication,
        frontmostComposerFocuser: (@escaping (Bool) -> Void) -> Bool = focusFrontmostComposer,
        focusInputCompletion: @escaping (Bool) -> Void = { _ in },
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        secureInputEnabled: () -> Bool = SecureInputMonitor.isEnabled,
        keyPoster: KeyPoster = { postKey(code: $0, flags: $1) },
        keyStatePoster: @escaping KeyStatePoster = postKeyState,
        modifierReleaseRecovery: StandaloneModifierReleaseRecovery = .shared,
        appSwitcherSession: AppSwitcherSession? = nil,
        scrollPoster: ScrollPoster = { postScrollWheel(lines: $0) },
        systemKeyPoster: SystemKeyPoster = postSystemKey,
        shortcutEventPoster: @escaping (CGEvent) -> Bool = ShortcutEventSequence.post,
        shortcutHardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.currentForMappedAction
    ) -> Bool {
        guard action != .disabled else { return true }
        if action != .appSwitcher, transientAppSwitcher.isActive {
            guard transientAppSwitcher.confirm() else { return false }
        }
        guard !action.requiresNonSecureInput || !secureInputEnabled() else {
            AppLogger.shared.write("BUTTON ACTION blocked reason=secure_input action=\(action.rawValue)")
            return false
        }
        if action.isAppInternal {
            AppLogger.shared.write("INTERNAL ACTION ignored_by_keyboard action=\(action.rawValue)")
            return true
        }
        if let application = action.presetApplication {
            let focusRequestID = focusRequests.begin()
            open(
                application,
                focusRequestID: focusRequestID,
                applicationURL: applicationURL,
                applicationOpener: applicationOpener,
                applicationFocuser: applicationFocuser
            )
            return true
        }
        if action == .openCustomApplication {
            guard let applicationProfile else {
                AppLogger.shared.write("APP ACTION custom unavailable reason=profile_missing")
                return true
            }
            let focusRequestID = focusRequests.begin()
            open(
                applicationProfile,
                focusRequestID: focusRequestID,
                applicationURL: customApplicationURL,
                applicationOpener: customApplicationOpener,
                applicationFocuser: customApplicationFocuser
            )
            return true
        }
        if action == .focusInput {
            guard accessibilityTrusted() else { return false }
            return frontmostComposerFocuser(focusInputCompletion)
        }
        if action == .customShortcut, shortcut == nil {
            AppLogger.shared.write("SHORTCUT ACTION ignored reason=not_configured")
            return true
        }
        guard accessibilityTrusted() else { return false }

        switch action {
        case .disabled, .repeatSingleClick:
            return true
        case .escape:
            keyPoster(53, [])
        case .returnKey:
            keyPoster(36, [])
        case .commandReturn:
            return ShortcutEventSequence.send(keyCode: 36, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .shiftReturn:
            return ShortcutEventSequence.send(keyCode: 36, modifiers: .maskShift,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandCopy:
            return ShortcutEventSequence.send(keyCode: 8, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandPaste:
            return ShortcutEventSequence.send(keyCode: 9, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandClose:
            return ShortcutEventSequence.send(keyCode: 13, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandQuit:
            return ShortcutEventSequence.send(keyCode: 12, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandCut:
            return ShortcutEventSequence.send(keyCode: 7, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandSelectAll:
            return ShortcutEventSequence.send(keyCode: 0, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandUndo:
            return ShortcutEventSequence.send(keyCode: 6, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandRedo:
            return ShortcutEventSequence.send(keyCode: 6, modifiers: [.maskCommand, .maskShift],
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandFind:
            return ShortcutEventSequence.send(keyCode: 3, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandSave:
            return ShortcutEventSequence.send(keyCode: 1, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .commandDelete:
            return ShortcutEventSequence.send(keyCode: 51, modifiers: .maskCommand,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .arrowUp:
            keyPoster(126, [])
        case .arrowDown:
            keyPoster(125, [])
        case .arrowLeft:
            keyPoster(123, [])
        case .arrowRight:
            keyPoster(124, [])
        case .scrollUp:
            scrollPoster(scrollLineCount)
        case .scrollDown:
            scrollPoster(-scrollLineCount)
        case .deleteBackward:
            keyPoster(51, [])
        case .showDesktop:
            return ShortcutEventSequence.send(keyCode: 103, modifiers: .maskSecondaryFn,
                hardwareFlags: shortcutHardwareFlags, eventPoster: shortcutEventPoster)
        case .contextMenu:
            keyPoster(contextualMenuKeyCode, [])
        case .appSwitcher:
            return (appSwitcherSession ?? transientAppSwitcher).triggerTemporarily()
        case .volumeUp:
            systemKeyPoster(0)
        case .volumeDown:
            systemKeyPoster(1)
        case .volumeMute:
            systemKeyPoster(7)
        case .playPause:
            systemKeyPoster(16)
        case .previousCommandLeft:
            systemKeyPoster(18)
        case .nextCommandRight:
            systemKeyPoster(17)
        case .customShortcut:
            if let shortcut {
                let eventFlags = shortcut.cgEventFlags
                if shortcut.standaloneModifier != nil {
                    guard modifierReleaseRecovery.permitsPress(CGKeyCode(shortcut.keyCode)) else { return false }
                    let pressed = keyStatePoster(
                        CGKeyCode(shortcut.keyCode),
                        true,
                        eventFlags
                    )
                    var released = keyStatePoster(CGKeyCode(shortcut.keyCode), false, [])
                    if !released {
                        released = keyStatePoster(CGKeyCode(shortcut.keyCode), false, [])
                        if !released {
                            AppLogger.shared.write("SHORTCUT ACTION cleanup_failed standalone=true recovery=scheduled")
                            modifierReleaseRecovery.recover(CGKeyCode(shortcut.keyCode), post: keyStatePoster)
                        }
                    }
                    let submitted = pressed && released
                    AppLogger.shared.write(
                        "SHORTCUT ACTION submitted key_code=\(shortcut.keyCode) " +
                            "modifier_flags=\(eventFlags.rawValue) standalone=true " +
                            "success=\(submitted)"
                    )
                    return submitted
                }
                if !eventFlags.isEmpty {
                    return ShortcutEventSequence.send(
                        keyCode: CGKeyCode(shortcut.keyCode),
                        modifiers: eventFlags,
                        hardwareFlags: shortcutHardwareFlags,
                        eventPoster: shortcutEventPoster
                    )
                }
                keyPoster(CGKeyCode(shortcut.keyCode), eventFlags)
                AppLogger.shared.write(
                    "SHORTCUT ACTION submitted key_code=\(shortcut.keyCode) " +
                        "modifier_flags=\(eventFlags.rawValue) standalone=false"
                )
            }
        case .focusInput:
            break
        case .openCustomApplication:
            break
        case .toggleLongRecording, .openCommonPhrases:
            break
        case .openRemoteBuddy, .openCodex, .openClaude, .openCmux, .openWeChat, .openCursor, .openXcode,
             .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openSafari, .openZed:
            break
        }
        return true
    }

    private static func open(
        _ application: PresetApplication,
        focusRequestID: UInt64,
        applicationURL: (String) -> URL?,
        applicationOpener: ApplicationOpener,
        applicationFocuser: @escaping ApplicationFocuser
    ) {
        guard let url = applicationURL(application.bundleIdentifier) else {
            AppLogger.shared.write("APP ACTION unavailable bundle=\(application.bundleIdentifier)")
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) " +
                        AppLogger.errorFields(error)
                )
            } else {
                AppLogger.shared.write("APP ACTION opened bundle=\(application.bundleIdentifier)")
                if application.focusStrategy != nil, let processIdentifier {
                    applicationFocuser(url, application, processIdentifier, focusRequestID)
                }
            }
        }
    }

    private static func openApplication(
        at url: URL,
        application: PresetApplication,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    private static func open(
        _ application: CustomApplicationProfile,
        focusRequestID: UInt64,
        applicationURL: (CustomApplicationProfile) -> URL?,
        applicationOpener: CustomApplicationOpener,
        applicationFocuser: @escaping CustomApplicationFocuser
    ) {
        guard let url = applicationURL(application) else {
            AppLogger.shared.write(
                "APP ACTION unavailable bundle=\(application.bundleIdentifier) custom=true"
            )
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) custom=true " +
                        AppLogger.errorFields(error)
                )
                return
            }
            AppLogger.shared.write(
                "APP ACTION opened bundle=\(application.bundleIdentifier) custom=true"
            )
            guard application.focusStrategy != .none, let processIdentifier else { return }
            applicationFocuser(application, processIdentifier, focusRequestID)
        }
    }

    private static func resolveCustomApplicationURL(
        _ application: CustomApplicationProfile
    ) -> URL? {
        let savedURL = URL(fileURLWithPath: application.applicationPath)
        if Bundle(url: savedURL)?.bundleIdentifier == application.bundleIdentifier {
            return savedURL
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        )
    }

    private static func openCustomApplication(
        at url: URL,
        application: CustomApplicationProfile,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    private static func focusCustomApplication(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        scheduleCustomApplicationFocus(
            application: application,
            processIdentifier: processIdentifier,
            requestID: requestID,
            attempt: 0
        )
    }

    private static func scheduleCustomApplicationFocus(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int
    ) {
        let maximumAttempts = 8
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(0) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard focusRequests.isCurrent(requestID) else { return }
            if isAccessibilityTrusted, application.focusStrategy == .recordedAccessibility {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier) {
                guard isAccessibilityTrusted else {
                    AppLogger.shared.write(
                        "APP FOCUS skipped bundle=\(application.bundleIdentifier) " +
                            "method=custom reason=not_trusted"
                    )
                    return
                }
                switch application.focusStrategy {
                case .none:
                    return
                case .keyboardShortcut:
                    if let shortcut = application.focusShortcut {
                        postKey(code: CGKeyCode(shortcut.keyCode), flags: shortcut.cgEventFlags)
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_shortcut"
                        )
                        return
                    }
                case .recordedAccessibility:
                    if let target = application.accessibilityTarget,
                       focusRecordedAccessibilityTarget(
                           target,
                           processIdentifier: processIdentifier
                       )
                    {
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_accessibility"
                        )
                        return
                    }
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < maximumAttempts {
                scheduleCustomApplicationFocus(
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt
                )
            } else if focusRequests.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) " +
                        "method=custom reason=target_not_focused"
                )
            }
        }
    }

    private static func focusApplication(
        at applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        guard focusRequests.isCurrent(requestID), let strategy = application.focusStrategy else { return }

        switch strategy {
        case .accessibilityComposer:
            scheduleAccessibilityComposerFocus(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: processIdentifier,
                requestID: requestID,
                requestGate: focusRequests,
                attempt: 0
            )
        case .cmuxSurfaceAPI:
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: application,
                processIdentifier: processIdentifier,
                requestID: requestID,
                attempt: 0
            )
        }
    }

    static func testCustomApplicationInput(_ profile: CustomApplicationProfile, completion: @escaping (Bool) -> Void) {
        guard isAccessibilityTrusted, let target = profile.accessibilityTarget,
            let url = resolveCustomApplicationURL(profile) else { completion(false); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            guard error == nil, let application else { completion(false); return }
            focusQueue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                let success = focusRecordedAccessibilityTarget(target, processIdentifier: application.processIdentifier)
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    @discardableResult
    static func focusFrontmostComposer(completion: @escaping (Bool) -> Void) -> Bool {
        guard isAccessibilityTrusted,
              let application = NSWorkspace.shared.frontmostApplication
        else { return false }
        let requestID = frontmostFocusRequests.begin()
        if application.bundleIdentifier == PresetApplication.cmux.bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: PresetApplication.cmux.bundleIdentifier
           ) {
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: .cmux,
                processIdentifier: application.processIdentifier,
                requestID: requestID,
                attempt: 0,
                requestGate: frontmostFocusRequests,
                completion: completion
            )
            return true
        }
        scheduleAccessibilityComposerFocus(
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            processIdentifier: application.processIdentifier,
            requestID: requestID,
            requestGate: frontmostFocusRequests,
            attempt: 0,
            completion: completion
        )
        return true
    }

    private static func scheduleCmuxFocus(
        applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int,
        requestGate: ApplicationFocusRequestGate = focusRequests,
        completion: ((Bool) -> Void)? = nil
    ) {
        let maximumAttempts = 4
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(100) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }
            let nextAttempt = attempt + 1
            if !applicationIsFrontmost(processIdentifier) {
                if nextAttempt < maximumAttempts {
                    scheduleCmuxFocus(
                        applicationURL: applicationURL,
                        application: application,
                        processIdentifier: processIdentifier,
                        requestID: requestID,
                        attempt: nextAttempt,
                        requestGate: requestGate,
                        completion: completion
                    )
                } else {
                    completeComposerFocus(
                        false,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                }
                return
            }
            let canContinue = {
                requestGate.isCurrent(requestID) && applicationIsFrontmost(processIdentifier)
            }
            let focused = focusCmux(
                applicationURL: applicationURL,
                canContinue: canContinue,
                terminalFocuser: { _ in
                    guard isAccessibilityTrusted else {
                        AppLogger.shared.write(
                            "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=not_trusted"
                        )
                        return false
                    }
                    return focusCmuxTerminal(
                        processIdentifier: processIdentifier,
                        keyPoster: { postKey(code: $0, flags: $1) }
                    )
                }
            )
            if focused {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(application.bundleIdentifier) method=cmux_api_accessibility"
                )
                completeComposerFocus(
                    true,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }

            if nextAttempt < maximumAttempts {
                scheduleCmuxFocus(
                    applicationURL: applicationURL,
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt,
                    requestGate: requestGate,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=terminal_not_focused"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func scheduleAccessibilityComposerFocus(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        attempt: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        let delay: DispatchTimeInterval = attempt == 0
            ? .milliseconds(0)
            : .milliseconds(composerFocusRetryMilliseconds)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }

            if applicationIsFrontmost(processIdentifier), !isAccessibilityTrusted {
                AppLogger.shared.write(
                    "APP FOCUS skipped bundle=\(bundleIdentifier) method=accessibility reason=not_trusted"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }
            if isAccessibilityTrusted {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier), isAccessibilityTrusted {
                if focusComposer(
                    processIdentifier: processIdentifier,
                    emitDiagnostics: attempt == 0 || attempt + 1 == composerFocusMaximumAttempts
                ) {
                    AppLogger.shared.write(
                        "APP FOCUS succeeded bundle=\(bundleIdentifier) method=accessibility"
                    )
                    completeComposerFocus(
                        true,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                    return
                }
            }
            if attempt == 0,
               usesWeChatComposerFallback(bundleIdentifier: bundleIdentifier),
               applicationIsFrontmost(processIdentifier),
               focusWeChatComposer(processIdentifier: processIdentifier) {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(bundleIdentifier) method=wechat_window_click"
                )
                completeComposerFocus(
                    true,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }

            let nextAttempt = attempt + 1
            if nextAttempt < composerFocusMaximumAttempts {
                scheduleAccessibilityComposerFocus(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    requestGate: requestGate,
                    attempt: nextAttempt,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(bundleIdentifier) method=accessibility reason=composer_not_found"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func completeComposerFocus(
        _ focused: Bool,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        completion: ((Bool) -> Void)?
    ) {
        guard let completion else { return }
        DispatchQueue.main.async {
            guard requestGate.isCurrent(requestID) else { return }
            completion(focused)
        }
    }


}

final class ApplicationFocusRequestGate {
    private let lock = NSLock()
    private var latestRequestID: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestRequestID &+= 1
        return latestRequestID
    }

    func isCurrent(_ requestID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestID == latestRequestID
    }
}
