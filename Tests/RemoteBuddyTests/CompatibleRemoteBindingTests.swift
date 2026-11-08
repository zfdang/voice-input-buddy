import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Compatible remote identities")
@MainActor
struct CompatibleRemoteBindingTests {
    private let alternate = RemoteHIDIdentity(vendorID: 0x1234, productID: 0x5678)
    private func settings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "compatible-remote-" + UUID().uuidString))
        return AppSettings(defaults: defaults)
    }

    @Test func pnpIdentityUsesLittleEndianAndRejectsMissingOrInvalidMetadata() {
        #expect(RemoteHIDIdentity.fromPnP(Data([2, 0x34, 0x12, 0x78, 0x56, 0, 0])) == alternate)
        #expect(RemoteHIDIdentity.fromPnP(Data([1, 0x34, 0x12, 0x78, 0x56, 1, 0])) == alternate)
        for bytes: [UInt8] in [[], [2, 1], [3, 0x34, 0x12, 1, 0, 0, 0], [2, 0, 0, 1, 0, 0, 0]] {
            #expect(RemoteHIDIdentity.fromPnP(Data(bytes)) == nil)
        }
    }

    @Test func physicalIdentityMustBeUnambiguousBeforeAutomaticLearning() {
        let first = RemoteHIDCandidate(binding: .init(identity: alternate, fingerprint: "first"), name: "Compatible remote")
        let second = RemoteHIDCandidate(binding: .init(identity: alternate, fingerprint: "second"), name: "Compatible remote")
        #expect(RemoteHIDCandidate.identified(identity: alternate, among: [first, first]) == first)
        #expect(RemoteHIDCandidate.identified(identity: alternate, among: [first, second]) == nil)
        let conflicting = RemoteHIDCandidate(binding: .init(identity: .xiaomi, fingerprint: "first"), name: "Other interface")
        #expect(RemoteHIDCandidate.unambiguous([first, conflicting]).isEmpty)
    }

    @Test func alternateIdentityPersistsWithoutChangingOtherDeviceMappings() throws {
        let defaults = try #require(UserDefaults(suiteName: "compatible-persist-" + UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let original = try #require(settings.remoteDeviceProfiles.first { $0.id == first })
        let binding = RemoteHIDBinding(identity: alternate, fingerprint: "selected-compatible-remote")
        #expect(settings.bindCompatibleHID(binding, to: google))
        #expect(settings.compatibleHIDBindings == [binding])
        #expect(!settings.bindCompatibleHID(binding, to: google))
        #expect(settings.remoteDeviceProfiles.first { $0.id == first } == original)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.compatibleHIDBindings == [binding])
        #expect(reloaded.profileID(forHIDFingerprint: binding.fingerprint) == google)
        reloaded.remoteDeviceProfiles.removeAll { $0.id == google }
        #expect(reloaded.compatibleHIDBindings.isEmpty)
    }

    @Test func standardIdentitiesDoNotCreateExtraWhitelistEntries() throws {
        for identity in [RemoteHIDIdentity.xiaomi, .chromecast] {
            let settings = try settings()
            let profile = settings.registerBluetoothRemote(identifier: UUID(), model: identity == .xiaomi ? .rc003 : .chromecastVoiceRemote)
            #expect(settings.bindCompatibleHID(.init(identity: identity, fingerprint: "standard"), to: profile))
            #expect(settings.compatibleHIDBindings.isEmpty)
            #expect(settings.profileID(forHIDFingerprint: "standard") == profile)
        }
    }

    @Test func onlySelectedSupportedFamiliesAndUniqueBindingsCanBeLearned() throws {
        #expect(BridgeAppModel.canLearnHIDIdentity(model: .chromecastVoiceRemote, source: .chromecastRemote))
        #expect(!BridgeAppModel.canLearnHIDIdentity(model: .chromecastVoiceRemote, source: .xiaomiRemote))
        #expect(!BridgeAppModel.canLearnHIDIdentity(model: .unknown, source: .xiaomiRemote))
        #expect(!BridgeAppModel.canLearnHIDIdentity(model: .appleSiriRemoteA2854, source: .siriRemote))
        let settings = try settings()
        let first = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let binding = RemoteHIDBinding(identity: alternate, fingerprint: "same-device")
        #expect(settings.bindCompatibleHID(binding, to: first))
        #expect(!settings.bindCompatibleHID(binding, to: second))
        #expect(settings.compatibleHIDBindings.count == 1)
        #expect(!settings.bindCompatibleHID(.init(identity: .init(vendorID: 0, productID: 1), fingerprint: "bad"), to: first))
    }

    @Test func dynamicMatchingAddsExactDeduplicatedPairsOnly() throws {
        let criteria = HIDRemoteMonitor.deviceMatchingCriteria(includeXiaomi: true, includeGoogle: true,
            additionalIdentities: [alternate, alternate, .xiaomi, .chromecast, .init(vendorID: 0, productID: 0)])
        #expect(criteria.count == 3)
        #expect(criteria.allSatisfy { $0.count == 2 })
        #expect(criteria.last?["VendorID"] as? Int == 0x1234)
        #expect(criteria.last?["ProductID"] as? Int == 0x5678)
    }

    @Test func googleSupportDoesNotBypassXiaomiPowerSuppression() throws {
        let settings = try settings()
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let other = RemoteHIDIdentity(vendorID: 0x2345, productID: 0x6789)
        #expect(settings.bindCompatibleHID(.init(identity: alternate, fingerprint: "xiaomi"), to: xiaomi))
        #expect(settings.bindCompatibleHID(.init(identity: other, fingerprint: "google"), to: google))
        let blocked = HIDRemoteMonitor.monitorFamilies(targetModel: .rc003, powerKeySuppressed: false, allowsGoogle: true)
        #expect(!blocked.xiaomi && !blocked.google)
        let discovery = HIDRemoteMonitor.monitorFamilies(targetModel: nil, powerKeySuppressed: false, allowsGoogle: true)
        #expect(!discovery.xiaomi && discovery.google)
        let identities = settings.compatibleHIDIdentities(includeXiaomi: discovery.xiaomi, includeGoogle: discovery.google)
        #expect(identities == [other])
        let matches = HIDRemoteMonitor.deviceMatchingCriteria(includeXiaomi: discovery.xiaomi,
            includeGoogle: discovery.google, additionalIdentities: identities)
        #expect(matches.count == 2)
        #expect(!matches.contains { ($0["VendorID"] as? Int) == Int(alternate.vendorID) })
        let protected = HIDRemoteMonitor.monitorFamilies(targetModel: .rc003, powerKeySuppressed: true, allowsGoogle: true)
        #expect(protected.xiaomi && !protected.google)
        let pendingXiaomi = HIDRemoteMonitor.monitorFamilies(targetModel: .unknown, powerKeySuppressed: true, allowsGoogle: true)
        #expect(pendingXiaomi.xiaomi && !pendingXiaomi.google)
        let unsafePending = HIDRemoteMonitor.monitorFamilies(targetModel: .unknown, powerKeySuppressed: false, allowsGoogle: true)
        #expect(!unsafePending.xiaomi && !unsafePending.google)
    }

    @Test func googleProtocolRecognitionUsesStoredBindingsWithoutLiveBLEConfirmation() throws {
        let settings = try settings()
        let google = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        #expect(settings.bindCompatibleHID(.init(identity: .chromecast, fingerprint: "google"), to: google))
        func recognized(_ identity: RemoteHIDIdentity, _ fingerprint: String) -> Bool {
            HIDRemoteMonitor.matchesGoogleProtocol(identity: identity, fingerprint: fingerprint,
                profiles: settings.remoteDeviceProfiles)
        }
        #expect(recognized(.chromecast, "google"))
        #expect(recognized(.chromecast, "other-device"))
        #expect(!recognized(alternate, "google"))
        #expect(settings.bindCompatibleHID(.init(identity: alternate, fingerprint: "clone"), to: google))
        #expect(recognized(alternate, "clone"))
        #expect(!recognized(.chromecast, "clone"))
        let index = try #require(settings.remoteDeviceProfiles.firstIndex { $0.id == google })
        settings.remoteDeviceProfiles[index].compatibleHIDBinding = .init(identity: alternate, fingerprint: "another-fingerprint")
        #expect(!recognized(alternate, "clone"))
        #expect(!settings.bindCompatibleHID(.init(identity: .xiaomi, fingerprint: "wrong-family"), to: google))
    }

    @Test func automaticBindingRequiresMatchingNameEvenWithUniqueVIDPID() {
        let candidate = RemoteHIDCandidate(binding: .init(identity: alternate, fingerprint: "remote"), name: "Chromecast 遥控器")
        #expect(G9N9NProtocol.isCandidateName(candidate.name))
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: "Chromecast 遥控器", among: [candidate]) == candidate)
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: "Other remote", among: [candidate]) == nil)
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: "", among: [candidate]) == nil)
    }

    @Test func sameModelRemotesAreDisambiguatedByNameBeforeCheckingUniqueness() {
        let first = RemoteHIDCandidate(binding: .init(identity: alternate, fingerprint: "first"), name: " Living Room ")
        let second = RemoteHIDCandidate(binding: .init(identity: alternate, fingerprint: "second"), name: "Bedroom")
        let candidates = [first, second]
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: "living room", among: candidates) == first)
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: " BEDROOM ", among: candidates) == second)
        #expect(RemoteHIDCandidate.identified(identity: alternate, among: candidates) == nil)
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: " ", among: candidates) == nil)
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: "missing", among: candidates) == nil)
        let duplicateName = RemoteHIDCandidate(binding: .init(identity: alternate, fingerprint: "third"), name: "Bedroom")
        #expect(RemoteHIDCandidate.identified(identity: alternate, expectedName: "Bedroom", among: candidates + [duplicateName]) == nil)
    }

    @Test func replacingWhitelistRestoresMappingsWhileOldServicesAreStillReachable() throws {
        let defaults = try #require(UserDefaults(suiteName: "compatible-mapper-" + UUID().uuidString))
        let original = HIDUsageMapping(source: RemoteHIDKeyMappingPolicy.remoteVoiceKey.source, destination: 99)
        var mappings = [original]
        var mapper: RemoteHIDKeyMapper!
        defer { mapper = nil }
        mapper = RemoteHIDKeyMapper(serviceProvider: {
            guard mapper.additionalIdentities.contains(alternate) else { return [] }
            return [.init(registryID: 123, locationID: 9, readMappings: { mappings },
                setMappings: { mappings = $0; return true })]
        }, recoveryDefaults: defaults, bootID: "binding-test")
        mapper.additionalIdentities = [alternate]
        #expect(mapper.apply(suppressPowerKey: true))
        #expect(mapper.isPowerKeySuppressed)
        #expect(mappings != [original])
        mapper.additionalIdentities = []
        #expect(mappings == [original])
        #expect(!mapper.isApplied)
        #expect(!mapper.isPowerKeySuppressed)
    }

    @Test func addDeviceOpensDeviceSelectionWithoutResettingConfiguredTools() throws {
        let settings = try settings()
        settings.setOnboardingVoiceTool(.voicecursor)
        settings.voiceKeyMode = .leftCommand
        settings.voiceFnTapModeEnabled = false
        let profile = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(profile)
        settings.completeOnboarding()
        let original = settings.remoteDeviceProfiles
        SettingsPageBehavior.beginDeviceSetup(settings: settings)
        #expect(settings.onboardingStep == .remoteAvailability)
        #expect(settings.onboardingPurpose == .addDevice)
        #expect(settings.canDismissOnboarding)
        #expect(!settings.isOnboardingComplete)
        #expect(settings.onboardingDevice == nil)
        #expect(settings.onboardingVoiceTool == .voicecursor)
        #expect(settings.voiceKeyMode == .leftCommand)
        #expect(settings.remoteDeviceProfiles == original)
    }
}
