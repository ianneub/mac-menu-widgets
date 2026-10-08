// Renders the app icon to a 1024×1024 PNG: a miniature menu bar (usage
// meter, sun, time) over a dropdown panel holding a clock face.
// Usage: swift scripts/make-icon.swift Assets/AppIcon.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
// Draw in top-left coordinates.
cg.translateBy(x: 0, y: size)
cg.scaleBy(x: 1, y: -1)

// Body: Apple's 824pt grid square with a continuous-corner feel.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
cg.addPath(bodyPath)
cg.setFillColor(color(0x1A1F5C))
cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(bodyPath)
cg.clip()
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                     colors: [color(0x5B8CFF), color(0x3A4FD0), color(0x1A1F5C)] as CFArray,
                     locations: [0, 0.45, 1])!
cg.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// Menu bar strip.
let barHeight: CGFloat = 132
cg.setFillColor(color(0xFFFFFF, 0.20))
cg.fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: barHeight))
cg.setFillColor(color(0xFFFFFF, 0.30))
cg.fill(CGRect(x: body.minX, y: body.minY + barHeight - 3, width: body.width, height: 3))
let barMid = body.minY + barHeight / 2 + 6

// Usage meter: three rising bars.
cg.setFillColor(color(0xFFFFFF))
for (i, h) in [CGFloat(26), 42, 58].enumerated() {
  let r = CGRect(x: 300 + CGFloat(i) * 26, y: barMid + 29 - h, width: 16, height: h)
  cg.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
}
cg.fillPath()

// Sun: disc and eight rays.
let sun = CGPoint(x: 452, y: barMid)
cg.fillEllipse(in: CGRect(x: sun.x - 17, y: sun.y - 17, width: 34, height: 34))
cg.setStrokeColor(color(0xFFFFFF))
cg.setLineWidth(8)
cg.setLineCap(.round)
for k in 0..<8 {
  let a = CGFloat(k) * .pi / 4
  cg.move(to: CGPoint(x: sun.x + cos(a) * 26, y: sun.y + sin(a) * 26))
  cg.addLine(to: CGPoint(x: sun.x + cos(a) * 36, y: sun.y + sin(a) * 36))
}
cg.strokePath()

// Time text. Flip back locally so the glyphs draw upright.
let text = NSAttributedString(string: "9:41", attributes: [
  .font: NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .semibold),
  .foregroundColor: NSColor.white,
])
let tSize = text.size()
cg.saveGState()
cg.translateBy(x: 0, y: size)
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.saveGraphicsState()
text.draw(at: NSPoint(x: 540, y: size - barMid - tSize.height / 2))
NSGraphicsContext.restoreGraphicsState()
cg.restoreGState()

// Dropdown panel under the menu bar.
let panel = CGRect(x: 232, y: 300, width: 560, height: 540)
let panelPath = CGPath(roundedRect: panel, cornerWidth: 72, cornerHeight: 72, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: color(0x000000, 0.35))
cg.addPath(panelPath)
cg.setFillColor(color(0xF7F8FF))
cg.fillPath()
cg.restoreGState()

// Clock face.
let c = CGPoint(x: panel.midX, y: panel.midY)
let r: CGFloat = 200
cg.setStrokeColor(color(0x1A1F5C))
cg.setLineWidth(18)
cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
for k in 0..<12 {
  let a = CGFloat(k) * .pi / 6
  let inner = k % 3 == 0 ? r - 52 : r - 38
  cg.setLineWidth(k % 3 == 0 ? 14 : 8)
  cg.move(to: CGPoint(x: c.x + sin(a) * inner, y: c.y - cos(a) * inner))
  cg.addLine(to: CGPoint(x: c.x + sin(a) * (r - 22), y: c.y - cos(a) * (r - 22)))
  cg.strokePath()
}
// Hands at 10:10, angles clockwise from 12.
func hand(_ angle: CGFloat, _ length: CGFloat, _ width: CGFloat, _ col: CGColor, tail: CGFloat = 0) {
  cg.setStrokeColor(col)
  cg.setLineWidth(width)
  cg.move(to: CGPoint(x: c.x - sin(angle) * tail, y: c.y + cos(angle) * tail))
  cg.addLine(to: CGPoint(x: c.x + sin(angle) * length, y: c.y - cos(angle) * length))
  cg.strokePath()
}
hand((10 + 10.0 / 60) / 12 * 2 * .pi, 108, 22, color(0x1A1F5C))
hand(10.0 / 60 * 2 * .pi, 160, 16, color(0x1A1F5C))
hand(38.0 / 60 * 2 * .pi, 172, 7, color(0xFF7A2F), tail: 36)
cg.setFillColor(color(0xFF7A2F))
cg.fillEllipse(in: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36))
cg.restoreGState()

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try FileManager.default.createDirectory(
  at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
