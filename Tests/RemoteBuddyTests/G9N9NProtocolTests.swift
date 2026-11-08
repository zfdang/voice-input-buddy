import Foundation
import CoreBluetooth
import IOKit.hid
import Testing
@testable import RemoteBuddy

@Suite("G9N9N public transports")
struct G9N9NProtocolTests {
    @Test(arguments: [(true, false), (false, true), (true, true)])
    func hidMatchingExcludesUnrelatedDevices(options: (Bool, Bool)) throws {
        let (xiaomi, google) = options
        let matches = HIDRemoteMonitor.deviceMatchingCriteria(includeXiaomi: xiaomi, includeGoogle: google)
        var allowed: Set<String> = []
        if xiaomi { allowed.insert("10007:12984") }
        if google { allowed.insert("\(G9N9NProtocol.vendorID):\(G9N9NProtocol.productID)") }
        #expect(matches.count == allowed.count)
        for match in matches {
            // Every OR clause needs identifiers: IOKit ignores a Product-only
            // clause and would then enumerate all keyboards, mice and headsets.
            let vendor = try #require(match[kIOHIDVendorIDKey] as? Int)
            let product = try #require(match[kIOHIDProductIDKey] as? Int)
            #expect(allowed.contains("\(vendor):\(product)"))
        }
        // Exercise native matching semantics without opening/seizing a device
        // or requesting Input Monitoring permission. Empty results are valid.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] {
            let vendor = try #require(IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)
            let product = try #require(IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)
            #expect(allowed.contains("\(vendor.intValue):\(product.intValue)"))
        }
    }

    @Test func multipleConsumerUsagesAndPaddingRemainOneAtomicReport() {
        let expected: Set<UInt16> = [RemoteButton.up.hidUsage, RemoteButton.volumeUp.hidUsage]
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0x42, 0, 0xe9, 0, 0, 0])) == expected)
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([2, 0x42, 0, 0xe9, 0])) == expected)
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0, 0, 0, 0])) == [])
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0x42, 0, 0xff, 0xff])) == [RemoteButton.up.hidUsage])
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0x42, 0, 0xe9])) == nil)
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data()) == nil)
    }

    @Test @MainActor func unknownUsageDoesNotLoseTheReleaseOfAKnownButton() throws {
        let name = "google-unknown-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let monitor = HIDRemoteMonitor(settings: settings, profileID: UUID(),
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "google", profileID: UUID())
        var active: Set<RemoteButton> = []
        monitor.onActiveButtons = { _, buttons in active = buttons }
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x42, 0, 0xff, 0xff]))
        #expect(active == [.up])
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0xff, 0xff]))
        #expect(active.isEmpty)
        monitor.disconnectSimulatedDevice()
    }

    @Test func noRemoteFamiliesProduceNoMatchingRequest() {
        #expect(HIDRemoteMonitor.deviceMatchingCriteria(includeXiaomi: false, includeGoogle: false).isEmpty)
    }

    private func capabilities(_ bytes: [UInt8] = [0x0B, 1, 0, 2, 3, 0, 120]) throws -> ATVVCapabilities {
        try #require(ATVVCapabilities.parse(Data(bytes), allowingLegacyLayout: false))
    }

    @Test func discoveryDoesNotAdoptEveryAtvvDeviceOrTheStreamerModel() {
        let id = UUID()
        #expect(!VoiceRemoteAdmission.decide(identifier: id, targetIdentifier: nil,
            advertisesVoiceService: true, name: "Chromecast Remote", advertisedName: nil).isAdopted)
        #expect(VoiceRemoteAdmission.decide(identifier: id, targetIdentifier: nil,
            advertisesVoiceService: true, name: "Chromecast Remote", advertisedName: nil,
            allowsG9N9N: true).isAdopted)
        for name in ["RemoteG10", "GY3LE", "Google TV Streamer", "Unrelated microphone"] {
            #expect(!VoiceRemoteAdmission.decide(identifier: id, targetIdentifier: nil,
                advertisesVoiceService: true, name: name, advertisedName: nil,
                allowsG9N9N: true).isAdopted)
        }
    }

    @Test func identityAndAudioDiscoveryCanFinishInEitherOrder() throws {
        let caps = try capabilities()
        var audioFirst = G9N9NReadiness()
        let accepted1 = audioFirst.acceptCapabilities(caps)
        #expect(accepted1)
        #expect(!audioFirst.isReady)
        let accepted2 = audioFirst.acceptIdentity(.xiaomi)
        #expect(!accepted2)
        #expect(!audioFirst.isReady)
        let accepted3 = audioFirst.acceptIdentity(.chromecast)
        #expect(accepted3)
        #expect(audioFirst.isReady)
        var identityFirst = G9N9NReadiness()
        let accepted4 = identityFirst.acceptIdentity(.chromecast)
        #expect(accepted4)
        #expect(!identityFirst.isReady)
        let accepted5 = identityFirst.acceptCapabilities(caps)
        #expect(accepted5)
        #expect(identityFirst.isReady)
        identityFirst = G9N9NReadiness()
        #expect(!identityFirst.isReady)
    }

    @Test func capturedChromecastCapabilitiesRequireGoogleIdentityWithoutAModelString() throws {
        let captured = try capabilities([0x0B, 1, 0, 2, 3, 0, 0xF0, 1, 0, 0x1A])
        #expect(captured.version == 0x0100)
        #expect(captured.frameSize == 240)
        #expect(captured.sampleRate == 16_000)
        #expect(captured.interaction == 3)
        let pnp = try #require(RemoteHIDIdentity.fromPnP(Data([1, 0xD1, 0x18, 0x50, 0x94, 0x10, 1])))
        var readiness = G9N9NReadiness()
        let audioAccepted = readiness.acceptCapabilities(captured)
        #expect(audioAccepted)
        #expect(!readiness.isReady)
        let missingIdentityAccepted = readiness.acceptIdentity(nil)
        #expect(!missingIdentityAccepted)
        let wrongIdentityAccepted = readiness.acceptIdentity(RemoteHIDIdentity(vendorID: 0x18D1, productID: 0x1234))
        #expect(!wrongIdentityAccepted)
        #expect(!readiness.isReady)
        let identityAccepted = readiness.acceptIdentity(pnp)
        #expect(identityAccepted)
        #expect(readiness.isReady)
    }

    @Test func replacementWithNo16kCodecOrBadFrameSizeCannotBecomeReady() throws {
        for bytes: [UInt8] in [
            [0x0B, 1, 0, 0, 3, 0, 120, 0, 0], // no codecs: must not borrow the interaction bits
            [0x0B, 1, 0, 1, 3, 0, 120],        // 8 kHz only
            [0x0B, 0, 4, 2, 0, 0, 120, 0, 0], // unsupported protocol revision
            [0x0B, 1, 0, 2, 3, 2, 1],          // unbounded frame size
        ] {
            var readiness = G9N9NReadiness()
            let accepted6 = readiness.acceptIdentity(.chromecast)
            #expect(accepted6)
            let accepted7 = readiness.acceptCapabilities(try capabilities(bytes))
            #expect(!accepted7)
            #expect(!readiness.isReady)
        }
    }

    @Test func consumerReportsKeepGoogleCodesSeparateFromXiaomi() {
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([2, 0x42, 0])) == [RemoteButton.up.hidUsage])
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0x77, 0])) == [RemoteButton.youtube.hidUsage])
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([2, 0, 0])) == [])
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([0x42, 0])) == nil)
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([3, 0x42, 0])) == nil)
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0xff, 0xff])) == [])
        #expect(RemoteHIDReportParser.usages(reportID: 2, data: Data([2, 0x42, 0])) == nil)
        #expect(Set(G9N9NMappingLayout.placements.map(\.button)) == Set(G9N9NProtocol.consumerButtons.values))
    }

    @Test func capturedIndexedDescriptorDecodesButtonsAndRejectsAmbiguousReports() {
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        let expected: [(UInt8, RemoteButton)] = [
            (1, .power), (3, .up), (4, .down), (5, .left), (6, .right),
            (7, .ok), (8, .mute), (10, .home), (11, .back),
            (12, .volumeUp), (13, .volumeDown), (14, .youtube), (15, .netflix), (17, .input),
        ]
        for (index, button) in expected {
            #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, index, 0]), descriptor: descriptor) == [button.hidUsage])
            #expect(G9N9NProtocol.usages(reportID: 1, data: Data([index, 0]), descriptor: descriptor) == [button.hidUsage])
        }
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 3, 12]), descriptor: descriptor) == [RemoteButton.up.hidUsage, RemoteButton.volumeUp.hidUsage])
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 0, 0]), descriptor: descriptor) == [])
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 3, 2]), descriptor: descriptor) == [RemoteButton.up.hidUsage])
        for payload: [UInt8] in [[1], [1, 3, 0, 0], [2, 3, 0], [1, 3, 18]] {
            #expect(G9N9NProtocol.usages(reportID: 1, data: Data(payload), descriptor: descriptor) == nil)
        }
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0x42, 0]), descriptor: descriptor) == nil)
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 3, 0])) == nil)
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 3, 0]), descriptor: Data([0])) == nil)
    }

    @Test func compatibleDescriptorWithVendorCollectionDecodesIndexedReports() {
        // Captured from a compatible unit (VID 18D1, PID 9450, version 0x0110).
        let vendorCollection = Data([
            0x06, 0x01, 0xff, 0x09, 0x01, 0xa1, 0x02, 0x85, 0x08, 0x09, 0x14,
            0x75, 0x08, 0x95, 0x14, 0x15, 0x80, 0x25, 0x7f, 0x81, 0x22,
            0x85, 0x04, 0x09, 0x04, 0x75, 0x08, 0x95, 0x01, 0x91, 0x02, 0xc0,
        ])
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor + vendorCollection
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 7, 0]), descriptor: descriptor) == [RemoteButton.ok.hidUsage])
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 11, 0]), descriptor: descriptor) == [RemoteButton.back.hidUsage])
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([1, 0, 0]), descriptor: descriptor) == [])
        #expect(G9N9NProtocol.usages(reportID: 8, data: Data(repeating: 0, count: 20), descriptor: descriptor) == nil)
        #expect(!G9N9NProtocol.usesIndexedConsumerLayout(G9N9NProtocol.indexedConsumerDescriptor.dropLast()))
    }

    @Test @MainActor func indexedReportsDrivePressAndReleaseWithoutStuckButtons() throws {
        let name = "google-indexed-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let monitor = HIDRemoteMonitor(settings: settings, profileID: UUID(),
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "indexed-google", profileID: UUID())
        var active = Set<RemoteButton>()
        monitor.onActiveButtons = { _, buttons in active = buttons }
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 3, 0]), descriptor: descriptor)
        #expect(active == [.up])
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 18, 0]), descriptor: descriptor)
        #expect(active == [.up])
        monitor.handleSimulatedGoogleReport(reportID: 1, data: Data([1, 0, 0]), descriptor: descriptor)
        #expect(active.isEmpty)
        monitor.disconnectSimulatedDevice()
    }

    @Test func everyDocumentedConsumerButtonMapsWithAndWithoutReportPrefix() {
        let expected: [(UInt16, RemoteButton)] = [
            (0x42, .up), (0x43, .down), (0x44, .left), (0x45, .right),
            (0x41, .ok), (0x224, .back), (0x223, .home),
            (0xE9, .volumeUp), (0xEA, .volumeDown), (0xE2, .mute),
            (0x77, .youtube), (0x78, .netflix), (0x189, .input), (0x19E, .power),
        ]
        for (usage, button) in expected {
            let payload = [UInt8(usage & 0xff), UInt8(usage >> 8)]
            #expect(G9N9NProtocol.usages(reportID: 2, data: Data(payload)) == [button.hidUsage])
            #expect(G9N9NProtocol.usages(reportID: 2, data: Data([2] + payload)) == [button.hidUsage])
        }
    }

    @Test func headerlessAudioPreservesDecoderStateAcrossFragmentedFrames() throws {
        let caps = try capabilities()
        let decoder = IMAADPCMDecoder()
        var accumulator = FrameAccumulator()
        // A synthetic, independently predictable IMA stream: each 0x11 byte
        // produces two increments of one at step index zero, high nibble first.
        #expect(accumulator.append(Data(repeating: 0x11, count: 17), frameSize: caps.frameSize).isEmpty)
        let frames = accumulator.append(Data(repeating: 0x11, count: 223), frameSize: caps.frameSize)
        #expect(frames.count == 2)
        #expect(decoder.decode(frames[0]) == (1...240).map(Int16.init))
        #expect(decoder.decode(frames[1]) == (241...480).map(Int16.init))
        #expect(accumulator.pending.isEmpty)
        #expect(caps.sampleRate == 16_000)
    }

    @Test func synchronizationAndSessionResetDoNotLeakAudioState() throws {
        let caps = try capabilities()
        let decoder = IMAADPCMDecoder()
        var accumulator = FrameAccumulator()
        _ = accumulator.append(Data(repeating: 0x7F, count: 13), frameSize: caps.frameSize)
        // The production bridge discards an incomplete frame on AUDIO_SYNC.
        accumulator.reset()
        decoder.reset(predictor: -1000, stepIndex: 0)
        let frames = accumulator.append(Data(repeating: 0x11, count: 120), frameSize: caps.frameSize)
        #expect(decoder.decode(frames[0]) == (-999 ... -760).map(Int16.init))
        accumulator.reset()
        decoder.reset()
        #expect(decoder.decode(Data([0x7F])) == [11, -19])
        #expect(accumulator.pending.isEmpty)
    }

    @Test @MainActor func googlePressAndReleaseUseMappingsAndMalformedReportsDoNotReleaseKeys() throws {
        let name = "g9n9n-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.commandQuit, for: .youtube)
        var invoked: [RemoteButton] = []
        var active = Set<RemoteButton>()
        let monitor = HIDRemoteMonitor(settings: settings, runtimePermissions: { true },
            actionPerformer: { button, _, _ in invoked.append(button); return true }, diagnosticLogger: { _ in })
        monitor.connectSimulatedDevice(fingerprint: "g9n9n", profileID: UUID())
        monitor.onActiveButtons = { _, buttons in active = buttons }
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([2, 0x77, 0]))
        #expect(active == [.youtube])
        #expect(invoked == [.youtube])
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([0x42]))
        #expect(active == [.youtube])
        monitor.handleSimulatedGoogleReport(reportID: 2, data: Data([2, 0, 0]))
        #expect(active.isEmpty)
        monitor.disconnectSimulatedDevice()
    }

    @Test @MainActor func googleBluetoothAndHidProfilesMergeWithinTheirFamily() throws {
        let name = "g9n9n-profiles-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomi = settings.registerBluetoothRemote(identifier: UUID(), model: .rc003)
        settings.selectRemoteProfile(xiaomi)
        let google = try #require(settings.registerHIDRemote(fingerprint: "g9n9n", model: .chromecastVoiceRemote))
        #expect(google != xiaomi)
        let bluetooth = UUID()
        #expect(settings.registerBluetoothRemote(identifier: bluetooth, model: .chromecastVoiceRemote) == google)
        #expect(settings.remoteDeviceProfiles.first { $0.id == google }?.bluetoothIdentifier == bluetooth)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.connectedRemoteProfileIDs = [google]
        #expect(model.isOnboardingControlSourceConnected(.chromecastRemote))
        #expect(!model.isOnboardingControlSourceConnected(.xiaomiRemote))
    }

    @Test @MainActor func googleHidIdentityWinsOverAnEmptyPlaceholderAndAmbiguityIsNotGuessed() throws {
        let name = "g9n9n-identity-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let hid = settings.registerHIDRemote(fingerprint: "first-google", model: .chromecastVoiceRemote)
        #expect(settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote) == hid)
        let second = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let third = settings.registerBluetoothRemote(identifier: UUID(), model: .chromecastVoiceRemote)
        let ambiguousHid = settings.registerHIDRemote(fingerprint: "unknown-google", model: .chromecastVoiceRemote)
        #expect(ambiguousHid != second && ambiguousHid != third)
        #expect(settings.remoteDeviceProfiles.first { $0.id == ambiguousHid }?.bluetoothIdentifier == nil)
    }

    @Test @MainActor func xiaomiAudioCannotPassGoogleOnboardingAfterADevicePickerChange() throws {
        let name = "g9n9n-source-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let xiaomiID = UUID()
        _ = settings.registerBluetoothRemote(identifier: xiaomiID, model: .rc003)
        let googleID = UUID()
        let google = settings.registerBluetoothRemote(identifier: googleID, model: .chromecastVoiceRemote)
        settings.selectRemoteProfile(google)
        settings.setOnboardingControlSource(.chromecastRemote)
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])
        model.voiceSession.isActive = true
        model.voiceSession.activeDeviceIdentifier = xiaomiID
        let view = OnboardingView(model: model)
        #expect(!view.selectedControlAcceptsVoice(.bluetoothRemote))
        model.voiceSession.activeDeviceIdentifier = googleID
        #expect(view.selectedControlAcceptsVoice(.bluetoothRemote))
        model.voiceSession.isActive = false
        model.voiceSession.activeDeviceIdentifier = nil
    }

    @Test func authenticationFailureIsNotProofOfAnAbsentVoiceService() {
        #expect(G9N9NProtocol.requiresPairing(NSError(domain: CBATTErrorDomain,
            code: CBATTError.insufficientAuthentication.rawValue)))
        #expect(!G9N9NProtocol.requiresPairing(NSError(domain: CBATTErrorDomain,
            code: CBATTError.attributeNotFound.rawValue)))
    }

    @Test func atvvDrivenVoiceUsesSoftwareShortcutRatherThanXiaomiFnMapping() {
        #expect(BridgeAppModel.canStartBluetoothVoice(mode: .function, voiceFnTapModeEnabled: true,
            isVoiceKeyNeutralized: false, hasHardwareVoiceKey: false, accessibilityGranted: true))
        #expect(!BridgeAppModel.canStartBluetoothVoice(mode: .function,
            isVoiceKeyNeutralized: false, hasHardwareVoiceKey: false, accessibilityGranted: false))
        #expect(!BridgeAppModel.canStartBluetoothVoice(mode: .function, voiceFnTapModeEnabled: true,
            isVoiceKeyNeutralized: false, hasHardwareVoiceKey: true, accessibilityGranted: true))
    }
}
