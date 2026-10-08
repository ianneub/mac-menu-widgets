import Foundation

/// Pure logic for the time widget, kept out of the views so it can be tested.
/// Offsets are minutes east of UTC, times are UTC epoch ms, like Astro.
public enum TimeModel {
  public static let minute: Double = 60_000
  public static let day: Double = 24 * 60 * minute

  // MARK: Zones

  /// Configured zones cleaned up: tz names that aren't plausible tzdata ids are
  /// dropped, and an empty name falls back to the tz's last path segment
  /// ("Asia/Kolkata" -> "Kolkata"). Coordinates are kept only if finite.
  public static func normalizeZones(_ zones: [WidgetsConfig.Zone]) -> [WidgetsConfig.Zone] {
    zones.compactMap { z in
      let tz = z.tz.trimmingCharacters(in: .whitespaces)
      guard !tz.isEmpty, tz.range(of: #"^[A-Za-z0-9_+\-/]+$"#, options: .regularExpression) != nil else { return nil }
      let trimmed = z.name.trimmingCharacters(in: .whitespaces)
      let name = trimmed.isEmpty
        ? (tz.split(separator: "/").last.map(String.init) ?? tz).replacingOccurrences(of: "_", with: " ")
        : trimmed
      var out = WidgetsConfig.Zone(name: name, tz: tz)
      if let lat = z.lat, let lon = z.lon, lat.isFinite, lon.isFinite {
        out.lat = lat
        out.lon = lon
      }
      return out
    }
  }

  public struct Coord: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
  }

