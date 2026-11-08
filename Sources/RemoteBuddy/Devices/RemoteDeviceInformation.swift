import Foundation

/// Information read during the current BLE connection, never inferred from a catalog.
struct RemoteDeviceInformation: Equatable {
    var modelNumber: String?
    var firmwareRevision: String?
    var identity: RemoteHIDIdentity?
    var capabilities: ATVVCapabilities?

    static func deviceString(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    var identityValue: String? {
        identity.map { String(format: "%04X / %04X", $0.vendorID, $0.productID) }
    }

    var protocolVersion: String? {
        capabilities.map { "ATVV \($0.version >> 8).\($0.version & 0xFF)" }
    }

    var audioFormat: String? {
        guard let capabilities else { return nil }
        let codec = [UInt8(1), 2].contains(capabilities.selectedCodec)
            ? "IMA ADPCM" : String(format: "Codec 0x%02X", capabilities.selectedCodec)
        let rate = String(format: "%g", capabilities.sampleRate / 1_000)
        return "\(rate) kHz · \(codec)"
    }
}
