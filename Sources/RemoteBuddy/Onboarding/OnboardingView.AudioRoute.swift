import SwiftUI

extension OnboardingView {
    var audioContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingTitle("onboarding.audio.title")
            Text(verbatim: localization.text("onboarding.audio.detail"))
                .foregroundStyle(.secondary)
            statusCard(icon: "mic.fill", title: localization.text("settings.driver.title"),
                detail: localization.text(microphoneDriverInstalled ? "settings.driver.installed" : "settings.driver.missing"),
                isComplete: microphoneDriverInstalled)
            statusCard(icon: "waveform", title: BuddyMicrophoneDevicePolicy.deviceName,
                detail: localization.text(onboardingAudioReady ? "onboarding.audio.automatic_ready" : "onboarding.audio.checking"),
                isComplete: onboardingAudioReady)
            if !microphoneDriverInstalled || !model.isAudioOutputVerified {
                Text(localization.text("settings.driver.reload_help")).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(localization.text("audio.action.refresh_devices")) { prepareAutomaticDriverCheck() }
                    Button(localization.text("audio.compatibility.open_install_guide")) { model.openVirtualMicrophoneSetupInstructions(using: localization) }
                }.buttonStyle(.bordered)
            }
        }
        .onAppear { prepareAutomaticDriverCheck() }
        .onChange(of: model.audioDevices) { _, _ in prepareAutomaticDriverCheck() }
    }

    private func prepareAutomaticDriverCheck() {
        guard interactionProbe == nil else { return }
        model.refreshAudioDevices()
        model.configureVirtualAudioOutput(reason: "onboarding_driver_check")
    }
}
