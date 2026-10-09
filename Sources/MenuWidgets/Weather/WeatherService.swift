import AppKit
import Combine
import Foundation
import WidgetsCore

/// Fetches and holds the weather: Open-Meteo (current conditions, daily and
/// hourly fallback) and, for US points, NWS's daily and hourly forecasts.
/// The last good responses are cached on disk so the menu-bar label isn't
/// blank at launch; a failed fetch keeps the previous data and retries.
@MainActor
final class WeatherService: ObservableObject {
  @Published private(set) var openMeteo: Weather.OpenMeteoReport?
  @Published private(set) var nwsDays: [Weather.Day] = []
  @Published private(set) var nwsHours: [Weather.Hour] = []
  /// What the widget runs on: the config's settings, with the point and
  /// name replaced by the Mac's location when `useLocation` is on.
  @Published private(set) var settings: WidgetsConfig.WeatherSettings
  /// Whether macOS lets the widget use the Mac's location.
  @Published private(set) var locationAccess: WeatherLocator.Access = .unknown
  private var configSettings: WidgetsConfig.WeatherSettings
  private var locator: WeatherLocator?
  /// Ticks every minute (today's chart dims past hours; "today" rolls over).
  @Published private(set) var now = Date()
  @Published private(set) var lastSuccess: Date?

  // NWS state is tagged with the point it was fetched for, so a location
  // change never shows another place's forecast.
  private var nwsPointKey = ""
  private var nwsForecastURL = ""  // "" unknown, "none" outside NWS coverage
  private var nwsDaysKey = ""
  private var nwsHoursKey = ""
  private var openMeteoKey = ""

  private var refreshTask: Task<Void, Never>?
  private var timers: [Timer] = []
  private var cancellables: Set<AnyCancellable> = []
  private var wakeObserver: NSObjectProtocol?

  static let refreshInterval: TimeInterval = 15 * 60
  nonisolated static let userAgent = "ianneub.weather (Mac menu widgets)"

