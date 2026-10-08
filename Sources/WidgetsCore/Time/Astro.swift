import Foundation

/// Sun and moon positions and the day's events for a place, from low-precision
/// series (Meeus, "Astronomical Algorithms", and Paul Schlyter's summary of the
/// same). Good to a couple of minutes for rise/set and phase times, which is as
/// close as refraction lets any of them be anyway. All times are UTC epoch ms,
/// all angles degrees, longitudes east-positive.
public enum Astro {
  public static let minute: Double = 60_000
  public static let hour: Double = 60 * minute
  public static let day: Double = 24 * hour

  static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
  static func deg(_ r: Double) -> Double { r * 180 / .pi }
  static func norm360(_ x: Double) -> Double {
    let y = x.truncatingRemainder(dividingBy: 360)
    return y < 0 ? y + 360 : y
  }
  static func norm180(_ x: Double) -> Double {
    let y = norm360(x)
    return y > 180 ? y - 360 : y
  }

  /// Days since J2000.0.
  static func days(_ ms: Double) -> Double { ms / day + 2440587.5 - 2451545.0 }

  static func obliquity(_ d: Double) -> Double { 23.4393 - 3.563e-7 * d }

  /// Greenwich mean sidereal time.
  static func gmst(_ ms: Double) -> Double { norm360(280.46061837 + 360.98564736629 * days(ms)) }

  public struct Equatorial { public var ra: Double; public var dec: Double }
  public struct GeoPoint: Equatable { public var lat: Double; public var lon: Double }

  static func toEquatorial(lon: Double, lat: Double, eps: Double) -> Equatorial {
    let l = rad(lon), b = rad(lat), e = rad(eps)
    let ra = atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
    let dec = asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
    return Equatorial(ra: norm360(deg(ra)), dec: deg(dec))
  }

  static func sunLongitude(_ d: Double) -> Double {
    let g = rad(norm360(357.5291 + 0.98560028 * d))
    return norm360(280.4665 + 0.98564736 * d + 1.915 * sin(g) + 0.020 * sin(2 * g))
  }

  /// Geocentric ecliptic longitude and latitude of the moon: the largest
  /// periodic terms of Meeus ch. 47.
  static func moonEcliptic(_ d: Double) -> (lon: Double, lat: Double) {
    let Ms = rad(norm360(357.5291 + 0.98560028 * d))  // sun mean anomaly
    let L = 218.3165 + 13.17639648 * d                 // moon mean longitude
    let M = rad(norm360(134.9634 + 13.06499295 * d))   // moon mean anomaly
    let D = rad(norm360(297.8502 + 12.19074912 * d))   // mean elongation
    let F = rad(norm360(93.2721 + 13.22935024 * d))    // argument of latitude
    var lon = L
    lon += 6.289 * sin(M)
    lon -= 1.274 * sin(M - 2 * D)
    lon += 0.658 * sin(2 * D)
    lon -= 0.186 * sin(Ms)
    lon += 0.214 * sin(2 * M)
    lon -= 0.114 * sin(2 * F)
    lon -= 0.059 * sin(2 * M - 2 * D)
    lon -= 0.057 * sin(M - 2 * D + Ms)
    lon += 0.053 * sin(M + 2 * D)
    lon += 0.046 * sin(2 * D - Ms)
    lon += 0.041 * sin(M - Ms)
    lon -= 0.035 * sin(D)
    lon -= 0.031 * sin(M + Ms)
    lon -= 0.015 * sin(2 * F - 2 * D)
    lon += 0.011 * sin(M - 4 * D)
    var lat = 5.128 * sin(F)
    lat += 0.281 * sin(M + F)
    lat += 0.278 * sin(M - F)
    lat += 0.173 * sin(2 * D - F)
    lat += 0.055 * sin(2 * D - M + F)
    lat += 0.046 * sin(2 * D - M - F)
    lat += 0.033 * sin(2 * D + F)
    lat += 0.017 * sin(2 * M + F)
    return (norm360(lon), lat)
  }

