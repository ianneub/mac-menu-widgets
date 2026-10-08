import Foundation
import Testing
@testable import WidgetsCore

// Ported from ianneub.time/Model.test.js.

private let M = TimeModel.self
private let eastern = TimeZone(identifier: "America/New_York")!

/// Epoch ms for an ISO 8601 string.
func timeIsoMs(_ s: String) -> Double {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime]
  if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
  f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone, .withDashSeparatorInDate]
  return f.date(from: s)!.timeIntervalSince1970 * 1000
}

/// Epoch ms for a wall-clock time in New York (month is 1-based).
private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Double {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = eastern
  return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970 * 1000
}

@Test func timeNormalizeZones() {
  typealias Z = WidgetsConfig.Zone
  #expect(M.normalizeZones(WidgetsConfig.TimeSettings().zones).count == 6)
  #expect(M.normalizeZones([Z(name: "", tz: "Asia/Kolkata"), Z(name: "Home", tz: "America/New_York")])
    == [Z(name: "Kolkata", tz: "Asia/Kolkata"), Z(name: "Home", tz: "America/New_York")])
  #expect(M.normalizeZones([Z(name: "", tz: "America/Los_Angeles")]) == [Z(name: "Los Angeles", tz: "America/Los_Angeles")])
  #expect(M.normalizeZones([Z(name: "", tz: "x; rm -rf /"), Z(name: "No tz", tz: "")]) == [])
  #expect(M.normalizeZones([Z(name: "SLC", tz: "America/Denver", lat: 40.76, lon: -111.89)])
    == [Z(name: "SLC", tz: "America/Denver", lat: 40.76, lon: -111.89)])
  #expect(M.normalizeZones([Z(name: "", tz: "UTC", lat: 40, lon: nil)]) == [Z(name: "UTC", tz: "UTC")])
}

@Test func timeZoneOffsetsFromFoundation() {
  let summer = Date(timeIntervalSince1970: timeIsoMs("2026-07-01T12:00:00Z") / 1000)
  #expect(M.zoneOffset(TimeZone(identifier: "Europe/London")!, at: summer).offset == 60)
  #expect(M.zoneOffset(TimeZone(identifier: "America/Phoenix")!, at: summer).offset == -420)
  #expect(M.zoneOffset(TimeZone(identifier: "Asia/Kathmandu")!, at: summer) == .init(offset: 345, abbr: ""))
  #expect(M.zoneOffset(eastern, at: summer) == .init(offset: -240, abbr: "EDT"))
  // tzdata's abbreviations, as `date +%Z` prints them, not Foundation's "GMT+1".
  let winter = Date(timeIntervalSince1970: timeIsoMs("2026-01-15T12:00:00Z") / 1000)
  func abbr(_ id: String, _ d: Date) -> String { M.zoneOffset(TimeZone(identifier: id)!, at: d, id: id).abbr }
  #expect(abbr("Europe/London", summer) == "BST")
  #expect(abbr("Europe/London", winter) == "GMT")
  #expect(abbr("Europe/Paris", summer) == "CEST")
  #expect(abbr("Europe/Paris", winter) == "CET")
  #expect(abbr("Asia/Kolkata", summer) == "IST")
  #expect(abbr("Asia/Tokyo", summer) == "JST")
  #expect(abbr("Australia/Sydney", winter) == "AEDT")
  #expect(abbr("America/Anchorage", winter) == "AKST")
  #expect(abbr("UTC", summer) == "UTC")
  // Far past the file's last transition: falls back on offset + DST flag.
  let future = Date(timeIntervalSince1970: timeIsoMs("2090-07-01T12:00:00Z") / 1000)
  #expect(abbr("Europe/London", future) == "BST")
}

@Test func timeOffsetAndRelativeLabels() {
  #expect(M.offsetLabel(60) == "+01:00")
  #expect(M.offsetLabel(-240) == "-04:00")
  #expect(M.offsetLabel(0) == "+00:00")
  #expect(M.offsetLabel(-570) == "-09:30")
  #expect(M.relativeLabel(-240, -240) == "Same time")
  #expect(M.relativeLabel(60, -240) == "5 hours ahead")
  #expect(M.relativeLabel(-300, -240) == "1 hour behind")
  #expect(M.relativeLabel(-420, -240) == "3 hours behind")
  #expect(M.relativeLabel(330, -240) == "9½ hours ahead")
  #expect(M.relativeLabel(345, 0) == "5¾ hours ahead")
  #expect(M.relativeLabel(-210, -240) == "30 minutes ahead")
}

@Test func timeZoneClockAndDayDeltas() {
  let now = timeIsoMs("2026-09-26T11:41:00Z")  // 7:41 AM EDT
  #expect(M.zoneClock(now, 60, -240) == .init(hours: 12, minutes: 41, dayDelta: 0))
  #expect(M.zoneClock(now, -480, -240) == .init(hours: 3, minutes: 41, dayDelta: 0))
  let late = timeIsoMs("2026-09-27T02:30:00Z")  // 10:30 PM EDT Sat
  #expect(M.zoneClock(late, 60, -240).dayDelta == 1)
  #expect(M.zoneClock(late, 60, -240).hours == 3)
  let early = timeIsoMs("2026-09-26T05:00:00Z")  // 1:00 AM EDT
  #expect(M.zoneClock(early, -480, -240).dayDelta == -1)
  #expect(M.dayDeltaLabel(1) == "Tomorrow")
  #expect(M.dayDeltaLabel(-1) == "Yesterday")
  #expect(M.dayDeltaLabel(0) == "")
}

