import Foundation
import CoreBluetooth

/// Public G9N9N transport facts. Names and USB IDs identify candidates, not authenticity.
/// References: ATVVoice (ATVV v1.0), vibe-mote (Consumer Control reports).
enum G9N9NProtocol {
    static let vendorID = 0x18D1
    static let productID = 0x9450

    static func isCandidateName(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return ["chromecast", "chromecast remote", "chromecast voice remote", "chromecast 遥控器", "g9n9n"].contains(name)
    }

    static let consumerButtons: [UInt16: RemoteButton] = [
        0x0042: .up, 0x0043: .down, 0x0044: .left, 0x0045: .right,
        0x0041: .ok, 0x0224: .back, 0x0223: .home,
        0x00E9: .volumeUp, 0x00EA: .volumeDown, 0x00E2: .mute,
        0x0077: .youtube, 0x0078: .netflix,
        // Captured G9N9N Consumer Control reports: vibe-mote/keys.py.
        0x0189: .input, 0x019E: .power,
        0x0089: .input,
    ]

    // Captured from the A3 / firmware 26.0 reference unit. Report 1 contains
    // two 8-bit indices into the descriptor's usage list, not 16-bit usages.
    static let indexedConsumerDescriptor = Data([
        0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x01,
        0x0a, 0x9e, 0x01, 0x09, 0xcd, 0x09, 0x42, 0x09, 0x43,
        0x09, 0x44, 0x09, 0x45, 0x09, 0x41, 0x09, 0xe2,
        0x0a, 0x21, 0x02, 0x0a, 0x23, 0x02, 0x0a, 0x24, 0x02,
        0x09, 0xe9, 0x09, 0xea, 0x09, 0x77, 0x09, 0x78,
        0x09, 0x79, 0x09, 0x89, 0x15, 0x01, 0x25, 0x11,
        0x95, 0x02, 0x75, 0x08, 0x81, 0x00, 0xc0,
    ])
    private static let indexedConsumerUsages: [UInt16] = [
        0x019e, 0x00cd, 0x0042, 0x0043, 0x0044, 0x0045,
        0x0041, 0x00e2, 0x0221, 0x0223, 0x0224, 0x00e9,
        0x00ea, 0x0077, 0x0078, 0x0079, 0x0089,
    ]

    // Compatible units (firmware 0x0110) append a vendor collection with other
    // report IDs after this complete report 1 collection. Report 1 is unchanged.
    static func usesIndexedConsumerLayout(_ descriptor: Data?) -> Bool {
        descriptor?.starts(with: indexedConsumerDescriptor) ?? false
    }

    static func isEnterChord(_ usages: Set<UInt16>) -> Bool {
        guard usages.count == 2, usages.contains(RemoteButton.ok.hidUsage) else { return false }
        return [RemoteButton.up, .down, .left, .right].contains { usages.contains($0.hidUsage) }
    }

    /// Known Consumer Control layouts, with or without their report-ID byte.
    /// Malformed or unrelated reports are ignored; unknown usages in a valid
    /// Consumer Control snapshot do not discard known key edges.
    static func usages(reportID: UInt32, data: Data, descriptor: Data? = nil) -> Set<UInt16>? {
        if usesIndexedConsumerLayout(descriptor) {
            guard reportID == 1 else { return nil }
            var bytes = Array(data)
            if bytes.count == 3, bytes.first == 1 { bytes.removeFirst() }
            guard bytes.count == 2,
                  bytes.allSatisfy({ Int($0) <= indexedConsumerUsages.count }) else { return nil }
            return Set(bytes.compactMap { index -> UInt16? in
                guard index != 0,
                      let button = consumerButtons[indexedConsumerUsages[Int(index) - 1]] else { return nil }
                return button.hidUsage
            })
        }
        guard reportID == 2 else { return nil }
        var bytes = Array(data)
        if bytes.count % 2 == 1, bytes.first == 2 { bytes.removeFirst() }
        guard !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
        var usages = Set<UInt16>()
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            if usage == 0 { continue }
            guard let button = consumerButtons[usage] else { continue }
            usages.insert(button.hidUsage)
        }
        return usages
    }

    static func requiresPairing(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == CBATTErrorDomain && [
            CBATTError.insufficientAuthentication.rawValue,
            CBATTError.insufficientEncryption.rawValue,
        ].contains(value.code)
    }

    static func acceptsCapabilities(_ caps: ATVVCapabilities) -> Bool {
        caps.version == 0x0100 && caps.codecs & 0x02 != 0 &&
            caps.selectedCodec == 0x02 && ATVVProtocol.supportsFrameSize(caps.frameSize)
    }
}

/// Both asynchronous discovery results are mandatory; neither alone grants audio readiness.
struct G9N9NReadiness {
    private(set) var identityConfirmed = false
    private(set) var audioConfirmed = false
    var isReady: Bool { identityConfirmed && audioConfirmed }

    // Retail model and DIS model strings differ (the tested G9N9N reports A3).
    // Validate the same peripheral's PnP identity, never gate on its model string.
    @discardableResult mutating func acceptIdentity(_ identity: RemoteHIDIdentity?) -> Bool {
        identityConfirmed = identity == .chromecast
        return identityConfirmed
    }

    @discardableResult mutating func acceptCapabilities(_ caps: ATVVCapabilities) -> Bool {
        audioConfirmed = G9N9NProtocol.acceptsCapabilities(caps)
        return audioConfirmed
    }
}
