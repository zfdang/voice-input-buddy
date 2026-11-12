import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Codable, Equatable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(property: [String: NSNumber]) {
        guard let source = property[Self.sourceKey],
              let destination = property[Self.destinationKey]
        else { return nil }
        self.source = source.uint64Value
        self.destination = destination.uint64Value
    }

    var property: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }
}

enum RemoteHIDKeyMappingPolicy {
    // RC003 exposes its microphone button as keyboard F5 (usage page 7,
    // usage 0x3e). macOS represents the laptop Fn/Globe key as the Apple
    // vendor top-case usage (usage page 0xff, usage 3).
    static let remoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0000_00FF_0000_0003
    )

    // 软件点按及需要先切换输入法的 Fn 长按均由 App 注入。
    // 丢弃遥控器原生语音键，避免输入法尚未激活时先收到 Fn，或与注入事件重复。
    static let neutralRemoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0
    )

    // RC003 exposes its power button as keyboard Power (usage 0x66).
    // Remap it to harmless F20 before macOS can turn it into a sleep event.
    static let suppressedRemotePowerKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0066,
        destination: 0x0000_0007_0000_006F
    )
    /// Neutralize T1-Remote Consumer AC Search (0x0221) so Voice press never opens Spotlight.
    static let neutralT1VoiceSearchKey = HIDUsageMapping(
        source: 0x000C_0000_0221,
        destination: 0x0
    )
    /// Neutralize T1-Remote reserved keyboard hold usage (0xAA) sent while Voice stays held.
    static let neutralT1VoiceHoldKey = HIDUsageMapping(
        source: 0x0007_0000_00AA,
        destination: 0x0
    )
    /// Remap T1-Remote System Power Down (Page 0x01, Usage 0x81) to F20 so pressing Power
    /// never triggers macOS display sleep while custom mapping is enabled.
    static let suppressedT1PowerKey = HIDUsageMapping(
        source: 0x0001_0000_0081,
        destination: 0x0007_0000_006F
    )

    static func applying(
        to existing: [HIDUsageMapping],
        voiceMapping: HIDUsageMapping = remoteVoiceKey,
        powerMapping: HIDUsageMapping? = nil
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            $0.source != remoteVoiceKey.source &&
                $0.source != suppressedRemotePowerKey.source
        } + [voiceMapping]
        if let powerMapping {
            desired.append(powerMapping)
        }
        return desired
    }

    static func applyingT1(
        to existing: [HIDUsageMapping],
        powerMapping: HIDUsageMapping? = nil
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            $0.source != neutralT1VoiceSearchKey.source &&
                $0.source != neutralT1VoiceHoldKey.source &&
                $0.source != suppressedT1PowerKey.source
        } + [neutralT1VoiceSearchKey, neutralT1VoiceHoldKey]
        if let powerMapping {
            desired.append(powerMapping)
        }
        return desired
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        originalPowerMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        let ownedVoice = current.first { $0.source == remoteVoiceKey.source }
        let restoreVoice = ownedVoice == remoteVoiceKey || ownedVoice == neutralRemoteVoiceKey
        let restorePower = current.first { $0.source == suppressedRemotePowerKey.source } == suppressedRemotePowerKey
        var restored = current.filter {
            !(restoreVoice && $0.source == remoteVoiceKey.source) &&
                !(restorePower && $0.source == suppressedRemotePowerKey.source)
        }
        if restoreVoice, let originalVoiceMapping { restored.append(originalVoiceMapping) }
        if restorePower, let originalPowerMapping { restored.append(originalPowerMapping) }
        return restored
    }

    static func restoringT1(
        originalSearchMapping: HIDUsageMapping?,
        originalHoldMapping: HIDUsageMapping?,
        originalPowerMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        let restoreSearch = current.first { $0.source == neutralT1VoiceSearchKey.source } == neutralT1VoiceSearchKey
        let restoreHold = current.first { $0.source == neutralT1VoiceHoldKey.source } == neutralT1VoiceHoldKey
        let restorePower = current.first { $0.source == suppressedT1PowerKey.source } == suppressedT1PowerKey
        var restored = current.filter {
            !(restoreSearch && $0.source == neutralT1VoiceSearchKey.source) &&
                !(restoreHold && $0.source == neutralT1VoiceHoldKey.source) &&
                !(restorePower && $0.source == suppressedT1PowerKey.source)
        }
        if restoreSearch, let originalSearchMapping { restored.append(originalSearchMapping) }
        if restoreHold, let originalHoldMapping { restored.append(originalHoldMapping) }
        if restorePower, let originalPowerMapping { restored.append(originalPowerMapping) }
        return restored
    }
}

