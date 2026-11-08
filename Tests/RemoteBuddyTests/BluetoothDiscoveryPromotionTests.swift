import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Bluetooth discovery promotion")
@MainActor
struct BluetoothDiscoveryPromotionTests {
    @Test func registrationPinsTheKnownBridgeIdentity() throws {
        let suite = "bluetooth-registration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { Set(model.connections.bridges.keys) })
        // Exercise registration's known-bridge identity fallback without a CBPeripheral.
        model.connections.bridges[identifier] = bridge
        model.connections.discoveryBridge = bridge
        #expect(bridge.targetIdentifier == nil)
        #expect(!bridge.acceptsCandidateIdentifier(identifier))
        let profileID = try #require(model.registerBluetoothBridgeIfNeeded(bridge))
        #expect(settings.profileID(forBluetoothIdentifier: identifier) == profileID)
        #expect(bridge.targetIdentifier == identifier)
        #expect(bridge.deviceIdentifier == identifier)
        #expect(bridge.acceptsCandidateIdentifier(identifier))
        #expect(model.connections.discoveryBridge == nil)
    }

    @Test func promotedDiscoveryBridgeRetainsItsDeviceAndCanReconnect() throws {
        let suite = "bluetooth-promotion-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        let other = UUID()
        let bridge = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { Set(model.connections.bridges.keys) })
        model.connections.discoveryBridge = bridge
        #expect(bridge.deviceIdentifier == nil)
        #expect(bridge.acceptsCandidateIdentifier(identifier))

        // Simulate the verified handshake identity, without creating a Bluetooth manager.
        #expect(bridge.bindVerifiedIdentity(identifier))
        let profileID = try #require(model.registerBluetoothBridgeIfNeeded(bridge))
        #expect(model.connections.discoveryBridge == nil)
        #expect(model.connections.bridges[identifier] === bridge)
        #expect(settings.profileID(forBluetoothIdentifier: identifier) == profileID)

        // No peripheral is retained here, just as after sleep/disconnect teardown.
        #expect(bridge.deviceIdentifier == identifier)
        #expect(bridge.targetIdentifier == identifier)
        #expect(bridge.acceptsCandidateIdentifier(identifier))
        #expect(!bridge.acceptsCandidateIdentifier(other))
        #expect(VoiceRemoteAdmission.decide(identifier: identifier,
            targetIdentifier: bridge.targetIdentifier, advertisesVoiceService: false,
            name: "Renamed remote", advertisedName: nil) == .adoptSavedIdentity)
        #expect(!bridge.bindVerifiedIdentity(other))
        #expect(bridge.deviceIdentifier == identifier)
        #expect(model.registerBluetoothBridgeIfNeeded(bridge) == profileID)
    }

    @Test func discoveryStillExcludesRegisteredDevicesAndBoundBridgeAllowsScanFallback() throws {
        let suite = "bluetooth-exclusions-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let identifier = UUID()
        let other = UUID()
        let discovery = BluetoothRemoteBridge(settings: settings, delegate: model,
            excludedIdentifiers: { [identifier] })
        #expect(!discovery.acceptsCandidateIdentifier(identifier))
        #expect(discovery.acceptsCandidateIdentifier(other))

        let registered = BluetoothRemoteBridge(settings: settings, delegate: model,
            targetIdentifier: identifier, excludedIdentifiers: { [identifier, other] })
        #expect(registered.acceptsCandidateIdentifier(identifier))
        #expect(!registered.acceptsCandidateIdentifier(other))
        // Saved identity does not bypass the foreign-product rejection.
        #expect(!VoiceRemoteAdmission.decide(identifier: identifier,
            targetIdentifier: registered.targetIdentifier, advertisesVoiceService: true,
            name: "Chromecast Remote", advertisedName: nil).isAdopted)
    }
}
