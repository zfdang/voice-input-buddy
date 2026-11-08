import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Settings window layout")
struct SettingsWindowLayoutTests {
    @Test(arguments: [CGRect(x: 0, y: 25, width: 800, height: 550),
                      CGRect(x: -1280, y: 40, width: 1280, height: 680),
                      CGRect(x: 200, y: -900, width: 640, height: 480)])
    func restoredLargeWindowFitsVisibleScreen(screen: CGRect) {
        let saved = CGRect(x: 1500, y: 100, width: 1020, height: 794)
        let fitted = SettingsWindowLayout.fittedFrame(saved, in: screen)
        #expect(screen.contains(fitted))
        let minimum = SettingsWindowLayout.minimumWindowSize(in: screen)
        #expect(minimum.width <= fitted.width)
        #expect(minimum.height <= fitted.height)
    }

    @Test(arguments: [CGFloat(500), 680, 732])
    func onboardingCanvasUsesActualViewportHeight(height: CGFloat) {
        let canvas = SettingsWindowLayout.canvasSize(viewport: CGSize(width: 720, height: height),
            minimum: SettingsWindowLayout.onboardingMinimumCanvasSize)
        #expect(canvas.height == height)
        #expect(canvas.width == 980)
    }

    @Test func onlyClosedWindowsMoveToAnotherTargetScreen() {
        #expect(SettingsWindowDisplayPolicy.shouldMove(isOpen: false, currentScreen: 0, targetScreen: 1))
        #expect(!SettingsWindowDisplayPolicy.shouldMove(isOpen: true, currentScreen: 0, targetScreen: 1))
        #expect(!SettingsWindowDisplayPolicy.shouldMove(isOpen: false, currentScreen: 1, targetScreen: 1))
        #expect(!SettingsWindowDisplayPolicy.shouldMove(isOpen: false, currentScreen: 0, targetScreen: nil))
    }

    @Test func compactViewportKeepsFullCanvasAndDesktopHasNoOverflow() {
        let compact = SettingsWindowLayout.canvasSize(viewport: CGSize(width: 720, height: 500))
        #expect(compact == CGSize(width: 980, height: 732))
        let desktop = CGSize(width: 1200, height: 900)
        #expect(SettingsWindowLayout.canvasSize(viewport: desktop) == desktop)
    }
}