enum RemoteHIDMappingFamily: String, Codable, Equatable {
    case xiaomi
    case t1Remote = "t1_remote"
}

struct RemoteHIDMappingService {
    let registryID: UInt64?
    let locationID: UInt32?
    let family: RemoteHIDMappingFamily
    private let retainedOwner: AnyObject?
    let readMappings: () -> [HIDUsageMapping]
    let setMappings: ([HIDUsageMapping]) -> Bool

    init(
        registryID: UInt64?,
        locationID: UInt32? = nil,
        family: RemoteHIDMappingFamily = .xiaomi,
        retainedOwner: AnyObject? = nil,
        readMappings: @escaping () -> [HIDUsageMapping],
        setMappings: @escaping ([HIDUsageMapping]) -> Bool
    ) {
        self.registryID = registryID
        self.locationID = locationID
        self.family = family
        self.retainedOwner = retainedOwner
        self.readMappings = readMappings
        self.setMappings = setMappings
    }
}

final class RemoteHIDKeyMapper {
    typealias ServiceProvider = () -> [RemoteHIDMappingService]

    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalMappings: Codable {
        let voice: HIDUsageMapping?
        let power: HIDUsageMapping?
        let family: RemoteHIDMappingFamily?
        let t1Search: HIDUsageMapping?
        let t1Hold: HIDUsageMapping?
        let t1Power: HIDUsageMapping?

        init(
            voice: HIDUsageMapping? = nil,
            power: HIDUsageMapping? = nil,
            family: RemoteHIDMappingFamily? = nil,
            t1Search: HIDUsageMapping? = nil,
            t1Hold: HIDUsageMapping? = nil,
            t1Power: HIDUsageMapping? = nil
        ) {
            self.voice = voice
            self.power = power
            self.family = family
            self.t1Search = t1Search
            self.t1Hold = t1Hold
            self.t1Power = t1Power
        }
    }

    private struct RecoveryJournal: Codable {
        let bootID: String
        let mappings: [UInt64: OriginalMappings]
    }
    private static let journalKey = "hid.originalMappings.v1"
    private let recoveryDefaults: UserDefaults
    private let bootID: String?
    private let recoveryJournalURL: URL?
    private let serviceProvider: ServiceProvider?
    var additionalIdentities = Set<RemoteHIDIdentity>() {
        willSet {
            // Restore while the old identity list can still find its services.
            if newValue != additionalIdentities { restore() }
        }
    }
    var t1Identities = Set<RemoteHIDIdentity>() {
        willSet {
            if newValue != t1Identities { restore() }
        }
    }
    private struct AppliedConfiguration: Equatable {
        let suppressPowerKey: Bool
        let neutralizeVoiceKey: Bool
        var serviceRegistryIDs: Set<UInt64>
    }

    private enum ServiceMappingEvaluation: Equatable {
        case upToDate
        case noServices
        case needsReapply
    }

    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private var appliedConfiguration: AppliedConfiguration?
    private(set) var isApplied = false
    private(set) var isPowerKeySuppressed = false
    private(set) var powerSuppressedLocationIDs: Set<UInt32>?
    private(set) var isVoiceKeyNeutralized = false
    private(set) var matchedServiceCount = 0

    var hasMatchingServices: Bool {
        matchedServiceCount > 0
    }

    private func matchingServices() -> [RemoteHIDMappingService] {
        serviceProvider?() ?? Self.systemServices(
            additionalIdentities: additionalIdentities,
            t1Identities: t1Identities
        )
    }

