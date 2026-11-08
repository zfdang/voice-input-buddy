import AppKit
import Testing
@testable import RemoteBuddy

@Suite("Standalone modifier cleanup")
@MainActor
struct StandaloneModifierRecoveryTests {
    @Test func failedReleaseRecoversAsynchronouslyAndBlocksAnotherPress() {
        let clock = ControlledTestScheduler()
        let recovery = StandaloneModifierReleaseRecovery(schedule: clock.voiceSchedule)
        var edges: [Bool] = []
        var permitsRelease = false
        let post: KeyboardInjector.KeyStatePoster = { _, down, _ in
            edges.append(down)
            return down || permitsRelease
        }
        #expect(!KeyboardInjector.send(.customShortcut, shortcut: StandaloneKeyboardModifier.leftCommand.shortcut,
            accessibilityTrusted: { true }, secureInputEnabled: { false }, keyStatePoster: post,
            modifierReleaseRecovery: recovery))
        #expect(!recovery.permitsPress(55))
        #expect(edges.filter { $0 }.count == 1)
        permitsRelease = true
        clock.runAll()
        #expect(recovery.permitsPress(55))
        #expect(edges.filter { $0 }.count == 1)
    }
}
