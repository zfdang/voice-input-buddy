import Foundation

/// Protocol, identity, and HID report definitions for the T1-Remote (ATVV v1.0 + multi-report BLE HID air-mouse/keyboard remote).
enum T1RemoteProtocol {
    static let vendorID: UInt16 = 0x620A
    static let productID: UInt16 = 0x0407
    static let voiceHoldUsage: UInt16 = 0x00AA
    static let voiceSearchConsumerUsage: UInt16 = 0x0221
    static let systemPowerDownUsage: UInt16 = 0x0081

    static let keyboardReportID: UInt32 = 1
    static let consumerReportID: UInt32 = 2
    static let systemControlReportID: UInt32 = 3
    static let mouseReportID: UInt32 = 4
    static let vendorReportID: UInt32 = 0x5A

    private static let mappedKeyboardUsages: Set<UInt8> = [
        0x28, // OK / Enter
        0x4F, // Right
        0x50, // Left
        0x51, // Down
        0x52, // Up
        0x65, // Menu
    ]

    private static let candidateNames: Set<String> = [
        "t1-remote",
        "t1 remote",
        "t1_remote",
    ]

    static func isCandidateName(_ name: String?) -> Bool {
        guard let normalized = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased(),
              !normalized.isEmpty
        else { return false }
        return candidateNames.contains(normalized)
    }

    enum HIDReportResult: Equatable {
        case usages(Set<UInt16>, voiceHoldPressed: Bool)
        case ignore
        case invalid
    }

    /// Decodes a single T1-Remote HID input report without requiring exclusive HID seizure.
    ///
    /// Reports 4 (air mouse) and `0x5A` (vendor) return `.ignore` so air-mouse cursor motion never
    /// logs parse errors or drops currently held buttons.
    static func decodeHIDReport(reportID: UInt32, data: Data) -> HIDReportResult {
        switch reportID {
        case keyboardReportID:
            guard let payload = stripLeadingReportID(UInt8(keyboardReportID), expectedLength: 8, data: data),
                  payload.count >= 8
            else { return .invalid }
            let modifier = payload[0]
            var usages: Set<UInt16> = []
            var voiceHoldPressed = false
            for byte in payload[2..<8] where byte != 0 {
                if byte == UInt8(voiceHoldUsage) {
                    voiceHoldPressed = true
                } else if modifier == 0, mappedKeyboardUsages.contains(byte) {
                    usages.insert(UInt16(byte))
                }
            }
            return .usages(usages, voiceHoldPressed: voiceHoldPressed)

        case consumerReportID:
            guard let payload = stripLeadingReportID(UInt8(consumerReportID), expectedLength: 2, data: data),
                  payload.count >= 2
            else { return .invalid }
            let usage = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
            switch usage {
            case 0x0224:
                return .usages([RemoteButton.back.hidUsage], voiceHoldPressed: false)
            case 0x0223:
                return .usages([RemoteButton.home.hidUsage], voiceHoldPressed: false)
            case 0x00E2:
                return .usages([RemoteButton.mute.hidUsage], voiceHoldPressed: false)
            case 0x00E9:
                return .usages([RemoteButton.volumeUp.hidUsage], voiceHoldPressed: false)
            case 0x00EA:
                return .usages([RemoteButton.volumeDown.hidUsage], voiceHoldPressed: false)
            default:
                // Includes `0x0000` release, `0x0221` (AC Search handled by ATVV + UserKeyMapping),
                // and unmapped back-keyboard multimedia keys.
                return .usages([], voiceHoldPressed: false)
            }

        case systemControlReportID:
            guard let payload = stripLeadingReportID(UInt8(systemControlReportID), expectedLength: 1, data: data),
                  payload.count >= 1
            else { return .invalid }
            let usages: Set<UInt16> = (payload[0] & 0x01) != 0 ? [RemoteButton.power.hidUsage] : []
            return .usages(usages, voiceHoldPressed: false)

        case mouseReportID, vendorReportID:
            return .ignore

        default:
            return .invalid
        }
    }

    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        switch decodeHIDReport(reportID: reportID, data: data) {
        case let .usages(usages, _):
            return usages
        case .ignore, .invalid:
            return nil
        }
    }

    private static func stripLeadingReportID(
        _ expectedID: UInt8,
        expectedLength: Int,
        data: Data
    ) -> [UInt8]? {
        if data.count == expectedLength + 1, data.first == expectedID {
            return Array(data.dropFirst())
        }
        if data.count >= expectedLength {
            return Array(data)
        }
        return nil
    }
}

/// Validates that a connected T1-Remote peripheral completed both ATVV audio capability
/// negotiation (16 kHz IMA-ADPCM) and compatible PnP identity admission.
struct T1RemoteReadiness {
    private var capabilitiesAccepted = false
    private var matchedIdentity = false

    mutating func acceptCapabilities(_ capabilities: ATVVCapabilities) -> Bool {
        guard capabilities.codecs & 0x02 != 0 else { return false }
        capabilitiesAccepted = true
        return true
    }

    mutating func acceptIdentity(
        _ identity: RemoteHIDIdentity,
        allowCustomIdentity: Bool = false
    ) -> Bool {
        let accepted = identity == .t1Remote ||
            (allowCustomIdentity && identity.vendorID != 0 && identity != .xiaomi && identity != .chromecast)
        guard accepted else { return false }
        matchedIdentity = true
        return true
    }

    var isReady: Bool { capabilitiesAccepted && matchedIdentity }
}