    private func evaluateAppliedServices(
        _ services: [RemoteHIDMappingService],
        suppressPowerKey: Bool,
        neutralizeVoiceKey: Bool
    ) -> ServiceMappingEvaluation {
        guard !services.isEmpty else { return .noServices }
        guard let applied = appliedConfiguration,
              applied.suppressPowerKey == suppressPowerKey,
              applied.neutralizeVoiceKey == neutralizeVoiceKey
        else { return .needsReapply }

        let expectedVoiceMapping = neutralizeVoiceKey
            ? RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey
            : RemoteHIDKeyMappingPolicy.remoteVoiceKey

        var liveRegistryIDs = Set<UInt64>()
        for service in services {
            guard let registryID = service.registryID,
                  applied.serviceRegistryIDs.contains(registryID)
            else { return .needsReapply }
            let mappings = service.readMappings()
            switch service.family {
            case .xiaomi:
                guard mappings.contains(expectedVoiceMapping) else { return .needsReapply }
                if suppressPowerKey,
                   !mappings.contains(RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey) {
                    return .needsReapply
                }
            case .t1Remote:
                guard mappings.contains(RemoteHIDKeyMappingPolicy.neutralT1VoiceSearchKey),
                      mappings.contains(RemoteHIDKeyMappingPolicy.neutralT1VoiceHoldKey)
                else { return .needsReapply }
                if suppressPowerKey,
                   !mappings.contains(RemoteHIDKeyMappingPolicy.suppressedT1PowerKey) {
                    return .needsReapply
                }
            }
            liveRegistryIDs.insert(registryID)
        }

        // Prune vanished service IDs so a reconnecting device cannot reuse stale readiness.
        appliedConfiguration?.serviceRegistryIDs = liveRegistryIDs
        return .upToDate
    }

    /// Revalidates `isVoiceKeyNeutralized` and power-key suppression against currently attached
    /// HID services so late-arriving, reconnected, or unmapped remotes never inherit stale readiness.
    @discardableResult
    func refreshAppliedMappingsValidity(
        expectedPowerKeySuppression: Bool,
        expectedVoiceKeyNeutralization: Bool
    ) -> Bool {
        guard expectedPowerKeySuppression || expectedVoiceKeyNeutralization else {
            return true
        }
        let services = matchingServices()
        matchedServiceCount = services.count
        if expectedVoiceKeyNeutralization, !isVoiceKeyNeutralized {
            resetAppliedState()
            return false
        }
        switch evaluateAppliedServices(
            services,
            suppressPowerKey: expectedPowerKeySuppression,
            neutralizeVoiceKey: expectedVoiceKeyNeutralization
        ) {
        case .upToDate:
            return true
        case .noServices, .needsReapply:
            // Reset all applied flags (isApplied, power-key suppression, neutralization,
            // and cached service IDs) whenever no services remain or live mappings diverge.
            resetAppliedState()
            return false
        }
    }

    /// Returns whether currently attached HID services require reapplying key mappings.
    func needsReapply(suppressPowerKey: Bool, neutralizeVoiceKey: Bool) -> Bool {
        let services = matchingServices()
        matchedServiceCount = services.count
        return evaluateAppliedServices(
            services,
            suppressPowerKey: suppressPowerKey,
            neutralizeVoiceKey: neutralizeVoiceKey
        ) == .needsReapply
    }

    /// Removes vanished HID services from cached applied state when a Bluetooth bridge leaves `.ready`.
    func pruneAppliedServices() {
        let services = matchingServices()
        matchedServiceCount = services.count
        guard !services.isEmpty, var applied = appliedConfiguration else {
            resetAppliedState()
            return
        }
        let liveIDs = Set(services.compactMap(\.registryID))
        applied.serviceRegistryIDs.formIntersection(liveIDs)
        if applied.serviceRegistryIDs.isEmpty {
            resetAppliedState()
        } else {
            appliedConfiguration = applied
            if let suppressedLocations = powerSuppressedLocationIDs {
                let liveLocations = suppressedLocations.intersection(services.compactMap(\.locationID))
                powerSuppressedLocationIDs = liveLocations.isEmpty ? nil : liveLocations
                isPowerKeySuppressed = powerSuppressedLocationIDs != nil
            }
        }
    }

    init(
        serviceProvider: ServiceProvider? = nil,
        recoveryDefaults: UserDefaults = .standard,
        bootID: String? = RemoteHIDKeyMapper.currentBootID(),
        recoveryJournalURL: URL? = nil
    ) {
        self.serviceProvider = serviceProvider
        self.recoveryDefaults = recoveryDefaults
        self.bootID = bootID
        self.recoveryJournalURL = recoveryJournalURL ?? (recoveryDefaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("RemoteBuddy/HIDMappingRecovery.json") : nil)
        if let bootID,
           let data = self.recoveryJournalURL.flatMap({ try? Data(contentsOf: $0) })
                ?? recoveryDefaults.data(forKey: Self.journalKey),
           let journal = try? JSONDecoder().decode(RecoveryJournal.self, from: data),
           journal.bootID == bootID {
            originalMappings = journal.mappings
        }
    }

