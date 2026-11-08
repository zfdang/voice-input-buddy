import Testing
@testable import RemoteBuddy

@Suite("Remote button gestures")
struct RemoteButtonGestureRecognizerTests {
    private final class Gestures {
        var recognizer = RemoteButtonGestureRecognizer()
        let clock = ControlledTestScheduler()
        var triggers: [(RemoteButton, ButtonTrigger)] = []
        var doubleTasks: [RemoteButton: HIDRemoteScheduledTask] = [:]
        var longTasks: [RemoteButton: HIDRemoteScheduledTask] = [:]

        func edge(_ phase: RemoteButtonPhase, _ button: RemoteButton = .ok,
                  double: Bool = true, long: Bool = true) {
            apply(recognizer.handle(phase, button: button,
                recognizesDoubleClick: double, recognizesLongPress: long))
        }
        func apply(_ commands: [RemoteButtonGestureRecognizer.Command]) {
            for command in commands {
                switch command {
                case let .scheduleDoubleClickTimeout(button):
                    doubleTasks[button] = clock.schedule(afterMilliseconds: HIDRemoteTiming.doubleClickMilliseconds,
                        repeatingEveryMilliseconds: nil) { [weak self] in
                        guard let self else { return }
                        self.apply(self.recognizer.doubleClickTimedOut(button))
                    }
                case let .cancelDoubleClickTimeout(button): doubleTasks.removeValue(forKey: button)?.cancel()
                case let .scheduleLongPressTimeout(button):
                    longTasks[button] = clock.schedule(afterMilliseconds: HIDRemoteTiming.longPressMilliseconds,
                        repeatingEveryMilliseconds: nil) { [weak self] in
                        guard let self else { return }
                        self.apply(self.recognizer.longPressTimedOut(button))
                    }
                case let .cancelLongPressTimeout(button): longTasks.removeValue(forKey: button)?.cancel()
                case let .trigger(button, trigger): triggers.append((button, trigger))
                }
            }
        }
        var kinds: [ButtonTrigger] { triggers.map { $0.1 } }
    }

    @Test func singleOnlyFiresOnReleaseAndIgnoresAutoRepeatAndOrphanRelease() {
        let input = Gestures()
        input.edge(.release)
        for _ in 0..<10 { input.edge(.press, double: false, long: false) }
        #expect(input.triggers.isEmpty)
        input.edge(.release)
        input.edge(.release)
        #expect(input.kinds == [.singleClick])
        #expect(!input.recognizer.isTracking(.ok))
        #expect(input.clock.activeCount == 0)
    }

    @Test func singleWaitsForExactlyTheDoubleClickWindowAfterRelease() {
        let input = Gestures()
        input.edge(.press)
        input.clock.advance(to: 100)
        input.edge(.release)
        input.clock.advance(to: 399)
        #expect(input.triggers.isEmpty)
        input.clock.advance(to: 400)
        #expect(input.kinds == [.singleClick])
        #expect(!input.recognizer.isTracking(.ok))
        input.clock.advance(to: 1_000)
        #expect(input.kinds == [.singleClick])
    }

    @Test func secondPressCancelsPendingSingleAndDoubleFiresOnSecondRelease() {
        let input = Gestures()
        input.edge(.press)
        input.edge(.release)
        input.clock.advance(to: 299)
        input.edge(.press)
        input.clock.advance(to: 300)
        #expect(input.triggers.isEmpty)
        input.edge(.press) // OS repeat must not become a third click.
        input.edge(.release)
        input.clock.advance(to: 1_000)
        #expect(input.kinds == [.doubleClick])
        #expect(!input.recognizer.isTracking(.ok))
    }

    @Test func pressAfterDoubleDeadlineStartsANewSingleClick() {
        let input = Gestures()
        input.edge(.press)
        input.edge(.release)
        input.clock.advance(to: 300)
        input.edge(.press)
        input.edge(.release)
        input.clock.advance(to: 600)
        #expect(input.kinds == [.singleClick, .singleClick])
    }

    @Test(arguments: [false, true])
    func longPressFiresOnceAtThresholdAndSuppressesRelease(double: Bool) {
        let input = Gestures()
        input.edge(.press, double: double)
        input.clock.advance(to: 549)
        #expect(input.triggers.isEmpty)
        input.clock.advance(to: 550)
        #expect(input.kinds == [.longPress])
        for _ in 0..<10 { input.edge(.press) }
        input.apply(input.recognizer.longPressTimedOut(.ok))
        input.edge(.release)
        input.clock.advance(to: 2_000)
        #expect(input.kinds == [.longPress])
        #expect(!input.recognizer.isTracking(.ok))
    }

    @Test func releaseBeforeLongThresholdCancelsLongAndFallsBackToSingle() {
        let input = Gestures()
        input.edge(.press, double: false)
        input.clock.advance(to: 549)
        input.edge(.release)
        input.clock.advance(to: 550)
        #expect(input.kinds == [.singleClick])
        #expect(input.recognizer.longPressTimedOut(.ok).isEmpty)
    }

    @Test func longSecondPressTakesPrecedenceOverDoubleClick() {
        let input = Gestures()
        input.edge(.press)
        input.edge(.release)
        input.clock.advance(to: 100)
        input.edge(.press)
        input.clock.advance(to: 650)
        input.edge(.release)
        #expect(input.kinds == [.longPress])
    }

    @Test func cancelAndResetIgnoreOutstandingTimeoutsAndReleases() {
        var recognizer = RemoteButtonGestureRecognizer()
        _ = recognizer.press(.ok, recognizesDoubleClick: true, recognizesLongPress: true)
        _ = recognizer.release(.ok)
        recognizer.cancel(.ok)
        #expect(recognizer.doubleClickTimedOut(.ok).isEmpty)
        #expect(recognizer.longPressTimedOut(.ok).isEmpty)
        #expect(recognizer.release(.ok).isEmpty)
        for button in [RemoteButton.left, .right] {
            _ = recognizer.press(button, recognizesDoubleClick: true, recognizesLongPress: true)
        }
        recognizer.reset()
        for button in [RemoteButton.left, .right] {
            #expect(!recognizer.isTracking(button))
            #expect(recognizer.longPressTimedOut(button).isEmpty)
        }
    }

    @Test func simultaneousButtonsAndRecognitionOptionsAreIndependent() {
        let input = Gestures()
        input.edge(.press, .left, double: false, long: false)
        input.edge(.press, .right)
        // Options are fixed by the first press, even when release options differ.
        input.edge(.release, .left)
        input.clock.advance(to: 550)
        input.edge(.release, .right)
        #expect(input.kinds == [.singleClick, .longPress])
        #expect(input.triggers.map { $0.0 } == [.left, .right])
    }
}
