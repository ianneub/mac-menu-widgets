import Foundation

// Pure weather logic, ported from the Omarchy ianneub.weather plugin's
// Model.js. US locations take their daily forecast, today's high/low and the
// icons from api.weather.gov (the forecast weather.gov shows); Open-Meteo
// supplies current conditions, non-US locations, rows past NWS's seven days,
// and the hours NWS's hourly forecast doesn't cover.
//
// The Mac port always has stored coordinates (config.json), so the plugin's
// wttr.in IP-auto-detect path is left out.

public enum Weather {

  // MARK: - Types

  /// One forecast row. Temperatures are rounded whole degrees.
  public struct Day: Equatable, Sendable {
    public var date: String
    public var maxtempF: Int?
    public var mintempF: Int?
    public var maxtempC: Int?
    public var mintempC: Int?
    public var openMeteoWeatherCode: Int?
    public var nwsIconCode: String?
    public var nwsNight: Bool = false
    /// Chance of precipitation in percent, nil when the source has none.
    public var precipChance: Double?
    public var nwsDayText: PeriodText?
    public var nwsNightText: PeriodText?

    public init(date: String) { self.date = date }
  }

  /// The parts of an NWS period the detail pane reads out.
  public struct PeriodText: Equatable, Sendable {
    public var name: String
    public var shortForecast: String
    public var detailedForecast: String
  }

  public enum HourSource: String, Sendable { case nws, openMeteo = "open-meteo" }

  /// One hour, in the forecast location's own wall-clock time.
  public struct Hour: Equatable, Sendable {
    public var date: String
    public var hour: Int
    public var pop: Int?
    public var tempF: Double?
    public var windMph: Double?
    public var windDir: Double?
    /// Relative humidity in percent.
    public var humidity: Double?
    public var dewPointF: Double?
    /// NWS hours only: the hour's dominant condition and whether it's night.
    public var nwsIconCode: String?
    public var nwsNight: Bool
    public var source: HourSource
    public init(date: String, hour: Int, pop: Int?, tempF: Double?, windMph: Double?, windDir: Double? = nil,
      humidity: Double? = nil, dewPointF: Double? = nil, nwsIconCode: String? = nil, nwsNight: Bool = false,
      source: HourSource) {
      self.date = date; self.hour = hour; self.pop = pop; self.tempF = tempF
      self.windMph = windMph; self.windDir = windDir
      self.humidity = humidity; self.dewPointF = dewPointF
      self.nwsIconCode = nwsIconCode; self.nwsNight = nwsNight; self.source = source
    }
  }