@Test func timeClockText() {
  #expect(M.clockText(0, 5, false) == ("12:05", "AM"))
  #expect(M.clockText(12, 41, false) == ("12:41", "PM"))
  #expect(M.clockText(15, 0, false) == ("3:00", "PM"))
  #expect(M.clockText(7, 9, true) == ("07:09", ""))
  #expect(M.clockLabel(13, 1, true) == "13:01")
  #expect(M.clockLabel(13, 1, false) == "1:01 PM")
  #expect(M.clockLabel(0, 30, true) == "00:30")
}

@Test func timeBarLabel() {
  let d = Date(timeIntervalSince1970: local(2026, 10, 8, 7, 49) / 1000)
  #expect(M.barLabel(d, false, showDate: true, tz: eastern) == "Thu Oct 8  7:49 AM")
  #expect(M.barLabel(d, true, showDate: true, tz: eastern) == "Thu Oct 8  07:49")
  #expect(M.barLabel(d, false, showDate: false, tz: eastern) == "7:49 AM")
}

@Test func timeWhenLabel() {
  let now = local(2026, 9, 26, 7, 41)
  #expect(M.whenLabel(local(2026, 9, 26, 12, 49), now, false, tz: eastern) == "today 12:49 PM")
  #expect(M.whenLabel(local(2026, 9, 27, 1, 10), now, false, tz: eastern) == "tomorrow 1:10 AM")
  #expect(M.whenLabel(local(2026, 9, 30, 15, 0), now, true, tz: eastern) == "Wed 15:00")
  #expect(M.whenLabel(local(2026, 10, 10, 15, 0), now, false, tz: eastern) == "Oct 10")
}

@Test func timePhaseWhen() {
  let now = local(2026, 10, 7, 7, 41)
  #expect(M.phaseWhen(local(2026, 10, 7, 22, 5), now, false, tz: eastern) == .init(date: "Wed, Oct 7", time: "10:05 PM", rel: "today"))
  #expect(M.phaseWhen(local(2026, 10, 8, 0, 30), now, true, tz: eastern) == .init(date: "Thu, Oct 8", time: "00:30", rel: "tomorrow"))
  #expect(M.phaseWhen(local(2026, 11, 1, 9, 0), now, false, tz: eastern) == .init(date: "Sun, Nov 1", time: "9:00 AM", rel: "in 25 days"))
}

@Test func timeParseZoneTab() {
  let tab = "# comment\nGB,GG\t+513030-0000731\tEurope/London\nUS\t+611305-1495401\tAmerica/Anchorage\tAlaska\nAU\t-3352+15113\tAustralia/Sydney\n"
  let z = M.parseZoneTab(tab)
  #expect(abs(z["Europe/London"]!.lat - 51.5083) < 1e-3)
  #expect(abs(z["Europe/London"]!.lon - -0.1253) < 1e-3)
  #expect(abs(z["America/Anchorage"]!.lon - -149.9003) < 1e-3)
  #expect(abs(z["Australia/Sydney"]!.lat - -33.8667) < 1e-3)
  // The system file is there on macOS (zone.tab) and covers the defaults.
  let sys = M.systemZoneCoords()
  #expect(sys["America/Phoenix"] != nil)
}

@Test func timeDayStartFor() {
  let now = timeIsoMs("2026-09-26T11:50:00Z")
  #expect(M.dayStartFor(now, 60) == timeIsoMs("2026-09-26T00:00:00+01:00"))
  #expect(M.dayStartFor(timeIsoMs("2026-09-26T02:00:00Z"), -240) == timeIsoMs("2026-09-25T00:00:00-04:00"))
}

@Test func timeInZoneRounds() {
  let t = timeIsoMs("2026-09-26T05:19:40Z")
  #expect(M.timeInZone(t, 60, false) == "6:20 AM")
  #expect(M.timeInZone(t, 60, true) == "06:20")
  #expect(M.timeInZone(nil, 60, false) == "—")
}

@Test func timePlaceWhenLabel() {
  // Saturday 2026-09-26 12:50 BST.
  #expect(M.placeWhenLabel(timeIsoMs("2026-09-26T11:50:00Z"), 60, "BST") == "Saturday  ·  12:50  ·  BST UTC+01:00")
  #expect(M.placeWhenLabel(timeIsoMs("2026-09-26T02:00:00Z"), -240, "EDT") == "Friday  ·  22:00  ·  EDT UTC-04:00")
  #expect(M.placeWhenLabel(timeIsoMs("2026-09-26T02:00:00Z"), 0, "UTC") == "Saturday  ·  02:00  ·  UTC+00:00")
}

@Test func timeDurationsAndDaylight() {
  #expect(M.durationShort(5 * 3_600_000 + 59.9 * 60_000) == "5h 59m")
  #expect(M.durationShort(37 * 60_000) == "37m")
  #expect(M.daylightLabel(716.9 * 60_000, .none) == "11 hours, 57 minutes of daylight")
  #expect(M.daylightLabel(61 * 60_000, .none) == "1 hour, 1 minute of daylight")
  #expect(M.daylightLabel(nil, .up) == "Sun up all day")
  #expect(M.daylightChange(-3.9 * 60_000) == "\u{2212}4 minutes vs yesterday")
  #expect(M.daylightChange(38_000) == "+38 seconds vs yesterday")
  #expect(M.daylightChange(0) == "Same as yesterday")
}

@Test func timeWorldMapLoads() {
  #expect(WorldMap.land.count == 119)
  #expect(WorldMap.land.allSatisfy { $0.count % 2 == 0 })
}
