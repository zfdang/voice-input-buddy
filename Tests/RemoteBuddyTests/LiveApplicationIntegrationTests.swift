import AppKit
import ApplicationServices
import Testing
@testable import RemoteBuddy

// Explicit local acceptance probe: moves focus in the installed WorkBuddy app.
// Never runs in the normal suite or CI, and never inserts/submits text.
@Suite("Live application focus", .enabled(if: ProcessInfo.processInfo.environment["REMOTE_BUDDY_LIVE_FOCUS_TESTS"] == "1"))
struct LiveApplicationIntegrationTests {
    @Test @MainActor func measureInstalledComposerScans() throws {
        try #require(KeyboardInjector.isAccessibilityTrusted)
        for integration in ApplicationIntegration.allCases {
            guard let run = NSRunningApplication.runningApplications(withBundleIdentifier: integration.bundleIdentifier).first else { continue }
            let app = AXUIElementCreateApplication(run.processIdentifier)
            _ = KeyboardInjector.axAttribute(app, attribute: kAXRoleAttribute)
            guard let reference = KeyboardInjector.axAttribute(app, attribute: kAXFocusedWindowAttribute),
                  CFGetTypeID(reference) == AXUIElementGetTypeID() else { continue }
            let window = reference as! AXUIElement
            for iteration in 1...3 {
                let started = ProcessInfo.processInfo.systemUptime
                var nodes = 0
                var truncated = false
                let candidates = KeyboardInjector.accessibilityTextCandidates(in: window, integration: integration,
                    didScan: { nodes = $0; truncated = $1 })
                let matches = candidates.filter {
                    KeyboardInjector.integratedComposerScore($0.snapshot, integration: integration,
                        windowFrame: KeyboardInjector.axFrame(window)) != nil
                }.count
                print("LIVE SCAN app=\(integration.rawValue) iteration=\(iteration) ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) nodes=\(nodes) candidates=\(candidates.count) matches=\(matches) truncated=\(truncated)")
            }
        }
    }

    @Test @MainActor func workBuddyReturnsFromToolbarToComposer() async throws {
        try #require(KeyboardInjector.isAccessibilityTrusted)
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: []) }
        for integration in [ApplicationIntegration.workBuddy] {
            let run = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: integration.bundleIdentifier).first)
            run.activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(1500))
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == run.processIdentifier)
            let app = AXUIElementCreateApplication(run.processIdentifier)
            _ = KeyboardInjector.axAttribute(app, attribute: kAXRoleAttribute)
            var pending = [app]
            var button: AXUIElement?
            var budget = AccessibilityTraversalBudget(maximumNodes: 5_000, maximumDuration: 2)
            while let element = pending.popLast(), budget.admitNode() {
                let role = KeyboardInjector.axAttribute(element, attribute: kAXRoleAttribute) as? String ?? ""
                if role == "AXPopUpButton",
                   KeyboardInjector.axAttribute(element, attribute: kAXDescriptionAttribute) as? String == "更多操作" {
                    button = element; break
                }
                if !["AXTextArea", "AXStaticText"].contains(role) {
                    pending += KeyboardInjector.axAttribute(element, attribute: kAXChildrenAttribute) as? [AXUIElement] ?? []
                }
            }
            let control = try #require(button)
            let focusResult = AXUIElementSetAttributeValue(control, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try #require(focusResult == .success)
            try await Task.sleep(for: .milliseconds(100))
            let selected = try #require(KeyboardInjector.axAttribute(app, attribute: kAXFocusedUIElementAttribute))
            try #require(CFGetTypeID(selected) == AXUIElementGetTypeID())
            try #require(CFEqual(selected, control))
            var operation: ScheduledOperation?
            let result: ApplicationFocusResult = await withCheckedContinuation { continuation in
                operation = KeyboardInjector.focusIntegratedApplication(integration, processIdentifier: run.processIdentifier) {
                    continuation.resume(returning: $0)
                }
            }
            withExtendedLifetime(operation) {}
            print("LIVE COMPOSER PROBE app=\(integration.rawValue) result=\(result)")
            #expect(result == .focused)
        }
    }
}