  static func sunEquatorial(_ ms: Double) -> Equatorial {
    let d = days(ms)
    return toEquatorial(lon: sunLongitude(d), lat: 0, eps: obliquity(d))
  }

  static func moonEquatorial(_ ms: Double) -> Equatorial {
    let d = days(ms)
    let m = moonEcliptic(d)
    return toEquatorial(lon: m.lon, lat: m.lat, eps: obliquity(d))
  }

  // MARK: Phase

  /// Degrees the moon is east of the sun: 0 new, 90 first quarter, 180 full, 270 last quarter.
  public static func moonElongation(_ ms: Double) -> Double {
    let d = days(ms)
    return norm360(moonEcliptic(d).lon - sunLongitude(d))
  }

  public static let principal = ["New Moon", "First Quarter", "Full Moon", "Last Quarter"]
  static let between = ["Waxing Crescent", "Waxing Gibbous", "Waning Gibbous", "Waning Crescent"]

  /// Principal phases are instants, so like iStat and timeanddate the name only
  /// shows within ~2 hours of one (the moon gains ~1° on the sun per 2 hours).
  public static func phaseName(_ elongation: Double) -> String {
    let rounded = (elongation / 90).rounded(.toNearestOrAwayFromZero)
    let nearest = Int(rounded) % 4
    let gap = abs(elongation - rounded * 90)
    if gap < 1 { return principal[nearest] }
    return between[Int(floor(elongation / 90))]
  }

  /// Signed degrees from `target` to the elongation, in (-180, 180].
  static func angleFrom(_ elongation: Double, _ target: Double) -> Double {
    norm180(elongation - target)
  }

  public struct Phase: Equatable {
    public var name: String
    public var ms: Double
  }

  /// The next principal phase after `ms`. Steps 6 h at a time (the elongation
  /// grows ~3° per step, so no 90° mark is skipped), then bisects.
  public static func nextPrincipal(_ ms: Double) -> Phase {
    let target = Double((Int(floor(moonElongation(ms) / 90)) + 1) * 90 % 360)
    var lo = ms
    var hi = ms
    for _ in 0..<200 {
      hi = lo + 6 * hour
      if angleFrom(moonElongation(hi), target) >= 0 { break }
      lo = hi
    }
    while hi - lo > minute {
      let mid = (lo + hi) / 2
      if angleFrom(moonElongation(mid), target) >= 0 { hi = mid } else { lo = mid }
    }
    return Phase(name: principal[Int(target / 90)], ms: hi.rounded())
  }

  /// The next `count` principal phases after `ms`, in order.
  public static func upcomingPhases(_ ms: Double, count: Int) -> [Phase] {
    var out: [Phase] = []
    var from = ms
    for _ in 0..<count {
      let p = nextPrincipal(from)
      out.append(p)
      // An hour on, the moon is ~0.5° past the mark, so the search moves on.
      from = p.ms + hour
    }
    return out
  }

  public struct MoonInfo {
    public var elongation: Double
    public var illumination: Double
    public var waxing: Bool
    public var name: String
    public var next: Phase
  }

  public static func moonInfo(_ ms: Double) -> MoonInfo {
    let e = moonElongation(ms)
    return MoonInfo(
      elongation: e,
      illumination: (1 - cos(rad(e))) / 2,
      waxing: e < 180,
      name: phaseName(e),
      next: nextPrincipal(ms))
  }

  // MARK: Positions in the sky

  static func altitudeOf(_ eq: Equatorial, _ ms: Double, _ lat: Double, _ lon: Double) -> Double {
    let H = rad(gmst(ms) + lon - eq.ra)
    let p = rad(lat), dec = rad(eq.dec)
    return deg(asin(sin(p) * sin(dec) + cos(p) * cos(dec) * cos(H)))
  }

