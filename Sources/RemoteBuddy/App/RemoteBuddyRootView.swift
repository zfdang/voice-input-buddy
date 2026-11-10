import SwiftUI

struct RemoteBuddyRootView: View {
    let model: BridgeAppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var updateInformation: UpdateInformationStore
    let checkForUpdates: () -> Void
    let refreshUpdateInformation: () -> Void
    let setDockIconVisible: (Bool) -> Void
    let setStatusBarIconVisible: (Bool) -> Void
    private let initialSettingsSection: SettingsSection?
    private let completedUpdateVersion: String?

    init(
        model: BridgeAppModel,
        updateInformation: UpdateInformationStore,
        checkForUpdates: @escaping () -> Void,
        refreshUpdateInformation: @escaping () -> Void,
        setDockIconVisible: @escaping (Bool) -> Void,
        setStatusBarIconVisible: @escaping (Bool) -> Void,
        initialSettingsSection: SettingsSection? = nil,
        completedUpdateVersion: String? = nil
    ) {
        self.model = model
        settings = model.settings
        self.updateInformation = updateInformation
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.setStatusBarIconVisible = setStatusBarIconVisible
        self.initialSettingsSection = initialSettingsSection
        self.completedUpdateVersion = completedUpdateVersion
    }

    var body: some View {
        Group {
            if settings.isOnboardingComplete {
                SettingsView(
                    model: model,
                    updateInformation: updateInformation,
                    checkForUpdates: checkForUpdates,
                    refreshUpdateInformation: refreshUpdateInformation,
                    setDockIconVisible: setDockIconVisible,
                    setStatusBarIconVisible: setStatusBarIconVisible,
                    initialSection: initialSettingsSection
                )
            } else {
                OnboardingView(model: model)
            }
        }
        .modifier(UpdateCompletionToast(
            version: completedUpdateVersion,
            contentLeadingInset: settings.isOnboardingComplete ? SettingsPageBehavior.contentLeadingInset : 0
        ))
        .onAppear {
            startRuntimeIfRequired(for: settings.onboardingStep)
        }
        .onReceive(settings.$onboardingStep) { step in
            startRuntimeIfRequired(for: step)
        }
    }

    private func startRuntimeIfRequired(for step: OnboardingStep) {
        guard OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: settings.isOnboardingComplete,
            step: step
        ) else { return }
        model.startIfNeeded()
    }
}