    static func bootIdentity(uuid: String?, bootTime: (seconds: Int64, microseconds: Int64)?) -> String? {
        if let uuid, !uuid.isEmpty { return uuid }
        guard let bootTime, bootTime.seconds > 0, (0..<1_000_000).contains(bootTime.microseconds) else { return nil }
        return "boot-time:\(bootTime.seconds):\(bootTime.microseconds)"
    }

    private static func currentBootID() -> String? {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size + 1)
            if sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
               let identity = bootIdentity(uuid: String(cString: bytes), bootTime: nil) { return identity }
        }
        var bootTime = timeval()
        size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
           let identity = bootIdentity(uuid: nil, bootTime: (Int64(bootTime.tv_sec), Int64(bootTime.tv_usec))) {
            AppLogger.shared.write("VOICE FN MAPPING boot_identity source=boot_time reason=uuid_unavailable")
            return identity
        }
        AppLogger.shared.write("VOICE FN MAPPING boot_identity result=unavailable")
        return nil
    }

    @discardableResult
    private func persistRecoveryJournal() -> Bool {
        guard let bootID else { return false }
        do {
            if let url = recoveryJournalURL {
                if originalMappings.isEmpty {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } else {
                    let directory = url.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    let data = try JSONEncoder().encode(RecoveryJournal(bootID: bootID, mappings: originalMappings))
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                recoveryDefaults.removeObject(forKey: Self.journalKey)
            } else if originalMappings.isEmpty {
                recoveryDefaults.removeObject(forKey: Self.journalKey)
            } else {
                // Isolated defaults suites are used by injected in-memory test services.
                recoveryDefaults.set(try JSONEncoder().encode(RecoveryJournal(bootID: bootID, mappings: originalMappings)), forKey: Self.journalKey)
            }
            return true
        } catch {
            AppLogger.shared.write("VOICE FN MAPPING journal result=failed")
            return false
        }
    }

    @discardableResult
    func apply(
        suppressPowerKey: Bool = false,
        neutralizeVoiceKey: Bool = false
    ) -> Bool {
        guard bootID != nil else { resetAppliedState(); return false }
        let services = matchingServices()
        let matchedCount = services.count
        matchedServiceCount = matchedCount
        guard matchedCount > 0 else {
            resetAppliedState()
            AppLogger.shared.write(
                "VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0"
            )
            return false
        }

        var snapshots: [Int: [HIDUsageMapping]] = [:]
        var appliedIndices: [Int] = []
        var newlyStoredRegistryIDs = Set<UInt64>()
        let matchedCountsByLocation = services.reduce(into: [UInt32: Int]()) { counts, service in
            guard let locationID = service.locationID else { return }
            counts[locationID, default: 0] += 1
        }
        var appliedCountsByLocation: [UInt32: Int] = [:]

        // Snapshot every service and persist once, before the first system write.
        for (index, service) in services.enumerated() {
            guard let registryID = service.registryID else { continue }
            let current = service.readMappings()
            snapshots[index] = current
            if originalMappings[registryID] == nil {
                switch service.family {
                case .xiaomi:
                    let currentPower = current.first {
                        $0.source == RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey.source
                    }
                    let currentVoice = current.first {
                        $0.source == RemoteHIDKeyMappingPolicy.remoteVoiceKey.source
                    }
                    // Recover older unjournaled sessions without saving our own output as input.
                    originalMappings[registryID] = OriginalMappings(
                        voice: [RemoteHIDKeyMappingPolicy.remoteVoiceKey,
                                RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey].contains(currentVoice)
                            ? nil : currentVoice,
                        power: currentPower == RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey
                            ? nil
                            : currentPower,
                        family: .xiaomi
                    )
                case .t1Remote:
                    let currentSearch = current.first {
                        $0.source == RemoteHIDKeyMappingPolicy.neutralT1VoiceSearchKey.source
                    }
                    let currentHold = current.first {
                        $0.source == RemoteHIDKeyMappingPolicy.neutralT1VoiceHoldKey.source
                    }
                    let currentPower = current.first {
                        $0.source == RemoteHIDKeyMappingPolicy.suppressedT1PowerKey.source
                    }
                    originalMappings[registryID] = OriginalMappings(
                        family: .t1Remote,
                        t1Search: currentSearch == RemoteHIDKeyMappingPolicy.neutralT1VoiceSearchKey
                            ? nil : currentSearch,
                        t1Hold: currentHold == RemoteHIDKeyMappingPolicy.neutralT1VoiceHoldKey
                            ? nil : currentHold,
                        t1Power: currentPower == RemoteHIDKeyMappingPolicy.suppressedT1PowerKey
                            ? nil : currentPower
                    )
                }
                newlyStoredRegistryIDs.insert(registryID)
            }
        }
        guard persistRecoveryJournal() else {
            newlyStoredRegistryIDs.forEach { originalMappings.removeValue(forKey: $0) }
            resetAppliedState()
            return false
        }

        for (index, service) in services.enumerated() {
            guard let registryID = service.registryID else {
                if neutralizeVoiceKey, service.family == .xiaomi {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            let current = snapshots[index] ?? service.readMappings()
            let desired: [HIDUsageMapping]
            switch service.family {
            case .xiaomi:
                desired = RemoteHIDKeyMappingPolicy.applying(
                    to: current,
                    voiceMapping: neutralizeVoiceKey
                        ? RemoteHIDKeyMappingPolicy.neutralRemoteVoiceKey
                        : RemoteHIDKeyMappingPolicy.remoteVoiceKey,
                    powerMapping: suppressPowerKey
                        ? RemoteHIDKeyMappingPolicy.suppressedRemotePowerKey
                        : originalMappings[registryID]?.power
                )
            case .t1Remote:
                desired = RemoteHIDKeyMappingPolicy.applyingT1(
                    to: current,
                    powerMapping: suppressPowerKey
                        ? RemoteHIDKeyMappingPolicy.suppressedT1PowerKey
                        : originalMappings[registryID]?.t1Power
                )
            }
            guard service.setMappings(desired) else {
                if neutralizeVoiceKey, service.family == .xiaomi {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            appliedIndices.append(index)
            if let locationID = service.locationID {
                appliedCountsByLocation[locationID, default: 0] += 1
            }
        }

        let appliedCount = appliedIndices.count
        let allTargetsApplied = appliedCount == matchedCount
        let xiaomiServicesCount = services.filter { $0.family == .xiaomi }.count
        let appliedXiaomiCount = appliedIndices.filter { services[$0].family == .xiaomi }.count
        let allXiaomiApplied = xiaomiServicesCount > 0 && appliedXiaomiCount == xiaomiServicesCount
        let t1ServicesCount = services.filter { $0.family == .t1Remote }.count
        let appliedT1Count = appliedIndices.filter { services[$0].family == .t1Remote }.count
        let allT1Applied = t1ServicesCount > 0 && appliedT1Count == t1ServicesCount
        let hasNeutralizableServices = (xiaomiServicesCount + t1ServicesCount) > 0
        let allNeutralized = hasNeutralizableServices &&
            (xiaomiServicesCount == 0 || allXiaomiApplied) &&
            (t1ServicesCount == 0 || allT1Applied)
        let fullySuppressedLocations = Set(matchedCountsByLocation.compactMap { locationID, count in
            appliedCountsByLocation[locationID] == count ? locationID : nil
        })
        let appliedRegistryIDs = Set(appliedIndices.compactMap { services[$0].registryID })
        if allTargetsApplied, appliedRegistryIDs.count == matchedCount {
            appliedConfiguration = AppliedConfiguration(
                suppressPowerKey: suppressPowerKey,
                neutralizeVoiceKey: neutralizeVoiceKey,
                serviceRegistryIDs: appliedRegistryIDs
            )
        } else {
            appliedConfiguration = nil
        }
        isApplied = (neutralizeVoiceKey && xiaomiServicesCount > 0) ? allXiaomiApplied && allTargetsApplied : appliedCount > 0
        isVoiceKeyNeutralized = neutralizeVoiceKey && allNeutralized
        if suppressPowerKey, !fullySuppressedLocations.isEmpty {
            isPowerKeySuppressed = true
            powerSuppressedLocationIDs = fullySuppressedLocations
        } else {
            isPowerKeySuppressed = false
            powerSuppressedLocationIDs = nil
        }
        let suppressionScope = isPowerKeySuppressed
            ? "locations=\(powerSuppressedLocationIDs?.count ?? 0)"
            : "none"
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) neutralized=\(isVoiceKeyNeutralized) " +
                "power_suppressed=\(isPowerKeySuppressed) suppression_scope=\(suppressionScope) " +
                "matched=\(matchedCount) applied=\(appliedCount)"
        )
        return isApplied
    }

    func restore() {
        guard !originalMappings.isEmpty else {
            resetAppliedState()
            return
        }

        let services = matchingServices()
        var restoredCount = 0
        for service in services {
            guard let registryID = service.registryID,
                  let original = originalMappings[registryID]
            else { continue }
            let restored: [HIDUsageMapping]
            switch original.family ?? service.family {
            case .xiaomi:
                restored = RemoteHIDKeyMappingPolicy.restoring(
                    originalVoiceMapping: original.voice,
                    originalPowerMapping: original.power,
                    in: service.readMappings()
                )
            case .t1Remote:
                restored = RemoteHIDKeyMappingPolicy.restoringT1(
                    originalSearchMapping: original.t1Search,
                    originalHoldMapping: original.t1Hold,
                    originalPowerMapping: original.t1Power,
                    in: service.readMappings()
                )
            }
            if service.setMappings(restored) {
                restoredCount += 1
                originalMappings.removeValue(forKey: registryID)
            }
        }

        // Offline or failed services remain journaled for the next reconnect/launch.
        persistRecoveryJournal()
        resetAppliedState()
        AppLogger.shared.write("VOICE FN MAPPING restored=\(restoredCount)")
    }

    private func rollback(
        services: [RemoteHIDMappingService],
        snapshots: [Int: [HIDUsageMapping]],
        appliedIndices: [Int],
        newlyStoredRegistryIDs: Set<UInt64>,
        matchedCount: Int
    ) {
        var rollbackCount = 0
        var registryIDsNeedingRestore = Set<UInt64>()
        for index in appliedIndices {
            guard let snapshot = snapshots[index] else { continue }
            if services[index].setMappings(snapshot) {
                rollbackCount += 1
            } else if let registryID = services[index].registryID {
                registryIDsNeedingRestore.insert(registryID)
            }
        }
        newlyStoredRegistryIDs
            .subtracting(registryIDsNeedingRestore)
            .forEach { originalMappings.removeValue(forKey: $0) }
        persistRecoveryJournal()
        resetAppliedState()
        AppLogger.shared.write(
            "VOICE FN MAPPING rollback matched=\(matchedCount) applied=\(appliedIndices.count) " +
                "restored=\(rollbackCount)"
        )
    }

    private func resetAppliedState() {
        appliedConfiguration = nil
        isApplied = false
        isPowerKeySuppressed = false
        powerSuppressedLocationIDs = nil
        isVoiceKeyNeutralized = false
    }

    private static func systemServices(
        additionalIdentities: Set<RemoteHIDIdentity>,
        t1Identities: Set<RemoteHIDIdentity>
    ) -> [RemoteHIDMappingService] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.compactMap { service in
            guard let family = targetFamily(
                service,
                additionalIdentities: additionalIdentities,
                t1Identities: t1Identities
            ) else { return nil }
            return RemoteHIDMappingService(
                registryID: registryID(service),
                locationID: locationID(service),
                family: family,
                retainedOwner: client,
                readMappings: { readMappings(service) },
                setMappings: { mappings in
                    IOHIDServiceClientSetProperty(
                        service,
                        mappingProperty,
                        mappings.map(\.property) as CFArray
                    )
                }
            )
        }
    }

    private static func targetFamily(
        _ service: IOHIDServiceClient,
        additionalIdentities: Set<RemoteHIDIdentity>,
        t1Identities: Set<RemoteHIDIdentity>
    ) -> RemoteHIDMappingFamily? {
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        guard let vendor, let product,
              (1...65535).contains(vendor.intValue), (0...65535).contains(product.intValue) else { return nil }
        let identity = RemoteHIDIdentity(vendorID: UInt16(vendor.intValue), productID: UInt16(product.intValue))
        if identity == .t1Remote || t1Identities.contains(identity) {
            return .t1Remote
        }
        if identity == .xiaomi || additionalIdentities.contains(identity) {
            return .xiaomi
        }
        return nil
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func locationID(_ service: IOHIDServiceClient) -> UInt32? {
        (IOHIDServiceClientCopyProperty(
            service,
            kIOHIDLocationIDKey as CFString
        ) as? NSNumber)?.uint32Value
    }

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}