  public static func sunAltitude(_ ms: Double, lat: Double, lon: Double) -> Double {
    altitudeOf(sunEquatorial(ms), ms, lat, lon)
  }

  /// Topocentric: the moon is close enough that parallax lowers it by up to ~0.95°.
  public static func moonAltitude(_ ms: Double, lat: Double, lon: Double) -> Double {
    let a = altitudeOf(moonEquatorial(ms), ms, lat, lon)
    return a - 0.9507 * cos(rad(a))
  }

  /// The point on Earth with the body straight overhead, for the map.
  static func subPoint(_ eq: Equatorial, _ ms: Double) -> GeoPoint {
    GeoPoint(lat: eq.dec, lon: norm180(eq.ra - gmst(ms)))
  }

  public static func subSolar(_ ms: Double) -> GeoPoint { subPoint(sunEquatorial(ms), ms) }
  public static func subLunar(_ ms: Double) -> GeoPoint { subPoint(moonEquatorial(ms), ms) }

  /// Latitude of the day/night line at a longitude, given the subsolar point.
  public static func terminatorLat(_ lon: Double, _ sub: GeoPoint) -> Double {
    let dec = abs(sub.lat) < 0.01 ? 0.01 : sub.lat
    return deg(atan(-cos(rad(lon - sub.lon)) / tan(rad(dec))))
  }

  // MARK: Events

  struct Samples { var t: [Double]; var a: [Double] }

  /// Altitude sampled every `step` ms across [start, end].
  static func sample(_ fn: (Double) -> Double, _ start: Double, _ end: Double, _ step: Double) -> Samples {
    var t: [Double] = [], a: [Double] = []
    var ms = start
    while ms <= end + 1 {
      t.append(ms)
      a.append(fn(ms))
      ms += step
    }
    return Samples(t: t, a: a)
  }

  public struct Crossing: Equatable {
    public var ms: Double
    public var rising: Bool
  }

  /// Times the altitude crosses `h` inside the samples, bisected to the second.
  static func crossings(_ fn: (Double) -> Double, _ s: Samples, _ h: Double) -> [Crossing] {
    var out: [Crossing] = []
    for i in 1..<s.t.count {
      let a0 = s.a[i - 1] - h, a1 = s.a[i] - h
      if (a0 < 0) == (a1 < 0) { continue }
      var lo = s.t[i - 1], hi = s.t[i]
      let rising = a0 < 0
      while hi - lo > 1000 {
        let mid = (lo + hi) / 2
        if (fn(mid) - h < 0) == rising { lo = mid } else { hi = mid }
      }
      out.append(Crossing(ms: ((lo + hi) / 2).rounded(), rising: rising))
    }
    return out
  }

  static func firstOf(_ list: [Crossing], _ rising: Bool) -> Double? {
    list.first { $0.rising == rising }?.ms
  }

  static func lastOf(_ list: [Crossing], _ rising: Bool) -> Double? {
    list.last { $0.rising == rising }?.ms
  }

  /// Meridian transit (solar noon, moon transit): the hour angle crossing zero
  /// upward. It also wraps from +180 to -180 once a day, but that's a falling
  /// crossing and gets skipped.
  static func transit(_ eqFn: @escaping (Double) -> Equatorial, _ lon: Double, _ start: Double, _ end: Double) -> Double? {
    let haFn = { (ms: Double) in norm180(gmst(ms) + lon - eqFn(ms).ra) }
    return firstOf(crossings(haFn, sample(haFn, start, end, 10 * minute), 0), true)
  }

  static let riseSet = -0.833  // refraction + semidiameter, for both sun and moon

  public struct Span: Equatable {
    public var start: Double?
    public var end: Double?
  }

  public enum Polar: String { case none = "", up, down }

