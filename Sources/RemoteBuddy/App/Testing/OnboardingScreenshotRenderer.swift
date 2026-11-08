#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum OnboardingScreenshotRenderer {
    private enum RenderingError: Error, LocalizedError {
        case invalidAppearance(String)
        case invalidLanguage(String)
        case missingFrameView
        case bitmapCreationFailed
        case pngCreationFailed

        var errorDescription: String? {
            switch self {
            case let .invalidAppearance(value):
                return "Unsupported screenshot appearance: \(value). Use light, dark, or system."
            case let .invalidLanguage(value):
                return "Unsupported screenshot language: \(value). Use zh-Hans, en, or system."
            case .missingFrameView:
                return "The offscreen window frame view is unavailable."
            case .bitmapCreationFailed:
                return "The offscreen window bitmap could not be created."
            case .pngCreationFailed:
                return "The offscreen window bitmap could not be encoded as PNG."
            }
        }
    }

    private enum ScreenshotLanguage {
        case simplifiedChinese
        case english
        case system

        init(environmentValue: String?) throws {
            switch environmentValue?.lowercased() ?? "zh-hans" {
            case "zh-hans", "zh_cn", "zh-cn":
                self = .simplifiedChinese
            case "en", "en-us", "en_us":
                self = .english
            case "system":
                self = .system
            case let value:
                throw RenderingError.invalidLanguage(value)
            }
        }

        var appLanguage: AppLanguage {
            switch self {
            case .simplifiedChinese:
                return .simplifiedChinese
            case .english:
                return .english
            case .system:
                return .system
            }
        }
    }

    private enum ScreenshotAppearance: String {
        case light
        case dark
        case system

        init(environmentValue: String?) throws {
            let value = environmentValue?.lowercased() ?? Self.light.rawValue
            guard let appearance = Self(rawValue: value) else {
                throw RenderingError.invalidAppearance(value)
            }
            self = appearance
        }

        var appKitAppearance: NSAppearance? {
            switch self {
            case .light:
                return NSAppearance(named: .aqua)
            case .dark:
                return NSAppearance(named: .darkAqua)
            case .system:
                return nil
            }
        }
    }

    static func renderAll(to outputDirectory: URL, appearanceName: String?) throws {
        let size = try SettingsScreenshotRenderer.screenshotSize(from: ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_SIZE"
        ])
        let screenshotAppearance = try ScreenshotAppearance(environmentValue: appearanceName)
        let screenshotLanguage = try ScreenshotLanguage(
            environmentValue: ProcessInfo.processInfo.environment[
                "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_LANGUAGE"
            ]
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let suiteName = "RemoteBuddy.OnboardingScreenshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RenderingError.bitmapCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = screenshotLanguage.appLanguage
        let requestedVoiceTool = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_VOICE_TOOL"
        ].flatMap(OnboardingVoiceTool.init(rawValue:))
        let requestedVoiceKeyMode = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_VOICE_KEY_MODE"
        ].flatMap(VoiceKeyMode.init(rawValue:))
        let requestedGuideStep = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_GUIDE_STEP"
        ].flatMap(Int.init)
        let requestedControlMethod = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_CONTROL_METHOD"
        ].flatMap(OnboardingControlMethod.init(rawValue:))
        let requestedControlSource = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_CONTROL_SOURCE"
        ].flatMap(OnboardingControlSource.init(rawValue:))
        let requestedAppleRemoteGeneration = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_APPLE_REMOTE_GENERATION"
        ].flatMap(OnboardingAppleRemoteGeneration.init(rawValue:))
        let systemFunctionKeyAvailable = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_SYSTEM_FN_AVAILABLE"
        ].map { $0 != "0" } ?? true
        let allVoiceToolsUnavailable = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_ALL_VOICE_TOOLS_UNAVAILABLE"
        ] == "1"
        let onboardingPermissionsOverride: SystemPermissionOverrides? = switch ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_PERMISSIONS"
        ] {
        case "all_granted", "granted":
            .allGranted
        case "missing", "denied":
            SystemPermissionOverrides(bluetooth: .denied, inputMonitoring: false, accessibility: false)
        default:
            nil
        }
        let remoteInputDiagnostic = switch ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_REMOTE_INPUT"
        ] {
        case "voice":
            FirstUseRemoteInputDiagnostic(
                voiceButtonPressCount: 1,
                controlButtonObservationCount: 0,
                lastInputKind: .voice
            )
        default:
            FirstUseRemoteInputDiagnostic()
        }
        let controlMethod = requestedControlMethod ?? .physicalRemote
        let controlSource = requestedControlSource ?? .defaultSource(for: controlMethod)
        if let requestedVoiceKeyMode {
            settings.voiceKeyMode = requestedVoiceKeyMode
        }
        settings.setOnboardingVoiceTool(requestedVoiceTool ?? .doubao)
        settings.setOnboardingControlSource(controlSource)
        if controlSource == .siriRemote {
            settings.setOnboardingAppleRemoteGeneration(
                requestedAppleRemoteGeneration ?? .generation7
            )
        }
        if let requestedDevice = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_DEVICE"
        ].flatMap(RemoteSetupDevice.init(rawValue:)) {
            settings.selectOnboardingDevice(requestedDevice)
        }
        let requestedPurpose = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_PURPOSE"
        ].flatMap(OnboardingPurpose.init(rawValue:)) ?? .initialSetup
        if requestedPurpose != .initialSetup {
            settings.completeOnboarding()
            if requestedPurpose == .integration {
                SettingsPageBehavior.beginIntegrationSetup(tool: settings.onboardingVoiceTool, settings: settings)
            } else {
                SettingsPageBehavior.beginDeviceSetup(settings: settings)
            }
        }
        let screenshotAudioDevices = [
            AudioDeviceInfo(id: 1, uid: BuddyMicrophoneDevicePolicy.deviceUID, name: BuddyMicrophoneDevicePolicy.deviceName),
            AudioDeviceInfo(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
        ]
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: screenshotAudioDevices
        )
        let localization = LocalizationStore(
            settings: settings,
            resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment
        )

        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = screenshotAppearance.appKitAppearance
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.appearance = previousAppearance }

