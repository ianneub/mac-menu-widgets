import SwiftUI
import WidgetsCore

/// The card beside the forecast while a day row is hovered: the day's hourly
/// chance of precipitation as bars, hourly temperature and wind lines, rain
/// total, wind, UV and sun times, then NWS's own day and night narrative.
struct DayDetailPane: View {
  @ObservedObject var service: WeatherService
  @ObservedObject var state: WeatherPanelState

  /// The hour under the pointer in any chart, -1 for none; the bars, both
  /// lines and the readout all follow it. (Kept on the state object: the
  /// Command Line Tools ship no SwiftUIMacros plugin, so no @State.)
  private var hoverHour: Int { state.hoverHour }

  static let width: CGFloat = 460
  static let padding: CGFloat = 16
  static var contentW: CGFloat { width - padding * 2 }
  static let gutter: CGFloat = 40
  static var slotW: CGFloat { (contentW - gutter) / 24 }

  var body: some View {
    let rows = service.rows
    if state.shownIndex >= 0 && state.shownIndex < rows.count {
      content(rows[state.shownIndex])
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .topLeading)
    } else {
      Color.clear.frame(width: Self.width, height: 1)
    }
  }

  @ViewBuilder private func content(_ day: Weather.Day) -> some View {
    let imperial = service.useImperial
    let slots = Weather.hourlyForDay(day.date, nws: service.activeNwsHours, openMeteo: service.openMeteoHours)
    let extras = Weather.openMeteoDayExtras(service.activeOpenMeteo, date: day.date)
    let hasHours = slots.contains { $0 != nil }
    let nwsHours = slots.contains { $0?.source == .nws }
    let isToday = day.date == service.today
    let nowHour = Calendar.current.component(.hour, from: service.now)
    let ctx = ChartContext(isToday: isToday, nowHour: nowHour, hoverHour: hoverHour)
    let tempValues = slots.map { Weather.tempValue($0, imperial: imperial) }
    let windValues = slots.map { Weather.windValue($0, imperial: imperial) }
    let tempRange = Weather.niceRange(Weather.hourlyTempRange(slots, imperial: imperial))
    let windRange = Weather.niceRange(Weather.hourlyWindRange(slots, imperial: imperial))
    let windUnit = imperial ? "mph" : "km/h"

    VStack(alignment: .leading, spacing: 14) {
      header(day, imperial: imperial)
      Divider().opacity(0.6)

      if hasHours {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline) {
            SectionHeader("CHANCE OF PRECIPITATION")
            Spacer()
            Text(readout(slots, imperial: imperial, hasHours: hasHours))
              .font(.system(size: WeatherStyle.bodySmall).monospacedDigit())
              .foregroundStyle(hoverHour >= 0 ? Color.primary : Color.secondary)
          }
          RainChart(slots: slots, ctx: ctx, peak: Weather.peakPrecipHour(slots))
            .onContinuousHover { hover("rain", $0) }
        }
      }

      if let tempRange {
        HourLine(title: "TEMPERATURE", values: tempValues, range: tempRange, suffix: "°", tickSuffix: "°",
          labelLow: true, fill: false, chartHeight: 84, ctx: ctx)
          .onContinuousHover { hover("temp", $0) }
      }

      if let windRange {
        VStack(alignment: .leading, spacing: 4) {
          HourLine(title: "WIND (\(windUnit.uppercased()))", values: windValues, range: windRange,
            suffix: " \(windUnit)", tickSuffix: "", labelLow: false, fill: true, chartHeight: 64, ctx: ctx)
            .onContinuousHover { hover("wind", $0) }
          windArrows(slots, imperial: imperial, ctx: ctx)
        }
      }

      if !hasHours {
        Text("No hourly forecast for this day yet.")
          .font(.system(size: WeatherStyle.bodySmall).italic())
          .foregroundStyle(.secondary)
      }

      stats(slots, extras: extras, imperial: imperial)

      if hasNarrative(day) {
        Divider().opacity(0.6)
        VStack(alignment: .leading, spacing: 10) {
          narrative(day.nwsDayText)
          narrative(day.nwsNightText)
        }
      }

      if hasHours {
        Text(nwsHours ? "Hourly: National Weather Service" : "Hourly: Open-Meteo")
          .font(.system(size: WeatherStyle.caption))
          .foregroundStyle(Color.primary.opacity(0.45))
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(width: Self.contentW, alignment: .leading)
  }

  // Moving between charts can deliver the old chart's exit after the new
  // one's first move, so a chart only clears the hover while it owns it.
  private func hover(_ owner: String, _ phase: HoverPhase) {
    switch phase {
    case .active(let p):
      state.hoverOwner = owner
      let x = p.x - Self.gutter
      let h = x < 0 ? -1 : max(0, min(23, Int(x / Self.slotW)))
      if state.hoverHour != h { state.hoverHour = h }
    case .ended:
      if state.hoverOwner == owner {
        state.hoverOwner = ""
        state.hoverHour = -1
      }
    }
  }

  private func readout(_ slots: [Weather.Hour?], imperial: Bool, hasHours: Bool) -> String {
    if hoverHour >= 0 {
      guard let s = slots[hoverHour] else { return Weather.hourLabel(hoverHour) + "  ·  no data" }
      var text = Weather.hourLabel(hoverHour) + "  ·  " + (s.pop.map { "\($0)%" } ?? "—")
      if let t = Weather.tempValue(s, imperial: imperial) { text += "  ·  \(Weather.jsRound(t))°" }
      if let w = Weather.windValue(s, imperial: imperial) {
        let dir = Weather.compassName(s.windDir)
        text += "  ·  " + (dir.isEmpty ? "" : dir + " ") + "\(Weather.jsRound(w)) \(imperial ? "mph" : "km/h")"
      }
      return text
    }
    if !hasHours { return "" }
    if let peak = Weather.peakPrecipHour(slots), let pop = peak.pop {
      return "Peak \(pop)% at \(Weather.hourLabel(peak.hour))"
    }
    return "No rain expected"
  }

  private func header(_ day: Weather.Day, imperial: Bool) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title(day))
          .font(.system(size: WeatherStyle.title, weight: .bold))
          .lineLimit(1)
        if let short = (day.nwsDayText ?? day.nwsNightText)?.shortForecast, !short.isEmpty {
          Text(short)
            .font(.system(size: WeatherStyle.body))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      HStack(spacing: 10) {
        let icon = Weather.dayIcon(day)
        Image(systemName: icon.isEmpty ? "cloud" : icon)
          .symbolRenderingMode(.multicolor)
          .font(.system(size: WeatherStyle.display))
        Text(Weather.bareTemp(day, .max, imperial: imperial))
          .font(.system(size: WeatherStyle.title, weight: .bold))
        Text(Weather.bareTemp(day, .min, imperial: imperial))
          .font(.system(size: WeatherStyle.title))
          .foregroundStyle(.secondary)
      }
      .monospacedDigit()
    }
  }

  private func title(_ day: Weather.Day) -> String {
    guard let d = Weather.noon(of: day.date) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "MMMM d"
    let date = f.string(from: d)
    if day.date == service.today { return "Today, " + date }
    f.dateFormat = "EEEE"
    return f.string(from: d) + ", " + date
  }

  /// Where the wind blows toward, every third hour: an arrow turned from
  /// the bearing it blows from.
  private func windArrows(_ slots: [Weather.Hour?], imperial: Bool, ctx: ChartContext) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach([1, 4, 7, 10, 13, 16, 19, 22], id: \.self) { h in
        if let s = slots[h], let dir = s.windDir, let w = Weather.windValue(s, imperial: imperial), w > 0 {
          Image(systemName: "arrow.up")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ctx.isPast(h) ? Color.primary.opacity(0.3) : Color.secondary)
            .rotationEffect(.degrees(dir + 180))
            .position(x: Self.gutter + Self.slotW * (Double(h) + 0.5), y: 8)
        }
      }
    }
    .frame(width: Self.contentW, height: 16)
  }

  private func stats(_ slots: [Weather.Hour?], extras: Weather.DayExtras?, imperial: Bool) -> some View {
    let items = [
      ("PRECIPITATION", Weather.precipAmountLabel(extras, imperial: imperial)),
      ("WIND", Weather.windLabel(slots, extras: extras, imperial: imperial)),
      ("UV INDEX", Weather.uvLabel(extras)),
      ("SUNRISE", extras?.sunrise ?? ""),
      ("SUNSET", extras?.sunset ?? ""),
    ].filter { !$0.1.isEmpty }
    let cellW = (Self.contentW - 24) / 3
    return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: 12, alignment: .topLeading), count: 3),
      alignment: .leading, spacing: 10) {
      ForEach(items, id: \.0) { label, value in
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(.system(size: WeatherStyle.caption))
            .tracking(1)
            .foregroundStyle(.secondary)
          Text(value)
            .font(.system(size: WeatherStyle.body))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: cellW, alignment: .leading)
      }
    }
  }

  private func hasNarrative(_ day: Weather.Day) -> Bool {
    !(day.nwsDayText?.detailedForecast ?? "").isEmpty || !(day.nwsNightText?.detailedForecast ?? "").isEmpty
  }

  @ViewBuilder private func narrative(_ period: Weather.PeriodText?) -> some View {
    if let period, !period.detailedForecast.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        Text(period.name.uppercased())
          .font(.system(size: WeatherStyle.caption, weight: .bold))
          .tracking(1)
          .foregroundStyle(.secondary)
        Text(period.detailedForecast)
          .font(.system(size: WeatherStyle.bodySmall))
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Charts

struct ChartContext {
  var isToday: Bool
  var nowHour: Int
  var hoverHour: Int
  func isPast(_ hour: Int) -> Bool { isToday && hour < nowHour }
}

struct SectionHeader: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(.system(size: WeatherStyle.caption, weight: .semibold))
      .tracking(1)
      .foregroundStyle(.secondary)
  }
}

