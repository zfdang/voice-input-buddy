import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Remote device information")
struct RemoteDeviceInformationTests {
    @Test func missingReadingsDoNotAdvertiseDefaultIdentityOrAudio() {
        let information = RemoteDeviceInformation()
        #expect(information.modelNumber == nil)
        #expect(information.firmwareRevision == nil)
        #expect(information.identityValue == nil)
        #expect(information.audioFormat == nil)
        #expect(information.protocolVersion == nil)
    }

    @Test func decodesOptionalBluetoothStringsWithoutPadding() {
        #expect(RemoteDeviceInformation.deviceString(Data(" RC003\0\r\n".utf8)) == "RC003")
        #expect(RemoteDeviceInformation.deviceString(Data("\0 \n".utf8)) == nil)
        #expect(RemoteDeviceInformation.deviceString(Data([0xFF])) == nil)
    }

    @Test func displaysReportedIdentityAndNegotiatedAudio() throws {
        let identity = try #require(RemoteHIDIdentity.fromPnP(Data([2, 0xD1, 0x18, 0x50, 0x94, 0, 0])))
        let capabilities = try #require(ATVVCapabilities.parse(Data([0x0B, 1, 0, 2, 3, 0, 120])))
        let information = RemoteDeviceInformation(identity: identity, capabilities: capabilities)
        #expect(information.identityValue == "18D1 / 9450")
        #expect(information.protocolVersion == "ATVV 1.0")
        #expect(information.capabilities?.frameSize == 120)
        #expect(information.audioFormat == "16 kHz · IMA ADPCM")
    }

    @Test func retainsActualEightKilohertzReading() throws {
        let capabilities = try #require(ATVVCapabilities.parse(Data([0x0B, 1, 0, 1, 3, 0, 134])))
        let information = RemoteDeviceInformation(capabilities: capabilities)
        #expect(information.audioFormat == "8 kHz · IMA ADPCM")
    }
}