  public struct DayEvents {
    public var sunrise: Double?
    public var sunset: Double?
    public var solarNoon: Double?
    public var daylight: Double?
    /// Sun never crosses the horizon today: up (midnight sun) or down (polar night).
    public var polar: Polar
    public var moonrise: Double?
    public var moonset: Double?
    public var moonTransit: Double?
    /// start = dawn, end = dusk.
    public var civil: Span
    public var nautical: Span
    public var astronomical: Span
    public var blueMorning: Span
    public var goldenMorning: Span
    public var goldenEvening: Span
    public var blueEvening: Span
  }

  /// Everything the detail pane lists for one local day starting at `dayStart`
  /// (the place's midnight, as UTC ms). Missing events are nil: polar days, or
  /// a moon that doesn't rise or set that day.
  public static func dayEvents(lat: Double, lon: Double, dayStart: Double) -> DayEvents {
    let sunFn = { (ms: Double) in sunAltitude(ms, lat: lat, lon: lon) }
    let moonFn = { (ms: Double) in moonAltitude(ms, lat: lat, lon: lon) }
    let end = dayStart + day
    let sun = sample(sunFn, dayStart, end, 10 * minute)
    let moon = sample(moonFn, dayStart, end, 10 * minute)

    func at(_ h: Double) -> [Crossing] { crossings(sunFn, sun, h) }
    let rs = at(riseSet), c6 = at(-6), c12 = at(-12), c18 = at(-18), c4 = at(-4), g6 = at(6)
    let mc = crossings(moonFn, moon, riseSet)

    let noon = transit(sunEquatorial, lon, dayStart, end)
    let noonAlt = noon.map(sunFn) ?? (sun.a.max() ?? 0)
    let sunrise = firstOf(rs, true), sunset = lastOf(rs, false)
    let daylight: Double?
    if let r = sunrise, let s = sunset, s > r { daylight = s - r }
    else if rs.isEmpty { daylight = noonAlt > riseSet ? day : 0 }
    else { daylight = nil }

    return DayEvents(
      sunrise: sunrise,
      sunset: sunset,
      solarNoon: noon,
      daylight: daylight,
      polar: rs.isEmpty ? (noonAlt > riseSet ? .up : .down) : .none,
      moonrise: firstOf(mc, true),
      moonset: firstOf(mc, false),
      moonTransit: transit(moonEquatorial, lon, dayStart, end),
      civil: Span(start: firstOf(c6, true), end: lastOf(c6, false)),
      nautical: Span(start: firstOf(c12, true), end: lastOf(c12, false)),
      astronomical: Span(start: firstOf(c18, true), end: lastOf(c18, false)),
      blueMorning: Span(start: firstOf(c6, true), end: firstOf(c4, true)),
      goldenMorning: Span(start: firstOf(c4, true), end: firstOf(g6, true)),
      goldenEvening: Span(start: lastOf(g6, false), end: lastOf(c4, false)),
      blueEvening: Span(start: lastOf(c4, false), end: lastOf(c6, false)))
  }

  public enum Body { case sun, moon }

  /// The next rise or set of a body within two days, or nil.
  public static func nextHorizonEvent(_ body: Body, lat: Double, lon: Double, from: Double) -> Crossing? {
    let fn: (Double) -> Double = body == .moon
      ? { moonAltitude($0, lat: lat, lon: lon) }
      : { sunAltitude($0, lat: lat, lon: lon) }
    let s = sample(fn, from, from + 2 * day, 10 * minute)
    return crossings(fn, s, riseSet).first
  }

  /// Altitude curves for the chart: `count` evenly spaced samples of each body
  /// across [start, end].
  public static func altitudeCurves(lat: Double, lon: Double, start: Double, end: Double, count: Int) -> (sun: [Double], moon: [Double]) {
    var sun: [Double] = [], moon: [Double] = []
    for i in 0..<count {
      let ms = start + (end - start) * Double(i) / Double(count - 1)
      sun.append(sunAltitude(ms, lat: lat, lon: lon))
      moon.append(moonAltitude(ms, lat: lat, lon: lon))
    }
    return (sun, moon)
  }
}