/// Chance of precipitation, one bar per hour, midnight to midnight, with
/// gridlines at every quarter (solid and labelled at 0/50/100 %).
struct RainChart: View {
  let slots: [Weather.Hour?]
  let ctx: ChartContext
  let peak: Weather.Hour?

  static let height: CGFloat = 112
  static let labelRoom: CGFloat = 16
  static let axisRoom: CGFloat = 18
  static var plotH: CGFloat { height - labelRoom - axisRoom }
  var plotX: CGFloat { DayDetailPane.gutter }
  var slotW: CGFloat { DayDetailPane.slotW }
  var width: CGFloat { DayDetailPane.contentW }

  func barHeight(_ pop: Int) -> CGFloat { CGFloat(max(0, min(100, pop))) / 100 * Self.plotH }
  func yAt(_ pop: Int) -> CGFloat { Self.labelRoom + Self.plotH - barHeight(pop) }

  var body: some View {
    ZStack(alignment: .topLeading) {
      Canvas { g, size in
        for q in [0, 25, 50, 75, 100] {
          var p = Path()
          let y = yAt(q).rounded() + 0.5
          p.move(to: CGPoint(x: plotX, y: y))
          p.addLine(to: CGPoint(x: size.width, y: y))
          if q % 50 == 0 {
            g.stroke(p, with: .color(.primary.opacity(q == 0 ? 0.25 : 0.08)), lineWidth: 1)
          } else {
            g.stroke(p, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          }
        }
        // Now, on today's chart: the hours before it are history.
        if ctx.isToday {
          let x = plotX + slotW * CGFloat(ctx.nowHour)
          g.fill(Path(CGRect(x: x - 1, y: Self.labelRoom - 4, width: 2, height: Self.plotH + 4)),
            with: .color(.primary.opacity(0.35)))
        }
        let gap: CGFloat = 2
        for h in 0..<24 {
          guard let pop = slots[h]?.pop, pop > 0 else { continue }
          let w = max(1, slotW - gap)
          // A 1% hour still shows as a sliver.
          let bh = max(2, barHeight(pop))
          let rect = CGRect(x: plotX + slotW * CGFloat(h) + (slotW - w) / 2, y: Self.labelRoom + Self.plotH - bh, width: w, height: bh)
          let r = min(3, w / 2)
          let shape = UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r).path(in: rect)
          let opacity = ctx.hoverHour == h ? 1 : (ctx.isPast(h) ? 0.3 : (ctx.hoverHour >= 0 ? 0.6 : 0.9))
          g.fill(shape, with: .color(.accentColor.opacity(opacity)))
        }
      }
      .frame(width: width, height: Self.height)

      ForEach([0, 50, 100], id: \.self) { q in
        Text("\(q)%")
          .font(.system(size: WeatherStyle.caption).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: plotX - 6, alignment: .trailing)
          .position(x: (plotX - 6) / 2, y: yAt(q))
      }

      // Value over the hovered bar, else over the day's peak.
      let labelHour = ctx.hoverHour >= 0 ? ctx.hoverHour : (peak?.hour ?? -1)
      if labelHour >= 0, let pop = slots[labelHour]?.pop, pop > 0 {
        let x = plotX + slotW * (CGFloat(labelHour) + 0.5)
        Text("\(pop)%")
          .font(.system(size: WeatherStyle.caption).monospacedDigit())
          .fixedSize()
          .position(x: min(max(x, plotX + 16), width - 14), y: yAt(pop) - 9)
      }

      ForEach([0, 6, 12, 18], id: \.self) { h in
        Text(h == 12 ? "Noon" : Weather.hourLabel(h).replacingOccurrences(of: " ", with: ""))
          .font(.system(size: WeatherStyle.caption))
          .foregroundStyle(.secondary)
          .fixedSize()
          .position(x: plotX + slotW * (CGFloat(h) + 0.5), y: Self.labelRoom + Self.plotH + 4 + 7)
      }
    }
    .frame(width: width, height: Self.height)
    .contentShape(Rectangle())
  }
}

