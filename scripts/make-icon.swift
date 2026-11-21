// Draws Cedar's icon: a black cedar on a white rounded square.   swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
// Exactly 1024 x 1024 pixels, whatever the screen's scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// The white tile, in macOS's icon shape, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(tilePath); ctx.fillPath()
ctx.restoreGState()
ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
ctx.setLineWidth(2)
ctx.addPath(tilePath); ctx.strokePath()

ctx.setFillColor(NSColor.black.cgColor)
let cx: CGFloat = 512

// The trunk: wide at the foot, narrowing to the top.
let trunk = CGMutablePath()
trunk.move(to: CGPoint(x: cx - 46, y: 205))
trunk.addQuadCurve(to: CGPoint(x: cx - 10, y: 790), control: CGPoint(x: cx - 22, y: 420))
trunk.addLine(to: CGPoint(x: cx + 10, y: 790))
trunk.addQuadCurve(to: CGPoint(x: cx + 46, y: 205), control: CGPoint(x: cx + 22, y: 420))
trunk.addQuadCurve(to: CGPoint(x: cx - 46, y: 205), control: CGPoint(x: cx, y: 190))
ctx.addPath(trunk); ctx.fillPath()

// The flat, spreading tiers a cedar is known for: each a long blade, arched on top, nearly level underneath,
// with tips that lift slightly.
func tier(y: CGFloat, half: CGFloat, height: CGFloat, lean: CGFloat) {
    let p = CGMutablePath()
    let left = CGPoint(x: cx - half + lean, y: y + height * 0.10)
    let right = CGPoint(x: cx + half + lean, y: y + height * 0.10)
    p.move(to: left)
    p.addCurve(to: CGPoint(x: cx + lean * 0.3, y: y + height),
               control1: CGPoint(x: cx - half * 0.72 + lean, y: y + height * 0.55),
               control2: CGPoint(x: cx - half * 0.30, y: y + height))
    p.addCurve(to: right,
               control1: CGPoint(x: cx + half * 0.30, y: y + height),
               control2: CGPoint(x: cx + half * 0.72 + lean, y: y + height * 0.55))
    p.addCurve(to: left,
               control1: CGPoint(x: cx + half * 0.45, y: y - height * 0.16),
               control2: CGPoint(x: cx - half * 0.45, y: y - height * 0.16))
    ctx.addPath(p); ctx.fillPath()
}
tier(y: 330, half: 300, height: 92, lean: -14)
tier(y: 448, half: 322, height: 96, lean: 16)
tier(y: 566, half: 262, height: 90, lean: -12)
tier(y: 676, half: 188, height: 82, lean: 10)
tier(y: 772, half: 104, height: 72, lean: 0)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