  /// tzdata's zone1970.tab / zone.tab -> ["Europe/London": Coord]. The
  /// coordinates column is ISO 6709: +DDMM[SS]+DDDMM[SS].
  public static func parseZoneTab(_ text: String) -> [String: Coord] {
    var out: [String: Coord] = [:]
    let re = try! NSRegularExpression(pattern: #"^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?$"#)
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.hasPrefix("#") { continue }
      let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      if cols.count < 3 { continue }
      let c = cols[1]
      guard let m = re.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)) else { continue }
      func g(_ i: Int) -> String? {
        guard let r = Range(m.range(at: i), in: c) else { return nil }
        return String(c[r])
      }
      func num(_ i: Int) -> Double { g(i).flatMap(Double.init) ?? 0 }
      let lat = num(2) + num(3) / 60 + num(4) / 3600
      let lon = num(6) + num(7) / 60 + num(8) / 3600
      out[cols[2]] = Coord(lat: g(1) == "-" ? -lat : lat, lon: g(5) == "-" ? -lon : lon)
    }
    return out
  }

  /// Reads the system's tzdata reference cities (zone1970.tab where present,
  /// else zone.tab, which is what macOS ships).
  public static func systemZoneCoords() -> [String: Coord] {
    for path in ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"] {
      if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        let parsed = parseZoneTab(text)
        if !parsed.isEmpty { return parsed }
      }
    }
    return [:]
  }

  public struct ZoneOffset: Equatable, Sendable {
    /// Minutes east of UTC.
    public var offset: Int
    /// Letter abbreviation ("BST", "EDT"), or "" when the zone has none.
    public var abbr: String
    public init(offset: Int, abbr: String) { self.offset = offset; self.abbr = abbr }
  }

  /// A zone's offset and abbreviation at an instant. The abbreviation is
  /// tzdata's own ("BST", "CEST", "IST", what `date +%Z` prints), read from
  /// the zone's TZif file: Foundation only knows US abbreviations and spells
  /// the rest "GMT+1". Zones whose tzdata name is numeric ("+0545") get "".
  /// `id` is the tz name as configured: Foundation turns "UTC" into "GMT".
  public static func zoneOffset(_ tz: TimeZone, at date: Date, id: String? = nil) -> ZoneOffset {
    let secs = tz.secondsFromGMT(for: date)
    var abbr = tzifAbbreviation(id ?? tz.identifier, at: date.timeIntervalSince1970, offset: secs,
                                isDST: tz.isDaylightSavingTime(for: date))
      ?? tz.abbreviation(for: date) ?? ""
    if abbr.range(of: "^[A-Za-z]+$", options: .regularExpression) == nil || abbr == "GMT" && secs != 0 {
      abbr = ""
    }
    return ZoneOffset(offset: secs / 60, abbr: abbr)
  }

  nonisolated(unsafe) private static var tzifCache: [String: Data] = [:]
  private static let tzifLock = NSLock()

  static func tzifAbbreviation(_ id: String, at seconds: Double, offset: Int, isDST: Bool) -> String? {
    tzifLock.lock()
    defer { tzifLock.unlock() }
    let data: Data
    if let cached = tzifCache[id] {
      data = cached
    } else {
      guard id.range(of: #"^[A-Za-z0-9_+\-/]+$"#, options: .regularExpression) != nil, !id.contains(".."),
            let d = FileManager.default.contents(atPath: "/usr/share/zoneinfo/" + id) else { return nil }
      tzifCache[id] = d
      data = d
    }
    return tzifAbbreviation(data, at: seconds, offset: offset, isDST: isDST)
  }

  /// The abbreviation in a TZif file for the local time type in force at
  /// `seconds` (the last transition at or before it), provided it agrees with
  /// the offset and DST flag Foundation reports. Past the last transition (or
  /// on disagreement) it falls back to the latest-used type with that offset
  /// and DST flag.
  public static func tzifAbbreviation(_ data: Data, at seconds: Double, offset: Int, isDST: Bool) -> String? {
    let b = [UInt8](data)
    guard b.count >= 44, b[0] == 0x54, b[1] == 0x5A, b[2] == 0x69, b[3] == 0x66 else { return nil }
    func u32(_ at: Int) -> Int {
      guard at + 4 <= b.count else { return 0 }
      return Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }
    func i32(_ at: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(at))) }
    func i64(_ at: Int) -> Int { Int(Int64(bitPattern: UInt64(u32(at)) << 32 | UInt64(u32(at + 4)))) }

    func counts(_ h: Int) -> (isut: Int, isstd: Int, leap: Int, time: Int, type: Int, char: Int) {
      (u32(h + 20), u32(h + 24), u32(h + 28), u32(h + 32), u32(h + 36), u32(h + 40))
    }
    var header = 0
    var c = counts(0)
    var timeSize = 4
    if b[4] >= 0x32 {  // version 2+: skip the 32-bit block for the 64-bit one
      let v1 = 44 + c.time * 4 + c.time + c.type * 6 + c.char + c.leap * 8 + c.isstd + c.isut
      guard v1 + 44 <= b.count else { return nil }
      header = v1
      c = counts(v1)
      timeSize = 8
    }
    let times = header + 44
    let idx = times + c.time * timeSize
    let types = idx + c.time
    let chars = types + c.type * 6
    guard c.type > 0, chars + c.char <= b.count else { return nil }

    func abbr(_ type: Int) -> String {
      var i = chars + Int(b[types + type * 6 + 5])
      var s = ""
      while i < chars + c.char, b[i] != 0 { s.append(Character(UnicodeScalar(b[i]))); i += 1 }
      return s
    }
    func matches(_ type: Int) -> Bool {
      i32(types + type * 6) == offset && (b[types + type * 6 + 4] != 0) == isDST
    }

    var current: Int?
    for i in 0..<c.time {
      let t = timeSize == 8 ? i64(times + i * 8) : i32(times + i * 4)
      if Double(t) > seconds { break }
      current = Int(b[idx + i])
    }
    if let current, current < c.type, matches(current) { return abbr(current) }
    // Latest-used matching type, then any matching type.
    for i in stride(from: c.time - 1, through: 0, by: -1) {
      let t = Int(b[idx + i])
      if t < c.type, matches(t) { return abbr(t) }
    }
    for t in 0..<c.type where matches(t) { return abbr(t) }
    return nil
  }

  // MARK: Labels

  static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

  /// Minutes east of UTC -> "+01:00" / "-04:00".
  public static func offsetLabel(_ minutes: Int) -> String {
    let sign = minutes < 0 ? "-" : "+"
    let a = abs(minutes)
    return sign + pad2(a / 60) + ":" + pad2(a % 60)
  }

  /// Hours as spoken: "1 hour", "9½ hours", "5¾ hours", "30 minutes".
  public static func hoursPhrase(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) minutes" }
    let whole = minutes / 60
    let fracs = [0: "", 15: "¼", 30: "½", 45: "¾"]
    guard let frac = fracs[minutes % 60] else { return "\(whole) hours \(minutes % 60) minutes" }
    return "\(whole)\(frac)" + (minutes == 60 ? " hour" : " hours")
  }

  /// "Same time" / "5 hours ahead" / "3 hours behind", relative to local time.
  public static func relativeLabel(_ zoneOffset: Int, _ localOffset: Int) -> String {
    let diff = zoneOffset - localOffset
    if diff == 0 { return "Same time" }
    return hoursPhrase(abs(diff)) + (diff > 0 ? " ahead" : " behind")
  }

  public struct ZoneClock: Equatable {
    public var hours: Int
    public var minutes: Int
    /// The zone's calendar day minus the local one (+1 = already tomorrow there).
    public var dayDelta: Int
  }

  public static func zoneClock(_ nowMs: Double, _ zoneOffset: Int, _ localOffset: Int) -> ZoneClock {
    let zone = nowMs + Double(zoneOffset) * minute
    let local = nowMs + Double(localOffset) * minute
    let mins = Int(floor(zone / minute))
    let dayMins = ((mins % 1440) + 1440) % 1440
    return ZoneClock(
      hours: dayMins / 60, minutes: dayMins % 60,
      dayDelta: Int(floor(zone / day)) - Int(floor(local / day)))
  }

  public static func dayDeltaLabel(_ delta: Int) -> String {
    delta == 1 ? "Tomorrow" : delta == -1 ? "Yesterday" : ""
  }

  /// ("12:41", "PM") for 12h, ("12:41", "") for 24h.
  public static func clockText(_ hours: Int, _ minutes: Int, _ use24h: Bool) -> (time: String, suffix: String) {
    if use24h { return (pad2(hours) + ":" + pad2(minutes), "") }
    let h = hours % 12
    return ("\(h == 0 ? 12 : h):" + pad2(minutes), hours < 12 ? "AM" : "PM")
  }

  /// The same as one string: "1:01 PM" / "13:01".
  public static func clockLabel(_ hours: Int, _ minutes: Int, _ use24h: Bool) -> String {
    let c = clockText(hours, minutes, use24h)
    return c.time + (c.suffix.isEmpty ? "" : " " + c.suffix)
  }

  /// The menu-bar text: "Thu Oct 8  7:49 AM" with the date (standing in for
  /// the macOS clock, which can't show a date alone), "7:49 AM" without.
  public static func barLabel(_ date: Date, _ use24h: Bool, showDate: Bool, tz: TimeZone = .current) -> String {
    let c = calendar(tz).dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
    let time = clockLabel(c.hour!, c.minute!, use24h)
    guard showDate else { return time }
    return weekdays[c.weekday! - 1] + " " + months[c.month! - 1] + " \(c.day!)  " + time
  }

  static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  static let weekdaysLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  static func calendar(_ tz: TimeZone) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal
  }

  /// Whole calendar days from `now` to `event` in `tz`.
  static func dayDiff(_ eventMs: Double, _ nowMs: Double, _ tz: TimeZone) -> Int {
    let cal = calendar(tz)
    let a = cal.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))
    let b = cal.startOfDay(for: Date(timeIntervalSince1970: eventMs / 1000))
    return cal.dateComponents([.day], from: a, to: b).day ?? 0
  }

  /// When an event falls, in `tz` (local by default), relative to now:
  /// "today 12:49 PM", "tomorrow 1:10 AM", "Wed 3:00 PM", "Oct 3".
  public static func whenLabel(_ eventMs: Double, _ nowMs: Double, _ use24h: Bool, tz: TimeZone = .current) -> String {
    let cal = calendar(tz)
    let ev = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: Date(timeIntervalSince1970: eventMs / 1000))
    let days = dayDiff(eventMs, nowMs, tz)
    let time = clockLabel(ev.hour!, ev.minute!, use24h)
    if days == 0 { return "today " + time }
    if days == 1 { return "tomorrow " + time }
    if days < 7 { return weekdays[ev.weekday! - 1] + " " + time }
    return months[ev.month! - 1] + " \(ev.day!)"
  }

  public struct PhaseWhen: Equatable {
    public var date: String
    public var time: String
    public var rel: String
  }

  /// A moon phase's local date, time and distance from today, for the phase
  /// pop-out: ("Wed, Oct 14", "3:47 PM", "in 7 days").
  public static func phaseWhen(_ eventMs: Double, _ nowMs: Double, _ use24h: Bool, tz: TimeZone = .current) -> PhaseWhen {
    let cal = calendar(tz)
    let ev = cal.dateComponents([.month, .day, .hour, .minute, .weekday], from: Date(timeIntervalSince1970: eventMs / 1000))
    let days = dayDiff(eventMs, nowMs, tz)
    return PhaseWhen(
      date: weekdays[ev.weekday! - 1] + ", " + months[ev.month! - 1] + " \(ev.day!)",
      time: clockLabel(ev.hour!, ev.minute!, use24h),
      rel: days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")
  }

  // MARK: Detail pane

  /// Midnight at the start of the zone's current day, as UTC ms.
  public static func dayStartFor(_ nowMs: Double, _ zoneOffset: Int) -> Double {
    let off = Double(zoneOffset) * minute
    return floor((nowMs + off) / day) * day - off
  }

  /// "Sunday  ·  13:05  ·  BST UTC+01:00": a place's weekday, 24 h clock and offset.
  public static func placeWhenLabel(_ nowMs: Double, _ offset: Int, _ abbr: String) -> String {
    let shifted = nowMs + Double(offset) * minute
    let mins = Int(floor(shifted / minute))
    let dayMins = ((mins % 1440) + 1440) % 1440
    let dayNum = Int(floor(shifted / day))
    let weekday = ((dayNum + 4) % 7 + 7) % 7  // 1970-01-01 was a Thursday
    let zone = (abbr.isEmpty || abbr == "UTC" ? "" : abbr + " ") + "UTC" + offsetLabel(offset)
    return weekdaysLong[weekday] + "  ·  " + clockLabel(dayMins / 60, dayMins % 60, true) + "  ·  " + zone
  }

  /// An event's wall-clock time in a zone, rounded to the nearest minute
  /// ("6:52 AM"); "—" when the event doesn't happen that day.
  public static func timeInZone(_ ms: Double?, _ zoneOffset: Int, _ use24h: Bool) -> String {
    guard let ms else { return "—" }
    let shifted = ms + Double(zoneOffset) * minute + 30_000
    let mins = Int(floor(shifted / minute))
    let dayMins = ((mins % 1440) + 1440) % 1440
    return clockLabel(dayMins / 60, dayMins % 60, use24h)
  }

  /// Countdown, truncated like iStat: "5h 59m", "37m".
  public static func durationShort(_ ms: Double) -> String {
    let mins = max(0, Int(floor(ms / minute)))
    let h = mins / 60
    return h > 0 ? "\(h)h \(mins % 60)m" : "\(mins % 60)m"
  }

  static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)" + (n == 1 ? "" : "s") }

  /// "11 hours, 57 minutes of daylight".
  public static func daylightLabel(_ ms: Double?, _ polar: Astro.Polar) -> String {
    if polar == .up { return "Sun up all day" }
    if polar == .down { return "Sun down all day" }
    guard let ms else { return "" }
    let mins = Int((ms / minute).rounded())
    return plural(mins / 60, "hour") + ", " + plural(mins % 60, "minute") + " of daylight"
  }

  /// Change from yesterday: "−4 minutes", "+38 seconds". Minus is U+2212.
  public static func daylightChange(_ deltaMs: Double?) -> String {
    guard let deltaMs, !deltaMs.isNaN else { return "" }
    let secs = Int((deltaMs / 1000).rounded())
    if secs == 0 { return "Same as yesterday" }
    let sign = secs < 0 ? "\u{2212}" : "+"
    let a = abs(secs)
    let body = a < 60 ? plural(a, "second") : plural(Int((Double(a) / 60).rounded()), "minute")
    return sign + body + " vs yesterday"
  }
}
