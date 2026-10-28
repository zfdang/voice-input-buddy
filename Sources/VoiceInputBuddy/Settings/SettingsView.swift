import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings

    @ObservedObject var loginItemService: LoginItemService
    @ObservedObject var updateInformation: UpdateInformationStore
    @EnvironmentObject var localization: LocalizationStore

    let checkForUpdates: () -> Void
    let refreshUpdateInformation: () -> Void
    let setDockIconVisible: (Bool) -> Void
    let setStatusBarIconVisible: (Bool) -> Void
    let syncEntryPointVisibility: () -> Void
    let appIconCatalog: AppIconCatalog
    private let minimumContentSize: CGSize
    let initialShortcutPickerShowsKeyboard: Bool
    let permissionOverrides: SystemPermissionOverrides?

    @State var remoteRebindingProfile: RemoteDeviceProfile?
    @State var remoteRemovalProfile: RemoteDeviceProfile?
    @State var isRemoteRemovalPresented = false
    @State var selectedSection: SettingsSection
    @State var selectedRemoteButton: RemoteButton = .ok
    @State private var selectedSiriRemoteControlID = "select"
    @State private var selectedChromecastControlID = "select"
    @State var isMappingSelectionLocked = true
    @State var mappingEditingTarget: ShortcutEditingTarget?
    @State var mappingActionFilter: MappingActionFilter = .all
    @State var shortcutCaptureTarget: ShortcutEditingTarget?
    @State var applicationShortcutCaptureProfileID: UUID?
    @State var shortcutCaptureFeedback: ShortcutCaptureFeedback?
    @State var customApplicationLearningStates: [UUID: CustomApplicationLearningState] = [:]
    @State var bluetoothAuthorization: CBManagerAuthorization
    @State var inputMonitoringGranted: Bool
    @State var accessibilityGranted: Bool
    @State var configurationStatus: ConfigurationStatus?
    @State var isRepositoryLinkCopied = false
    @State var isMappingPermissionAlertPresented = false
    @State var isWaitingForMappingPermissions = false

    init(
        model: BridgeAppModel,
        updateInformation: UpdateInformationStore,
        checkForUpdates: @escaping () -> Void = {},
        refreshUpdateInformation: @escaping () -> Void = {},
        setDockIconVisible: @escaping (Bool) -> Void = { _ in },
        setStatusBarIconVisible: @escaping (Bool) -> Void = { _ in },
        syncEntryPointVisibility: @escaping () -> Void = {},
        appIconCatalog: AppIconCatalog? = nil,
        initialSection: SettingsSection? = nil,
        initialMappingEditingButton: RemoteButton? = nil,
        initialMappingEditingTrigger: ButtonTrigger = .singleClick,
        initialShortcutPickerShowsKeyboard: Bool = false,
        minimumContentSize: CGSize = SettingsWindowLayout.minimumCanvasSize,
        permissionOverrides: SystemPermissionOverrides? = nil
    ) {
        self.model = model
        settings = model.settings

        loginItemService = model.loginItemService
        self.updateInformation = updateInformation
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.setStatusBarIconVisible = setStatusBarIconVisible
        self.syncEntryPointVisibility = syncEntryPointVisibility
        self.appIconCatalog = appIconCatalog ?? .live()
        self.minimumContentSize = minimumContentSize
        self.initialShortcutPickerShowsKeyboard = initialShortcutPickerShowsKeyboard
        self.permissionOverrides = permissionOverrides
        _selectedSection = State(initialValue: SettingsPageBehavior.initialSection(
            requestedSection: initialSection
        ))
        _selectedRemoteButton = State(initialValue: initialMappingEditingButton ?? .ok)
        _mappingEditingTarget = State(
            initialValue: initialMappingEditingButton.map {
                ShortcutEditingTarget(button: $0, trigger: initialMappingEditingTrigger)
            }
        )
        _bluetoothAuthorization = State(initialValue: permissionOverrides?.bluetooth ?? CBManager.authorization)
        _inputMonitoringGranted = State(initialValue: permissionOverrides?.inputMonitoring ?? HIDRemoteMonitor.isInputMonitoringGranted)
        _accessibilityGranted = State(initialValue: permissionOverrides?.accessibility ?? KeyboardInjector.isAccessibilityTrusted)
    }

    var body: some View {
        AdaptiveSettingsViewport(minimumSize: minimumContentSize) {
            settingsContent
        }
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsPageBehavior.sidebarWidth)
            Color(nsColor: .separatorColor)
                .frame(width: SettingsPageBehavior.sidebarDividerWidth)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            selectedPage
        }
        .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea())
        .environment(\.locale, localization.locale)
        .onAppear {
            if selectedSection == .mapping {
                model.selectDefaultMappingRemoteIfAvailable()
            }
            model.refreshRemoteDeviceNames(reason: .page)
            refreshPermissionStates()
            loginItemService.refresh()

        }
        .onChange(of: selectedSection) { _, section in
            if section == .mapping {
                model.selectDefaultMappingRemoteIfAvailable()
            }
            if section == .connection || section == .mapping {
                model.refreshRemoteDeviceNames(reason: .page)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStates()
            loginItemService.refresh()
            resumeCustomMappingIfPermissionsGranted()

        }
        .alert(
            localization.text("button_mapping.permission_prompt.title"),
            isPresented: $isMappingPermissionAlertPresented
        ) {
            Button(localization.text("button_mapping.permission_prompt.open")) {
                isWaitingForMappingPermissions = true
                selectedSection = .permissions
                model.applyHIDSettings()
            }
            Button(localization.text("common.action.cancel"), role: .cancel) {
                settings.customMappingEnabled = false
                model.applyHIDSettings()
            }
        } message: {
            Text(localization.text("button_mapping.permission_prompt.message"))
        }
    }
}
