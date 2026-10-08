import SwiftUI
import WidgetsCore

/// The moon drawn at a given phase, northern-hemisphere view: waxing is lit on
/// the right. The lit shape is the bright limb's half circle closed by the
/// terminator, a half ellipse whose width follows the phase.
struct TimeMoonDisc: View {
  var lit: Double     // illuminated fraction, 0 new .. 1 full
  var waxing: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    // The lit side is always light, so a full moon never reads as a black
    // disc in light mode; there the dark side is a grey disc with a rim.
    let light = scheme == .light
    let litColor = light ? Color(white: 0.99) : Color.primary
    Canvas { ctx, size in
      let r = min(size.width, size.height) / 2 - 1
      let cx = size.width / 2, cy = size.height / 2
      let whole = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
      ctx.fill(whole, with: .color(light ? Color(white: 0.55).opacity(0.55) : .primary.opacity(0.14)))

      let side: CGFloat = waxing ? 1 : -1
      let bulge: CGFloat = lit < 0.5 ? 1 : -1
      let rx = r * abs(1 - 2 * lit)
      var p = Path()
      // Bright limb: top to bottom round the lit side.
      for i in 0...48 {
        let t = -Double.pi / 2 + Double(i) * .pi / 48
        let pt = CGPoint(x: cx + side * r * cos(t), y: cy + r * sin(t))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
      }
      // Terminator: bottom back to top.
      for i in 0...48 {
        let t = Double.pi / 2 - Double(i) * .pi / 48
        p.addLine(to: CGPoint(x: cx + side * bulge * rx * cos(t), y: cy + r * sin(t)))
      }
      p.closeSubpath()
      ctx.fill(p, with: .color(litColor))
      if light { ctx.stroke(whole, with: .color(.black.opacity(0.25)), lineWidth: 0.75) }
    }
  }
}

/// Pops out beside the moon row while it's hovered: the next two lunar cycles
/// of principal phases, each with its drawn moon, local date and time, and how
/// many days away it is.
struct TimeMoonPane: View {
  @ObservedObject var state: TimeState
  static let padding: CGFloat = 14

  /// Principal phase -> how the disc is drawn.
  private static let looks: [String: (lit: Double, waxing: Bool)] = [
    "New Moon": (0, true), "First Quarter": (0.5, true),
    "Full Moon": (1, true), "Last Quarter": (0.5, false),
  ]

  var body: some View {
    let nowMs = state.nowMs
    let phases = Astro.upcomingPhases(nowMs, count: 8)
    VStack(alignment: .leading, spacing: 6) {
      TimeSectionHeader("UPCOMING PHASES")
      ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
        let when = TimeModel.phaseWhen(phase.ms, nowMs, state.use24h)
        let look = Self.looks[phase.name] ?? (0, true)
        // A new cycle starts at each new moon; a rule above it splits the two.
        if phase.name == "New Moon" && i > 0 {
          Divider().padding(.vertical, 2)
        }
        HStack(spacing: 12) {
          TimeMoonDisc(lit: look.lit, waxing: look.waxing).frame(width: 24, height: 24)
          VStack(alignment: .leading, spacing: 0) {
            Text(phase.name).font(.body.weight(.semibold)).lineLimit(1)
            Text(when.rel).font(.callout).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: 0) {
            Text(when.date).font(.body)
            Text(when.time).font(.callout).foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(Self.padding)
    .frame(width: 300)
  }
}
