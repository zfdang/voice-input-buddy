import Foundation
import AppKit
import Testing
@testable import VoiceInputBuddy

@Suite("Product privacy boundaries")
struct ProductBoundaryTests {
    @Test @MainActor func onboardingLoadsReplacementJPEGsAndRetainsDarkPNGSelection() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(path: resources.path))
        let paired = [
            "doubao-menu", "doubao-settings",
            "weixin-input-menu", "weixin-input-settings",
            "bageshuo-menu", "bageshuo-settings", "bageshuo-input-microphone",
        ]
        let microphone = ["doubao-input-microphone", "weixin-input-microphone", "voicecursor-setting-fn", "voicecursor-setting-mic"]
        for name in paired + microphone {
            let url = try #require(VoiceInputBuddyResourceBundle.onboardingImageURL(named: name, isDark: false, in: bundle))
            #expect(url.lastPathComponent == "\(name)-light.jpg")
            let image = try #require(NSImage(contentsOf: url))
            #expect(image.size.width > 0 && image.size.height > 0)
            let dark = try #require(VoiceInputBuddyResourceBundle.onboardingImageURL(named: name, isDark: true, in: bundle))
            #expect(dark.lastPathComponent == "\(name)-\(paired.contains(name) ? "dark.png" : "light.jpg")")
        }
    }

    @Test func referencedLocalizationKeysExistInAllSupportedLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Resources")
        let appSources = root.appendingPathComponent("Sources/VoiceInputBuddy")
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: appSources, includingPropertiesForKeys: nil)!
        var allSource = ""
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            allSource += try String(contentsOf: fileURL, encoding: .utf8) + "\n"
        }
        var referencedKeys = Set<String>()
        let patterns = [
            #"titleKey:\s*"([\w\.-]+)""#,
            #"detailKey:\s*"([\w\.-]+)""#,
            #"localization\.text\("([\w\.-]+)"\)"#,
            #"LocalizedMessage\(\s*"([\w\.-]+)""#,
        ]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let nsSource = allSource as NSString
            let matches = regex.matches(in: allSource, range: NSRange(location: 0, length: nsSource.length))
            for match in matches {
                referencedKeys.insert(nsSource.substring(with: match.range(at: 1)))
            }
        }
        for lang in ["zh-Hans.lproj", "en.lproj"] {
            let stringsURL = resources.appendingPathComponent(lang).appendingPathComponent("Localizable.strings")
            let content = try String(contentsOf: stringsURL, encoding: .utf8)
            let keyRegex = try NSRegularExpression(pattern: #"^\s*"([^"\n]+)"\s*="#, options: .anchorsMatchLines)
            let nsContent = content as NSString
            let keyMatches = keyRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            var definedKeys = Set<String>()
            for match in keyMatches {
                definedKeys.insert(nsContent.substring(with: match.range(at: 1)))
            }
            let missing = referencedKeys.subtracting(definedKeys)
            #expect(missing.isEmpty, "Missing keys in \(lang): \(missing)")
        }
    }

    @Test func releaseTagsCanBeComparedAndPreviewFallsBack() async {
        #expect(UpdateVersion.normalized("v26-10-11.021") == "26.10.11.021")
        #expect(UpdateVersion.isNewer("v26-10-11.022", than: "v26-10-11.021"))
        let stable = URL(string: "https://voice.zfdang.com/appcast-arm64.xml")!
        let preview = URL(string: "https://voice.zfdang.com/preview/appcast-arm64.xml")!
        let resolution = await UpdateFeedResolver.resolvePreviewFeed(stableURL: stable, previewURL: preview) { url in
            if url == preview { throw URLError(.fileDoesNotExist) }
            return Data(#"<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>21</sparkle:version><sparkle:shortVersionString>v26-10-11.021</sparkle:shortVersionString></item></channel></rss>"#.utf8)
        }
        #expect(resolution.selected?.url == stable)
        #expect(resolution.selected?.version == "26.10.11.021")
    }

    @Test func updateFeedOnlyUsesProductHTTPSOrigin() {
        let selection = UpdateFeedSelection(stableFeedURLString: "https://voice.zfdang.com/appcast-arm64.xml")
        #expect(selection.feedURLString(checksForPreReleaseUpdates: false) == "https://voice.zfdang.com/appcast-arm64.xml")
        #expect(selection.feedURLString(checksForPreReleaseUpdates: true) == "https://voice.zfdang.com/preview/appcast-arm64.xml")
        for url in ["http://voice.zfdang.com/appcast-arm64.xml", "https://evil.example/appcast-arm64.xml",
                    "https://voice.zfdang.com/appcast-arm64.xml?redirect=evil", "https://user@voice.zfdang.com/appcast-arm64.xml",
                    "https://voice.zfdang.com:8443/appcast-arm64.xml", "https://voice.zfdang.com/other.xml"] {
            #expect(UpdateFeedSelection(stableFeedURLString: url).validatedStableFeedURL == nil)
        }
    }

    @Test @MainActor func configurationOperationsPersistPreferencesWithoutUsageData() throws {
        let suite = "voice-input-buddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setAction(.commandCopy, for: .right)
        settings.gainDB = 12
        try settings.importConfiguration(from: settings.exportedConfigurationData())
        _ = settings.recordLaunchAndDetectCompletedUpdate(currentBuild: "80", sparkleHadLaunchedBefore: false)
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(!persisted.isEmpty)
        #expect(persisted.keys.allSatisfy { !$0.hasPrefix("usage.") })
        let exported = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        #expect(exported.keys.allSatisfy { !$0.hasPrefix("usage.") })
    }

    @Test @MainActor func everySetupScreenshotAndRemoteIllustrationDecodes() throws {
        let bundle = VoiceInputBuddyResourceBundle.mainOrDevelopment
        for name in ["doubao-menu", "doubao-settings", "system-fn",
                     "weixin-app-shortcuts", "weixin-input-menu",
                     "weixin-input-settings", "bageshuo-menu",
                     "bageshuo-settings", "bageshuo-input-microphone"] {
            for theme in ["light", "dark"] {
                let url = try #require(VoiceInputBuddyResourceBundle.onboardingImageURL(
                    named: name, isDark: theme == "dark", in: bundle))
                let image = try #require(NSImage(contentsOf: url))
                #expect(image.isValid)
            }
        }
        let remote = try #require(bundle.url(forResource: "BuddyRemoteIllustration",
                                            withExtension: "png"))
        #expect(try #require(NSImage(contentsOf: remote)).isValid)
    }

    @Test func unavailableFeaturesStayOutOfNavigation() {
        let sections = SettingsPageBehavior.sidebarSections()
        #expect(sections.contains(.mapping))
        #expect(sections.contains(.connection))
        #expect(!SettingsSection.allCases.map(\.rawValue).contains("transcripts"))
        #expect(!SettingsSection.allCases.map(\.rawValue).contains("membership"))
    }

    @Test func dailyNavigationKeepsPermissionRepairBeforeSettings() {
        let sections = SettingsPageBehavior.sidebarSections()
        #expect(sections == [.connection, .mapping, .integration, .permissions, .about])
        #expect(SettingsPageBehavior.visibleSection(for: .permissions) == .permissions)
        #expect(SettingsPageBehavior.initialSection(
            requestedSection: nil
        ) == .connection)
        #expect(SettingsPageBehavior.initialSection(
            requestedSection: .permissions
        ) == .permissions)
    }

    @Test @MainActor func changingIntegrationKeepsHardwareAudioAndMappings() throws {
        let suite = "voice-input-buddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.gainDB = 6
        settings.customMappingEnabled = true
        settings.setOnboardingControlSource(.chromecastRemote)
        settings.completeOnboarding()
        SettingsPageBehavior.beginIntegrationSetup(tool: .voicecursor, settings: settings)
        #expect(settings.selectedAudioDeviceUID == "BuddyMic2ch_UID")
        #expect(settings.gainDB == 6)
        #expect(settings.customMappingEnabled)
        #expect(settings.onboardingVoiceTool == .voicecursor)
        #expect(settings.onboardingControlSource == .chromecastRemote)
        #expect(settings.onboardingPurpose == .integration)
        #expect(settings.onboardingStep == .voiceTool)
        #expect(!settings.isOnboardingComplete)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.onboardingVoiceTool == .voicecursor)
        let tools = OnboardingVoiceToolVisibilityPolicy.tools
        #expect(tools.contains(.voicecursor))
        #expect(tools.contains(.other))
    }

    @Test func integrationCatalogIncludesUninstalledToolsInConsistentOrder() {
        #expect(OnboardingVoiceToolVisibilityPolicy.tools == [
            .weixin, .doubao, .bageshuo, .typeless, .voicecursor, .macosDictation, .other,
        ])
    }

    @Test @MainActor func firstRunLanguageFollowsSystemAndExplicitChoicePersists() throws {
        let suite = "voice-input-buddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.applicationLanguage == .system)
        let localization = LocalizationStore(settings: settings)
        localization.select(.english)
        #expect(AppSettings(defaults: defaults).applicationLanguage == .english)
        localization.select(.simplifiedChinese)
        #expect(AppSettings(defaults: defaults).applicationLanguage == .simplifiedChinese)
    }

    @Test @MainActor func plannedRemoteIllustrationsLoadWithoutUsingTheXiaomiImage() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let bundle = try #require(Bundle(path: resources.path))
        let planned = RemoteSetupDevice.allCases.filter { $0 != .xiaomi }
        #expect(Set(planned.map(\.illustrationResource)).count == 3)
        for device in planned {
            #expect(device.illustrationResource != RemoteSetupDevice.xiaomi.illustrationResource)
            let url = try #require(bundle.url(forResource: device.illustrationResource, withExtension: "png"))
            let image = try #require(NSImage(contentsOf: url))
            #expect(image.size.width > 0 && image.size.height > image.size.width)
        }
    }

    @Test func deviceScopeKeepsGoogleModelsDistinctAndSelectable() {
        #expect(RemoteSetupDevice.allCases == [
            .xiaomi, .chromecastG9N9N, .googleStreamerGY3LE, .siriRemote,
        ])
        #expect(RemoteSetupDevice.chromecastG9N9N.googleHardwareModelNumber == "G9N9N")
        #expect(RemoteSetupDevice.googleStreamerGY3LE.googleHardwareModelNumber == "GY3LE")
        #expect(RemoteSetupDevice.allCases.filter(\.canStartSetup) == [.xiaomi, .chromecastG9N9N, .googleStreamerGY3LE])
        // Listing a planned device must not admit it through the Xiaomi hardware bridge.
        #expect(XiaomiRemoteCatalog.entry(matchingDISModelNumber: "G9N9N") == nil)
        #expect(XiaomiRemoteCatalog.entry(matchingDISModelNumber: "GY3LE") == nil)
    }

    @Test @MainActor func g9n9nSelectionPersistsWithoutClaimingAConnection() throws {
        let suite = "voice-input-buddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        let view = OnboardingView(model: model)
        view.selectControlSource(.chromecastRemote)
        #expect(settings.onboardingControlSource == .chromecastRemote)
        #expect(settings.onboardingControlMethod == .physicalRemote)
        #expect(AppSettings(defaults: defaults).onboardingControlSource == .chromecastRemote)
        #expect(!model.isOnboardingControlSourceConnected(.chromecastRemote))
        #expect(OnboardingRemotePhotoKind.resolve(source: .chromecastRemote, selectedModel: .rc003)
            == .bundled(resourceName: "ChromecastG9N9NIllustration"))
        #expect(RemoteSetupDevice.chromecastG9N9N.canStartSetup)
    }

    @Test @MainActor func deviceChoicePersistsAndContinueBlocksOnlyUpcomingAdapters() throws {
        for device in RemoteSetupDevice.allCases {
            let suite = "voice-input-buddy.tests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.setOnboardingStep(.remoteAvailability)
            let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
            let view = OnboardingView(model: model)
            view.selectDevice(device)
            #expect(settings.onboardingDevice == device)
            #expect(view.canContinue == device.canStartSetup)
            #expect(AppSettings(defaults: defaults).onboardingDevice == device)
            view.continueFlow()
            if device.canStartSetup {
                #expect(settings.onboardingStep == .remote)
                #expect(!model.isOnboardingControlSourceConnected(settings.onboardingControlSource))
            } else {
                #expect(settings.onboardingStep == .remoteAvailability)
                #expect(settings.onboardingControlSource == .unselected)
                #expect(!settings.firstUseEvents.contains { $0.step == .remoteAvailability && $0.kind == .passed })
            }
            settings.restartOnboarding()
            #expect(settings.onboardingDevice == nil)
            settings.setOnboardingStep(.remoteAvailability)
            #expect(!view.canContinue)
        }
    }

    @Test @MainActor func googleSelectionKeepsItsOwnIllustrationAndConnectionValidation() throws {
        for device in [RemoteSetupDevice.chromecastG9N9N, .googleStreamerGY3LE] {
            let suite = "google-selection-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            let view = OnboardingView(model: BridgeAppModel(settings: settings, initialAudioDevices: []))
            settings.setOnboardingStep(.remoteAvailability)
            view.selectDevice(device)
            view.continueFlow()
            #expect(settings.onboardingStep == .remote)
            #expect(settings.onboardingControlSource == .chromecastRemote)
            let restored = AppSettings(defaults: defaults)
            #expect(restored.onboardingDevice == device)
            #expect(OnboardingRemotePhotoKind.resolve(source: restored.onboardingControlSource,
                selectedModel: .rc003, selectedDevice: restored.onboardingDevice)
                == .bundled(resourceName: device.illustrationResource))
            #expect(!OnboardingFlowPolicy.canContinue(from: .remote, voiceTool: .doubao,
                selectedDevice: device, capabilities: .init(bluetoothGranted: true,
                    inputMonitoringGranted: true, accessibilityGranted: true)))
            #expect(view.physicalRemotePairingKeys.thirdStep == "onboarding.remote.chromecast_pairing.third")
        }
        #expect(RemoteSetupDevice.googleStreamerGY3LE.canStartSetup)
        #expect(OnboardingRemotePhotoKind.resolve(source: .chromecastRemote,
            selectedModel: .rc003, selectedDevice: .xiaomi)
            == .bundled(resourceName: RemoteSetupDevice.chromecastG9N9N.illustrationResource))
    }

    @Test func wizardRequiresEachPermissionAndKeepsRemoteControl() {
        #expect(OnboardingBuildCapabilities.availableControlSources == [.xiaomiRemote, .chromecastRemote])
        let ready = OnboardingCapabilities(
            bluetoothGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )
        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions, voiceTool: .unselected, remoteAvailability: .unselected,
            controlMethod: .unselected, capabilities: ready
        ))
        for keyPath in [
            \OnboardingCapabilities.bluetoothGranted,
            \OnboardingCapabilities.inputMonitoringGranted,
            \OnboardingCapabilities.accessibilityGranted
        ] {
            var missing = ready
            missing[keyPath: keyPath] = false
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .permissions, voiceTool: .unselected, capabilities: missing
            ))
        }
    }

    @Test func driverIsRequiredAtAudioSetupRatherThanPermissions() {
        var ready = OnboardingCapabilities(
            bluetoothGranted: true, inputMonitoringGranted: true,
            accessibilityGranted: true, audioReady: true, audioOutputSelected: true
        )
        #expect(OnboardingFlowPolicy.canContinue(
            from: .permissions, voiceTool: .unselected, remoteAvailability: .unselected,
            controlMethod: .unselected, capabilities: ready
        ))
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .audio, voiceTool: .unselected, capabilities: ready
        ))
        ready.microphoneDriverInstalled = true
        #expect(OnboardingFlowPolicy.canContinue(
            from: .audio, voiceTool: .unselected, capabilities: ready
        ))
    }

    @Test func inputToolRequiresViewedStepsButNoMicrophoneCheckbox() {
        let passed = OnboardingCapabilities(
            bluetoothGranted: true, inputMonitoringGranted: true, accessibilityGranted: true,
            voiceSessionStarted: true, voiceSamplesReceived: true,
            voiceSessionEnded: true, transcriptionAppeared: true
        )
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTool, voiceTool: .unselected, capabilities: passed
        ))
        for tool in [OnboardingVoiceTool.weixin, .doubao, .bageshuo, .voicecursor, .typeless, .other] {
            #expect(!OnboardingFlowPolicy.canContinue(
                from: .voiceTool, voiceTool: tool, capabilities: OnboardingCapabilities()
            ))
            #expect(OnboardingFlowPolicy.canContinue(
                from: .voiceTool, voiceTool: tool,
                voiceToolGuideStepsCompleted: true, capabilities: OnboardingCapabilities()
            ))
        }
        // Step 7 verifies the input result and has no configuration confirmations.
        #expect(OnboardingFlowPolicy.canContinue(
            from: .voiceTest, voiceTool: .weixin, capabilities: passed
        ))
        var incomplete = passed
        incomplete.voiceSamplesReceived = false
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTest, voiceTool: .weixin,
            capabilities: incomplete
        ))
        var typed = passed
        typed.manualTranscriptInputObserved = true
        #expect(!OnboardingFlowPolicy.canContinue(
            from: .voiceTest, voiceTool: .weixin,
            capabilities: typed
        ))
    }

    @Test @MainActor func wizardStartsWithEnvironmentAndUsesOnlyCurrentSteps() throws {
        let suite = "voice-input-buddy.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.onboardingStep == .permissions)
        #expect(settings.onboardingControlMethod == .unselected)
        settings.setOnboardingControlSource(.xiaomiRemote)
        #expect(AppSettings(defaults: defaults).onboardingControlMethod == .physicalRemote)
        #expect(OnboardingStep.permissions.previous == nil)
        #expect(OnboardingStep.permissions.next == .remoteAvailability)
        #expect(OnboardingStep.remoteAvailability.next == .remote)
        #expect(OnboardingStep.remote.next == .controls)
        #expect(OnboardingStep.controls.next == .audio)
        #expect(OnboardingStep.audio.next == .voiceTool)
        #expect(OnboardingStep(rawValue: "welcome") == nil)
        #expect(OnboardingStep(rawValue: "controlMethod") == nil)
        settings.completeOnboarding()
        settings.restartOnboarding()
        #expect(settings.onboardingStep == .permissions)
        #expect(settings.onboardingControlMethod == .unselected)
    }

    @Test func independentMicrophoneIsAcceptedByWizard() {
        #expect(OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: BuddyMicrophoneDevicePolicy.deviceUID,
            name: BuddyMicrophoneDevicePolicy.deviceName
        ))
        #expect(!OnboardingAudioSelectionPolicy.isSupportedDevice(
            uid: "speaker", name: "MacBook Speakers"
        ))
    }

}
