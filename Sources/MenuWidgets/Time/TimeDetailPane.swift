import SwiftUI
import WidgetsCore

/// The card that floats beside the world clock while a row is hovered, after
/// iStat Menus' location detail: a day/night map, sun and moon times, the sun
/// and moon over the next and last 12 hours, twilight and magic hours. Times
/// are the place's own wall clock. Without coordinates (UTC) only the map and
/// a hint are shown.
struct TimeDetailPane: View {
  @ObservedObject var state: TimeState
  let index: Int

  static let width: CGFloat = 420
  static let column: CGFloat = 84

  var body: some View {
    if let place = state.place(index) {
      content(place)
        .padding(14)
        .frame(width: Self.width)
    } else {
      EmptyView()
    }
  }

  @ViewBuilder
  private func content(_ place: TimePlace) -> some View {
    let nowMs = state.nowMs
    let use24h = state.use24h
    let info = TimePlaceAstro(place: place, nowMs: nowMs)
    let t = { (ms: Double?) in TimeModel.timeInZone(ms, place.offset, use24h) }

    VStack(alignment: .leading, spacing: 12) {
      // ---- Where and when.
      HStack(alignment: .firstTextBaseline) {
        Text(place.name).font(.title3.weight(.bold)).lineLimit(1)
        Spacer(minLength: 12)
        Text(TimeModel.placeWhenLabel(nowMs, place.offset, place.abbr))
          .font(.callout).foregroundStyle(.secondary).monospacedDigit()
      }

      TimeDayNightMap(nowMs: nowMs, dots: state.mapDots, place: place.coord)
        .frame(height: (Self.width - 28) * (84 + 58) / 360)

      if let e = info.events {
        // ---- Sun and moon: rise, highest point, set.
        VStack(alignment: .leading, spacing: 4) {
          TableHeader(title: "SUN & MOON", heads: ["RISE", "HIGHEST", "SET"])
          TableRow(symbol: "sun.max", label: "Sun", values: [t(e.sunrise), t(e.solarNoon), t(e.sunset)])
          TableRow(symbol: "moon", label: "Moon", values: [t(e.moonrise), t(e.moonTransit), t(e.moonset)])
        }
        VStack(spacing: 1) {
          Text(TimeModel.daylightLabel(e.daylight, e.polar)).font(.callout)
          if let y = info.yesterday, e.polar == .none, y.polar == .none,
             let a = e.daylight, let b = y.daylight {
            Text(TimeModel.daylightChange(a - b)).font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity)

        // ---- Sun and moon altitude, 12 hours either side of now (the middle).
        if let curves = info.curves {
          TimeAltitudeChart(sun: curves.sun, moon: curves.moon)
            .frame(height: 110)
            .overlay(alignment: .bottomLeading) {
              Text(horizonLabel(info.nextSun, .sun, e, nowMs)).font(.caption).padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
              Text(horizonLabel(info.nextMoon, .moon, e, nowMs)).font(.caption).padding(6)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
          TableHeader(title: "TWILIGHT", heads: ["DAWN", "DUSK"])
          TableRow(symbol: "sun.horizon", label: "Civil", values: [t(e.civil.start), t(e.civil.end)])
          TableRow(symbol: "sun.horizon", label: "Nautical", values: [t(e.nautical.start), t(e.nautical.end)])
          TableRow(symbol: "sun.horizon", label: "Astronomical", values: [t(e.astronomical.start), t(e.astronomical.end)])
        }

        VStack(alignment: .leading, spacing: 4) {
          TableHeader(title: "MAGIC HOURS", heads: ["START", "END"])
          TableRow(symbol: "camera.aperture", label: "Blue hour", values: [t(e.blueMorning.start), t(e.blueMorning.end)])
          TableRow(symbol: "camera.aperture", label: "Golden hour", values: [t(e.goldenMorning.start), t(e.goldenMorning.end)])
          TableRow(symbol: "camera.aperture", label: "Golden hour", values: [t(e.goldenEvening.start), t(e.goldenEvening.end)])
          TableRow(symbol: "camera.aperture", label: "Blue hour", values: [t(e.blueEvening.start), t(e.blueEvening.end)])
        }
      } else {
        Text("No location for this zone. Add \"lat\" and \"lon\" to its entry in ~/.config/menu-widgets/config.json for sun and moon times.")
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func horizonLabel(_ ev: Astro.Crossing?, _ body: Astro.Body, _ e: Astro.DayEvents, _ nowMs: Double) -> String {
    guard let ev else {
      return body == .sun ? "Sun stays " + (e.polar == .down ? "down" : "up") : ""
    }
    let what = body == .sun ? (ev.rising ? "Sunrise" : "Sunset") : (ev.rising ? "Moonrise" : "Moonset")
    return what + " in " + TimeModel.durationShort(ev.ms - nowMs)
  }

  private struct TableHeader: View {
    let title: String
    let heads: [String]
    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        TimeSectionHeader(title)
        Spacer(minLength: 0)
        ForEach(heads, id: \.self) { h in
          Text(h).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            .frame(width: TimeDetailPane.column, alignment: .trailing)
        }
      }
    }
  }

  private struct TableRow: View {
    let symbol: String
    let label: String
    let values: [String]
    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Image(systemName: symbol).font(.callout).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
        Text(label).font(.callout)
        Spacer(minLength: 0)
        ForEach(Array(values.enumerated()), id: \.offset) { _, v in
          Text(v).font(.callout).monospacedDigit().frame(width: TimeDetailPane.column, alignment: .trailing)
        }
      }
    }
  }
}

/// The astronomy for one place at one minute.
private struct TimePlaceAstro {
  var events: Astro.DayEvents?
  var yesterday: Astro.DayEvents?
  var nextSun: Astro.Crossing?
  var nextMoon: Astro.Crossing?
  var curves: (sun: [Double], moon: [Double])?

