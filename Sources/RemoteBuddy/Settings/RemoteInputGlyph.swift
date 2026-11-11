import SwiftUI

/// The Google remote's Input key: an arrow entering a box that is open on the left.
/// No SF Symbol shows this, so it is drawn as a generic outline, not a vendor mark.
struct RemoteInputGlyph: View {
    var size: CGFloat

    var body: some View {
        RemoteInputGlyphShape()
            .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.1), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

private struct RemoteInputGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let radius = min(rect.width, rect.height) * 0.12
        var path = Path()
        // The box leaves the middle of its left side open for the arrow.
        path.move(to: point(0.3, 0.36))
        path.addArc(tangent1End: point(0.3, 0.16), tangent2End: point(0.92, 0.16), radius: radius)
        path.addArc(tangent1End: point(0.92, 0.16), tangent2End: point(0.92, 0.84), radius: radius)
        path.addArc(tangent1End: point(0.92, 0.84), tangent2End: point(0.3, 0.84), radius: radius)
        path.addArc(tangent1End: point(0.3, 0.84), tangent2End: point(0.3, 0.64), radius: radius)
        path.addLine(to: point(0.3, 0.64))
        path.move(to: point(0.06, 0.5))
        path.addLine(to: point(0.64, 0.5))
        path.move(to: point(0.46, 0.32))
        path.addLine(to: point(0.64, 0.5))
        path.addLine(to: point(0.46, 0.68))
        return path
    }
}
