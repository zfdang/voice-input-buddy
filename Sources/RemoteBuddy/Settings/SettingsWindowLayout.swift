import AppKit
import SwiftUI

/// Keep the window reachable on small screens and after restoring a frame saved
/// on a larger display. The canvas scrolls independently of the window minimum.
enum SettingsWindowLayout {
    static let preferredContentSize = CGSize(width: 1020, height: 772)
    static let minimumCanvasSize = CGSize(width: 980, height: 732)
    static let onboardingMinimumCanvasSize = CGSize(width: 980, height: 0)

    static func minimumWindowSize(in visibleFrame: CGRect) -> CGSize {
        CGSize(width: min(720, visibleFrame.width), height: min(500, visibleFrame.height))
    }

    static func fittedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width, height: height
        )
    }

    static func canvasSize(viewport: CGSize, minimum: CGSize = minimumCanvasSize) -> CGSize {
        CGSize(width: max(viewport.width, minimum.width), height: max(viewport.height, minimum.height))
    }
}

/// Preserve readable controls while letting smaller windows reach every part of
/// the settings and first-run wizard, including their bottom navigation.
struct AdaptiveSettingsViewport<Content: View>: View {
    var minimumSize = SettingsWindowLayout.minimumCanvasSize
    var axes: Axis.Set = [.horizontal, .vertical]
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let canvas = SettingsWindowLayout.canvasSize(viewport: proxy.size, minimum: minimumSize)
            ScrollView(axes) {
                content()
                    .frame(width: canvas.width, height: canvas.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
