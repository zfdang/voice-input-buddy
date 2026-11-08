import AppKit

// Original schematic. Coordinates share the mapping canvas's normalized anchors.
let size = NSSize(width: 508, height: 1030)
// Preserve the original button geometry and restore a longer, narrower grip.
let buttonCoordinateHeight: CGFloat = 1030
let image = NSImage(size: size)
image.lockFocusFlipped(true)
func round(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
// Brushed-metal schematic, redrawn without any manufacturer's logo or photo.
let body = NSBezierPath(roundedRect: NSRect(x: 104, y: 4, width: 300, height: 1022), xRadius: 22, yRadius: 22)
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
shadow.shadowBlurRadius = 10; shadow.shadowOffset = NSSize(width: 0, height: -2)
NSGraphicsContext.saveGraphicsState(); shadow.set()
NSColor(calibratedWhite: 0.72, alpha: 1).setFill(); body.fill()
NSGraphicsContext.restoreGraphicsState()
let metal = NSGradient(colorsAndLocations:
    (NSColor(calibratedWhite: 0.68, alpha: 1), 0),
    (NSColor(calibratedWhite: 0.94, alpha: 1), 0.055),
    (NSColor(calibratedWhite: 0.80, alpha: 1), 0.17),
    (NSColor(calibratedWhite: 0.91, alpha: 1), 0.50),
    (NSColor(calibratedWhite: 0.77, alpha: 1), 0.86),
    (NSColor(calibratedWhite: 0.95, alpha: 1), 0.955),
    (NSColor(calibratedWhite: 0.60, alpha: 1), 1))!
metal.draw(in: body, angle: 0)
NSColor(calibratedWhite: 0.56, alpha: 1).setStroke(); body.lineWidth = 1.5; body.stroke()
// Light machining texture is clipped to the body, not a downloaded product image.
NSGraphicsContext.saveGraphicsState(); body.addClip()
for y in stride(from: CGFloat(8), to: CGFloat(1026), by: 3) {
    let line = NSBezierPath(); line.move(to: NSPoint(x: 108, y: y)); line.line(to: NSPoint(x: 400, y: y))
    line.lineWidth = 0.35; NSColor.white.withAlphaComponent(0.035).setStroke(); line.stroke()
}
NSGraphicsContext.restoreGraphicsState()
let ring = NSBezierPath(ovalIn: NSRect(x: 138, y: 139, width: 234, height: 234))
NSGradient(starting: NSColor(calibratedWhite: 0.19, alpha: 1), ending: NSColor(calibratedWhite: 0.08, alpha: 1))!.draw(in: ring, angle: 90)
NSColor(calibratedWhite: 0.36, alpha: 1).setStroke(); ring.lineWidth = 2; ring.stroke()
// Shared volume rocker; all anchors remain identical to the mapping canvas.
round(NSRect(x: 0.604 * size.width - 32, y: 0.390 * buttonCoordinateHeight - 32, width: 64, height: 0.09 * buttonCoordinateHeight + 64), radius: 32,
      color: NSColor(calibratedWhite: 0.13, alpha: 1))
let buttons: [(CGFloat, CGFloat, String)] = [
    (0.386, 0.099, "⏻"), (0.630, 0.099, "mic.fill"),
    (0.502, 0.179, "chevron.up"), (0.362, 0.246, "chevron.left"),
    (0.638, 0.246, "chevron.right"), (0.502, 0.317, "chevron.down"),
    (0.502, 0.246, "OK"), (0.406, 0.389, "arrow.uturn.backward"),
    (0.604, 0.390, "+"), (0.406, 0.479, "house"),
    (0.604, 0.480, "−"), (0.406, 0.569, "line.3.horizontal"),
    (0.604, 0.569, "TV")
]
for (x, y, label) in buttons {
    let rect = NSRect(x: x * size.width - 28, y: y * buttonCoordinateHeight - 28, width: 56, height: 56)
    let isTopButton = y < 0.13
    let isDirection = y > 0.13 && y < 0.34 && label != "OK"
    if !isDirection {
        let shape = NSBezierPath(ovalIn: rect)
        NSGradient(starting: NSColor(calibratedWhite: isTopButton ? 0.92 : 0.25, alpha: 1),
                   ending: NSColor(calibratedWhite: isTopButton ? 0.74 : 0.14, alpha: 1))!.draw(in: shape, angle: 90)
        NSColor(calibratedWhite: isTopButton ? 0.48 : 0.09, alpha: 1).setStroke()
        shape.lineWidth = 1.5; shape.stroke()
    }
    let ink = isTopButton ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
    if let symbol = NSImage(systemSymbolName: label, accessibilityDescription: nil) {
        symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 23, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink])))?
            .draw(in: rect.insetBy(dx: 15, dy: 15))
    } else {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: ink
        ])
        let measured = text.size()
        text.draw(at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2))
    }
}
for (label, y, fontSize) in [("Remote Buddy", CGFloat(885), CGFloat(18)), ("遥控搭子", CGFloat(915), CGFloat(20))] {
    let text = NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.30, alpha: 1)
    ])
    text.draw(at: NSPoint(x: size.width / 2 - text.size().width / 2, y: y))
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: CommandLine.arguments[1]))
