import AppKit

/// The cedar from the app icon, simplified for the menu bar (three tiers, so the gaps survive at 18 points).
enum TreeIcon {
    /// A template image: macOS tints it to match the menu bar.
    static func menuBar(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the tree in black, in a 100 x 100 design space scaled to `rect`.
    static func draw(in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 100, y: rect.height / 100)
        ctx.setFillColor(NSColor.black.cgColor)

        let trunk = CGMutablePath()
        trunk.move(to: CGPoint(x: 43, y: 4))
        trunk.addLine(to: CGPoint(x: 48, y: 90))
        trunk.addLine(to: CGPoint(x: 52, y: 90))
        trunk.addLine(to: CGPoint(x: 57, y: 4))
        trunk.closeSubpath()
        ctx.addPath(trunk)
        ctx.fillPath()

        for (y, half, height) in [(20.0, 47.0, 19.0), (47.0, 36.0, 18.0), (72.0, 22.0, 20.0)] as [(CGFloat, CGFloat, CGFloat)] {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 50 - half, y: y + height * 0.1))
            p.addCurve(to: CGPoint(x: 50, y: y + height), control1: CGPoint(x: 50 - half * 0.7, y: y + height * 0.55),
                       control2: CGPoint(x: 50 - half * 0.3, y: y + height))
            p.addCurve(to: CGPoint(x: 50 + half, y: y + height * 0.1), control1: CGPoint(x: 50 + half * 0.3, y: y + height),
                       control2: CGPoint(x: 50 + half * 0.7, y: y + height * 0.55))
            p.addCurve(to: CGPoint(x: 50 - half, y: y + height * 0.1), control1: CGPoint(x: 50 + half * 0.45, y: y - height * 0.14),
                       control2: CGPoint(x: 50 - half * 0.45, y: y - height * 0.14))
            ctx.addPath(p)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}
