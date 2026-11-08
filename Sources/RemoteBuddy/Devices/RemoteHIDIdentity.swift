import Foundation
import IOKit.hid

struct RemoteHIDIdentity: Codable, Hashable {
    let vendorID: UInt16
    let productID: UInt16

    static let xiaomi = Self(vendorID: 0x2717, productID: 0x32B8)
    static let chromecast = Self(vendorID: 0x18D1, productID: 0x9450)
    var isStandard: Bool { self == .xiaomi || self == .chromecast }
    var matchingDictionary: [String: Any] {
        [kIOHIDVendorIDKey: Int(vendorID), kIOHIDProductIDKey: Int(productID)]
    }

    // Bluetooth DIS PnP ID: namespace byte, then little-endian VID/PID/version.
    // It is only a hint until matched to actual Bluetooth HID metadata.
    static func fromPnP(_ data: Data) -> Self? {
        let bytes = Array(data)
        guard bytes.count == 7, bytes[0] == 1 || bytes[0] == 2 else { return nil }
        let vendor = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        guard vendor != 0 else { return nil }
        return Self(vendorID: vendor, productID: UInt16(bytes[3]) | UInt16(bytes[4]) << 8)
    }

    static func read(from device: IOHIDDevice) -> Self? {
        guard let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
              (1...65535).contains(vendor.intValue), (0...65535).contains(product.intValue)
        else { return nil }
        return Self(vendorID: UInt16(vendor.intValue), productID: UInt16(product.intValue))
    }
}

struct RemoteHIDBinding: Codable, Equatable {
    let identity: RemoteHIDIdentity
    let fingerprint: String
}

struct RemoteHIDCandidate: Identifiable, Equatable {
    let binding: RemoteHIDBinding
    let name: String
    var id: String { binding.fingerprint }

    // Read-only enumeration. Selection never requires opening every device.
    static func available() -> [Self] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let pairedNames = RemoteDeviceNameReader.readHIDNames()
        let candidates = devices.compactMap { device -> Self? in
            let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
            guard page == 0x0C || (page == 0x01 && usage == 0x06),
                  let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
                  transport.lowercased().contains("bluetooth"),
                  let identity = RemoteHIDIdentity.read(from: device),
                  let fingerprint = HIDRemoteMonitor.fingerprint(for: device),
                  let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return Self(binding: RemoteHIDBinding(identity: identity, fingerprint: fingerprint), name: pairedNames[fingerprint]?.name ?? name)
        }
        return unambiguous(candidates).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func unambiguous(_ candidates: [Self]) -> [Self] {
        Dictionary(grouping: candidates, by: \.id).values.compactMap { interfaces in
            guard let first = interfaces.first,
                  interfaces.allSatisfy({ $0.binding == first.binding }) else { return nil }
            return first
        }
    }

    static func identified(identity: RemoteHIDIdentity, expectedName: String? = nil, among candidates: [Self]) -> Self? {
        let normalizedName = expectedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedName, normalizedName.isEmpty { return nil }
        let matches = unambiguous(candidates).filter { candidate in
            guard candidate.binding.identity == identity else { return false }
            guard let normalizedName else { return true }
            return candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedName) == .orderedSame
        }
        return matches.count == 1 ? matches.first : nil
    }
}
