#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum SettingsScreenshotRenderer {
    private enum RenderingError: Error, LocalizedError {
        case invalidSize(String)
        case invalidAppearance(String)
        case invalidLanguage(String)
        case bitmapCreationFailed
        case pngCreationFailed

        var errorDescription: String? {
            switch self {
            case let .invalidSize(value):
                return "Unsupported settings screenshot size: \(value). Use WIDTHxHEIGHT."
            case let .invalidAppearance(value):
                return "Unsupported settings screenshot appearance: \(value)."
            case let .invalidLanguage(value):
                return "Unsupported settings screenshot language: \(value)."
            case .bitmapCreationFailed:
                return "The settings screenshot bitmap could not be created."
            case .pngCreationFailed:
                return "The settings screenshot bitmap could not be encoded as PNG."
            }
        }
    }

    private static let sections = SettingsPageBehavior.sidebarSectionOrder + [.commonPhrases]

    static func renderAll(
        to outputDirectory: URL,
        sizeValue: String?,
        appearanceName: String?,
        languageName: String?
    ) throws {
        let size = try screenshotSize(from: sizeValue)
        let appearance = try screenshotAppearance(from: appearanceName)
        let language = try screenshotLanguage(from: languageName)
        let opensShortcutEditor = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_OPEN_SHORTCUT_EDITOR"
        ] == "1"
        let opensActionEditor = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_OPEN_ACTION_EDITOR"
        ] == "1"
        let opensMappingEditor = opensShortcutEditor || opensActionEditor
        let editingButton = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_EDITING_BUTTON"
        ].flatMap(RemoteButton.init(rawValue:)) ?? .ok
        let editingTrigger = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_EDITING_TRIGGER"
        ].flatMap(ButtonTrigger.init(rawValue:)) ?? .singleClick
        let showsStandardKeyboard = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_SHORTCUT_MODE"
        ] == "keyboard"
        let usesSiriRemote = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_SIRI_REMOTE"
        ] == "1"
        let usesChromecast = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_CHROMECAST"
        ] == "1"
        let showsRemoteCards = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_REMOTE_CARDS"
        ] == "1"
        let onlySection = ProcessInfo.processInfo.environment["REMOTE_BUDDY_SETTINGS_SCREENSHOT_SECTION"]
        let interactive = ProcessInfo.processInfo.environment["REMOTE_BUDDY_SETTINGS_SCREENSHOT_INTERACTIVE"] == "1"
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let suiteName = "RemoteBuddy.SettingsScreenshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RenderingError.bitmapCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = language
        settings.completeOnboarding()
        if let iconIdentifier = ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_APP_ICON"
        ] {
            settings.appIconIdentifier = AppIconIdentifier(rawValue: iconIdentifier)
        }
        var remoteCardSystemNames: [UUID: String] = [:]
        var remoteCardBatteryLevels: [UUID: Int] = [:]
        var remoteCardPowerStates: [UUID: RemotePowerState] = [:]
        let screenshotAudioDevices: [AudioDeviceInfo] = switch ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_AUDIO_DRIVER"
        ] {
        case "missing":
            []
        default:
            [
                AudioDeviceInfo(id: 1, uid: BuddyMicrophoneDevicePolicy.deviceUID, name: BuddyMicrophoneDevicePolicy.deviceName),
                AudioDeviceInfo(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
            ]
        }
        let permissionsOverride: SystemPermissionOverrides? = switch ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_PERMISSIONS"
        ] {
        case "missing", "denied":
            SystemPermissionOverrides(bluetooth: .denied, inputMonitoring: false, accessibility: false)
        default:
            .allGranted
        }
        let model = BridgeAppModel(
            settings: settings,
            initialAudioDevices: screenshotAudioDevices
        )
        if showsRemoteCards {
            settings.customMappingEnabled = true
            let xiaomiID = settings.registerBluetoothRemote(
                identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            )
            settings.updateRemoteProfileModel(xiaomiID, model: .rc003)
            model.remoteDeviceInformation[UUID(uuidString: "00000000-0000-0000-0000-000000000101")!] = RemoteDeviceInformation(
                modelNumber: "RC003", firmwareRevision: "2671", identity: .xiaomi,
                capabilities: ATVVCapabilities(version: 0x0100, codecs: 2, interaction: 3,
                    frameSize: 120, selectedCodec: 2, sampleRate: 16_000)
            )
            settings.bindHIDFingerprint("settings-screenshot-xiaomi", to: xiaomiID)
            let chromecastID = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
            settings.selectRemoteProfile(xiaomiID)
            remoteCardSystemNames = [
                xiaomiID: language == .simplifiedChinese ? "书房遥控器" : "Study Remote",
                chromecastID: language == .simplifiedChinese ? "客厅 G9N9N" : "Living Room G9N9N",
            ]
            remoteCardBatteryLevels = [
                xiaomiID: 78,
                chromecastID: 64,
            ]
            remoteCardPowerStates = [
                xiaomiID: .charging,
                chromecastID: .onBattery,
            ]
        }
        _ = usesSiriRemote
        if usesChromecast {
            let identifier = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
            settings.selectRemoteProfile(identifier)
        }
        if opensShortcutEditor {
            settings.customMappingEnabled = true
            settings.setAction(.customShortcut, for: .ok, trigger: .singleClick)
            settings.setShortcut(
                KeyboardShortcutPreset.spotlight.shortcut,
                for: .ok,
                trigger: .singleClick
            )
        }
        if showsRemoteCards {
            model.configureRemoteCardsForSettingsScreenshot(
                profileIDs: Set(remoteCardSystemNames.keys),
                systemNames: remoteCardSystemNames,
                batteryLevels: remoteCardBatteryLevels,
                powerStates: remoteCardPowerStates
            )
        }
        let updateInformation = UpdateInformationStore(userDefaults: defaults)
        if ProcessInfo.processInfo.environment["REMOTE_BUDDY_SETTINGS_SCREENSHOT_UP_TO_DATE"] == "1" {
            updateInformation.setUpToDate()
        } else {
            seedAvailableUpdate(updateInformation, language: language)
        }
        if ProcessInfo.processInfo.environment[
            "REMOTE_BUDDY_SETTINGS_SCREENSHOT_UPDATE_SEEN"
        ] == "1" {
            updateInformation.markAvailableUpdateSeen()
        }
        let localization = LocalizationStore(settings: settings, resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)

        _ = NSApplication.shared
        AppIconController().apply(settings.appIconIdentifier, source: "screenshot")
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }
        if interactive {
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
        }

        // Interactive review uses the production view, navigation and window geometry,
        // with the same isolated fixture settings as the offscreen renderer.
        if ProcessInfo.processInfo.environment["REMOTE_BUDDY_SETTINGS_SCREENSHOT_INTERACTIVE"] == "1" {
            let section = sections.first { $0.rawValue == onlySection } ?? .mapping
            let controller = NSHostingController(rootView: SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialMappingEditingButton: section == .mapping && opensMappingEditor ? editingButton : nil,
                initialMappingEditingTrigger: editingTrigger,
                initialShortcutPickerShowsKeyboard: showsStandardKeyboard,
                permissionOverrides: permissionsOverride
            ).environmentObject(localization))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "RemoteBuddy — Settings Review"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.minSize = SettingsWindowLayout.minimumWindowSize(in: NSScreen.main?.visibleFrame
                ?? NSRect(origin: .zero, size: size))
            window.contentViewController = controller
            window.setContentSize(size)
            window.center()
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }

        for section in sections where onlySection == nil || onlySection == section.rawValue {
            let rootView = SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialMappingEditingButton: section == .mapping && opensMappingEditor
                    ? editingButton
                    : nil,
                initialMappingEditingTrigger: editingTrigger,
                initialShortcutPickerShowsKeyboard: showsStandardKeyboard,
                minimumContentSize: SettingsWindowLayout.minimumCanvasSize,
                permissionOverrides: permissionsOverride
            )
            .modifier(UpdateCompletionToast(version: ProcessInfo.processInfo.environment[
                "REMOTE_BUDDY_SETTINGS_SCREENSHOT_COMPLETED_UPDATE_VERSION"
            ], contentLeadingInset: SettingsPageBehavior.contentLeadingInset))
            .environmentObject(localization)
            .frame(width: size.width, height: size.height)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: interactive ? [.titled, .closable, .resizable] : [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hostingController
            window.title = "RemoteBuddy — UI check"
            window.setContentSize(size)
            window.orderFront(nil)
            if interactive {
                // The production settings view uses isolated screenshot data;
                // this bounded mode permits clicks without starting hardware.
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let deadline = Date().addingTimeInterval(300)
                while window.isVisible && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            window.contentView?.layoutSubtreeIfNeeded()
            scrollCanvasToEndIfRequested(in: window.contentView)
            window.contentView?.displayIfNeeded()
            // Layout can enqueue another SwiftUI symbol-rendering pass. Let it
            // finish before caching pixels from this newly created window.
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()

            guard let contentView = window.contentView,
                  contentView.bounds.size == size,
                  let representation = contentView.bitmapImageRepForCachingDisplay(
                      in: contentView.bounds
                  )
            else {
                throw RenderingError.bitmapCreationFailed
            }
            contentView.cacheDisplay(in: contentView.bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw RenderingError.pngCreationFailed
            }
            let filename = String(
                format: "%@-%dx%d.png",
                section.rawValue,
                Int(size.width),
                Int(size.height)
            )
            try png.write(to: outputDirectory.appendingPathComponent(filename))
            window.orderOut(nil)
            window.contentViewController = nil
        }

        // Capture the same nonactivating panel view used for real input. This
        // hidden renderer neither opens a remote session nor posts text.
        let panelSize = CommonPhrasePanelView.size
        let phrasePanel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        phrasePanel.contentView = NSHostingView(rootView:
            CommonPhrasePanelView(controller: model.commonPhrases).environmentObject(localization))
        phrasePanel.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let view = phrasePanel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw RenderingError.bitmapCreationFailed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let panelPNG = bitmap.representation(using: .png, properties: [:])
        else { throw RenderingError.pngCreationFailed }
        try panelPNG.write(to: outputDirectory.appendingPathComponent("common-phrases-panel.png"))
        phrasePanel.orderOut(nil)
        phrasePanel.contentView = nil
    }

    private static func seedAvailableUpdate(
        _ updateInformation: UpdateInformationStore,
        language: AppLanguage
    ) {
        let notes: String
        switch language {
        case .simplifiedChinese:
            notes = "优化设置页面结构\n权限与日志集中管理\n修复已知问题"
        case .system, .english:
            notes = "Refined the Settings layout\nCentralized permissions and logs\nFixed known issues"
        }
        updateInformation.setAvailable(
            displayVersion: "1.9.22",
            buildVersion: "183",
            fallbackDescription: notes
        )
    }

    /// Exercise the compact canvas's actual AppKit scroll range in isolated previews.
    static func scrollCanvasToEndIfRequested(in view: NSView?) {
        guard ProcessInfo.processInfo.environment["REMOTE_BUDDY_SCREENSHOT_SCROLL_TO_END"] == "1",
              let view else { return }
        func firstScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { firstScrollView($0) }.first
        }
        guard let scroll = firstScrollView(view), let document = scroll.documentView else { return }
        let x = max(0, document.bounds.width - scroll.contentView.bounds.width)
        let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func screenshotSize(from value: String?) throws -> NSSize {
        let value = value ?? "1020x772"
        let components = value.lowercased().split(separator: "x")
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width.isFinite, height.isFinite,
              width >= 320, width <= 8192,
              height >= 240, height <= 8192
        else {
            throw RenderingError.invalidSize(value)
        }
        return NSSize(width: width, height: height)
    }

    private static func screenshotAppearance(from value: String?) throws -> NSAppearance? {
        switch value?.lowercased() ?? "light" {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        case "system": return nil
        case let value: throw RenderingError.invalidAppearance(value)
        }
    }

    private static func screenshotLanguage(from value: String?) throws -> AppLanguage {
        switch value?.lowercased() ?? "zh-hans" {
        case "zh-hans", "zh", "chinese": return .simplifiedChinese
        case "en", "english": return .english
        case let value: throw RenderingError.invalidLanguage(value)
        }
    }
}

#endif
