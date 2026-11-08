import AppKit
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Session recovery")
@MainActor
struct SessionRecoveryTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "session-recovery-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func disabledSessionCompletesCleanupWithoutWaitingForLostRemoteStop() {
        let scheduler = ControlledTestScheduler()
        var completions = 0
        let session = VoiceFnTapSessionController(startDelay: 0,
            schedule: { delay, action in
                let task = scheduler.schedule(afterMilliseconds: UInt64(delay * 1000), repeatingEveryMilliseconds: nil, action)
                return ScheduledOperation(cancellation: { task.cancel() })
            }, setFunctionKeyPressed: { _ in true }, enqueueAudio: { _ in },
            drainAudio: { _, completion in completion() }, onFailure: { _ in })
        session.setEnabled(true)
        #expect(session.startVoice())
        scheduler.runNext()
        scheduler.runNext()
        session.setEnabled(false) { _ in completions += 1 }
        scheduler.runAll()
        #expect(completions == 1)
        #expect(!session.requiresCleanupBeforeMapping)
        #expect(session.receive([1, 2])) // Quarantine late audio from the old held press.
        session.shutdown()
        #expect(!session.receive([1, 2]))
        #expect(completions == 1)
    }

    @Test func aShorterJoiningDrainCannotCutOffTheOriginalTail() {
        let clock = ControlledTestScheduler()
        let output = VirtualAudioOutput(logger: { _ in }, uptime: { Double(clock.now) / 1_000 },
            scheduleDrainDeadline: clock.voiceSchedule)
        output.registerPendingVoiceBuffer()
        var outcomes: [VirtualAudioDrainOutcome] = []
        output.endSessionAfterDraining(maximumDelay: 2) { outcomes.append($0) }
        output.endSessionAfterDraining(maximumDelay: 0.75) { outcomes.append($0) }
        clock.advance(to: 750)
        #expect(outcomes.isEmpty)
        clock.advance(to: 2_000)
        #expect(outcomes == [.forced, .forced])
    }

    @Test func joiningAnUnlimitedDrainDoesNotArmAShorterDeadline() {
        let clock = ControlledTestScheduler()
        let output = VirtualAudioOutput(logger: { _ in }, uptime: { Double(clock.now) / 1_000 },
            scheduleDrainDeadline: clock.voiceSchedule)
        output.registerPendingVoiceBuffer()
        var outcomes: [VirtualAudioDrainOutcome] = []
        output.endSessionAfterDraining(maximumDelay: nil) { outcomes.append($0) }
        output.endSessionAfterDraining(maximumDelay: 0.75) { outcomes.append($0) }
        clock.advance(to: 10_000)
        #expect(outcomes.isEmpty)
        output.cancelPendingDrain()
        #expect(outcomes == [.forced, .forced])
    }

    @Test func cancelledDrainAnswersExactlyOnceEvenAfterDeadline() {
        let clock = ControlledTestScheduler()
        let output = VirtualAudioOutput(logger: { _ in }, scheduleDrainDeadline: clock.voiceSchedule)
        output.registerPendingVoiceBuffer()
        var outcomes: [VirtualAudioDrainOutcome] = []
        output.endSessionAfterDraining(maximumDelay: 0.02) { (outcome: VirtualAudioDrainOutcome) in outcomes.append(outcome) }
        output.cancelPendingDrain()
        output.cancelPendingDrain()
        #expect(outcomes == [.forced])
        clock.advance(to: 20)
        #expect(outcomes == [.forced])
    }

    @Test func destroyedOutputAnswersOutstandingDrain() {
        var output: VirtualAudioOutput? = VirtualAudioOutput(logger: { _ in })
        weak let observed = output
        output!.registerPendingVoiceBuffer()
        var outcomes: [VirtualAudioDrainOutcome] = []
        output!.endSessionAfterDraining(maximumDelay: nil) { (outcome: VirtualAudioDrainOutcome) in outcomes.append(outcome) }
        output = nil
        #expect(observed == nil)
        #expect(outcomes == [.forced])
    }

    @Test func rejectionOnlyClearsItsOwnPendingAudio() {
        let pending = BluetoothPendingAudioStart()
        let owner = UUID()
        pending.begin(for: owner)
        let accepted = pending.audio.appendIfWaiting([1, 2, 3])
        #expect(accepted)
        #expect(!pending.cancel(ifOwnedBy: UUID()))
        #expect(pending.identifier == owner)
        #expect(pending.cancel(ifOwnedBy: owner))
        #expect(pending.identifier == nil)
        let laterAccepted = pending.audio.appendIfWaiting([4])
        let drained = pending.audio.drain()
        #expect(!laterAccepted)
        #expect(drained.isEmpty)
    }

    @Test func acknowledgedWritesSerializeAndDropFailedBacklog() {
        let scheduler = ControlledTestScheduler()
        var sent: [Data] = []
        var failures = 0
        let queue = AcknowledgedBluetoothWriteQueue(scheduler: scheduler, send: { sent.append($0) }, onFailure: { failures += 1 })
        #expect(queue.enqueue(Data([1])))
        #expect(queue.enqueue(Data([2])))
        #expect(queue.enqueue(Data([3])))
        #expect(sent == [Data([1])])
        queue.acknowledge(success: true)
        #expect(sent == [Data([1]), Data([2])])
        queue.acknowledge(success: false)
        scheduler.runAll()
        #expect(failures == 1)
        #expect(sent.count == 2)
        #expect(queue.enqueue(Data([4])))
        queue.reset()
        scheduler.runAll()
        #expect(failures == 1)
    }

    @Test func writeTimeoutIsFiniteAndQueueCapacityIsBounded() {
        let scheduler = ControlledTestScheduler()
        var failures = 0
        var sent = 0
        let queue = AcknowledgedBluetoothWriteQueue(scheduler: scheduler, send: { _ in sent += 1 }, onFailure: { failures += 1 })
        for _ in 0..<32 { #expect(queue.enqueue(Data([1]))) }
        #expect(!queue.enqueue(Data([2])))
        #expect(sent == 1)
        scheduler.runNext()
        #expect(failures == 1)
        #expect(queue.enqueue(Data([3])))
        queue.acknowledge(success: true)
        scheduler.runAll()
        #expect(failures == 1)
    }

    @Test func bootFallbackIsStableAndNeverUsesOneCrossBootSentinel() {
        #expect(RemoteHIDKeyMapper.bootIdentity(uuid: "uuid", bootTime: nil) == "uuid")
        let first = RemoteHIDKeyMapper.bootIdentity(uuid: nil, bootTime: (100, 12))
        #expect(first == RemoteHIDKeyMapper.bootIdentity(uuid: nil, bootTime: (100, 12)))
        #expect(first != RemoteHIDKeyMapper.bootIdentity(uuid: nil, bootTime: (200, 12)))
        #expect(RemoteHIDKeyMapper.bootIdentity(uuid: nil, bootTime: nil) == nil)
    }

    @Test func recoveryJournalIsAtomicAndFailurePreventsSystemWrite() throws {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let original = HIDUsageMapping(source: RemoteHIDKeyMappingPolicy.remoteVoiceKey.source, destination: 99)
        var mappings = [original]
        var writes = 0
        let services = { [RemoteHIDMappingService(registryID: 1, readMappings: { mappings }, setMappings: { mappings = $0; writes += 1; return true })] }
        let first = RemoteHIDKeyMapper(serviceProvider: services, recoveryDefaults: values, bootID: "boot", recoveryJournalURL: url)
        #expect(first.apply())
        #expect(FileManager.default.fileExists(atPath: url.path))
        values.removePersistentDomain(forName: name)
        let restarted = RemoteHIDKeyMapper(serviceProvider: services, recoveryDefaults: values, bootID: "boot", recoveryJournalURL: url)
        restarted.restore()
        #expect(mappings == [original])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try Data([0]).write(to: directory.appendingPathComponent("file"))
        let invalid = directory.appendingPathComponent("file/journal.json")
        let failing = RemoteHIDKeyMapper(serviceProvider: services, recoveryDefaults: values, bootID: "boot", recoveryJournalURL: invalid)
        let before = writes
        #expect(!failing.apply())
        #expect(writes == before)
        let unknownBoot = RemoteHIDKeyMapper(serviceProvider: services, recoveryDefaults: values, bootID: nil, recoveryJournalURL: url)
        #expect(!unknownBoot.apply())
        #expect(writes == before)
    }

    @Test func partialImportPreservesApplicationLibraryButReplacesMappingOverrides() throws {
        let (values, name) = defaults()
        defer { values.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: values)
        let profile = CustomApplicationProfile(displayName: "Example", bundleIdentifier: "example.test", applicationPath: "/Applications/Example.app")
        _ = settings.addCustomApplicationProfile(profile)
        let binding = UnifiedButtonBinding(remoteProfileID: nil, button: .left, trigger: .singleClick,
            configured: .init(action: .arrowLeft, shortcut: nil))
        settings.unifiedBaseBindings = [binding]
        var object = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        object.removeValue(forKey: "customApplicationProfiles")
        object.removeValue(forKey: "unifiedBaseBindings")
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.customApplicationProfiles == [profile])
        #expect(settings.unifiedBaseBindings.isEmpty)
        object["customApplicationProfiles"] = []
        object["unifiedBaseBindings"] = []
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.customApplicationProfiles.isEmpty)
        #expect(settings.unifiedBaseBindings.isEmpty)
    }



    @Test func environmentDiagnosticsStillCheckPermissions() {
        let context = FirstUseDiagnosticContext(step: .permissions, capabilities: .init(), hasSelectedAudioUID: false)
        #expect(context.failureReason == .bluetoothPermissionDenied)
    }


}
