import SwiftUI
import WidgetsCore

/// The world clock popup: hero local time, the moon, then one row per zone
/// with its offset from here and its own wall clock.
struct TimePanel: View {
  @ObservedObject var state: TimeState
  @ObservedObject var host: PanelHost
  @FocusState private var focused: Bool

  static let width: CGFloat = 360
  static let padding: CGFloat = 14

  var body: some View {
    let now = state.now
    let use24h = state.use24h
    let local = state.local
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let clock = TimeModel.clockText(c.hour!, c.minute!, use24h)
    let moon = Astro.moonInfo(state.nowMs)
    // Rounded down so a moon a few hours short of full never reads "100%"
    // under a "Waxing Gibbous" label.
    let moonPercent = moon.name == "Full Moon" ? 100 : Int(floor(moon.illumination * 100))

    VStack(alignment: .leading, spacing: 10) {
      // ---- Hero: local time. Hovering it opens the pane for here.
      VStack(spacing: 2) {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
          Image(systemName: "clock")
            .font(.system(size: 34, weight: .light))
            .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
          Text(clock.time)
            .font(.system(size: 46, weight: .bold))
            .monospacedDigit()
          TimeSide(
            alt: TimeModel.clockLabel(c.hour!, c.minute!, !use24h), suffix: clock.suffix,
            suffixSize: 20, altSize: 13)
        }
        Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()) + "  ·  "
          + (local.abbr.isEmpty ? "" : local.abbr + " ") + "UTC" + TimeModel.offsetLabel(local.offset))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
      .timeRowHighlight(state.shownIndex == TimeState.here)
      .onHover { $0 ? state.hoverEnter(TimeState.here) : state.hoverExit(TimeState.here) }

      Divider()

      // ---- Moon: phase name on the left, drawn disc on the right.
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Moon").font(.title3)
          Text("\(moon.name)  ·  \(moonPercent)% lit")
            .font(.callout).foregroundStyle(.secondary)
          Text(moon.next.name + " " + TimeModel.whenLabel(moon.next.ms, state.nowMs, use24h))
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        TimeMoonDisc(lit: moon.illumination, waxing: moon.waxing)
          .frame(width: 42, height: 42)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .timeRowHighlight(state.shownIndex == TimeState.moon)
      .onHover { $0 ? state.hoverEnter(TimeState.moon) : state.hoverExit(TimeState.moon) }
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("timePanel")).minY } action: {
        state.moonRowY = $0
      }

      Divider()

      TimeSectionHeader("WORLD CLOCK").padding(.horizontal, 8)

      // ---- One row per zone: name and offset left, its time right.
      VStack(spacing: 2) {
        ForEach(state.rows) { row in
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
              Text(row.name).font(.title3).lineLimit(1)
              Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
              Text(row.time.isEmpty ? "—" : row.time)
                .font(.system(size: 26))
                .monospacedDigit()
              TimeSide(alt: row.alt, suffix: row.suffix, suffixSize: 13, altSize: 11)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .timeRowHighlight(state.shownIndex == row.id)
          .onHover { $0 ? state.hoverEnter(row.id) : state.hoverExit(row.id) }
        }
      }
    }
    .padding(TimePanel.padding)
    .frame(width: TimePanel.width)
    .coordinateSpace(name: "timePanel")
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(.upArrow) { state.step(-1); return .handled }
    .onKeyPress(.downArrow) { state.step(1); return .handled }
    .onChange(of: state.openCount) { focused = true }
    .onChange(of: state.shownIndex) { updatePane() }
    .onChange(of: host.pointerInSidePane) { _, inside in if !inside { state.scheduleHide() } }
  }

  private func updatePane() {
    switch state.shownIndex {
    case TimeState.none:
      host.hideSidePane(after: 0)
    case TimeState.moon:
      // First phase level with the moon row (the pane's own padding above it).
      host.showSidePane(anchorY: max(0, state.moonRowY + TimePanel.padding - TimeMoonPane.padding)) {
        TimeMoonPane(state: state)
      }
    default:
      let index = state.shownIndex
      host.showSidePane(anchorY: 0) {
        TimeDetailPane(state: state, index: index)
      }
    }
  }
}

/// The small stack beside a big time: the other-format clock over AM/PM,
/// with the bottom line on the big time's baseline.
struct TimeSide: View {
  var alt: String
  var suffix: String
  var suffixSize: CGFloat
  var altSize: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !alt.isEmpty {
        Text(alt).font(.system(size: altSize)).monospacedDigit().foregroundStyle(.secondary)
      }
      if !suffix.isEmpty {
        Text(suffix).font(.system(size: suffixSize))
      }
    }
  }
}

struct TimeSectionHeader: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .tracking(0.6)
  }
}

extension View {
  /// The filled background of a hovered or keyboard-selected row, like a menu item.
  func timeRowHighlight(_ on: Bool) -> some View {
    background(
      RoundedRectangle(cornerRadius: 7)
        .fill(on ? Color.accentColor.opacity(0.22) : Color.clear))
      .contentShape(Rectangle())
  }
}
