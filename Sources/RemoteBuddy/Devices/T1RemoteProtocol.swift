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

    // Keep Enter (0x28) and arrows (0x4F..0x52) native so the shared Report 1
    // channel never intercepts rear QWERTY Enter/arrow keys when buttons are mapped.
    private static let mappedKeyboardUsages: Set<UInt8> = [
        0x65, // Menu
    ]

    // Unmodified Enter (0x28) and arrows (0x4F..0x52) are still observed read-only for
    // onboarding validation and button-test highlighting without entering button mapping.
    private static let passthroughObservedKeyboardUsages: Set<UInt8> = [
        0x28, // OK / Enter
        0x4F, // Right
        0x50, // Left
        0x51, // Down
        0x52, // Up
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

    struct MonitorHIDDecodeResult: Equatable {
        let result: HIDReportResult
        let observedPassthroughUsages: Set<UInt16>
    }

    /// Decodes a single T1-Remote HID input report without requiring exclusive HID seizure.
    ///
    /// Reports 4 (air mouse) and `0x5A` (vendor) return `.ignore` so air-mouse cursor motion never
    /// logs parse errors or drops currently held buttons.
    static func decodeHIDReport(reportID: UInt32, data: Data) -> HIDReportResult {
        decodeHIDReportForMonitor(reportID: reportID, data: data).result
    }

    /// Decodes both mappable button usages and read-only observed passthrough usages (unmodified
    /// front-panel OK/arrow keys) for HID monitoring and onboarding feedback.
    static func decodeHIDReportForMonitor(reportID: UInt32, data: Data) -> MonitorHIDDecodeResult {
        switch reportID {
        case keyboardReportID:
            guard let payload = stripLeadingReportID(UInt8(keyboardReportID), expectedLength: 8, data: data),
                  payload.count >= 8
            else {
                return MonitorHIDDecodeResult(result: .invalid, observedPassthroughUsages: [])
            }
            let modifier = payload[0]
            var usages: Set<UInt16> = []
            var passthroughUsages: Set<UInt16> = []
            var voiceHoldPressed = false
            for byte in payload[2..<8] where byte != 0 {
                if byte == UInt8(voiceHoldUsage) {
                    voiceHoldPressed = true
                } else if mappedKeyboardUsages.contains(byte) {
                    // Keep mapped front-panel buttons (Menu 0x65) active even when rear QWERTY
                    // modifiers change mid-hold so modifier chords cannot drop an active hold.
                    usages.insert(UInt16(byte))
                } else if modifier == 0, passthroughObservedKeyboardUsages.contains(byte) {
                    passthroughUsages.insert(UInt16(byte))
                }
            }
            return MonitorHIDDecodeResult(
                result: .usages(usages, voiceHoldPressed: voiceHoldPressed),
                observedPassthroughUsages: passthroughUsages
            )

        case consumerReportID:
            guard let payload = stripLeadingReportID(UInt8(consumerReportID), expectedLength: 2, data: data),
                  payload.count >= 2
            else {
                return MonitorHIDDecodeResult(result: .invalid, observedPassthroughUsages: [])
            }
            let usage = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
            switch usage {
            case 0x0000:
                return MonitorHIDDecodeResult(
                    result: .usages([], voiceHoldPressed: false),
                    observedPassthroughUsages: []
                )
            case 0x0224:
                return MonitorHIDDecodeResult(
                    result: .usages([RemoteButton.back.hidUsage], voiceHoldPressed: false),
                    observedPassthroughUsages: []
                )
            case 0x0223:
                return MonitorHIDDecodeResult(
                    result: .usages([RemoteButton.home.hidUsage], voiceHoldPressed: false),
                    observedPassthroughUsages: []
                )
            case 0x00E2:
                return MonitorHIDDecodeResult(
                    result: .usages([RemoteButton.mute.hidUsage], voiceHoldPressed: false),
                    observedPassthroughUsages: []
                )
            case 0x00E9:
                return MonitorHIDDecodeResult(
                    result: .usages([RemoteButton.volumeUp.hidUsage], voiceHoldPressed: false),
                    observedPassthroughUsages: []
                )
            case 0x00EA:
                return MonitorHIDDecodeResult(
                    result: .usages([RemoteButton.volumeDown.hidUsage], voiceHoldPressed: false),
                    observedPassthroughUsages: []
                )
            default:
                // Non-release unmapped consumer usages (such as 0x0221 AC Search or back-keyboard
                // media keys) must not wipe currently held Report 2 buttons when interleaved.
                return MonitorHIDDecodeResult(result: .ignore, observedPassthroughUsages: [])
            }

        case systemControlReportID:
            guard let payload = stripLeadingReportID(UInt8(systemControlReportID), expectedLength: 1, data: data),
                  payload.count >= 1
            else {
                return MonitorHIDDecodeResult(result: .invalid, observedPassthroughUsages: [])
            }
            let usages: Set<UInt16> = (payload[0] & 0x01) != 0 ? [RemoteButton.power.hidUsage] : []
            return MonitorHIDDecodeResult(
                result: .usages(usages, voiceHoldPressed: false),
                observedPassthroughUsages: []
            )

        case mouseReportID, vendorReportID:
            return MonitorHIDDecodeResult(result: .ignore, observedPassthroughUsages: [])

        default:
            return MonitorHIDDecodeResult(result: .invalid, observedPassthroughUsages: [])
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
        if data.count >= expectedLength + 1, data.first == expectedID {
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

    var identityConfirmed: Bool { matchedIdentity }

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
            (allowCustomIdentity &&
                identity.vendorID != 0 &&
                !Self.foreignVendorIDs.contains(identity.vendorID))
        guard accepted else { return false }
        matchedIdentity = true
        return true
    }

    static func shouldAllowCustomIdentity(
        adoptUnidentifiedATVVAsT1: Bool,
        isTargetedPeripheral: Bool,
        savedModelIsT1Remote: Bool,
        savedCustomIdentity: RemoteHIDIdentity?,
        reportedIdentity: RemoteHIDIdentity
    ) -> Bool {
        if adoptUnidentifiedATVVAsT1 { return true }
        guard isTargetedPeripheral, savedModelIsT1Remote else { return false }
        return savedCustomIdentity == nil || savedCustomIdentity == reportedIdentity
    }

    private static let foreignVendorIDs: Set<UInt16> = [
        RemoteHIDIdentity.xiaomi.vendorID,
        RemoteHIDIdentity.chromecast.vendorID,
        0x05AC,
        0x004C,
    ]

    var isReady: Bool { capabilitiesAccepted && matchedIdentity }
}

/// Tracks currently held HID usages separately per T1 report ID so reports from
/// different interfaces (keyboard, consumer, system) do not clear each other's buttons.
struct T1ReportUsageState {
    private var usagesByReportID: [UInt32: Set<UInt16>] = [:]

    mutating func update(reportID: UInt32, usages: Set<UInt16>) -> Set<UInt16> {
        if usages.isEmpty {
            usagesByReportID.removeValue(forKey: reportID)
        } else {
            usagesByReportID[reportID] = usages
        }
        return usagesByReportID.values.reduce(into: Set<UInt16>()) { combined, reportUsages in
            combined.formUnion(reportUsages)
        }
    }

    mutating func remove(_ usage: UInt16) {
        for (reportID, var usages) in usagesByReportID where usages.remove(usage) != nil {
            if usages.isEmpty {
                usagesByReportID.removeValue(forKey: reportID)
            } else {
                usagesByReportID[reportID] = usages
            }
        }
    }

    mutating func reset() {
        usagesByReportID.removeAll()
    }
}
