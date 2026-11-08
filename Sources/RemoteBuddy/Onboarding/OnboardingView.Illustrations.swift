import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var rightPane: some View {
        ZStack {
            LinearGradient(
                colors: rightPaneGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(rightPaneHighlightColor)
                .frame(width: 360, height: 360)
                .blur(radius: 10)
                .offset(x: 110, y: -110)

            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if settings.onboardingStep == .voiceTool,
                           settings.onboardingVoiceTool != .unselected {
                            inputMethodGuide(for: settings.onboardingVoiceTool)
                                .frame(maxWidth: 440)
                                .padding(.horizontal, 28)
                        } else if settings.onboardingStep == .voiceTool {
                            welcomeIllustration
                        } else if settings.onboardingStep == .remoteAvailability {
                            selectedDeviceIllustration
                        } else if settings.onboardingStep == .complete {
                            completeIllustration
                        } else {
                            selectedControlIllustration
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .padding(.bottom, centerRightPaneContent ? 12 : 16)
                    .frame(
                        minHeight: centerRightPaneContent ? geometry.size.height : 0,
                        alignment: centerRightPaneContent ? .center : .top
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var centerRightPaneContent: Bool {
        [.remoteAvailability, .voiceTest, .complete].contains(settings.onboardingStep)
    }

    private var welcomeIllustration: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 118, height: 118)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            Image(systemName: "waveform")
                .font(.system(size: 72, weight: .medium))
                .foregroundStyle(Color.accentColor)
                Text(verbatim: localization.text("onboarding.illustration.tagline"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var selectedDeviceIllustration: some View {
        VStack(spacing: 16) {
            if let device = settings.onboardingDevice,
               let image = bundledRemoteImage(resourceName: device.illustrationResource) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 480)
                    .accessibilityLabel(localization.text("remote.catalog.illustration"))
                if !device.canStartSetup {
                    Text(localization.text("remote.catalog.unsupported_notice"))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("remote.unsupported-notice")
                }
            } else {
                remoteAvailabilityIllustration
            }
        }
        .padding(.horizontal, 28)
    }

    private var remoteIllustration: some View {
        VStack(spacing: 16) {
            if settings.onboardingStep != .voiceTest {
                onboardingRemotePhoto
            }
            sideStatusPanel
        }
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var onboardingRemotePhoto: some View {
        switch OnboardingRemotePhotoKind.resolve(
            source: settings.onboardingControlSource,
            selectedModel: settings.selectedRemoteProfile?.model,
            selectedDevice: settings.onboardingDevice
        ) {
        case let .bundled(resourceName):
            if let image = bundledRemoteImage(resourceName: resourceName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 480)
                    .shadow(color: .black.opacity(0.20), radius: 16, y: 10)
            } else {
                remotePhotoPlaceholder
            }
        case .siriRemote:
            remotePhotoPlaceholder
        case .chromecastRemote:
            remotePhotoPlaceholder
        case .placeholder:
            remotePhotoPlaceholder
        }
    }

    private var remotePhotoPlaceholder: some View {
        Image(systemName: "appletvremote.gen4.fill")
            .font(.system(size: 180))
            .foregroundStyle(.secondary)
    }

    private var controlMethodIllustration: some View {
        VStack(spacing: 26) {
            HStack(spacing: 38) {
                Image(systemName: "iphone")
                Image(systemName: "safari.fill")
            }
            .font(.system(size: 58, weight: .medium))
            .foregroundStyle(Color.accentColor)
                Text(verbatim: localization.text("onboarding.control_method.illustration"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var remoteAvailabilityIllustration: some View {
        VStack(spacing: 24) {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 150, weight: .medium))
                .foregroundStyle(Color.accentColor)
                Text(verbatim: localization.text("onboarding.remote_availability.illustration"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedControlIllustration: some View {
        switch settings.onboardingControlMethod {
        case .physicalRemote, .unselected:
            remoteIllustration
        }
    }

    @ViewBuilder
    private var completeIllustration: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 170, height: 170)
                Image(systemName: "checkmark")
                    .font(.system(size: 74, weight: .bold))
                    .foregroundStyle(Color.green)
            }
                Text(verbatim: localization.text("onboarding.complete.illustration"))
                .font(.system(size: 18, weight: .semibold))
        }
    }
}