  public struct ValueRange: Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var span: Double
    public var ticks: [Double] = []
  }

  public struct DayExtras: Equatable, Sendable {
    public var precipMm: Double?
    public var precipIn: Double?
    public var uvIndex: Double?
    public var windMph: Double?
    public var windKmh: Double?
    public var gustMph: Double?
    public var gustKmh: Double?
    public var sunrise: String
    public var sunset: String
  }

  public struct Current: Equatable, Sendable {
    public var tempC: Int
    public var tempF: Int
    public var feelsLikeC: Int?
    public var feelsLikeF: Int?
    public var windKmh: Int?
    public var windMph: Int?
    public var humidity: Int?
    public var weatherCode: Int?
    public var isDay: Bool
  }

  /// A forecast location rounded to the four decimals NWS accepts; `key`
  /// doubles as the /points path and the tag tying NWS data to its place.
  public struct Point: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var key: String
  }

  public enum NwsPoint: Equatable, Sendable {
    case forecast(String)
    /// Outside NWS coverage (anywhere outside the US).
    case none
  }

  // MARK: - Open-Meteo payload

  public struct OpenMeteoReport: Codable, Sendable, Equatable {
    public struct Daily: Codable, Sendable, Equatable {
      public var time: [String]
      public var weather_code: [Double?]?
      public var temperature_2m_max: [Double?]?
      public var temperature_2m_min: [Double?]?
      public var precipitation_sum: [Double?]?
      public var precipitation_probability_max: [Double?]?
      public var sunrise: [String?]?
      public var sunset: [String?]?
      public var uv_index_max: [Double?]?
      public var wind_speed_10m_max: [Double?]?
      public var wind_gusts_10m_max: [Double?]?
    }
    public struct Hourly: Codable, Sendable, Equatable {
      public var time: [String]
      public var temperature_2m: [Double?]?
      public var precipitation_probability: [Double?]?
      public var wind_speed_10m: [Double?]?
      public var wind_direction_10m: [Double?]?
      public var relative_humidity_2m: [Double?]?
      public var dew_point_2m: [Double?]?
    }
    public struct CurrentBlock: Codable, Sendable, Equatable {
      public var temperature_2m: Double?
      public var apparent_temperature: Double?
      public var relative_humidity_2m: Double?
      public var wind_speed_10m: Double?
      public var weather_code: Double?
      public var is_day: Double?
    }
    public var daily: Daily?
    public var hourly: Hourly?
    public var current: CurrentBlock?

    public static func parse(_ data: Data) -> OpenMeteoReport? {
      try? JSONDecoder().decode(OpenMeteoReport.self, from: data)
    }
  }

  public static func openMeteoURL(point: Point, forecastDays: Int) -> URL {
    var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
    c.queryItems = [
      .init(name: "latitude", value: String(point.latitude)),
      .init(name: "longitude", value: String(point.longitude)),
      .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,sunrise,sunset,uv_index_max,wind_speed_10m_max,wind_gusts_10m_max"),
      .init(name: "hourly", value: "temperature_2m,precipitation_probability,wind_speed_10m,wind_direction_10m,relative_humidity_2m,dew_point_2m"),
      .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"),
      .init(name: "forecast_days", value: String(min(16, forecastDayLimit(forecastDays) + 1))),
      .init(name: "timezone", value: "auto"),
    ]
    return c.url!
  }

  // MARK: - Small helpers

  /// Every match of `pattern`, each as [whole, group1, …] ("" for unmatched groups).
  static func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
      (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
  }

  /// JavaScript's Math.round (halves round up, toward +∞).
  public static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

  static func rounded(_ x: Double?) -> Int? { x.map(jsRound) }

  public static func celsiusToFahrenheit(_ c: Double) -> Double { c * 9 / 5 + 32 }
  public static func fahrenheitToCelsius(_ f: Double) -> Double { (f - 32) * 5 / 9 }

  public static func isFutureForecastDate(_ date: String, _ today: String) -> Bool {
    !date.isEmpty && String(date.prefix(10)) > today
  }

  /// Total rows to render, clamped to what the popup lays out.
  public static func forecastDayLimit(_ limit: Int) -> Int { max(1, min(14, limit)) }

  /// "imperial"/"F" → °F, "metric"/"C" → °C, else by locale (US, LR, MM).
  public static func shouldUseImperial(unit: String, localeIdentifier: String = Locale.current.identifier) -> Bool {
    switch unit.trimmingCharacters(in: .whitespaces).lowercased() {
    case "imperial", "f", "fahrenheit": return true
    case "metric", "c", "celsius": return false
    default:
      let name = localeIdentifier.replacingOccurrences(of: ".", with: "_")
      return name.range(of: #"^en[_-]US($|[_.-])"#, options: .regularExpression) != nil
        || name.range(of: #"^en[_-]LR($|[_.-])"#, options: .regularExpression) != nil
        || name.range(of: #"^my($|[_.-])"#, options: .regularExpression) != nil
    }
  }

  /// Rounded to four decimals, as NWS redirects anything finer.
  public static func forecastPoint(latitude: Double, longitude: Double) -> Point? {
    guard latitude.isFinite, longitude.isFinite else { return nil }
    let lat = (latitude * 10_000).rounded() / 10_000
    let lon = (longitude * 10_000).rounded() / 10_000
    return Point(latitude: lat, longitude: lon, key: "\(jsNumber(lat)),\(jsNumber(lon))")
  }

  /// A number the way JavaScript prints it (no trailing ".0").
  static func jsNumber(_ x: Double) -> String {
    x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
  }

  // MARK: - Open-Meteo days

  static func at<T>(_ list: [T?]?, _ i: Int) -> T? {
    guard let list, i < list.count else { return nil }
    return list[i]
  }

  public static func openMeteoDay(_ daily: OpenMeteoReport.Daily, _ i: Int) -> Day {
    var d = Day(date: daily.time[i])
    let maxC = at(daily.temperature_2m_max, i)
    let minC = at(daily.temperature_2m_min, i)
    d.maxtempC = rounded(maxC)
    d.mintempC = rounded(minC)
    d.maxtempF = rounded(maxC.map(celsiusToFahrenheit))
    d.mintempF = rounded(minC.map(celsiusToFahrenheit))
    d.openMeteoWeatherCode = at(daily.weather_code, i).map { Int($0) }
    d.precipChance = at(daily.precipitation_probability_max, i)
    return d
  }

  public static func openMeteoForecastDays(_ report: OpenMeteoReport?, today: String, limit: Int) -> [Day] {
    guard let daily = report?.daily else { return [] }
    let max = forecastDayLimit(limit)
    var out: [Day] = []
    for i in daily.time.indices where out.count < max {
      if isFutureForecastDate(daily.time[i], today) { out.append(openMeteoDay(daily, i)) }
    }
    return out
  }

  /// The Open-Meteo row for one date (today's, which the strip's future-day
  /// list skips, or a fallback for an NWS row).
  public static func openMeteoDayOn(_ report: OpenMeteoReport?, date: String) -> Day? {
    guard let daily = report?.daily else { return nil }
    guard let i = daily.time.firstIndex(where: { String($0.prefix(10)) == date }) else { return nil }
    return openMeteoDay(daily, i)
  }

  public static func buildTodayForecast(_ report: OpenMeteoReport?, today: String, nwsDays: [Day],
    nwsHours: [Hour] = []) -> Day? {
    let fallback = openMeteoDayOn(report, date: today)
    let day = nwsDayOn(nwsDays, date: today).map { withMissingTemps($0, from: fallback) } ?? fallback
    return day.map { withHourlyOutlook($0, nws: nwsHours, openMeteo: openMeteoHourly(report)) }
  }

  /// The rendered strip: today first, then future days. `limit` is the
  /// total row count, so 10 means today plus nine. NWS covers seven days;
  /// a longer strip continues on Open-Meteo.
  public static func buildForecastRows(_ report: OpenMeteoReport?, today: String, limit: Int, nwsDays: [Day],
    nwsHours: [Hour] = []) -> [Day] {
    let total = forecastDayLimit(limit)
    var rows: [Day] = []
    if let t = buildTodayForecast(report, today: today, nwsDays: nwsDays) { rows.append(t) }
    var remaining = total - rows.count
    if remaining > 0 {
      let nws = nwsFutureDays(nwsDays, today: today, limit: remaining)
      for d in nws { rows.append(withMissingTemps(d, from: openMeteoDayOn(report, date: d.date))) }
      remaining -= nws.count
      if remaining > 0 {
        rows += openMeteoForecastDays(report, today: nws.last?.date ?? today, limit: remaining)
      }
    }
    let omHours = openMeteoHourly(report)
    return rows.map { withHourlyOutlook($0, nws: nwsHours, openMeteo: omHours) }
  }

  /// A row's chance of rain and icon from the hours its detail chart draws.
  public static func withHourlyOutlook(_ day: Day, nws: [Hour], openMeteo: [Hour]) -> Day {
    withHourlyIcon(withHourlyPrecipChance(day, nws: nws, openMeteo: openMeteo), nws: nws)
  }

  /// A row's chance of rain from the same hours its detail chart draws (the
  /// wettest one), so the two agree. NWS's own figure covers the day and
  /// the night after it, through 6 am the next morning, so rain due before
  /// dawn would otherwise count on the wrong day. A day the hours don't
  /// fully cover keeps its daily figure; 23 hours is enough for the
  /// spring-forward day.
  public static func withHourlyPrecipChance(_ day: Day, nws: [Hour], openMeteo: [Hour]) -> Day {
    let pops = hourlyForDay(day.date, nws: nws, openMeteo: openMeteo).compactMap { $0?.pop }
    guard pops.count >= 23, let peak = pops.max() else { return day }
    var out = day
    out.precipChance = Double(peak)
    return out
  }

  /// An NWS row's icon from its date's hourly icons, for the same reason as
  /// its chance: the period's icon includes the night after it. Rain, snow
  /// or storms in any hour win, as they set the chance; the commonest of
  /// them shows, so one stormy hour doesn't outvote a day of showers.
  /// Otherwise the commonest sky over the daytime hours (the night's when
  /// none are left), so a cloudy night doesn't cloud a sunny day. Ties go
  /// to the higher rank. Night only when every hour left is. Needs the
  /// hours through 11 pm; the hourly forecast's last, partial day keeps
  /// the period's icon.
  public static func withHourlyIcon(_ day: Day, nws: [Hour]) -> Day {
    guard !(day.nwsIconCode ?? "").isEmpty else { return day }
    let hours = nws.filter { $0.date == day.date && !($0.nwsIconCode ?? "").isEmpty }
    guard hours.contains(where: { $0.hour == 23 }) else { return day }
    let wet = hours.compactMap(\.nwsIconCode).filter { (nwsIconRank[$0] ?? -1) >= nwsWetRank }
    let daytime = hours.filter { !$0.nwsNight }
    let sky = (daytime.isEmpty ? hours : daytime).compactMap(\.nwsIconCode)
    // Fog or haze only when that's all there is, as in a period's icon.
    let clear = sky.filter { (nwsIconRank[$0] ?? -1) > 0 }
    var out = day
    out.nwsIconCode = commonestNwsCode(wet.isEmpty ? (clear.isEmpty ? sky : clear) : wet)
    out.nwsNight = daytime.isEmpty
    return out
  }

  /// The code most hours share, the higher-ranked on a tie.
  static func commonestNwsCode(_ codes: [String]) -> String {
    var counts: [String: Int] = [:]
    for c in codes { counts[c, default: 0] += 1 }
    return counts.max { a, b in
      a.value != b.value ? a.value < b.value : (nwsIconRank[a.key] ?? -1) < (nwsIconRank[b.key] ?? -1)
    }?.key ?? ""
  }

  // MARK: - NWS

  /// /points response → the gridpoint forecast URL, `.none` outside NWS
  /// coverage (its 404 body says so), nil for a failure worth retrying.
  public static func parseNwsPoint(_ data: Data) -> NwsPoint? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let props = obj["properties"] as? [String: Any], let f = props["forecast"] as? String, !f.isEmpty {
      return .forecast(f)
    }
    if let status = obj["status"] as? NSNumber, status.intValue == 404 { return NwsPoint.none }
    return nil
  }

  public static func nwsHourlyURL(_ forecastURL: String) -> String {
    if forecastURL.isEmpty || forecastURL == "none" { return "" }
    return forecastURL.replacingOccurrences(of: #"/forecast/?$"#, with: "/forecast/hourly", options: .regularExpression)
  }

  static func number(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  /// NWS's QuantitativeValue ({unitCode, value}) or a bare number.
  static func nwsValue(_ field: Any?) -> Double? {
    if let dict = field as? [String: Any] { return number(dict["value"]) }
    return number(field)
  }

  /// °F, handling both the number + temperatureUnit form and the
  /// QuantitativeValue form NWS is migrating to.
  static func nwsTemperatureF(_ period: [String: Any]?) -> Double? {
    guard let period else { return nil }
    var value: Any? = period["temperature"]
    var unit = period["temperatureUnit"] as? String
    if let q = value as? [String: Any] {
      unit = ((q["unitCode"] as? String) ?? "").hasSuffix("degC") ? "C" : "F"
      value = q["value"]
    }
    guard let n = number(value) else { return nil }
    return unit == "C" ? celsiusToFahrenheit(n) : n
  }

  /// How much a condition says about the day, for picking one icon when an
  /// NWS period names two: precipitation beats sky cover, the cloudier sky
  /// wins, and fog or haze shows only when nothing else is forecast.
  static let nwsIconRank: [String: Int] = [
    "fog": 0, "haze": 0, "smoke": 0, "dust": 0,
    "skc": 1, "few": 1, "wind_skc": 1, "wind_few": 1, "hot": 1, "cold": 1,
    "sct": 2, "wind_sct": 2,
    "bkn": 3, "wind_bkn": 3,
    "ovc": 4, "wind_ovc": 4,
    "rain_showers": 5, "rain_showers_hi": 5,
    "rain": 6,
    "snow": 7, "rain_snow": 7, "rain_sleet": 7, "snow_sleet": 7, "sleet": 7,
    "fzra": 7, "rain_fzra": 7, "snow_fzra": 7, "blizzard": 7,
    "tsra": 8, "tsra_sct": 8, "tsra_hi": 8,
    "tornado": 9, "hurricane": 9, "tropical_storm": 9,
  ]

  /// Ranks from here up are precipitation or worse, not sky cover.
  static let nwsWetRank = 5

  /// The dominant condition code in an NWS icon URL, "" when there is none.
  public static func nwsIconCode(_ iconURL: String) -> String {
    guard let r = iconURL.range(of: #"/(day|night)/[^?]+"#, options: .regularExpression) else { return "" }
    let path = iconURL[r].split(separator: "/", omittingEmptySubsequences: true).dropFirst()
    return dominantNwsCode(path.map { String($0.split(separator: ",", omittingEmptySubsequences: false).first ?? "") })
  }

  /// The highest-ranked code (the first on a tie), "" when there are none.
  static func dominantNwsCode(_ codes: [String]) -> String {
    var best = ""
    var bestRank = -1
    for code in codes {
      let rank = nwsIconRank[code] ?? -1
      if rank > bestRank { best = code; bestRank = rank }
    }
    return best
  }

  static func periodText(_ p: [String: Any]?) -> PeriodText? {
    guard let p else { return nil }
    return PeriodText(
      name: p["name"] as? String ?? "",
      shortForecast: p["shortForecast"] as? String ?? "",
      detailedForecast: p["detailedForecast"] as? String ?? "")
  }

  /// The higher of the day and night chances; NWS's null means 0.
  static func nwsPrecipChance(_ day: [String: Any]?, _ night: [String: Any]?) -> Double {
    var best = 0.0
    for p in [day, night] {
      if let pop = p.flatMap({ nwsValue($0["probabilityOfPrecipitation"]) }), pop > best { best = pop }
    }
    return best
  }

  static func nwsDay(date: String, day: [String: Any]?, night: [String: Any]?) -> Day {
    let high = nwsTemperatureF(day)
    let low = nwsTemperatureF(night)
    var d = Day(date: date)
    d.maxtempF = rounded(high)
    d.mintempF = rounded(low)
    d.maxtempC = rounded(high.map(fahrenheitToCelsius))
    d.mintempC = rounded(low.map(fahrenheitToCelsius))
    d.nwsIconCode = nwsIconCode(((day ?? night)?["icon"] as? String) ?? "")
    d.nwsNight = day == nil
    d.precipChance = nwsPrecipChance(day, night)
    d.nwsDayText = periodText(day)
    d.nwsNightText = periodText(night)
    return d
  }

  static func periods(_ data: Data) -> [[String: Any]]? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let props = obj["properties"] as? [String: Any],
      let periods = props["periods"] as? [[String: Any]], !periods.isEmpty
    else { return nil }
    return periods
  }

  /// NWS forecast → one row per day (each day's high with the following
  /// night's low, as weather.gov's strip reads), nil on anything unusable.
  /// After about 6 pm the forecast opens on Tonight, so today's row then
  /// carries only a low.
  public static func nwsForecastDays(_ data: Data) -> [Day]? {
    guard let periods = periods(data) else { return nil }
    var rows: [Day] = []
    for (i, p) in periods.enumerated() {
      let next = i + 1 < periods.count ? periods[i + 1] : nil
      let date = String(((p["startTime"] as? String) ?? "").prefix(10))
      if date.isEmpty { continue }
      let isDay = p["isDaytime"] as? Bool ?? false
      let nextIsDay = next?["isDaytime"] as? Bool ?? false
      if isDay {
        rows.append(nwsDay(date: date, day: p, night: next != nil && !nextIsDay ? next : nil))
      } else if i == 0 && !(next != nil && nextIsDay && String(((next?["startTime"] as? String) ?? "").prefix(10)) == date) {
        // A leading night that isn't the pre-dawn "Overnight" before today's
        // daytime period: it's tonight, and today's daytime is over.
        rows.append(nwsDay(date: date, day: nil, night: p))
      }
    }
    return rows
  }

  public static func nwsDayOn(_ days: [Day], date: String) -> Day? {
    days.first { $0.date == date }
  }

  public static func nwsFutureDays(_ days: [Day], today: String, limit: Int) -> [Day] {
    Array(days.filter { isFutureForecastDate($0.date, today) }.prefix(max(0, limit)))
  }

  /// An NWS row missing a high or a low borrows it from the fallback row
  /// for the same date, so its range bar still draws.
  public static func withMissingTemps(_ day: Day, from fallback: Day?) -> Day {
    guard let fb = fallback else { return day }
    var out = day
    if out.maxtempC == nil { out.maxtempC = fb.maxtempC }
    if out.maxtempF == nil { out.maxtempF = fb.maxtempF }
    if out.mintempC == nil { out.mintempC = fb.mintempC }
    if out.mintempF == nil { out.mintempF = fb.mintempF }
    return out
  }

  // MARK: - Hourly

  /// "5 mph" or "5 to 10 mph" → the top of the range.
  public static func nwsWindMph(_ text: String) -> Double? {
    let nums = matches(#"\d+(\.\d+)?"#, in: text).compactMap { Double($0[0]) }
    guard let n = nums.last else { return nil }
    return text.contains("km/h") ? n * 0.621371 : n
  }

  static let compassPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

  /// "NE" → 45, the bearing the wind blows from; nil when calm/unknown.
  public static func compassDegrees(_ text: String) -> Double? {
    let t = text.trimmingCharacters(in: .whitespaces).uppercased()
    return compassPoints.firstIndex(of: t).map { Double($0) * 22.5 }
  }

  /// 45 → "NE", the nearest of the sixteen points.
  public static func compassName(_ degrees: Double?) -> String {
    guard let degrees, degrees.isFinite else { return "" }
    let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    return compassPoints[jsRound(d / 22.5) % 16]
  }

  static func stampParts(_ stamp: String) -> (String, Int)? {
    guard stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}"#, options: .regularExpression) != nil else { return nil }
    let chars = Array(stamp)
    guard let hour = Int(String(chars[11...12])) else { return nil }
    return (String(stamp.prefix(10)), hour)
  }

  /// NWS's dewpoint QuantitativeValue (sent in °C) as °F.
  static func nwsDewPointF(_ field: Any?) -> Double? {
    guard let n = nwsValue(field) else { return nil }
    let unit = ((field as? [String: Any])?["unitCode"] as? String) ?? ""
    return unit.hasSuffix("degF") ? n : celsiusToFahrenheit(n)
  }

  /// NWS forecast/hourly → hour rows, nil on anything unusable. A null
  /// chance is how NWS writes "none".
  public static func nwsHourly(_ data: Data) -> [Hour]? {
    guard let periods = periods(data) else { return nil }
    return periods.compactMap { p in
      guard let (date, hour) = stampParts(p["startTime"] as? String ?? "") else { return nil }
      let icon = nwsIconCode(p["icon"] as? String ?? "")
      return Hour(
        date: date, hour: hour,
        pop: jsRound(nwsValue(p["probabilityOfPrecipitation"]) ?? 0),
        tempF: nwsTemperatureF(p),
        windMph: nwsWindMph(p["windSpeed"] as? String ?? ""),
        windDir: compassDegrees(p["windDirection"] as? String ?? ""),
        humidity: nwsValue(p["relativeHumidity"]),
        dewPointF: nwsDewPointF(p["dewpoint"]),
        nwsIconCode: icon.isEmpty ? nil : icon,
        nwsNight: !(p["isDaytime"] as? Bool ?? true),
        source: .nws)
    }
  }

  public static func openMeteoHourly(_ report: OpenMeteoReport?) -> [Hour] {
    guard let h = report?.hourly else { return [] }
    return h.time.indices.compactMap { i in
      guard let (date, hour) = stampParts(h.time[i]) else { return nil }
      return Hour(
        date: date, hour: hour,
        pop: at(h.precipitation_probability, i).map(jsRound),
        tempF: at(h.temperature_2m, i).map(celsiusToFahrenheit),
        windMph: at(h.wind_speed_10m, i).map { $0 * 0.621371 },
        windDir: at(h.wind_direction_10m, i),
        humidity: at(h.relative_humidity_2m, i),
        dewPointF: at(h.dew_point_2m, i).map(celsiusToFahrenheit),
        source: .openMeteo)
    }
  }

  /// One slot per hour of `date`: NWS's hour when it has one, Open-Meteo's
  /// otherwise, nil where neither does. The DST fall-back day's repeated
  /// 1 am keeps the first reading.
  public static func hourlyForDay(_ date: String, nws: [Hour], openMeteo: [Hour]) -> [Hour?] {
    var slots = [Hour?](repeating: nil, count: 24)
    func fill(_ rows: [Hour], override: Bool) {
      for r in rows where r.date == date && (0...23).contains(r.hour) {
        if r.source == .openMeteo && r.pop == nil { continue }
        if slots[r.hour] == nil || (override && slots[r.hour]!.source != r.source) { slots[r.hour] = r }
      }
    }
    fill(openMeteo, override: false)
    fill(nws, override: true)
    return slots
  }

  /// The wettest hour (earliest on a tie), nil when all dry.
  public static func peakPrecipHour(_ slots: [Hour?]) -> Hour? {
    var best: Hour?
    for case let s? in slots {
      guard let pop = s.pop, pop > 0 else { continue }
      if best == nil || pop > best!.pop! { best = s }
    }
    return best
  }

  public static func tempValue(_ slot: Hour?, imperial: Bool) -> Double? {
    guard let f = slot?.tempF else { return nil }
    return imperial ? f : fahrenheitToCelsius(f)
  }

  public static func hourlyTempRange(_ slots: [Hour?], imperial: Bool) -> ValueRange? {
    let values = slots.compactMap { tempValue($0, imperial: imperial) }
    guard let lo = values.min(), let hi = values.max() else { return nil }
    return ValueRange(min: lo, max: hi, span: Swift.max(1, hi - lo))
  }

  /// Hourly wind in mph or km/h, nil where there's none.
  public static func windValue(_ slot: Hour?, imperial: Bool) -> Double? {
    guard let w = slot?.windMph else { return nil }
    return imperial ? w : w * 1.609344
  }

  /// From zero, and at least 10 mph (16 km/h) tall so a breezy day reads as
  /// calm instead of filling the chart.
  public static func hourlyWindRange(_ slots: [Hour?], imperial: Bool) -> ValueRange? {
    guard let top = slots.compactMap({ windValue($0, imperial: imperial) }).max() else { return nil }
    let floor: Double = imperial ? 10 : 16
    return ValueRange(min: 0, max: Swift.max(floor, top), span: Swift.max(floor, top))
  }

  /// Widened to round gridlines: the smallest step from 1, 2, 5, 10… that
  /// spans the range in at most four intervals, bounds snapped out to it.
  public static func niceRange(_ range: ValueRange?) -> ValueRange? {
    guard let range else { return nil }
    let steps: [Double] = [1, 2, 5, 10, 20, 25, 50, 100]
    let step = steps.first { (range.max / $0).rounded(.up) - (range.min / $0).rounded(.down) <= 4 } ?? steps.last!
    let lo = (range.min / step).rounded(.down) * step
    var hi = (range.max / step).rounded(.up) * step
    if hi == lo { hi = lo + step }
    var ticks: [Double] = []
    var t = lo
    while t <= hi + 1e-9 { ticks.append(t); t += step }
    return ValueRange(min: lo, max: hi, span: hi - lo, ticks: ticks)
  }

  public static func hourLabel(_ hour: Int) -> String {
    let twelve = hour % 12 == 0 ? 12 : hour % 12
    return "\(twelve) \(hour < 12 ? "AM" : "PM")"
  }

  /// "2026-10-04T07:37" → "7:37 AM".
  public static func clockFromStamp(_ stamp: String) -> String {
    guard let m = matches(#"T(\d{2}):(\d{2})"#, in: stamp).first, let h = Int(m[1]) else { return "" }
    return "\(h % 12 == 0 ? 12 : h % 12):\(m[2]) \(h < 12 ? "AM" : "PM")"
  }

  // MARK: - Daily extras (detail pane)

  public static func openMeteoDayExtras(_ report: OpenMeteoReport?, date: String) -> DayExtras? {
    guard let daily = report?.daily,
      let i = daily.time.firstIndex(where: { String($0.prefix(10)) == date })
    else { return nil }
    let mm = at(daily.precipitation_sum, i)
    let wind = at(daily.wind_speed_10m_max, i)
    let gust = at(daily.wind_gusts_10m_max, i)
    return DayExtras(
      precipMm: mm, precipIn: mm.map { $0 / 25.4 },
      uvIndex: at(daily.uv_index_max, i),
      windMph: wind.map { $0 * 0.621371 }, windKmh: wind,
      gustMph: gust.map { $0 * 0.621371 }, gustKmh: gust,
      sunrise: clockFromStamp(at(daily.sunrise, i) ?? ""),
      sunset: clockFromStamp(at(daily.sunset, i) ?? ""))
  }

  public static func precipAmountLabel(_ extras: DayExtras?, imperial: Bool) -> String {
    guard let extras, let mm = extras.precipMm else { return "" }
    if imperial {
      let inches = extras.precipIn ?? mm / 25.4
      if inches <= 0 { return "0 in" }
      return inches < 0.01 ? "< 0.01 in" : String(format: "%.2f in", inches)
    }
    if mm <= 0 { return "0 mm" }
    if mm < 0.1 { return "< 0.1 mm" }
    return (mm < 10 ? String(format: "%.1f", mm) : String(jsRound(mm))) + " mm"
  }

  /// The day's top wind: the strongest hourly reading where there are hours,
  /// Open-Meteo's daily max otherwise, plus gusts when they run above it.
  public static func windLabel(_ slots: [Hour?], extras: DayExtras?, imperial: Bool) -> String {
    var top = slots.compactMap { $0?.windMph }.max()
    if top == nil { top = extras?.windMph }
    guard let top else { return "" }
    let scale = imperial ? 1 : 1.609344
    var label = "\(jsRound(top * scale))" + (imperial ? " mph" : " km/h")
    if let gust = extras?.gustMph, jsRound(gust * scale) > jsRound(top * scale) {
      label += ", gusts \(jsRound(gust * scale))"
    }
    return label
  }

  /// The hours, 10 am through 3 pm, when humidity is most felt outdoors.
  public static let muggyHours = 10...15

  static func muggySlots(_ slots: [Hour?]) -> [Hour] {
    slots.compactMap { $0 }.filter { muggyHours.contains($0.hour) }
  }

  /// Relative humidity at the hottest hour from 10 am to 3 pm (the earliest
  /// on a tie). Humidity falls as the air warms, so this is what the warm
  /// part of the day feels like, not the damp morning.
  public static func humidityLabel(_ slots: [Hour?]) -> String {
    var hottest: Hour?
    for s in muggySlots(slots) where s.humidity != nil {
      guard let t = s.tempF else { continue }
      if hottest == nil || t > hottest!.tempF! { hottest = s }
    }
    return hottest?.humidity.map { "\(jsRound($0))%" } ?? ""
  }

  /// The highest dew point from 10 am to 3 pm.
  public static func dewPointLabel(_ slots: [Hour?], imperial: Bool) -> String {
    muggySlots(slots).compactMap(\.dewPointF).max().map { "\(jsRound(imperial ? $0 : fahrenheitToCelsius($0)))°" } ?? ""
  }

  public static func uvLabel(_ extras: DayExtras?) -> String {
    guard let uv = extras?.uvIndex.map(jsRound) else { return "" }
    let level = uv <= 2 ? "Low" : uv <= 5 ? "Moderate" : uv <= 7 ? "High" : uv <= 10 ? "Very high" : "Extreme"
    return "\(uv) · \(level)"
  }

  // MARK: - Current conditions

  public static func openMeteoCurrent(_ report: OpenMeteoReport?) -> Current? {
    guard let c = report?.current, let t = c.temperature_2m else { return nil }
    return Current(
      tempC: jsRound(t), tempF: jsRound(celsiusToFahrenheit(t)),
      feelsLikeC: rounded(c.apparent_temperature),
      feelsLikeF: rounded(c.apparent_temperature.map(celsiusToFahrenheit)),
      windKmh: rounded(c.wind_speed_10m),
      windMph: rounded(c.wind_speed_10m.map { $0 * 0.621371 }),
      humidity: rounded(c.relative_humidity_2m),
      weatherCode: c.weather_code.map { Int($0) },
      isDay: (c.is_day ?? 1) != 0)
  }

  public static func currentIcon(_ current: Current?) -> String {
    guard let current, let code = current.weatherCode else { return "" }
    return iconForOpenMeteoCode(code, night: !current.isDay)
  }

  // MARK: - Strip helpers

  public static func dayPrecipChance(_ day: Day?) -> Double? { day?.precipChance }

  /// Blank under 10%, like Apple Weather, so only wet days stand out.
  public static func precipChanceLabel(_ day: Day?) -> String {
    guard let pop = dayPrecipChance(day), pop >= 10 else { return "" }
    return "\(jsRound(pop))%"
  }

  public enum TempKind { case max, min }

  public static func tempValue(_ day: Day?, _ kind: TempKind, imperial: Bool) -> Int? {
    guard let day else { return nil }
    switch (kind, imperial) {
    case (.max, true): return day.maxtempF
    case (.min, true): return day.mintempF
    case (.max, false): return day.maxtempC
    case (.min, false): return day.mintempC
    }
  }

  public static func bareTemp(_ day: Day?, _ kind: TempKind, imperial: Bool) -> String {
    tempValue(day, kind, imperial: imperial).map { "\($0)°" } ?? ""
  }

  /// Coldest low and warmest high across the strip: every row's bar is
  /// drawn against it, so the rows compare at a glance.
  public static func forecastTempRange(_ days: [Day], imperial: Bool) -> ValueRange? {
    let lows = days.compactMap { tempValue($0, .min, imperial: imperial) }
    let highs = days.compactMap { tempValue($0, .max, imperial: imperial) }
    guard let lo = lows.min(), let hi = highs.max() else { return nil }
    return ValueRange(min: Double(lo), max: Double(hi), span: Swift.max(1, Double(hi - lo)))
  }

  public static func rangeFraction(_ value: Double?, _ range: ValueRange?) -> Double {
    guard let range, let value, value.isFinite else { return 0 }
    return Swift.max(0, Swift.min(1, (value - range.min) / range.span))
  }

  // MARK: - Icons (SF Symbols)

  public static func dayIcon(_ day: Day?) -> String {
    guard let day else { return "" }
    if let code = day.nwsIconCode, !code.isEmpty { return iconForNwsCode(code, night: day.nwsNight) }
    if let code = day.openMeteoWeatherCode { return iconForOpenMeteoCode(code, night: false) }
    return ""
  }

  /// WMO weather code → the wttr.in-style condition both sources share.
  public static func iconForOpenMeteoCode(_ c: Int, night: Bool) -> String {
    switch c {
    case 0: return iconForCode(113, night: night)
    case 1, 2: return iconForCode(116, night: night)
    case 3: return iconForCode(119, night: night)
    case 45, 48: return iconForCode(143, night: night)
    case 51, 53, 55, 56, 57, 61: return iconForCode(266, night: night)
    case 63, 65, 66, 67, 80, 81, 82: return iconForCode(308, night: night)
    case 71, 73, 75, 77, 85, 86: return iconForCode(338, night: night)
    case 95, 96, 99: return iconForCode(389, night: night)
    default: return iconForCode(119, night: night)
    }
  }

  public static func iconForNwsCode(_ code: String, night: Bool) -> String {
    switch code {
    case "skc", "few", "wind_skc", "wind_few", "hot", "cold": return iconForCode(113, night: night)
    case "sct", "bkn", "wind_sct", "wind_bkn": return iconForCode(116, night: night)
    case "fog", "haze", "smoke", "dust": return iconForCode(143, night: night)
    case "rain_showers", "rain_showers_hi": return iconForCode(176, night: night)
    case "rain": return iconForCode(308, night: night)
    case "snow", "blizzard": return iconForCode(338, night: night)
    case "rain_snow", "rain_sleet", "snow_sleet", "sleet", "fzra", "rain_fzra", "snow_fzra":
      return iconForCode(317, night: night)
    case "tsra", "tsra_sct", "tsra_hi", "tornado", "hurricane", "tropical_storm":
      return iconForCode(389, night: night)
    default: return iconForCode(119, night: night)
    }
  }

  /// wttr.in condition code → SF Symbol (the plugin's nerd-font glyph map).
  public static func iconForCode(_ code: Int, night: Bool) -> String {
    switch code {
    case 113: return night ? "moon.stars.fill" : "sun.max.fill"
    case 116: return night ? "cloud.moon.fill" : "cloud.sun.fill"
    case 119, 122: return "cloud.fill"
    case 143, 248, 260: return night ? "cloud.fog.fill" : "sun.haze.fill"
    case 176, 263, 353: return night ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill"
    case 179, 227, 230, 323, 326, 368: return night ? "cloud.snow.fill" : "sun.snow.fill"
    case 182, 185, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377: return "cloud.sleet.fill"
    case 200, 386, 389, 392, 395: return "cloud.bolt.rain.fill"
    case 266, 293, 296, 299, 302, 305, 308, 356, 359: return "cloud.rain.fill"
    case 329, 332, 335, 338, 371: return "cloud.snow.fill"
    default: return "cloud.fill"
    }
  }

  // MARK: - Dates

  /// "yyyy-MM-dd" in the given time zone.
  public static func dateString(_ date: Date, timeZone: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }

  /// Noon on a "yyyy-MM-dd" date in the current zone (for weekday names).
  public static func noon(of date: String) -> Date? {
    let parts = date.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }

  // MARK: - Geocoding (location picker)

  public struct Place: Equatable, Sendable {
    public var name: String
    public var description: String
    public var latitude: Double
    public var longitude: Double
  }

  public static func geocodingURL(_ query: String) -> URL {
    var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
    c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "5"),
      .init(name: "language", value: "en"), .init(name: "format", value: "json")]
    return c.url!
  }

  public static func parseGeocodingResults(_ data: Data) -> [Place] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let results = obj["results"] as? [[String: Any]]
    else { return [] }
    return results.compactMap { r in
      guard let name = r["name"] as? String, !name.isEmpty,
        let lat = number(r["latitude"]), let lon = number(r["longitude"])
      else { return nil }
      let region = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
      return Place(name: name, description: region.joined(separator: ", "), latitude: lat, longitude: lon)
    }
  }
}