  init(config: ConfigStore) {
    let c = config.config.weather
    configSettings = c
    // The last known place (kept by the locator) is used from the start, so
    // launch doesn't fetch the config's point first.
    let loc = c.useLocation ? WeatherLocator() : nil
    locator = loc
    settings = WeatherLocation.effective(c, located: loc?.access == .denied ? nil : loc?.place)
    loadCache()
    if let loc { wire(loc) }
    config.$config
      .map(\.weather)
      .removeDuplicates { a, b in
        a.latitude == b.latitude && a.longitude == b.longitude && a.name == b.name && a.useLocation == b.useLocation
          && a.forecastDays == b.forecastDays && a.showTodayRange == b.showTodayRange && a.unit == b.unit
      }
      .dropFirst()
      .sink { [weak self] s in
        guard let self else { return }
        self.configSettings = s
        self.syncLocator()
        self.apply()
      }
      .store(in: &cancellables)

    timers.append(Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.locator?.update()
        self?.refresh()
      }
    })
    timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let n = Date()
        if Calendar.current.component(.minute, from: n) != Calendar.current.component(.minute, from: self.now) { self.now = n }
      }
    })
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // The network is often not back the instant the lid opens.
      MainActor.assumeIsolated {
        self?.now = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          self?.locator?.update()
          self?.refresh()
        }
      }
    }
    refresh()
    locator?.update()
  }

  // MARK: location

  private func wire(_ loc: WeatherLocator) {
    locationAccess = loc.access
    loc.onPlace = { [weak self] _ in self?.apply() }
    loc.onAccess = { [weak self] a in
      self?.locationAccess = a
      self?.apply()
    }
  }

  /// Starts or stops following the Mac's location as the config says.
  private func syncLocator() {
    if configSettings.useLocation, locator == nil {
      let loc = WeatherLocator()
      locator = loc
      wire(loc)
      loc.update()
    } else if !configSettings.useLocation, let loc = locator {
      loc.stop()
      locator = nil
      locationAccess = .unknown
    }
  }

  /// Recomputes the settings; a new point (or forecast length) refetches.
  private func apply() {
    let place = locator?.access == .denied ? nil : locator?.place
    let s = WeatherLocation.effective(configSettings, located: place)
    let refetch = s.latitude != settings.latitude || s.longitude != settings.longitude
      || s.forecastDays != settings.forecastDays
    settings = s
    if refetch { refresh() }
  }

  /// Whether the shown place is the Mac's location.
  var followingLocation: Bool {
    configSettings.useLocation && locationAccess != .denied && locator?.place != nil
  }

  var point: Weather.Point? {
    Weather.forecastPoint(latitude: settings.latitude, longitude: settings.longitude)
  }

  var useImperial: Bool { Weather.shouldUseImperial(unit: settings.unit) }

  var today: String { Weather.dateString(now) }

  var activeOpenMeteo: Weather.OpenMeteoReport? { openMeteoKey == point?.key ? openMeteo : nil }
  var activeNwsDays: [Weather.Day] { nwsDaysKey == point?.key ? nwsDays : [] }
  var activeNwsHours: [Weather.Hour] { nwsHoursKey == point?.key ? nwsHours : [] }

  var current: Weather.Current? { Weather.openMeteoCurrent(activeOpenMeteo) }
  var rows: [Weather.Day] {
    Weather.buildForecastRows(activeOpenMeteo, today: today, limit: settings.forecastDays, nwsDays: activeNwsDays,
      nwsHours: activeNwsHours)
  }
  var todayForecast: Weather.Day? {
    Weather.buildTodayForecast(activeOpenMeteo, today: today, nwsDays: activeNwsDays, nwsHours: activeNwsHours)
  }
  var openMeteoHours: [Weather.Hour] { Weather.openMeteoHourly(activeOpenMeteo) }

  /// Turned off in the config: no more fetches.
  func stop() {
    locator?.stop()
    locator = nil
    refreshTask?.cancel()
    timers.forEach { $0.invalidate() }
    timers = []
    cancellables.removeAll()
    if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    wakeObserver = nil
  }

  /// Refreshes when the data is older than `age` (popup open).
  func refreshIfStale(olderThan age: TimeInterval = 60) {
    now = Date()
    if let t = lastSuccess, Date().timeIntervalSince(t) < age { return }
    refresh()
  }

  func refresh() {
    guard let point else { return }
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      guard let self else { return }
      async let om: Void = self.fetchOpenMeteo(point)
      async let nws: Void = self.fetchNws(point)
      _ = await (om, nws)
    }
  }

  // MARK: fetching

  private func fetchOpenMeteo(_ point: Weather.Point) async {
    let url = Weather.openMeteoURL(point: point, forecastDays: settings.forecastDays)
    for attempt in 0...3 {
      if Task.isCancelled { return }
      if attempt > 0 { try? await Task.sleep(for: .seconds(2.5)) }
      guard let (data, status) = await get(url), status == 200,
        let report = Weather.OpenMeteoReport.parse(data), report.daily != nil
      else { continue }
      openMeteo = report
      openMeteoKey = point.key
      lastSuccess = Date()
      saveCache("openmeteo", data, key: point.key)
      return
    }
  }

  /// /points maps the coordinates to a forecast office's grid (once per
  /// location), then the daily and hourly gridpoint forecasts in parallel.
  private func fetchNws(_ point: Weather.Point) async {
    if nwsPointKey != point.key || nwsForecastURL.isEmpty {
      var resolved: Weather.NwsPoint?
      for attempt in 0...3 {
        if Task.isCancelled { return }
        if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
        // A 404 is an answer (outside NWS coverage), told apart from an
        // outage by its JSON body.
        if let (data, _) = await get(URL(string: "https://api.weather.gov/points/\(point.key)")!, nws: true),
          let r = Weather.parseNwsPoint(data)
        {
          resolved = r
          break
        }
      }
      guard let resolved else { return }
      nwsPointKey = point.key
      switch resolved {
      case .forecast(let u): nwsForecastURL = u
      case .none: nwsForecastURL = "none"
      }
      saveMeta()
    }
    guard nwsForecastURL != "none", let daily = URL(string: nwsForecastURL),
      let hourly = URL(string: Weather.nwsHourlyURL(nwsForecastURL))
    else { return }

    async let d: Void = fetchNwsDaily(daily, point)
    async let h: Void = fetchNwsHourly(hourly, point)
    _ = await (d, h)
  }

  private func fetchNwsDaily(_ url: URL, _ point: Weather.Point) async {
    // The gridpoint endpoint throws intermittent 500s; keep the last-good
    // days and try again shortly.
    for attempt in 0...3 {
      if Task.isCancelled { return }
      if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
      guard let (data, _) = await get(url, nws: true), let days = Weather.nwsForecastDays(data) else { continue }
      nwsDays = days
      nwsDaysKey = point.key
      saveCache("nws-forecast", data, key: point.key)
      return
    }
  }

  private func fetchNwsHourly(_ url: URL, _ point: Weather.Point) async {
    for attempt in 0...3 {
      if Task.isCancelled { return }
      if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
      guard let (data, _) = await get(url, nws: true), let hours = Weather.nwsHourly(data) else { continue }
      nwsHours = hours
      nwsHoursKey = point.key
      saveCache("nws-hourly", data, key: point.key)
      return
    }
  }

  private nonisolated func get(_ url: URL, nws: Bool = false) async -> (Data, Int)? {
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: nws ? 8 : 5)
    // NWS asks every client to identify itself.
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    if nws { req.setValue("application/geo+json", forHTTPHeaderField: "Accept") }
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
    return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
  }

  // MARK: geocoding (location picker)

  func geocode(_ query: String) async -> [Weather.Place] {
    guard let (data, status) = await get(Weather.geocodingURL(query)), status == 200 else { return [] }
    return Weather.parseGeocodingResults(data)
  }

  // MARK: cache

  private static var cacheDir: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.ianneub.menu-widgets/weather", isDirectory: true)
  }

  private struct Meta: Codable {
    var keys: [String: String] = [:]
    var nwsPointKey = ""
    var nwsForecastURL = ""
  }

  private var meta = Meta()

  private func saveCache(_ name: String, _ data: Data, key: String) {
    try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
    try? data.write(to: Self.cacheDir.appendingPathComponent(name + ".json"), options: .atomic)
    meta.keys[name] = key
    saveMeta()
  }

  private func saveMeta() {
    meta.nwsPointKey = nwsPointKey
    meta.nwsForecastURL = nwsForecastURL
    try? FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(meta) {
      try? d.write(to: Self.cacheDir.appendingPathComponent("meta.json"), options: .atomic)
    }
  }

  private func loadCache() {
    let dir = Self.cacheDir
    guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
      let m = try? JSONDecoder().decode(Meta.self, from: d)
    else { return }
    meta = m
    nwsPointKey = m.nwsPointKey
    nwsForecastURL = m.nwsForecastURL
    func read(_ name: String) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(name + ".json")) }
    if let d = read("openmeteo"), let r = Weather.OpenMeteoReport.parse(d) {
      openMeteo = r
      openMeteoKey = m.keys["openmeteo"] ?? ""
    }
    if let d = read("nws-forecast"), let days = Weather.nwsForecastDays(d) {
      nwsDays = days
      nwsDaysKey = m.keys["nws-forecast"] ?? ""
    }
    if let d = read("nws-hourly"), let hours = Weather.nwsHourly(d) {
      nwsHours = hours
      nwsHoursKey = m.keys["nws-hourly"] ?? ""
    }
  }
}
