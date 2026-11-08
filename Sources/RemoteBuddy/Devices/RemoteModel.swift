import Foundation

enum RemoteModel: String, Codable, CaseIterable, Identifiable {
    case rc001
    case rc003
    case appleSiriRemoteA2854 = "apple_siri_remote_a2854"
    case appleSiriRemoteA2540 = "apple_siri_remote_a2540"
    /// Google Chromecast Voice Remote G9N9N, handled by the public ATVV/HID adapters.
    case chromecastVoiceRemote = "chromecast_voice_remote"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let model = Self(rawValue: value) {
            self = model
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported remote model"
            )
        }
    }

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .rc001: return "remote.device.model.rc001"
        case .rc003: return "remote.device.model.rc003"
        case .appleSiriRemoteA2854:
            return "remote.device.model.unknown"
        case .appleSiriRemoteA2540:
            return "remote.device.model.unknown"
        case .chromecastVoiceRemote:
            return "remote.catalog.chromecastG9N9N.title"
        case .unknown: return "remote.device.model.unknown"
        }
    }

    var stableHardwareModelID: String? {
        switch self {
        case .rc001: "xiaomi-remote-rc001"
        case .rc003: "xiaomi-remote-2-pro"
        case .appleSiriRemoteA2854: "apple-siri-remote-a2854"
        case .appleSiriRemoteA2540: "apple-siri-remote-a2540"
        case .chromecastVoiceRemote: "chromecast-voice-remote"
        case .unknown: nil
        }
    }

    var isAppleSiriRemote: Bool {
        self == .appleSiriRemoteA2854 || self == .appleSiriRemoteA2540
    }

    /// Google layout and Consumer Control report family.
    var isChromecastRemote: Bool {
        self == .chromecastVoiceRemote
    }

    /// Siri uses a separate adapter; public ATVV remotes share the native pipeline.
    var usesPrivateAdapter: Bool {
        isAppleSiriRemote
    }

    /// 按 DIS 型号串识别型号。规则集中在 `XiaomiRemoteCatalog`——这里不再单独写名单。
    static func identified(by modelNumber: String) -> RemoteModel? {
        XiaomiRemoteCatalog.entry(matchingDISModelNumber: modelNumber)?.model
    }
}
