import AudioExceptionFixtures
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Audio engine exception boundary")
struct AudioEngineExceptionTests {
    @Test func catchesCppExceptionsAtTheAudioBoundary() {
        #expect(AudioFixtureCatchesCppException())
    }

    @Test func catchesObjectiveCExceptionsAndPreservesSwiftErrors() {
        #expect(throws: AudioEngineSafety.Failure.self) {
            try AudioEngineSafety.perform {
                NSException(name: .invalidArgumentException, reason: "Simulated device format change").raise()
            }
        }
        enum StartFailure: Error { case unavailable }
        #expect(throws: StartFailure.self) {
            try AudioEngineSafety.perform { throw StartFailure.unavailable }
        }
        var completed = false
        #expect(throws: Never.self) { try AudioEngineSafety.perform { completed = true } }
        #expect(completed)
    }
}
