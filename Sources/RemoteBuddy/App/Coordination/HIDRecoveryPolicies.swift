import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

struct HIDPermissionSnapshot: Equatable {
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    static var current: HIDPermissionSnapshot {
        HIDPermissionSnapshot(
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
    }
}

enum HIDPermissionRecoveryPolicy {
    static func shouldReapplySettings(
        started: Bool,
        customMappingEnabled: Bool,
        voiceKeyMode: VoiceKeyMode = .function,
        voiceFnTapModeEnabled: Bool = false,
        softwareVoiceKeyHeld: Bool = false,
        monitoringInterrupted: Bool = false,
        previous: HIDPermissionSnapshot?,
        current: HIDPermissionSnapshot
    ) -> Bool {
        guard started,
              (
                  customMappingEnabled ||
                      voiceKeyMode.requiresAccessibility ||
                      voiceFnTapModeEnabled ||
                      softwareVoiceKeyHeld || monitoringInterrupted
              ),
              let previous
        else { return false }
        return previous != current || (monitoringInterrupted &&
            current.inputMonitoringGranted && current.accessibilityGranted)
    }
}

enum HIDMappingRecoveryPolicy {
    static let retryDelays: [TimeInterval] = [0.5, 1, 2, 4, 8]

    static func shouldPreserveFnTapPreferenceAfterMappingFailure(
        hasMatchingServices: Bool
    ) -> Bool {
        !hasMatchingServices
    }

    static func retryDelay(
        forAttempt attempt: Int,
        started: Bool,
        readyBridgeCount: Int,
        hasMatchingServices: Bool
    ) -> TimeInterval? {
        guard started,
              readyBridgeCount > 0,
              !hasMatchingServices,
              retryDelays.indices.contains(attempt)
        else { return nil }
        return retryDelays[attempt]
    }
}
