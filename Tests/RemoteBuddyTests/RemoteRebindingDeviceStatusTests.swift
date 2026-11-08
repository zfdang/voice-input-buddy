import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Remote rebinding device status") @MainActor
struct RemoteRebindingDeviceStatusTests {
    @Test func transferUsesCurrentConnectionAndInvalidatesStaleOriginalValues() throws {
        let name = "device-status-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = BridgeAppModel(settings: AppSettings(defaults: defaults))
        let old = UUID(), replacement = UUID()
        model.remoteBatteryLevels = [old: 2, replacement: 78]
        model.remotePowerStates = [old: .onBattery, replacement: .charging]
        model.transferRemoteDeviceStatus(from: replacement, to: old)
        #expect(model.remoteBatteryLevels[old] == 78)
        #expect(model.remotePowerStates[old] == .charging)
        #expect(model.remotePowerStates[replacement] == nil)
        #expect(model.remoteBatteryLevels[replacement] == nil)
        model.transferRemoteDeviceStatus(from: replacement, to: old)
        #expect(model.remoteBatteryLevels[old] == nil)
        #expect(model.remotePowerStates[old] == nil)
    }
}
