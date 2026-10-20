// Renders the app icon to a 1024×1024 PNG: the widgets stacked like cards in
// a wallet (mail, usage, reminders, weather), with the time card in front.
// Usage: swift scripts/make-icon.swift Assets/AppIcon.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let white = color(0xFFFFFF)

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
// Draw in top-left coordinates.
cg.translateBy(x: 0, y: size)
cg.scaleBy(x: 1, y: -1)
cg.setLineCap(.round)
cg.setLineJoin(.round)

// A point `r` from `c` at `degrees` clockwise from 12 o'clock.
func point(_ c: CGPoint, _ r: CGFloat, _ degrees: CGFloat) -> CGPoint {
  let a = degrees * .pi / 180
  return CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
}

func stroke(_ from: CGPoint, _ to: CGPoint, _ width: CGFloat, _ col: CGColor) {
  cg.setStrokeColor(col)
  cg.setLineWidth(width)
  cg.move(to: from)
  cg.addLine(to: to)
  cg.strokePath()
}

func fillRounded(_ rect: CGRect, _ radius: CGFloat, _ col: CGColor) {
  cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
  cg.setFillColor(col)
  cg.fillPath()
}

// Body: Apple's 824pt grid square with a continuous-corner feel.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
cg.addPath(bodyPath)
cg.setFillColor(color(0x10142A))
cg.fillPath()
cg.restoreGState()

cg.saveGState()
cg.addPath(bodyPath)
cg.clip()
let night = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [color(0x252C52), color(0x10142A)] as CFArray, locations: [0, 1])!
let glow = CGPoint(x: 512, y: body.minY + body.height * 0.3)
cg.drawRadialGradient(night, startCenter: glow, startRadius: 0, endCenter: glow, endRadius: 700,
                      options: [.drawsAfterEndLocation])

// Small glyphs on the cards behind, each centered on `c`.
func envelope(_ c: CGPoint, _ card: CGColor) {
  let w: CGFloat = 69, h = w * 0.7
  let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
  fillRounded(r, w * 0.12, white)
  cg.setStrokeColor(card)
  cg.setLineWidth(5.6)
  cg.move(to: CGPoint(x: r.minX + w * 0.1, y: r.minY + h * 0.16))
  cg.addLine(to: CGPoint(x: c.x, y: c.y + h * 0.08))
  cg.addLine(to: CGPoint(x: r.minX + w * 0.9, y: r.minY + h * 0.16))
  cg.strokePath()
}

func gauge(_ c: CGPoint) {
  let r: CGFloat = 33.5
  let g = CGPoint(x: c.x, y: c.y + 3.7)
  cg.setStrokeColor(white)
  cg.setLineWidth(r * 0.2)
  // From 8 o'clock clockwise over the top to 4 o'clock (angles from +x, y down).
  cg.addArc(center: g, radius: r, startAngle: 150 * .pi / 180, endAngle: 30 * .pi / 180, clockwise: false)
  cg.strokePath()
  stroke(g, point(g, r * 0.68, 45), r * 0.14, white)
  cg.setFillColor(white)
  cg.fillEllipse(in: CGRect(x: g.x - r * 0.16, y: g.y - r * 0.16, width: r * 0.32, height: r * 0.32))
}

func checkbox(_ c: CGPoint) {
  let s: CGFloat = 59.5
  cg.addPath(CGPath(roundedRect: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s),
                    cornerWidth: s * 0.26, cornerHeight: s * 0.26, transform: nil))
  cg.setStrokeColor(white)
  cg.setLineWidth(s * 0.12)
  cg.strokePath()
  cg.setLineWidth(s * 0.132)
  cg.move(to: CGPoint(x: c.x - s * 0.24, y: c.y + s * 0.02))
  cg.addLine(to: CGPoint(x: c.x - s * 0.06, y: c.y + s * 0.2))
  cg.addLine(to: CGPoint(x: c.x + s * 0.26, y: c.y - s * 0.2))
  cg.strokePath()
}

func sun(_ c: CGPoint) {
  let r: CGFloat = 19.8
  cg.setFillColor(white)
  cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
  for k in 0..<8 {
    stroke(point(c, r * 1.4, CGFloat(k) * 45), point(c, r * 1.85, CGFloat(k) * 45), 5.6, white)
  }
}

// The stack, back to front. Each card's shadow falls on the one behind it.
let cardX: CGFloat = 180, cardW: CGFloat = 664, cardH: CGFloat = 330
let cards: [(UInt32, ((CGPoint, CGColor) -> Void)?)] = [
  (0x20B074, { envelope($0, $1) }),
  (0xF4A321, { c, _ in gauge(c) }),
  (0xFF6A5A, { c, _ in checkbox(c) }),
  (0x2BB0F5, { c, _ in sun(c) }),
  (0x5865F2, nil),
]
var top: CGFloat = 0
for (i, (hex, glyph)) in cards.enumerated() {
  top = 168 + CGFloat(i) * 94
  let card = CGRect(x: cardX, y: top, width: cardW, height: cardH)
  cg.saveGState()
  cg.setShadow(offset: CGSize(width: 0, height: 6), blur: 20, color: color(0x000000, 0.35))
  fillRounded(card, 46, color(hex))
  cg.restoreGState()
  if let glyph {
    glyph(CGPoint(x: cardX + 78, y: top + 48), color(hex))
    fillRounded(CGRect(x: cardX + 140, y: top + 38, width: 180 + CGFloat(i % 2) * 60, height: 20), 10, color(0xFFFFFF, 0.55))
  }
}

// Front card: a clock reading 7:47, beside a few lines of placeholder text.
let c = CGPoint(x: cardX + 170, y: top + cardH / 2 + 4)
let r: CGFloat = 112
cg.setStrokeColor(white)
cg.setLineWidth(r * 0.09)
cg.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
for k in 0..<12 {
  let major = k % 3 == 0
  let a = CGFloat(k) * 30
  stroke(point(c, r * (major ? 0.70 : 0.78), a), point(c, r * 0.86, a), r * (major ? 0.075 : 0.045), white)
}
stroke(c, point(c, r * 0.46, (7 + 47.0 / 60) * 30), r * 0.12, white)
stroke(c, point(c, r * 0.70, 47 * 6), r * 0.085, white)
let accent = color(0xFFB25C)
let second: CGFloat = 10 * 6
stroke(point(c, r * 0.16, second + 180), point(c, r * 0.76, second), r * 0.035, accent)
cg.setFillColor(accent)
cg.fillEllipse(in: CGRect(x: c.x - r * 0.085, y: c.y - r * 0.085, width: r * 0.17, height: r * 0.17))

fillRounded(CGRect(x: cardX + 330, y: top + 110, width: 250, height: 34), 17, color(0xFFFFFF, 0.9))
fillRounded(CGRect(x: cardX + 330, y: top + 170, width: 180, height: 22), 11, color(0xFFFFFF, 0.55))
fillRounded(CGRect(x: cardX + 330, y: top + 214, width: 210, height: 22), 11, color(0xFFFFFF, 0.55))
cg.restoreGState()

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try FileManager.default.createDirectory(
  at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
