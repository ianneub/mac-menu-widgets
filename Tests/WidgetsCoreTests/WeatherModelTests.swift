import Foundation
import Testing
@testable import WidgetsCore

// Port of the Omarchy plugin's Model.test.js.

private typealias W = Weather

private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

private func nwsHour(_ stamp: String, _ pop: Any, _ temp: Double, _ wind: String = "5 mph", _ dir: String = "") -> [String: Any] {
  ["startTime": stamp, "windDirection": dir, "temperature": temp, "temperatureUnit": "F",
   "probabilityOfPrecipitation": ["unitCode": "wmoUnit:percent", "value": pop], "windSpeed": wind]
}

private func hour(_ date: String, _ h: Int, _ pop: Int?, _ src: W.HourSource, temp: Double? = 60, wind: Double? = 3) -> W.Hour {
  W.Hour(date: date, hour: h, pop: pop, tempF: temp, windMph: wind, source: src)
}

private func slot(pop: Int? = nil, temp: Double? = nil, wind: Double? = nil, h: Int = 0) -> W.Hour {
  W.Hour(date: "2026-10-04", hour: h, pop: pop, tempF: temp, windMph: wind, source: .nws)
}

@Suite struct WeatherModelTests {
  @Test func nwsHourlyUrlSitsBesideDaily() {
    #expect(W.nwsHourlyURL("https://api.weather.gov/gridpoints/FFC/51,87/forecast")
      == "https://api.weather.gov/gridpoints/FFC/51,87/forecast/hourly")
    #expect(W.nwsHourlyURL("none") == "")
    #expect(W.nwsHourlyURL("") == "")
  }

  @Test func nwsHourlyReadsLocalStampNullChanceIsZero() throws {
    let rows = try #require(W.nwsHourly(json(["properties": ["periods": [
      nwsHour("2026-10-04T23:00:00-04:00", 61, 73, "0 mph"),
      nwsHour("2026-10-05T00:00:00-04:00", NSNull(), 70, "5 to 10 mph", "NE"),
    ]]])))
    #expect(rows.count == 2)
    #expect(rows[0] == W.Hour(date: "2026-10-04", hour: 23, pop: 61, tempF: 73, windMph: 0, windDir: nil, source: .nws))
    #expect(rows[1].date == "2026-10-05")
    #expect(rows[1].hour == 0)
    #expect(rows[1].pop == 0)
    #expect(rows[1].windMph == 10)
    #expect(rows[1].windDir == 45)
    #expect(W.nwsHourly(Data("<html>500</html>".utf8)) == nil)
    #expect(W.nwsHourly(json(["properties": ["periods": []]])) == nil)
  }

  @Test func openMeteoHourlyConvertsUnits() throws {
    let report = try #require(W.OpenMeteoReport.parse(json(["hourly": [
      "time": ["2026-10-04T00:00", "2026-10-04T01:00"],
      "temperature_2m": [20, NSNull()],
      "precipitation_probability": [40, NSNull()],
      "wind_speed_10m": [10, 0],
      "wind_direction_10m": [200, NSNull()],
    ]])))
    let rows = W.openMeteoHourly(report)
    #expect(rows[0].tempF == 68)
    #expect(rows[0].pop == 40)
    #expect(abs(rows[0].windMph! - 6.21371) < 1e-6)
    #expect(rows[1].pop == nil)
    #expect(rows[0].windDir == 200)
    #expect(rows[1].windDir == nil)
    #expect(W.openMeteoHourly(nil).isEmpty)
  }

  @Test func hourlyForDayNwsWinsOpenMeteoFills() {
    var om = (0..<24).map { hour("2026-10-04", $0, 5, .openMeteo) }
    om.append(hour("2026-10-05", 0, 99, .openMeteo))
    let nws = [hour("2026-10-04", 12, 61, .nws, temp: 73, wind: 0), hour("2026-10-04", 13, 0, .nws, temp: 74, wind: 0)]
    let slots = W.hourlyForDay("2026-10-04", nws: nws, openMeteo: om)
    #expect(slots.count == 24)
    #expect(slots[11]?.source == .openMeteo)
    #expect(slots[12]?.pop == 61)
    #expect(slots[13]?.pop == 0)
    #expect(slots[13]?.source == .nws)
    #expect(slots.allSatisfy { $0 != nil })
    #expect(W.hourlyForDay("2026-10-06", nws: nws, openMeteo: []).allSatisfy { $0 == nil })
  }

  @Test func dstFallBackRepeatKeepsFirstHour() {
    let nws = [hour("2026-11-01", 1, 10, .nws), hour("2026-11-01", 1, 80, .nws)]
    #expect(W.hourlyForDay("2026-11-01", nws: nws, openMeteo: [])[1]?.pop == 10)
  }

  @Test func peakPrecipHour() {
    let slots: [W.Hour?] = [nil, slot(pop: 30, h: 1), slot(pop: 50, h: 2), slot(pop: 50, h: 3), slot(pop: 0, h: 4)]
    #expect(W.peakPrecipHour(slots)?.hour == 2)
    #expect(W.peakPrecipHour([nil, slot(pop: 0, h: 1)]) == nil)
  }

  @Test func hourlyTempRange() {
    let slots: [W.Hour?] = [slot(temp: 50), nil, slot(temp: 68), slot(temp: nil)]
    #expect(W.hourlyTempRange(slots, imperial: true) == W.ValueRange(min: 50, max: 68, span: 18))
    #expect(W.hourlyTempRange(slots, imperial: false) == W.ValueRange(min: 10, max: 20, span: 10))
    #expect(W.hourlyTempRange([nil], imperial: true) == nil)
  }

  @Test func compass() {
    #expect(W.compassDegrees("N") == 0)
    #expect(W.compassDegrees("sw") == 225)
    #expect(W.compassDegrees("") == nil)
    #expect(W.compassName(44) == "NE")
    #expect(W.compassName(359) == "N")
    #expect(W.compassName(-90) == "W")
    #expect(W.compassName(nil) == "")
  }

  @Test func hourlyWindRangeFromZero() {
    #expect(W.hourlyWindRange([slot(wind: 5), slot(wind: 0), nil], imperial: true) == W.ValueRange(min: 0, max: 10, span: 10))
    #expect(W.hourlyWindRange([slot(wind: 25)], imperial: true) == W.ValueRange(min: 0, max: 25, span: 25))
    #expect(W.hourlyWindRange([slot(wind: 5)], imperial: false)?.max == 16)
    #expect(W.hourlyWindRange([nil, slot(wind: nil)], imperial: true) == nil)
    #expect(W.windValue(nil, imperial: true) == nil)
  }

  @Test func niceRange() {
    func r(_ a: Double, _ b: Double) -> W.ValueRange { W.ValueRange(min: a, max: b, span: b - a) }
    #expect(W.niceRange(r(57, 82))?.ticks == [50, 60, 70, 80, 90])
    #expect(W.niceRange(r(64, 79))?.ticks == [60, 65, 70, 75, 80])
    #expect(W.niceRange(r(68, 70))?.ticks == [68, 69, 70])
    #expect(W.niceRange(r(0, 10))?.ticks == [0, 5, 10])
    #expect(W.niceRange(r(0, 23))?.ticks == [0, 10, 20, 30])
    #expect(W.niceRange(r(-3, 4))?.ticks == [-4, -2, 0, 2, 4])
    #expect(W.niceRange(r(70, 70)) == W.ValueRange(min: 70, max: 71, span: 1, ticks: [70, 71]))
    #expect(W.niceRange(nil) == nil)
  }

  @Test func labels() {
    #expect(W.hourLabel(0) == "12 AM")
    #expect(W.hourLabel(12) == "12 PM")
    #expect(W.hourLabel(15) == "3 PM")
    #expect(W.clockFromStamp("2026-10-04T07:37") == "7:37 AM")
    #expect(W.clockFromStamp("2026-10-04T19:19") == "7:19 PM")
    #expect(W.clockFromStamp("") == "")
  }

  @Test func dayExtrasAndLabels() throws {
    let report = try #require(W.OpenMeteoReport.parse(json(["daily": [
      "time": ["2026-10-04", "2026-10-05"],
      "precipitation_sum": [12.9, 0],
      "uv_index_max": [2.2, 5.9],
      "wind_speed_10m_max": [13.4, 21.2],
      "wind_gusts_10m_max": [26.6, 37.4],
      "sunrise": ["2026-10-04T07:37", "2026-10-05T07:38"],
      "sunset": ["2026-10-04T19:19", "2026-10-05T19:18"],
    ]])))
    let today = W.openMeteoDayExtras(report, date: "2026-10-04")
    #expect(today?.sunrise == "7:37 AM")
    #expect(today?.sunset == "7:19 PM")
    #expect(W.precipAmountLabel(today, imperial: true) == "0.51 in")
    #expect(W.precipAmountLabel(today, imperial: false) == "13 mm")
    let tomorrow = W.openMeteoDayExtras(report, date: "2026-10-05")
    #expect(W.precipAmountLabel(tomorrow, imperial: true) == "0 in")
    #expect(W.uvLabel(today) == "2 · Low")
    #expect(W.uvLabel(tomorrow) == "6 · High")
    #expect(W.openMeteoDayExtras(report, date: "2026-10-09") == nil)

    // Hourly NWS wind beats the daily max; gusts come along when stronger.
    #expect(W.windLabel([slot(wind: 12), nil, slot(wind: 7)], extras: today, imperial: true) == "12 mph, gusts 17")
    #expect(W.windLabel([], extras: today, imperial: true) == "8 mph, gusts 17")
    #expect(W.windLabel([], extras: nil, imperial: true) == "")
  }

  @Test func nwsForecastDaysKeepNarratives() throws {
    let days = try #require(W.nwsForecastDays(json(["properties": ["periods": [
      ["name": "Today", "startTime": "2026-10-04T08:00:00-04:00", "isDaytime": true, "temperature": 79, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/day/tsra,70", "shortForecast": "Showers", "detailedForecast": "Rain likely."],
      ["name": "Tonight", "startTime": "2026-10-04T18:00:00-04:00", "isDaytime": false, "temperature": 64, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/night/sct", "shortForecast": "Partly Cloudy", "detailedForecast": "Clearing."],
    ]]])))
    #expect(days[0].nwsDayText?.name == "Today")
    #expect(days[0].nwsDayText?.detailedForecast == "Rain likely.")
    #expect(days[0].nwsNightText?.shortForecast == "Partly Cloudy")
    #expect(days[0].maxtempF == 79)
    #expect(days[0].mintempF == 64)
    #expect(days[0].nwsIconCode == "tsra")
  }

  @Test func eachDayRowCarriesPrecipChance() throws {
    let days = try #require(W.nwsForecastDays(json(["properties": ["periods": [
      ["name": "Today", "startTime": "2026-10-04T08:00:00-04:00", "isDaytime": true, "temperature": 79, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/day/sct", "probabilityOfPrecipitation": ["value": 20]],
      ["name": "Tonight", "startTime": "2026-10-04T18:00:00-04:00", "isDaytime": false, "temperature": 64, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/night/tsra,60", "probabilityOfPrecipitation": ["value": 60]],
      ["name": "Monday", "startTime": "2026-10-05T06:00:00-04:00", "isDaytime": true, "temperature": 75, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/day/few", "probabilityOfPrecipitation": ["value": NSNull()]],
    ]]])))
    // The row spans day and night, so tonight's storms count.
    #expect(W.dayPrecipChance(days[0]) == 60)
    #expect(W.precipChanceLabel(days[0]) == "60%")
    // NWS's null chance is "none worth mentioning".
    #expect(W.dayPrecipChance(days[1]) == 0)
    #expect(W.precipChanceLabel(days[1]) == "")

    let om = try #require(W.OpenMeteoReport.parse(json(["daily": [
      "time": ["2026-10-04", "2026-10-05", "2026-10-06"],
      "precipitation_probability_max": [90, 35, 6],
    ]])))
    #expect(W.openMeteoForecastDays(om, today: "2026-10-04", limit: 3).map(W.precipChanceLabel) == ["35%", ""])
    #expect(W.precipChanceLabel(nil) == "")
  }

  @Test func eveningForecastOpensOnTonight() throws {
    let days = try #require(W.nwsForecastDays(json(["properties": ["periods": [
      ["name": "Tonight", "startTime": "2026-10-04T18:00:00-04:00", "isDaytime": false, "temperature": 60, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/night/skc"],
      ["name": "Monday", "startTime": "2026-10-05T06:00:00-04:00", "isDaytime": true, "temperature": 75, "temperatureUnit": "F",
       "icon": "https://api.weather.gov/icons/land/day/few"],
    ]]])))
    #expect(days.count == 2)
    #expect(days[0].date == "2026-10-04")
    #expect(days[0].maxtempF == nil)
    #expect(days[0].mintempF == 60)
    #expect(days[0].nwsNight)
    #expect(W.dayIcon(days[0]) == "moon.stars.fill")
    // The last daytime period has no night: it borrows Open-Meteo's low.
    let fb = W.withMissingTemps(days[1], from: { var d = W.Day(date: "2026-10-05"); d.mintempF = 55; return d }())
    #expect(fb.mintempF == 55)
    #expect(fb.maxtempF == 75)
  }

  @Test func forecastRowsTodayThenNwsThenOpenMeteo() throws {
    let om = try #require(W.OpenMeteoReport.parse(json(["daily": [
      "time": ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"],
      "temperature_2m_max": [20, 21, 22, 23], "temperature_2m_min": [10, 11, 12, 13],
      "weather_code": [0, 3, 61, 95],
    ]])))
    var nws = W.Day(date: "2026-10-05"); nws.maxtempF = 80; nws.nwsIconCode = "rain"
    let rows = W.buildForecastRows(om, today: "2026-10-04", limit: 4, nwsDays: [nws])
    #expect(rows.map(\.date) == ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"])
    #expect(rows[0].openMeteoWeatherCode == 0)
    #expect(rows[1].maxtempF == 80)
    #expect(rows[1].mintempF == 52) // borrowed: 11 °C
    #expect(W.dayIcon(rows[1]) == "cloud.rain.fill")
    #expect(W.dayIcon(rows[3]) == "cloud.bolt.rain.fill")
    #expect(W.buildForecastRows(om, today: "2026-10-04", limit: 1, nwsDays: []).count == 1)
  }

  @Test func iconCodePicksDominantCondition() {
    #expect(W.nwsIconCode("https://api.weather.gov/icons/land/day/rain_showers,20/tsra_hi,60?size=medium") == "tsra_hi")
    #expect(W.nwsIconCode("https://api.weather.gov/icons/land/day/fog/skc") == "skc")
    #expect(W.nwsIconCode("") == "")
  }

  @Test func forecastPointAndRound() {
    #expect(W.forecastPoint(latitude: 33.74901, longitude: -84.38798)?.key == "33.749,-84.388")
    #expect(W.jsRound(2.5) == 3)
    #expect(W.jsRound(-2.5) == -2)
  }

  @Test func currentConditions() throws {
    let om = try #require(W.OpenMeteoReport.parse(json(["current": [
      "temperature_2m": 21.4, "apparent_temperature": 20, "relative_humidity_2m": 55,
      "wind_speed_10m": 10, "weather_code": 2, "is_day": 0,
    ]])))
    let c = try #require(W.openMeteoCurrent(om))
    #expect(c.tempF == 71)
    #expect(c.tempC == 21)
    #expect(c.feelsLikeF == 68)
    #expect(c.windMph == 6)
    #expect(c.humidity == 55)
    #expect(W.currentIcon(c) == "cloud.moon.fill")
  }

  @Test func geocoding() {
    let places = W.parseGeocodingResults(json(["results": [
      ["name": "Paris", "latitude": 48.85, "longitude": 2.35, "admin1": "Île-de-France", "country": "France"],
      ["name": "Nowhere"],
    ]]))
    #expect(places == [W.Place(name: "Paris", description: "Île-de-France, France", latitude: 48.85, longitude: 2.35)])
    #expect(W.parseGeocodingResults(Data("{}".utf8)).isEmpty)
  }

  @Test func unitPreference() {
    #expect(W.shouldUseImperial(unit: "F"))
    #expect(!W.shouldUseImperial(unit: "metric"))
    #expect(W.shouldUseImperial(unit: "", localeIdentifier: "en_US"))
    #expect(!W.shouldUseImperial(unit: "", localeIdentifier: "en_GB"))
  }

  /// WEATHER_FIXTURES=dir with hourly.json (NWS) and om.json (Open-Meteo).
  @Test func realPayloadsParse() throws {
    guard let dir = ProcessInfo.processInfo.environment["WEATHER_FIXTURES"] else { return }
    let nws = try #require(W.nwsHourly(Data(contentsOf: URL(fileURLWithPath: dir + "/hourly.json"))))
    let om = W.openMeteoHourly(W.OpenMeteoReport.parse(try Data(contentsOf: URL(fileURLWithPath: dir + "/om.json"))))
    #expect(nws.count > 100)
    #expect(om.count >= 24 * 8)
    let slots = W.hourlyForDay(nws[30].date, nws: nws, openMeteo: om)
    #expect(slots.allSatisfy { $0?.source == .nws })
    if let forecast = try? Data(contentsOf: URL(fileURLWithPath: dir + "/forecast.json")) {
      let days = try #require(W.nwsForecastDays(forecast))
      #expect(days.count >= 7)
    }
  }
}
