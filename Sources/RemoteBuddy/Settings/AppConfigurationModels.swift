import Combine
import Foundation

enum AppConfigurationError: Error {
    case fileTooLarge
}

struct OnboardingVoiceConfigurationSnapshot: Codable {
    let voiceKeyMode: VoiceKeyMode
    let voiceFnTapModeEnabled: Bool
    let chromecastVoiceMode: ChromecastVoiceMode
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
