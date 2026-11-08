import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth discovery paths")
@MainActor
struct BluetoothDiscoverySequenceTests {
    @Test func failedCachedConnectionFindsItsAlreadyConnectedTarget() throws {
        let suite = "bluetooth-discovery-paths-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let target = UUID(), other = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model,
            targetIdentifier: target, excludedIdentifiers: { [target, other] })
        var policy = BluetoothReconnectPolicy()
        _ = policy.nextAutomaticDelay(bypassCachedTarget: true, jitterUnit: 0.5)
        var paths: [String] = []
        BluetoothDiscoverySequence.run(
            cachedTarget: {
                paths.append("cache")
                return policy.allowsCachedTargetRetrieval ? target : nil
            },
            connectedCandidates: { paths.append("connected"); return [other, target] },
            adopt: { candidate, source in
                guard bridge.acceptsCandidateIdentifier(candidate) else { return false }
                paths.append(source.rawValue)
                return VoiceRemoteAdmission.decide(identifier: candidate,
                    targetIdentifier: bridge.targetIdentifier, advertisesVoiceService: true,
                    name: "Renamed remote", advertisedName: nil).isAdopted
            },
            scan: { paths.append("scan") }
        )
        #expect(paths == ["cache", "connected", "connected_peripheral"])
    }

    @Test func cachedTargetStopsFurtherQueries() {
        var paths: [String] = []
        BluetoothDiscoverySequence.run(
            cachedTarget: { paths.append("cache"); return 1 },
            connectedCandidates: { paths.append("connected"); return [2] },
            adopt: { _, source in paths.append(source.rawValue); return true },
            scan: { paths.append("scan") }
        )
        #expect(paths == ["cache", "target_identifier"])
    }

    @Test func rejectedCandidatesReachScanning() {
        var paths: [String] = []
        BluetoothDiscoverySequence.run(
            cachedTarget: { paths.append("cache"); return 1 },
            connectedCandidates: { paths.append("connected"); return [2, 3] },
            adopt: { candidate, source in paths.append("\(source.rawValue):\(candidate)"); return false },
            scan: { paths.append("scan") }
        )
        #expect(paths == ["cache", "target_identifier:1", "connected",
                          "connected_peripheral:2", "connected_peripheral:3", "scan"])
    }
}
