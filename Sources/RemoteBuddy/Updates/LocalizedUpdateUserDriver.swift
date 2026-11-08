import AppKit
import Combine
import Sparkle

struct UpdateDialogVersion: Equatable {
    let version: String
    let commitCount: String

    static func current(bundle: Bundle = .main) -> Self {
        Self(version: bundle.object(forInfoDictionaryKey: "BuddyReleaseVersion") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
             commitCount: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
    }
}

/// Sparkle retains responsibility for verification, downloading and installation.
/// Only its public user-interface callbacks are implemented here.
@MainActor
final class LocalizedUpdateUserDriver: NSObject, SPUUserDriver, NSWindowDelegate {
    private struct Action {
        let key: String
        let completes: Bool
        let handler: () -> Void
    }

    private let localization: LocalizationStore
    private let currentVersion: UpdateDialogVersion
    private let presentsWindows: Bool
    private let activateApplication: @MainActor () -> Void
    private var languageSubscription: AnyCancellable?
    private(set) var window: NSWindow?
    private var isPresented = false
    private var installAndRelaunchWhenReady = false
    private var candidateVersion: UpdateDialogVersion?
    private var actions: [Action] = []
    private var closeActionIndex: Int?
    private var detailArguments: [String] = []
    private var detailKey = "update.dialog.checking.detail"
    private var titleKey = "menu.check_for_updates"
    private var progress: Double?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    private(set) var diagnostic: String?

    var title: String { localization.text(titleKey) }
    var detail: String { LocalizedMessage(detailKey, arguments: detailArguments).text(using: localization) }
    var versionRows: [UpdateDialogVersionRow] {
        var rows = [UpdateDialogVersionRow(
            label: localization.text("update.dialog.installed_version"),
            version: currentVersion.version)]
        if let candidateVersion, titleKey != "update.dialog.up_to_date" {
            let labelKey = titleKey == "update.dialog.not_found" ? "update.dialog.latest_version" : "update.dialog.available_version"
            rows.append(.init(label: localization.text(labelKey), version: candidateVersion.version))
        }
        return rows
    }
    var actionTitles: [String] { actions.map { localization.text($0.key) } }
    var displayedProgress: Double? { progress }

    private var progressText: String? {
        guard titleKey == "update.dialog.downloading" else { return nil }
        let format = ByteCountFormatStyle(style: .file).locale(localization.locale)
        let received = format.format(Int64(clamping: receivedLength))
        guard expectedLength > 0 else { return received }
        let expected = format.format(Int64(clamping: expectedLength))
        let percent = Int(min(1, Double(receivedLength) / Double(expectedLength)) * 100)
        return "\(received) / \(expected) · \(percent)%"
    }

    private var statusStyle: (symbol: String, tint: NSColor) {
        switch titleKey {
        case "update.dialog.up_to_date": return ("checkmark.circle.fill", .systemGreen)
        case "update.dialog.error": return ("exclamationmark.triangle.fill", .systemOrange)
        case "update.dialog.found", "update.dialog.ready": return ("arrow.down.circle.fill", .controlAccentColor)
        case "update.dialog.downloading": return ("arrow.down.to.line", .controlAccentColor)
        case "update.dialog.extracting", "update.dialog.installing": return ("shippingbox", .controlAccentColor)
        case "update.dialog.permission": return ("clock.arrow.circlepath", .controlAccentColor)
        case "update.dialog.not_found": return ("info.circle", .secondaryLabelColor)
        default: return ("arrow.triangle.2.circlepath", .controlAccentColor)
        }
    }

    init(localization: LocalizationStore, currentVersion: UpdateDialogVersion = .current(),
         presentsWindows: Bool = true,
         activateApplication: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.localization = localization
        self.currentVersion = currentVersion
        self.presentsWindows = presentsWindows
        self.activateApplication = activateApplication
        super.init()
        languageSubscription = localization.$locale
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
    }

    private func present(_ title: String, detail: String? = nil, arguments: [String] = [],
                         progress: Double? = nil, diagnostic: String? = nil, closeActionIndex: Int? = nil,
                         activate: Bool = true, actions: [Action] = []) {
        isPresented = true
        titleKey = title
        detailKey = detail ?? title + ".detail"
        detailArguments = arguments
        self.progress = progress
        self.diagnostic = diagnostic
        self.actions = actions
        self.closeActionIndex = closeActionIndex
        render(activate: activate)
    }

    private func render(activate: Bool = false) {
        guard isPresented, presentsWindows else { return }
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self
            panel.center()
            window = panel
        }
        guard let window else { return }
        // Preparation finishes asynchronously, potentially while another app is
        // active. Activation alone does not keep the restart confirmation above
        // that app's windows. Elevate only the stages waiting for an install choice.
        let awaitsInstallationChoice = titleKey == "update.dialog.ready"
            || (titleKey == "update.dialog.installing" && !actions.isEmpty)
        window.level = awaitsInstallationChoice ? .floating : .normal
        window.title = localization.text("update.dialog.window")
        let content = makeContentView()
        window.contentView = content
        window.setContentSize(content.preferredSize)
        content.layoutSubtreeIfNeeded()
        window.defaultButtonCell = content.actionButtons.last(where: { $0.keyEquivalent == "\r" })?.cell as? NSButtonCell
        if activate { showUpdateInFocus() }
    }

