import Foundation
import Testing
@testable import RemoteBuddy

#if DEBUG
@Suite("Development resource discovery")
struct DevelopmentResourceTests {
    @Test func nestedFeatureFilesResolveResourcesAtAnyDepth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        for location in ["Sources/RemoteBuddy/Localization.swift",
                         "Sources/RemoteBuddy/Support/Localization.swift",
                         "Sources/RemoteBuddy/Features/Support/Nested/Localization.swift"] {
            #expect(RemoteBuddyResourceBundle.developmentResourceRoot(
                from: root.appendingPathComponent(location)) == resources)
        }
    }

    @Test func missingPackageOrResourcesDoesNotAdoptUnrelatedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Sources/Feature/File.swift")
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        #expect(RemoteBuddyResourceBundle.developmentResourceRoot(from: source) == nil)
        // A file named Resources is not a resource directory.
        try Data().write(to: root.appendingPathComponent("Resources"))
        #expect(RemoteBuddyResourceBundle.developmentResourceRoot(from: source) == nil)
    }
}
#endif