#if DEBUG
        let interactive = ProcessInfo.processInfo.environment["VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_INTERACTIVE"] == "1"
        let interactiveStep = ProcessInfo.processInfo.environment[
            "VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_INTERACTIVE_STEP"
        ].flatMap(OnboardingStep.init(rawValue:)) ?? .voiceTool
        let renderedPages: [(OnboardingStep, String)] = interactive
            ? [(interactiveStep, "interactive.png")] : pages(for: controlMethod).filter { requestedPurpose.steps.contains($0.0) }
#else
        let renderedPages = pages(for: controlMethod)
#endif
        for (step, filename) in renderedPages {
            settings.setOnboardingStep(step)
            let actionProbe = OnboardingInteractionProbe(openURL: { _ in })
            let rootView = OnboardingView(
                model: model,
                completeRuntimeReadyOverride: true,
                allowsInputSourceSwitching: false,
                systemFunctionKeyAvailableOverride: systemFunctionKeyAvailable,
                voiceToolAvailabilityOverride: [
                    .weixin: allVoiceToolsUnavailable ? .notInstalled : .available,
                    .doubao: allVoiceToolsUnavailable ? .notInstalled : .available,
                    .bageshuo: allVoiceToolsUnavailable ? .notInstalled : .available,
                    .typeless: allVoiceToolsUnavailable ? .notInstalled : .available,
                    .other: .unknown,
                ],
                initialInputMethodGuideStep: requestedGuideStep,
                remoteInputDiagnosticOverride: remoteInputDiagnostic,
                interactionProbe: actionProbe,
                permissionOverrides: onboardingPermissionsOverride
            )
                .environmentObject(localization)
                .frame(width: size.width, height: size.height)
            let hostingController = NSHostingController(rootView: rootView)
            let window = makeWindow(hostingController: hostingController, size: size)

            window.makeKeyAndOrderFront(nil)
            if !interactive, step == .remoteAvailability,
               ProcessInfo.processInfo.environment["VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_TRY_CONTINUE"] == "1" {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                actionProbe.invoke("continue")
            }

#if DEBUG
            if interactive {
                window.title = "Remote Buddy Preview"
                NSApp.finishLaunching()
                NSApp.activate(ignoringOtherApps: true)
                let closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { NSApp.stop(nil) }
                }
                let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
                    MainActor.assumeIsolated { window.performClose(nil) }
                }
                NSApp.run()
                timer.invalidate()
                NotificationCenter.default.removeObserver(closeObserver)
            }
#endif
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            window.contentView?.layoutSubtreeIfNeeded()
            SettingsScreenshotRenderer.scrollCanvasToEndIfRequested(in: window.contentView)
            window.contentView?.displayIfNeeded()

            guard let frameView = window.contentView?.superview else {
                throw RenderingError.missingFrameView
            }
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()

            let bounds = frameView.bounds
            guard let representation = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw RenderingError.bitmapCreationFailed
            }
            frameView.cacheDisplay(in: bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw RenderingError.pngCreationFailed
            }
            try png.write(to: outputDirectory.appendingPathComponent(filename))
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }

    private static func pages(
        for controlMethod: OnboardingControlMethod
    ) -> [(OnboardingStep, String)] {
        return OnboardingStep.visibleCases.enumerated().map { index, step in
            let number = String(format: "%02d", index + 1)
            return (step, "\(number)-\(filenameComponent(for: step)).png")
        }
    }

    private static func filenameComponent(for step: OnboardingStep) -> String {
        switch step {
        case .voiceTool: return "voice-tool"
        case .remoteAvailability: return "control-source"
        case .permissions: return "permissions"
        case .remote: return "remote"
        case .audio: return "audio"
        case .voiceTest: return "voice-test"
        case .controls: return "controls"
        case .complete: return "complete"
        }
    }

    private static func makeWindow<Content: View>(
        hostingController: NSHostingController<Content>, size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "遥控搭子"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.contentViewController = hostingController
        window.setContentSize(size)
        window.center()
        return window
    }
}

#endif
