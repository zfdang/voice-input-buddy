import Combine
import Foundation

/// What an import refused to adopt. An exported configuration file is the app's only trust
/// boundary: it travels between Macs through downloads and chat, and it carries application
/// paths, bundle identifiers and keyboard shortcuts that a remote button later launches or
/// synthesizes. Entries that cannot be trusted are dropped instead of installed, and this
/// report is what turns a silent drop into something the user is told about.
struct ConfigurationImportReport: Equatable {
    /// Storage keys of the settings that lost at least one entry.
    var rejectedEntryStorageKeys: [String] = []
    /// Custom applications that are structurally fine but absent from this Mac. They are kept
    /// so a configuration exported from a better-equipped Mac survives the trip.
    var applicationsMissingOnThisMac: [String] = []

    var isClean: Bool {
        rejectedEntryStorageKeys.isEmpty && applicationsMissingOnThisMac.isEmpty
    }
}

enum AppConfigurationError: Error {
    case unsupportedVersion
    case fileTooLarge
    case invalidValues
    case unsafeVoiceKeyChange
}

struct VoiceKeyConfigurationState: Equatable {
    let mode: VoiceKeyMode
    let fnTapModeEnabled: Bool
    let tool: OnboardingVoiceTool
}

struct OnboardingVoiceConfigurationSnapshot: Codable {
    let voiceKeyMode: VoiceKeyMode
    let voiceFnTapModeEnabled: Bool
    let chromecastVoiceMode: ChromecastVoiceMode
}

struct PersonalizedConfiguration: Codable {
    static let currentFormatVersion = 2

    let formatVersion: Int
    let gainDB: Double
    var remoteGainDB: [UUID: Double]? = nil
    let customMappingEnabled: Bool
    let buttonBindings: [String: ButtonAction]
    let buttonShortcuts: [String: CustomKeyboardShortcut]
    let unifiedBaseBindings: [UnifiedButtonBinding]?
    let selectedMappingProfileID: UUID?
    let buttonApplicationProfileIDs: [String: UUID]?
    let secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    let buttonRapidPressEnabled: [String: Bool]?
    let customApplicationProfiles: [CustomApplicationProfile]?
    let applicationLanguage: AppLanguage
    let appIconIdentifier: AppIconIdentifier?
    let showDockIcon: Bool
    let showStatusBarIcon: Bool?
    let openMainWindowAtLaunch: Bool?
    let checksForPreReleaseUpdates: Bool?
    let experimentalContinuousRecordingEnabled: Bool?
    var voiceTool: OnboardingVoiceTool? = nil
    let voiceFnTapModeEnabled: Bool?
    let voiceKeyMode: VoiceKeyMode?
    let continuousRecordingPowerBindingBackup: ConfiguredButtonAction?
}

/// Reads at most the limit plus one byte, including growing files and streams.
enum ConfigurationFileReader {
    static let maximumBytes = 2 * 1024 * 1024

    static func read(from url: URL, maximumBytes: Int = maximumBytes) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw AppConfigurationError.fileTooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try file.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw AppConfigurationError.fileTooLarge
    }
}
