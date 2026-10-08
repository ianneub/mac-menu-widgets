import Foundation

/// Settings for all widgets, read from ~/.config/menu-widgets/config.json
/// (the Mac counterpart of the widgets' entries in Omarchy's shell.json).
/// Missing keys fall back to the desktop's values.
public struct WidgetsConfig: Codable, Sendable {
  public var time: TimeSettings = .init()
  public var weather: WeatherSettings = .init()
  public var agents: AgentsSettings = .init()

  public init() {}

  public struct Zone: Codable, Sendable, Equatable {
    public var name: String
    public var tz: String
    public var lat: Double?
    public var lon: Double?
    public init(name: String, tz: String, lat: Double? = nil, lon: Double? = nil) {
      self.name = name; self.tz = tz; self.lat = lat; self.lon = lon
    }
  }

  public struct TimeSettings: Codable, Sendable {
    /// "12h" or "24h".
    public var timeFormat: String = "12h"
    /// Date before the time in the menu bar ("Thu Oct 8  7:49 AM"); a
    /// Mac-only addition, since the macOS clock can't show the date alone.
    public var showDate: Bool = true
    public var zones: [Zone] = [
      .init(name: "London", tz: "Europe/London"),
      .init(name: "UTC", tz: "UTC"),
      .init(name: "Denver", tz: "America/Denver"),
      .init(name: "Phoenix", tz: "America/Phoenix"),
      .init(name: "Los Angeles", tz: "America/Los_Angeles"),
      .init(name: "Anchorage", tz: "America/Anchorage"),
    ]
    public init() {}
  }

  public struct WeatherSettings: Codable, Sendable {
    public var name: String = "Atlanta GA"
    public var latitude: Double = 33.749
    public var longitude: Double = -84.388
    public var forecastDays: Int = 10
    public var showTodayRange: Bool = true
    /// "F" or "C".
    public var unit: String = "F"
    public init() {}
  }

  public struct AgentsSettings: Codable, Sendable {
    public var refreshIntervalSec: Int = 900
    public init() {}
  }

  public static var directory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/menu-widgets")
  }

  public static var fileURL: URL { directory.appendingPathComponent("config.json") }

  /// Loads the config, tolerating a missing file or missing keys.
  public static func load() -> WidgetsConfig {
    guard let data = try? Data(contentsOf: fileURL) else { return WidgetsConfig() }
    return (try? JSONDecoder().decode(WidgetsConfig.self, from: data)) ?? WidgetsConfig()
  }

  public func save() throws {
    try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(self).write(to: Self.fileURL, options: .atomic)
  }
}

// Missing keys decode to defaults instead of failing the whole file.
extension WidgetsConfig {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    time = (try? c.decode(TimeSettings.self, forKey: .time)) ?? .init()
    weather = (try? c.decode(WeatherSettings.self, forKey: .weather)) ?? .init()
    agents = (try? c.decode(AgentsSettings.self, forKey: .agents)) ?? .init()
  }
}

// A zone may also be a bare tz string ("Asia/Tokyo"), as in shell.json;
// its name is then the last path component with underscores as spaces.
extension WidgetsConfig.Zone {
  private enum Keys: String, CodingKey { case name, tz, lat, lon }

  public init(from decoder: Decoder) throws {
    if let tz = try? decoder.singleValueContainer().decode(String.self) {
      let city = tz.split(separator: "/").last.map(String.init) ?? tz
      self.init(name: city.replacingOccurrences(of: "_", with: " "), tz: tz)
      return
    }
    let c = try decoder.container(keyedBy: Keys.self)
    let tz = try c.decode(String.self, forKey: .tz)
    let fallback = tz.split(separator: "/").last.map(String.init) ?? tz
    self.init(
      name: (try? c.decode(String.self, forKey: .name)) ?? fallback.replacingOccurrences(of: "_", with: " "),
      tz: tz,
      lat: try? c.decode(Double.self, forKey: .lat),
      lon: try? c.decode(Double.self, forKey: .lon))
  }
}

extension WidgetsConfig.TimeSettings {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self()
    timeFormat = (try? c.decode(String.self, forKey: .timeFormat)) ?? d.timeFormat
    showDate = (try? c.decode(Bool.self, forKey: .showDate)) ?? d.showDate
    zones = (try? c.decode([WidgetsConfig.Zone].self, forKey: .zones)) ?? d.zones
  }
}

extension WidgetsConfig.WeatherSettings {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self()
    name = (try? c.decode(String.self, forKey: .name)) ?? d.name
    latitude = (try? c.decode(Double.self, forKey: .latitude)) ?? d.latitude
    longitude = (try? c.decode(Double.self, forKey: .longitude)) ?? d.longitude
    forecastDays = (try? c.decode(Int.self, forKey: .forecastDays)) ?? d.forecastDays
    showTodayRange = (try? c.decode(Bool.self, forKey: .showTodayRange)) ?? d.showTodayRange
    unit = (try? c.decode(String.self, forKey: .unit)) ?? d.unit
  }
}

extension WidgetsConfig.AgentsSettings {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    refreshIntervalSec = (try? c.decode(Int.self, forKey: .refreshIntervalSec)) ?? Self().refreshIntervalSec
  }
}