  init(place: TimePlace, nowMs: Double) {
    guard let c = place.coord else { return }
    let dayStart = TimeModel.dayStartFor(nowMs, place.offset)
    events = Astro.dayEvents(lat: c.lat, lon: c.lon, dayStart: dayStart)
    yesterday = Astro.dayEvents(lat: c.lat, lon: c.lon, dayStart: dayStart - Astro.day)
    nextSun = Astro.nextHorizonEvent(.sun, lat: c.lat, lon: c.lon, from: nowMs)
    nextMoon = Astro.nextHorizonEvent(.moon, lat: c.lat, lon: c.lon, from: nowMs)
    curves = Astro.altitudeCurves(lat: c.lat, lon: c.lon, start: nowMs - 12 * Astro.hour, end: nowMs + 12 * Astro.hour, count: 97)
  }
}

/// Equirectangular day/night map, 180°W–180°E by 84°N–58°S: land, the night
/// side, every place's dot, the moon and the sun overhead points, and the
/// shown place in the accent color.
struct TimeDayNightMap: View {
  let nowMs: Double
  let dots: [TimeModel.Coord]
  let place: TimeModel.Coord?

  static let latTop = 84.0, latBottom = -58.0
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    // Night is the background color laid over the map in dark mode; in light
    // mode that would lighten it, so night is a dark wash there instead.
    let nightColor = scheme == .dark ? Color(nsColor: .windowBackgroundColor).opacity(0.72) : Color.black.opacity(0.22)
    Canvas { ctx, size in
      let W = size.width, H = size.height
      func X(_ lon: Double) -> CGFloat { (lon + 180) / 360 * W }
      func Y(_ lat: Double) -> CGFloat {
        max(0, min(H, (Self.latTop - lat) / (Self.latTop - Self.latBottom) * H))
      }

      ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(.primary.opacity(0.12)))

      var land = Path()
      for ring in WorldMap.land {
        land.move(to: CGPoint(x: X(ring[0]), y: Y(ring[1])))
        var j = 2
        while j < ring.count {
          land.addLine(to: CGPoint(x: X(ring[j]), y: Y(ring[j + 1])))
          j += 2
        }
        land.closeSubpath()
      }
      ctx.fill(land, with: .color(.primary.opacity(0.30)))

