import AppKit
import Sparkle
import Testing
@testable import RemoteBuddy

@Suite("Localized update dialogs")
@MainActor
struct UpdateDialogTests {
    private func localization(_ suite: String) throws -> LocalizationStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return LocalizationStore(settings: AppSettings(defaults: defaults), resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
    }

    @Test func checkingFollowsChosenLanguageAndCancellationIsDeliveredOnce() throws {
        let suite = "update-dialog-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.english)
        let driver = LocalizedUpdateUserDriver(localization: language,
            currentVersion: .init(version: "v26-10-12.070", commitCount: "70"), presentsWindows: false)
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        #expect(driver.title == "Checking for updates…")
        #expect(driver.versionRows == [.init(label: "Installed version", version: "v26-10-12.070")])
        language.select(.simplifiedChinese)
        #expect(driver.title == "正在检查更新…")
        #expect(driver.versionRows == [.init(label: "当前版本", version: "v26-10-12.070")])
        #expect(driver.actionTitles == ["取消"])
        driver.performAction(at: 0)
        driver.performAction(at: 0)
        #expect(cancellations == 1)
    }

    @Test func foundVersionsStaySeparateAndInstallChoiceIsExplicit() throws {
        let suite = "update-dialog-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.english)
        let driver = LocalizedUpdateUserDriver(localization: language,
            currentVersion: .init(version: "v26-10-12.070", commitCount: "70"), presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        driver.showAvailableUpdate(.init(version: "v26-10-12.073", commitCount: "73")) { choices.append($0) }
        #expect(driver.versionRows.map(\.version) == ["v26-10-12.070", "v26-10-12.073"])
        #expect(choices.isEmpty)
        language.select(.simplifiedChinese)
        #expect(driver.versionRows.map(\.label) == ["当前版本", "更新版本"])
        #expect(driver.actionTitles == ["稍后提醒", "跳过此版本", "升级并重启"])
        driver.performAction(at: 2)
        driver.performAction(at: 2)
        #expect(choices == [.install])
    }

    @Test func errorAcknowledgementUsesAppLanguageAndDoesNotExposeSystemMessage() throws {
        let suite = "update-dialog-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.simplifiedChinese)
        let driver = LocalizedUpdateUserDriver(localization: language, presentsWindows: false)
        var acknowledgements = 0
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSLocalizedDescriptionKey: "Untranslated system message"])
        driver.showUpdaterError(error) { acknowledgements += 1 }
        #expect(driver.title == "更新未能完成")
        #expect(driver.diagnostic?.contains("-1009") == true)
        #expect(driver.actionTitles == ["关闭"])
        #expect(!driver.detail.contains("Untranslated system message"))
        driver.performAction(at: 0)
        driver.performAction(at: 0)
        #expect(acknowledgements == 1)
    }

    @Test(arguments: [true, false])
    func installationHandoffKeepsTheSameVisibleWindow(initialConsent: Bool) throws {
        let suite = "update-continuity-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        var activations = 0
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite),
            activateApplication: { activations += 1 })
        defer { driver.dismissUpdateInstallation() }
        var choices: [SPUUserUpdateChoice] = []
        driver.showAvailableUpdate(.init(version: "v26-10-15.215", commitCount: "215")) { choices.append($0) }
        let panel = try #require(driver.window)
        if initialConsent {
            driver.performAction(at: 2)
            #expect(driver.window === panel)
            #expect(panel.isVisible)
        }
        driver.showDownloadInitiated {}
        let downloadActivations = activations
        driver.showDownloadDidStartExtractingUpdate()
        #expect(driver.window === panel)
        #expect(panel.isVisible)
        #expect(activations == downloadActivations)
        driver.showExtractionReceivedProgress(1)
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        if !initialConsent { driver.performAction(at: 2) }
        let installationActivations = activations
        #expect(driver.window === panel)
        #expect(panel.isVisible)
        #expect(driver.actionTitles.isEmpty)
        #expect(driver.displayedProgress == -1)
        #expect(choices == (initialConsent ? [.install, .install] : [.install]))
        driver.showInstallingUpdate(withApplicationTerminated: false) {}
        driver.showInstallingUpdate(withApplicationTerminated: true) {}
        #expect(driver.window === panel)
        #expect(panel.isVisible)
        #expect(activations == installationActivations)
        var acknowledged = false
        driver.showUpdateInstalledAndRelaunched(true) { acknowledged = true }
        #expect(acknowledged)
        #expect(!panel.isVisible)
        #expect(driver.window == nil)
    }

    @Test func hiddenProgressDoesNotReappearDuringAutomaticInstallation() throws {
        let suite = "update-hidden-continuity-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        var activations = 0
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite),
            activateApplication: { activations += 1 })
        defer { driver.dismissUpdateInstallation() }
        driver.showAvailableUpdate(.init(version: "v26-10-15.215", commitCount: "215")) { _ in }
        driver.performAction(at: 2)
        driver.showDownloadInitiated {}
        driver.showDownloadDidStartExtractingUpdate()
        let panel = try #require(driver.window)
        driver.closeWindow()
        let previousActivations = activations
        driver.showReady(toInstallAndRelaunch: { _ in })
        driver.showInstallingUpdate(withApplicationTerminated: false) {}
        #expect(driver.window === panel)
        #expect(!panel.isVisible)
        #expect(activations == previousActivations)
        driver.showUpdateInFocus()
        #expect(panel.isVisible)
        #expect(!driver.actionTitles.isEmpty)
    }

    @Test func confirmedUpgradeContinuesAfterPreparationWithoutAnotherConfirmation() throws {
        let suite = "update-confirmed-restart-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.english)
        let driver = LocalizedUpdateUserDriver(localization: language, presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        driver.showAvailableUpdate(.init(version: "v26-10-15.215", commitCount: "215")) { choices.append($0) }
        #expect(driver.actionTitles.last == "Update and Restart")
        #expect(driver.detail.contains("administrator authorization"))
        driver.performAction(at: 2)
        driver.performAction(at: 2)
        #expect(choices == [.install])
        driver.showDownloadInitiated {}
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 100)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(1)
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices == [.install, .install])
        #expect(driver.actionTitles.isEmpty)
        // The initial consent is consumed; a resumed update asks again.
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(choices.count == 2)
        #expect(driver.actionTitles.last == "Install and Restart")
    }

    @Test(arguments: ["cancel", "dismiss", "error", "newCheck", "newCandidate"])
    func interruptedUpgradeDoesNotReuseRestartConsent(interruption: String) throws {
        let suite = "update-interrupted-restart-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite), presentsWindows: false)
        let next = UpdateDialogVersion(version: "v26-10-15.215", commitCount: "215")
        driver.showAvailableUpdate(next) { _ in }
        driver.performAction(at: 2)
        driver.showDownloadInitiated {}
        switch interruption {
        case "cancel": driver.closeWindow()
        case "dismiss": driver.dismissUpdateInstallation()
        case "error": driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009)) {}
        case "newCheck": driver.showUserInitiatedUpdateCheck {}
        default: driver.showAvailableUpdate(next) { _ in }
        }
        var installs = 0
        driver.showReady(toInstallAndRelaunch: { _ in installs += 1 })
        #expect(installs == 0)
        #expect(driver.actionTitles.count == 3)
    }

    @Test func readyUpdateCanBeDeferredWithoutSkippingIt() throws {
        let suite = "update-dialog-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.english)
        let driver = LocalizedUpdateUserDriver(localization: language, presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(driver.actionTitles == ["Cancel Install", "Install Later", "Install and Restart"])
        driver.performAction(at: 1)
        driver.performAction(at: 1)
        #expect(choices == [.dismiss])
    }

    @Test func progressUpdatesReuseTheExistingIndicator() throws {
        let suite = "update-progress-" + UUID().uuidString
        let language = try localization(suite)
        let driver = LocalizedUpdateUserDriver(localization: language, presentsWindows: false)
        driver.showDownloadInitiated {}
        let content = driver.makeContentView()
        let indicator = try #require(content.progressIndicator)
        content.updateProgress(0.5, text: "50%")
        #expect(content.progressIndicator === indicator)
        #expect(!indicator.isIndeterminate)
        #expect(indicator.doubleValue == 0.5)
        content.updateProgress(1, text: "100%")
        #expect(content.progressIndicator === indicator)
        #expect(indicator.doubleValue == 1)
    }

    @Test func progressHandlesUnknownLengthsAndDismissalDoesNotCancelCompletedDownload() throws {
        let suite = "update-dialog-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        let driver = LocalizedUpdateUserDriver(localization: language, presentsWindows: false)
        var cancellations = 0
        driver.showDownloadInitiated { cancellations += 1 }
        #expect(driver.displayedProgress == -1)
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 200)
        #expect(driver.displayedProgress == 1)
        driver.showDownloadDidStartExtractingUpdate()
        #expect(driver.actionTitles.isEmpty)
        driver.dismissUpdateInstallation()
        #expect(cancellations == 0)
    }

    @Test func latestVersionClaimRequiresAnExactInstalledVersionMatch() throws {
        let suite = "update-current-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.simplifiedChinese)
        let current = UpdateDialogVersion(version: "v26-10-13.111", commitCount: "111")
        let driver = LocalizedUpdateUserDriver(localization: language, currentVersion: current, presentsWindows: false)
        driver.showNoUpdate(latestVersion: nil, acknowledgement: {})
        #expect(driver.title == "暂无可安装的更新")
        driver.showNoUpdate(latestVersion: .init(version: "v26-10-14.112", commitCount: "112"), acknowledgement: {})
        #expect(driver.title == "暂无可安装的更新")
        #expect(driver.versionRows.count == 2)
        driver.showNoUpdate(latestVersion: current, acknowledgement: {})
        #expect(driver.title == "已是最新版本")
        #expect(driver.versionRows.count == 1)
        #expect(driver.actionTitles == ["关闭"])
    }

    @Test func installedUpdateAcknowledgesWithoutACompletionDialog() throws {
        let suite = "update-installed-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let language = try localization(suite)
        language.select(.simplifiedChinese)
        let driver = LocalizedUpdateUserDriver(localization: language, presentsWindows: false)
        var acknowledgements = 0
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        #expect(acknowledgements == 1)
        #expect(driver.actionTitles.isEmpty)
        #expect(driver.window == nil)
        driver.performAction(at: 0)
        driver.performAction(at: 0)
        #expect(acknowledgements == 1)
    }

    @Test func windowCloseDefersUpdatesAndAcknowledgesOnlyOnce() throws {
        let suite = "update-close-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite), presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        driver.showAvailableUpdate(.init(version: "v26-10-14.112", commitCount: "112")) { choices.append($0) }
        driver.closeWindow()
        driver.closeWindow()
        #expect(choices == [.dismiss])
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        driver.closeWindow()
        driver.closeWindow()
        #expect(choices == [.dismiss, .dismiss])
        var acknowledgements = 0
        driver.showNoUpdate(latestVersion: nil) { acknowledgements += 1 }
        driver.closeWindow()
        driver.closeWindow()
        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009)) { acknowledgements += 1 }
        driver.closeWindow()
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        driver.closeWindow()
        driver.closeWindow()
        #expect(acknowledgements == 3)
        var permission: SUUpdatePermissionResponse?
        driver.show(SPUUpdatePermissionRequest()) { permission = $0 }
        driver.closeWindow()
        #expect(permission?.automaticUpdateChecks == false)
        #expect(permission?.sendSystemProfile == false)
    }

    @Test func nativeCloseButtonCancelsDownloadAndHidesNoncancellableWork() throws {
        let suite = "update-native-close-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite))
        defer { driver.dismissUpdateInstallation() }
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        let checkingWindow = try #require(driver.window)
        #expect(checkingWindow.standardWindowButton(.closeButton)?.isEnabled == true)
        checkingWindow.performClose(nil)
        #expect(cancellations == 1)
        driver.showDownloadInitiated { cancellations += 1 }
        let downloadWindow = try #require(driver.window)
        downloadWindow.performClose(nil)
        downloadWindow.performClose(nil)
        #expect(cancellations == 2)
        driver.showDownloadDidStartExtractingUpdate()
        let extractionWindow = try #require(driver.window)
        extractionWindow.performClose(nil)
        #expect(!extractionWindow.isVisible)
        driver.showExtractionReceivedProgress(0.5)
        #expect(!extractionWindow.isVisible)
        #expect(driver.window === extractionWindow)
        var retries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        let installationWindow = try #require(driver.window)
        installationWindow.performClose(nil)
        #expect(!installationWindow.isVisible)
        #expect(retries == 0)
        driver.performAction(at: 0)
        #expect(retries == 1)
        #expect(cancellations == 2)
    }

    @Test func confirmationStagesRestoreTheWindowButProgressDoesNotStealFocus() throws {
        let suite = "update-focus-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        var activations = 0
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite),
            activateApplication: { activations += 1 })
        defer { driver.dismissUpdateInstallation() }
        driver.showDownloadInitiated {}
        let window = try #require(driver.window)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        window.orderOut(nil)
        let downloadingActivations = activations
        driver.showDownloadDidReceiveData(ofLength: 100)
        #expect(activations == downloadingActivations)
        #expect(!window.isVisible)
        driver.showReady(toInstallAndRelaunch: { _ in })
        #expect(driver.window === window)
        #expect(window.isVisible)
        #expect(activations == downloadingActivations + 1)
        window.orderOut(nil)
        driver.showUpdateInFocus()
        #expect(window.isVisible)
        #expect(activations == downloadingActivations + 2)
        driver.dismissUpdateInstallation()
        driver.showUpdateInFocus()
        #expect(activations == downloadingActivations + 2)
        #expect(!window.isVisible)
    }

    @Test func restartConfirmationFloatsUntilInstallationContinuesOrIsDeferred() throws {
        let suite = "update-restart-focus-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let driver = LocalizedUpdateUserDriver(localization: try localization(suite), activateApplication: {})
        defer { driver.dismissUpdateInstallation() }
        driver.showDownloadInitiated {}
        let panel = try #require(driver.window as? NSPanel)
        #expect(panel.level == .normal)
        driver.showDownloadDidStartExtractingUpdate()
        #expect(panel.level == .normal)
        panel.orderOut(nil)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        #expect(driver.window === panel)
        #expect(panel.isVisible)
        #expect(panel.level == .floating)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.moveToActiveSpace))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        driver.showInstallingUpdate(withApplicationTerminated: false) {}
        #expect(panel.level == .floating)
        driver.showInstallingUpdate(withApplicationTerminated: true) {}
        #expect(panel.level == .normal)
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        driver.performAction(at: 1)
        #expect(choices == [.dismiss])
        #expect(!panel.isVisible)
        #expect(driver.window == nil)
        driver.showDownloadInitiated {}
        #expect(driver.window?.level == .normal)
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese])
    func footerActionsFitTheDialogInBothLanguages(language: AppLanguage) throws {
        let suite = "update-layout-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let localization = try localization(suite)
        localization.select(language)
        let driver = LocalizedUpdateUserDriver(localization: localization,
            currentVersion: .init(version: "v26-10-13.111", commitCount: "111"), presentsWindows: false)
        driver.showAvailableUpdate(.init(version: "v26-10-14.112", commitCount: "112")) { _ in }
        driver.showReady(toInstallAndRelaunch: { _ in })
        let content = driver.makeContentView()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content.preferredSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        var lastRight: CGFloat = 0
        for button in content.actionButtons {
            let rect = content.convert(button.alignmentRect(forFrame: button.bounds), from: button)
            #expect(content.bounds.contains(rect))
            #expect(rect.minX >= lastRight)
            #expect(button.bounds.width >= button.intrinsicContentSize.width)
            lastRight = rect.maxX
        }
        #expect(content.actionButtons.last?.keyEquivalent == "\r")
    }
}
