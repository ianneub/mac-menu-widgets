import Foundation
import Testing
@testable import WidgetsCore

@Test func partialConfigKeepsDefaults() throws {
  let json = #"{"weather": {"name": "Paris", "latitude": 48.85, "longitude": 2.35}}"#
  let c = try JSONDecoder().decode(WidgetsConfig.self, from: Data(json.utf8))
  #expect(c.weather.name == "Paris")
  #expect(c.weather.forecastDays == 10)
  #expect(c.time.zones.count == 6)
  #expect(c.agents.refreshIntervalSec == 900)
}

@Test func bareZoneStringsDecode() throws {
  let json = #"{"time": {"zones": ["Asia/Tokyo", {"tz": "America/New_York"}, {"name": "Home", "tz": "America/Chicago", "lat": 1, "lon": 2}]}}"#
  let z = try JSONDecoder().decode(WidgetsConfig.self, from: Data(json.utf8)).time.zones
  #expect(z.map(\.name) == ["Tokyo", "New York", "Home"])
  #expect(z[2].lat == 1)
}
