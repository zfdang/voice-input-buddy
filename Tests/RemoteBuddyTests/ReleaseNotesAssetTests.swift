import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Update feed descriptions")
struct ReleaseNotesAssetTests {
    @MainActor @Test func updateDetailsComeFromTheFeedWithoutSeparateAssets() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UpdateInformationStore(userDefaults: defaults)
        store.setAvailable(displayVersion: "v26-10-12.043", buildVersion: "43",
                           fallbackDescription: "- Updates app and driver.\n- Administrator authorization required.")
        guard case .available(let details) = store.state else {
            Issue.record("Expected available update"); return
        }
        #expect(details.releaseNotes == ["Updates app and driver.", "Administrator authorization required."])
        #expect(store.hasUnseenUpdate)
        store.markAvailableUpdateSeen()
        #expect(!store.hasUnseenUpdate)
        store.reset()
        #expect(store.state == .idle)
    }
}
