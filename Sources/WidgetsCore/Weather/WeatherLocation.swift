import Foundation

/// Where the Mac is, for the weather widget's "Current Location": a point
/// from Core Location and the place name reverse geocoding gave it.
public struct LocatedPlace: Codable, Equatable, Sendable {
  public var latitude: Double
  public var longitude: Double
  public var name: String

  public init(latitude: Double, longitude: Double, name: String) {
    self.latitude = latitude; self.longitude = longitude; self.name = name
  }
}

public enum WeatherLocation {
  /// A fix closer than this to the last one isn't a move: Wi-Fi positioning
  /// wanders, and each move costs a reverse geocode and new NWS lookups.
  public static let minimumMove: Double = 2_000

  /// "Cupertino, CA" → "Cupertino CA", the way the config names places.
  public static func displayName(_ cityWithContext: String) -> String {
    cityWithContext
      .replacingOccurrences(of: ",", with: "")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// Great-circle distance in meters.
  public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let r = 6_371_000.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
      + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * r * asin(min(1, sqrt(a)))
  }

  /// Whether a new fix should replace the last place.
  public static func moved(from last: LocatedPlace?, latitude: Double, longitude: Double) -> Bool {
    guard let last else { return true }
    return distance(last.latitude, last.longitude, latitude, longitude) >= minimumMove
  }

  /// The settings the widget runs on: the config's, with the point and name
  /// replaced by the Mac's location when that's turned on and known.
  public static func effective(_ config: WidgetsConfig.WeatherSettings, located: LocatedPlace?) -> WidgetsConfig.WeatherSettings {
    guard config.useLocation, let located else { return config }
    var s = config
    s.latitude = located.latitude
    s.longitude = located.longitude
    if !located.name.isEmpty { s.name = located.name }
    return s
  }
}
