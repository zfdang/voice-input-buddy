import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Application instance file lock")
struct InstanceLockTests {
    private func run(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func heldLockRejectsSecondAcquisitionAndReleaseAllowsNext() throws {
        try run { directory in
            let path = directory.appendingPathComponent("instance.lock")
            var held: ApplicationInstanceLock?
            if case let .acquired(lock) = ApplicationInstanceLock.acquire(at: path) { held = lock }
            #expect(held != nil)
            let heldContent = try String(contentsOf: path, encoding: .utf8)
            #expect(heldContent.trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())")
            if case .alreadyLocked = ApplicationInstanceLock.acquire(at: path) {} else {
                Issue.record("A second descriptor must not acquire the held lock")
            }
            held = nil
            guard case let .acquired(next) = ApplicationInstanceLock.acquire(at: path) else {
                Issue.record("A released lock must be available"); return
            }
            let nextContent = try String(contentsOf: path, encoding: .utf8)
            #expect(nextContent.trimmingCharacters(in: .whitespacesAndNewlines) == "\(getpid())")
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            withExtendedLifetime(next) {}
        }
    }

    @Test func launchRetriesAfterAnExitingInstanceReleasesItsLock() throws {
        try run { directory in
            let path = directory.appendingPathComponent("instance.lock")
            var held: ApplicationInstanceLock?
            if case let .acquired(lock) = ApplicationInstanceLock.acquire(at: path) { held = lock }
            var pauses = 0
            let result = ApplicationInstanceLock.acquireForLaunch(at: path,
                existingInstanceIsRunning: { false }, pause: { pauses += 1; if pauses == 4 { held = nil } })
            guard case .acquired = result else { Issue.record("Relaunch must acquire the released lock"); return }
            #expect(pauses == 4)
            withExtendedLifetime(held) {}
        }
    }

    @Test func liveInstanceDoesNotWaitAndMissingInstanceHasBoundedRetries() throws {
        try run { directory in
            let path = directory.appendingPathComponent("instance.lock")
            guard case let .acquired(lock) = ApplicationInstanceLock.acquire(at: path) else { return }
            var pauses = 0
            for running in [true, false] {
                let result = ApplicationInstanceLock.acquireForLaunch(at: path,
                    existingInstanceIsRunning: { running }, pause: { pauses += 1 })
                guard case .alreadyLocked = result else { Issue.record("Must not bypass a held lock"); return }
            }
            #expect(pauses == 8)
            withExtendedLifetime(lock) {}
        }
    }

    @Test func symlinkLockIsRefusedWithoutChangingTarget() throws {
        try run { directory in
            let target = directory.appendingPathComponent("unrelated")
            let link = directory.appendingPathComponent("instance.lock")
            try Data("untouched".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            if case .failed = ApplicationInstanceLock.acquire(at: link) {} else {
                Issue.record("Lock acquisition must refuse a symlink")
            }
            #expect(try Data(contentsOf: target) == Data("untouched".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        }
    }

    @Test func invalidParentReportsFailureInsteadOfLockingOrChangingFile() throws {
        try run { directory in
            let parent = directory.appendingPathComponent("file")
            try Data("original".utf8).write(to: parent)
            if case .failed = ApplicationInstanceLock.acquire(at: parent.appendingPathComponent("instance.lock")) {} else {
                Issue.record("A non-directory parent must fail")
            }
            #expect(try Data(contentsOf: parent) == Data("original".utf8))
        }
    }
}