      // Night: from the terminator to whichever pole is dark.
      let sun = Astro.subSolar(nowMs)
      let edge: CGFloat = sun.lat >= 0 ? H : 0
      var night = Path()
      night.move(to: CGPoint(x: 0, y: edge))
      var lon = -180.0
      while lon <= 180 {
        night.addLine(to: CGPoint(x: X(lon), y: Y(Astro.terminatorLat(lon, sun))))
        lon += 2
      }
      night.addLine(to: CGPoint(x: W, y: edge))
      night.closeSubpath()
      ctx.fill(night, with: .color(nightColor))

      func disc(_ lat: Double, _ lon: Double, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: X(lon) - r, y: Y(lat) - r, width: 2 * r, height: 2 * r))
      }

      for d in dots { ctx.fill(disc(d.lat, d.lon, 2.5), with: .color(.primary.opacity(0.85))) }

      let moon = Astro.subLunar(nowMs)
      ctx.fill(disc(moon.lat, moon.lon, 4.5), with: .color(.primary.opacity(0.55)))

      // Sun: a disc with eight short rays.
      let sx = X(sun.lon), sy = Y(sun.lat)
      ctx.fill(disc(sun.lat, sun.lon, 4.5), with: .color(.primary))
      var rays = Path()
      for a in 0..<8 {
        let ang = Double(a) * .pi / 4
        rays.move(to: CGPoint(x: sx + cos(ang) * 7, y: sy + sin(ang) * 7))
        rays.addLine(to: CGPoint(x: sx + cos(ang) * 10, y: sy + sin(ang) * 10))
      }
      ctx.stroke(rays, with: .color(.primary), lineWidth: 1.5)

      if let p = place {
        let d = disc(p.lat, p.lon, 5)
        ctx.fill(d, with: .color(.accentColor))
        ctx.stroke(d, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
      }
    }
  }
}

/// Sun (accent) and moon altitude across ±12 h, now in the middle; above the
/// horizon line is day sky.
struct TimeAltitudeChart: View {
  let sun: [Double]
  let moon: [Double]

  var body: some View {
    Canvas { ctx, size in
      let W = size.width, H = size.height
      let horizon = (H * 0.5).rounded()
      func Y(_ alt: Double) -> CGFloat { horizon - alt / 90 * (horizon - 8) }
      func X(_ i: Int, _ n: Int) -> CGFloat { CGFloat(i) / CGFloat(n - 1) * W }

      ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: horizon)), with: .color(.primary.opacity(0.10)))
      ctx.fill(Path(CGRect(x: 0, y: horizon, width: W, height: H - horizon)), with: .color(.primary.opacity(0.03)))
      var line = Path()
      line.move(to: CGPoint(x: 0, y: horizon + 0.5))
      line.addLine(to: CGPoint(x: W, y: horizon + 0.5))
      ctx.stroke(line, with: .color(.primary.opacity(0.35)), lineWidth: 1)

      func curve(_ values: [Double]) -> Path {
        var p = Path()
        for (i, v) in values.enumerated() {
          let pt = CGPoint(x: X(i, values.count), y: Y(v))
          i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
      }
      ctx.stroke(curve(moon), with: .color(.primary.opacity(0.45)), lineWidth: 1.5)
      ctx.stroke(curve(sun), with: .color(.accentColor), lineWidth: 2)

      guard !sun.isEmpty else { return }
      let mid = (sun.count - 1) / 2
      ctx.fill(Path(ellipseIn: CGRect(x: W / 2 - 5, y: Y(moon[mid]) - 5, width: 10, height: 10)), with: .color(.primary.opacity(0.7)))
      ctx.fill(Path(ellipseIn: CGRect(x: W / 2 - 7, y: Y(sun[mid]) - 7, width: 14, height: 14)), with: .color(.accentColor))
    }
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}