/// An hourly line on the rain chart's hour axis: a section title, then the
/// line over the range's gridlines (labelled in the left gutter), its
/// extremes labelled. Past hours (today) are faint; hours no source covers
/// break the line. `fill` shades down to the floor, for zero-based scales.
struct HourLine: View {
  let title: String
  let values: [Double?]
  let range: Weather.ValueRange
  let suffix: String
  let tickSuffix: String
  let labelLow: Bool
  let fill: Bool
  let chartHeight: CGFloat
  let ctx: ChartContext

  var plotX: CGFloat { DayDetailPane.gutter }
  var slotW: CGFloat { DayDetailPane.slotW }
  var width: CGFloat { DayDetailPane.contentW }
  var padTop: CGFloat { 16 }
  var padBottom: CGFloat { fill ? 2 : 16 }

  func value(_ h: Int) -> Double? { h >= 0 && h < values.count ? values[h] : nil }
  func xAt(_ h: Int) -> CGFloat { plotX + slotW * (CGFloat(h) + 0.5) }
  func yAt(_ v: Double) -> CGFloat {
    padTop + (1 - CGFloat((v - range.min) / range.span)) * (chartHeight - padTop - padBottom)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionHeader(title)
      ZStack(alignment: .topLeading) {
        Canvas { g, size in draw(g, size) }
          .frame(width: width, height: chartHeight)

        ForEach(range.ticks, id: \.self) { t in
          Text("\(Weather.jsRound(t))\(tickSuffix)")
            .font(.system(size: WeatherStyle.caption).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: plotX - 6, alignment: .trailing)
            .position(x: (plotX - 6) / 2, y: yAt(t))
        }

        ForEach(extremes(), id: \.hour) { e in
          if let v = value(e.hour) {
            Text("\(Weather.jsRound(v))\(suffix)")
              .font(.system(size: WeatherStyle.caption).monospacedDigit())
              .fixedSize()
              .position(x: min(max(xAt(e.hour), plotX + 18), width - 22), y: e.above ? yAt(v) - 9 : yAt(v) + 9)
          }
        }
      }
      .frame(width: width, height: chartHeight)
      .contentShape(Rectangle())
    }
  }

  /// The highest hour is labelled, and the lowest when labelLow.
  private func extremes() -> [(hour: Int, above: Bool)] {
    var hi = -1, lo = -1
    for h in 0..<24 {
      guard let v = value(h) else { continue }
      if hi < 0 || v > value(hi)! { hi = h }
      if lo < 0 || v < value(lo)! { lo = h }
    }
    if hi < 0 { return [] }
    return hi == lo || !labelLow ? [(hi, true)] : [(hi, true), (lo, false)]
  }

  private func draw(_ g: GraphicsContext, _ size: CGSize) {
    for t in range.ticks {
      let floor = fill && t == range.min
      var p = Path()
      let y = yAt(t).rounded() + 0.5
      p.move(to: CGPoint(x: plotX, y: y))
      p.addLine(to: CGPoint(x: size.width, y: y))
      g.stroke(p, with: .color(.primary.opacity(floor ? 0.25 : 0.08)), lineWidth: 1)
    }

    // One stroke per unbroken run of hours, shaded to the floor first when filling.
    func runs(_ from: Int, _ to: Int, _ color: Color, _ area: Color?) {
      var h = from
      while h <= to {
        while h <= to && value(h) == nil { h += 1 }
        if h > to { break }
        let start = h
        while h + 1 <= to && value(h + 1) != nil { h += 1 }
        let end = h
        h += 1

        if let area {
          let base = yAt(range.min)
          var a = Path()
          a.move(to: CGPoint(x: xAt(start), y: base))
          for k in start...end { a.addLine(to: CGPoint(x: xAt(k), y: yAt(value(k)!))) }
          a.addLine(to: CGPoint(x: xAt(end), y: base))
          a.closeSubpath()
          g.fill(a, with: .color(area))
        }
        var line = Path()
        line.move(to: CGPoint(x: xAt(start), y: yAt(value(start)!)))
        for k in start...end where k > start { line.addLine(to: CGPoint(x: xAt(k), y: yAt(value(k)!))) }
        if start == end { line.addLine(to: CGPoint(x: xAt(start) + 0.01, y: yAt(value(start)!))) }
        g.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      }
    }
    let split = ctx.isToday ? max(0, min(23, ctx.nowHour)) : 0
    if split > 0 { runs(0, split, .primary.opacity(0.3), fill ? .primary.opacity(0.06) : nil) }
    runs(split, 23, .accentColor, fill ? .accentColor.opacity(0.16) : nil)

    if ctx.hoverHour >= 0, let v = value(ctx.hoverHour) {
      let dot = Path(ellipseIn: CGRect(x: xAt(ctx.hoverHour) - 4.5, y: yAt(v) - 4.5, width: 9, height: 9))
      g.fill(dot, with: .color(.accentColor))
      g.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 2)
    }
  }
}