    func makeContentView() -> UpdateDialogContentView {
        let buttons = actions.enumerated().map { index, action in
            let button = NSButton(title: localization.text(action.key), target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            let isCancel = action.key == "common.action.cancel"
            let isPrimary = index == actions.count - 1 && !isCancel
            button.keyEquivalent = isCancel ? "\u{1b}" : isPrimary ? "\r" : ""
            button.bezelColor = isPrimary ? .controlAccentColor : nil
            return button
        }
        let history = NSButton(title: localization.text("update.dialog.history"), target: self, action: #selector(openHistory))
        let style = statusStyle
        return UpdateDialogContentView(title: title, message: detail,
            symbol: style.symbol, tint: style.tint, versions: versionRows,
            progress: progress, progressText: progressText, diagnostic: diagnostic,
            historyButton: history, actions: buttons)
    }

    @objc private func openHistory() {
        NSWorkspace.shared.open(AppLinks.githubRepository.appendingPathComponent("releases"))
    }

    @objc private func clicked(_ sender: NSButton) { performAction(at: sender.tag) }

    func performAction(at index: Int) {
        guard actions.indices.contains(index) else { return }
        let action = actions[index]
        if action.completes { dismissUpdateInstallation() }
        action.handler()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        closeWindow()
        // Keep ownership explicit: a reply may synchronously present the next stage.
        return false
    }

    func closeWindow() {
        guard isPresented else { return }
        if let closeActionIndex {
            performAction(at: closeActionIndex)
        } else {
            // Extraction and installation cannot be cancelled at this stage.
            // Hide their UI while retaining state for Sparkle's focus callback.
            window?.orderOut(nil)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        present("update.dialog.permission", detail: "update.dialog.permission.detail", closeActionIndex: 0, actions: [
            Action(key: "update.dialog.manual_only", completes: true) {
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
            },
            Action(key: "update.dialog.allow_checks", completes: true) {
                reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
            },
        ])
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        installAndRelaunchWhenReady = false
        candidateVersion = nil
        present("update.dialog.checking", progress: -1, closeActionIndex: 0,
                actions: [Action(key: "common.action.cancel", completes: true, handler: cancellation)])
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        showAvailableUpdate(UpdateDialogVersion(version: appcastItem.displayVersionString, commitCount: appcastItem.versionString), reply: reply)
    }

    func showAvailableUpdate(_ version: UpdateDialogVersion, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installAndRelaunchWhenReady = false
        candidateVersion = version
        present("update.dialog.found", detail: "update.dialog.found.detail", closeActionIndex: 0,
                actions: [
            Action(key: "update.dialog.later", completes: true) { reply(.dismiss) },
            Action(key: "update.dialog.skip", completes: true) { reply(.skip) },
            Action(key: "update.dialog.install", completes: false) { [weak self] in
                // The first confirmation explicitly includes restarting. Carry
                // that choice through download and system authorization only.
                guard let self else { return }
                self.installAndRelaunchWhenReady = true
                self.expectedLength = 0
                self.receivedLength = 0
                self.present("update.dialog.downloading", progress: -1, activate: false)
                reply(.install)
            },
        ])
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // An unavailable compatible update is not necessarily the latest installed version.
        if let item = (error as NSError).userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem {
            showNoUpdate(latestVersion: .init(version: item.displayVersionString, commitCount: item.versionString),
                         acknowledgement: acknowledgement)
        } else {
            showNoUpdate(latestVersion: nil, acknowledgement: acknowledgement)
        }
    }

    func showNoUpdate(latestVersion: UpdateDialogVersion?, acknowledgement: @escaping () -> Void) {
        candidateVersion = latestVersion
        let isCurrent = candidateVersion.map {
            $0.commitCount == currentVersion.commitCount &&
                UpdateVersion.normalized($0.version) != nil &&
                UpdateVersion.normalized($0.version) == UpdateVersion.normalized(currentVersion.version)
        } ?? false
        present(isCurrent ? "update.dialog.up_to_date" : "update.dialog.not_found", closeActionIndex: 0,
                actions: [Action(key: "update.dialog.close", completes: true, handler: acknowledgement)])
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        installAndRelaunchWhenReady = false
        let error = error as NSError
        present("update.dialog.error", diagnostic: LocalizedMessage("update.dialog.error_code",
                    arguments: [error.domain, String(error.code)]).text(using: localization), closeActionIndex: 0,
                actions: [Action(key: "update.dialog.close", completes: true, handler: acknowledgement)])
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        present("update.dialog.downloading", progress: -1, closeActionIndex: 0,
                actions: [Action(key: "common.action.cancel", completes: true, handler: cancellation)])
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let sum = receivedLength.addingReportingOverflow(length)
        receivedLength = sum.overflow ? UInt64.max : sum.partialValue
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        progress = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : -1
        refreshProgressView()
    }

    private func refreshProgressView() {
        guard isPresented, presentsWindows else { return }
        if let content = window?.contentView as? UpdateDialogContentView, let progress {
            content.updateProgress(progress, text: progressText)
        } else { render() }
    }

    func showDownloadDidStartExtractingUpdate() { present("update.dialog.extracting", progress: -1, activate: false) }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = min(1, max(0, progress)); refreshProgressView() }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installAndRelaunchWhenReady {
            beginInstallation()
            reply(.install)
            return
        }
        present("update.dialog.ready", closeActionIndex: 1, actions: [
            Action(key: "update.dialog.cancel_install", completes: true) { reply(.skip) },
            Action(key: "update.dialog.install_later", completes: true) { reply(.dismiss) },
            Action(key: "update.dialog.install_restart", completes: false) { [weak self] in
                self?.beginInstallation()
                reply(.install)
            },
        ])
    }

    private func beginInstallation() {
        installAndRelaunchWhenReady = false
        // Retain the progress window across the asynchronous installer handoff.
        present("update.dialog.installing", progress: -1, activate: false)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        present("update.dialog.installing", detail: applicationTerminated
                    ? "update.dialog.installing.detail" : "update.dialog.waiting_for_quit.detail", progress: -1,
                activate: window == nil,
                actions: applicationTerminated ? [] : [Action(key: "update.dialog.retry_quit", completes: false, handler: retryTerminatingApplication)])
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // The relaunched app reports completion with a transient notice in its
        // main window. Do not require another acknowledgement in the old driver.
        dismissUpdateInstallation()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        installAndRelaunchWhenReady = false
        isPresented = false
        actions = []
        closeActionIndex = nil
        window?.orderOut(nil)
        window = nil
    }

    func showUpdateInFocus() {
        guard isPresented, presentsWindows, let window else { return }
        // Match Sparkle's standard driver: plain activate() can fail when a
        // background/menu-bar app needs confirmation after an asynchronous stage.
        activateApplication()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
#if DEBUG
    static func runPreviewIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let stage = environment["REMOTE_BUDDY_UPDATE_UI_PREVIEW"] else { return false }
        let suite = "remote-buddy.update-preview." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { return true }
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults),
            resourceBundle: RemoteBuddyResourceBundle.mainOrDevelopment)
        localization.select(environment["REMOTE_BUDDY_UPDATE_UI_LANGUAGE"] == "en" ? .english : .simplifiedChinese)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let current = UpdateDialogVersion(version: "v26-10-13.111", commitCount: "111")
        let next = UpdateDialogVersion(version: "v26-10-14.112", commitCount: "112")
        let appearance = environment["REMOTE_BUDDY_UPDATE_UI_APPEARANCE"] == "dark" ? "dark" : "light"
        application.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let driver = LocalizedUpdateUserDriver(localization: localization, currentVersion: current)
        let stop = { application.stop(nil) }
        switch stage {
        case "found":
            driver.showAvailableUpdate(next) { _ in stop() }
        case "ready":
            driver.showAvailableUpdate(next) { _ in stop() }
            driver.showReady(toInstallAndRelaunch: { _ in stop() })
        case "current":
            driver.showNoUpdate(latestVersion: current, acknowledgement: stop)
        case "unavailable":
            driver.showNoUpdate(latestVersion: next, acknowledgement: stop)
        case "download":
            driver.showAvailableUpdate(next) { _ in stop() }
            driver.showDownloadInitiated(cancellation: stop)
            driver.showDownloadDidReceiveExpectedContentLength(20_000_000)
            driver.showDownloadDidReceiveData(ofLength: 8_400_000)
        case "extracting":
            driver.showAvailableUpdate(next) { _ in stop() }
            driver.showDownloadDidStartExtractingUpdate()
        case "installing", "waiting_quit":
            driver.showAvailableUpdate(next) { _ in stop() }
            driver.showInstallingUpdate(withApplicationTerminated: stage == "installing",
                                       retryTerminatingApplication: stop)
        case "permission":
            driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { _ in stop() }
        case "error":
            driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), acknowledgement: stop)
        default:
            driver.showUserInitiatedUpdateCheck(cancellation: stop)
        }
        if let output = environment["REMOTE_BUDDY_UPDATE_UI_EXPORT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let view = driver.window?.contentView?.superview else { application.stop(nil); return }
                view.layoutSubtreeIfNeeded()
                driver.window?.displayIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        let directory = URL(fileURLWithPath: output, isDirectory: true)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let language = environment["REMOTE_BUDDY_UPDATE_UI_LANGUAGE"] == "en" ? "en" : "zh"
                        try? data.write(to: directory.appendingPathComponent("\(stage)-\(language)-\(appearance).png"), options: .atomic)
                    }
                }
                application.stop(nil)
            }
            application.run()
            driver.dismissUpdateInstallation()
            return true
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { application.stop(nil) }
        }
        application.run()
        timer.invalidate()
        driver.dismissUpdateInstallation()
        return true
    }
#endif

}
