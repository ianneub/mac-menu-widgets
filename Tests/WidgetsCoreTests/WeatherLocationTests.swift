import Foundation
import Testing
@testable import WidgetsCore

@Test func locationDisplayNames() {
  #expect(WeatherLocation.displayName("Cupertino, CA") == "Cupertino CA")
  #expect(WeatherLocation.displayName("  New York,  NY ") == "New York NY")
  #expect(WeatherLocation.displayName("London") == "London")
}

@Test func locationDistances() {
  // Atlanta to Chattanooga is about 170 km.
  let d = WeatherLocation.distance(33.749, -84.388, 35.0456, -85.3097)
  #expect(d > 160_000 && d < 175_000)
  #expect(WeatherLocation.distance(33.749, -84.388, 33.749, -84.388) == 0)
}

@Test func locationMoves() {
  let here = LocatedPlace(latitude: 33.749, longitude: -84.388, name: "Atlanta GA")
  #expect(WeatherLocation.moved(from: nil, latitude: 0, longitude: 0))
  // ~1 km north: Wi-Fi wander, not a move.
  #expect(!WeatherLocation.moved(from: here, latitude: 33.758, longitude: -84.388))
  // ~5 km: a move.
  #expect(WeatherLocation.moved(from: here, latitude: 33.794, longitude: -84.388))
}

@Test func locationOverridesConfigOnlyWhenOn() {
  var config = WidgetsConfig.WeatherSettings()
  config.name = "Fallback"
  let here = LocatedPlace(latitude: 40.7608, longitude: -111.891, name: "Salt Lake City UT")
  let on = WeatherLocation.effective(config, located: here)
  #expect(on.name == "Salt Lake City UT" && on.latitude == 40.7608 && on.longitude == -111.891)
  #expect(WeatherLocation.effective(config, located: nil).name == "Fallback")
  config.useLocation = false
  #expect(WeatherLocation.effective(config, located: here).name == "Fallback")
  // No name from geocoding: keep the point, fall back to the config's name.
  config.useLocation = true
  #expect(WeatherLocation.effective(config, located: .init(latitude: 1, longitude: 2, name: "")).name == "Fallback")
}

@Test func weatherUseLocationDefaultsOn() throws {
  let c = try JSONDecoder().decode(WidgetsConfig.self, from: Data(#"{"weather": {"name": "X"}}"#.utf8))
  #expect(c.weather.useLocation)
  let off = try JSONDecoder().decode(WidgetsConfig.self, from: Data(#"{"weather": {"useLocation": false}}"#.utf8))
  #expect(!off.weather.useLocation)
}
