import Foundation
import Testing
@testable import WidgetsCore

// Ported from ianneub.time/Astro.test.js. Reference values: USNO phase
// instants, and the iStat Menus pane for London on 2026-09-26 (screenshot
// taken at 12:50 PM BST).

private let A = Astro.self
private let MIN = 60_000.0
private let DAY = 86_400_000.0

private func near(_ actual: Double?, _ expected: Double, _ tolMin: Double, _ what: String) {
  guard let actual else {
    Issue.record("\(what): null")
    return
  }
  #expect(abs(actual - expected) <= tolMin * MIN,
    "\(what): off by \(String(format: "%.1f", (actual - expected) / MIN)) min")
}

@Test(arguments: [
  ("2023-12-05T05:49:00Z", "Last Quarter"),
  ("2024-04-08T18:21:00Z", "New Moon"),
  ("2024-04-23T23:49:00Z", "Full Moon"),
  ("2025-01-13T22:27:00Z", "Full Moon"),
  ("2025-06-03T03:41:00Z", "First Quarter"),
])
func astroNextPrincipal(iso: String, name: String) {
  let next = A.nextPrincipal(timeIsoMs(iso) - 2 * DAY)
  #expect(next.name == name)
  near(next.ms, timeIsoMs(iso), 10, name)
}

@Test func astroMoonInfoMatchesIStat() {
  let info = A.moonInfo(timeIsoMs("2026-09-26T11:41:00Z"))
  #expect(info.name == "Waxing Gibbous")
  #expect(info.waxing)
  #expect(info.illumination > 0.99)
  #expect(info.next.name == "Full Moon")
  near(info.next.ms, timeIsoMs("2026-09-26T16:49:00Z"), 10, "full moon")
}

@Test func astroUpcomingPhases() {
  let start = timeIsoMs("2026-10-07T12:00:00Z")
  let list = A.upcomingPhases(start, count: 8)
  #expect(list.count == 8)
  let names = ["New Moon", "First Quarter", "Full Moon", "Last Quarter"]
  let first = names.firstIndex(of: list[0].name)!
  for i in 1..<list.count {
    #expect(list[i].name == names[(first + i) % 4])
    let gap = (list[i].ms - list[i - 1].ms) / DAY
    #expect(gap > 5.5 && gap < 9, "gap \(gap) days")
  }
  #expect(list[0].ms > start)
}

@Test func astroPhaseName() {
  #expect(A.phaseName(0.5) == "New Moon")
  #expect(A.phaseName(359.5) == "New Moon")
  #expect(A.phaseName(45) == "Waxing Crescent")
  #expect(A.phaseName(90.4) == "First Quarter")
  #expect(A.phaseName(179.5) == "Full Moon")
  #expect(A.phaseName(200) == "Waning Gibbous")
  #expect(A.phaseName(300) == "Waning Crescent")
}

@Test func astroLondonDayEventsMatchIStat() {
  func bst(_ hm: String) -> Double { timeIsoMs("2026-09-26T\(hm):00+01:00") }
  let e = A.dayEvents(lat: 51.5074, lon: -0.1278, dayStart: bst("00:00"))
  near(e.sunrise, bst("06:52"), 2, "sunrise")
  near(e.solarNoon, bst("12:52"), 2, "solarNoon")
  near(e.sunset, bst("18:49"), 2, "sunset")
  near(e.moonset, bst("06:30"), 2, "moonset")
  near(e.moonTransit, bst("00:15"), 2, "moonTransit")
  near(e.moonrise, bst("18:27"), 2, "moonrise")
  near(e.civil.start, bst("06:20"), 2, "civil dawn")
  near(e.civil.end, bst("19:23"), 2, "civil dusk")
  near(e.nautical.start, bst("05:41"), 2, "nautical dawn")
  near(e.nautical.end, bst("20:02"), 2, "nautical dusk")
  near(e.astronomical.start, bst("05:00"), 2, "astro dawn")
  near(e.astronomical.end, bst("20:43"), 2, "astro dusk")
  near(e.blueMorning.end, bst("06:33"), 2, "blue hour end")
  near(e.goldenMorning.end, bst("07:38"), 2, "golden hour end")
  near(e.goldenEvening.start, bst("18:06"), 2, "golden hour start")
  near(e.blueEvening.start, bst("19:11"), 2, "blue hour start")
  #expect(Int((e.daylight! / MIN).rounded()) == 11 * 60 + 57)
  let y = A.dayEvents(lat: 51.5074, lon: -0.1278, dayStart: bst("00:00") - DAY)
  #expect(Int(((e.daylight! - y.daylight!) / MIN).rounded()) == -4)
}

@Test func astroNextHorizonEvents() {
  let now = timeIsoMs("2026-09-26T11:50:00Z")
  let sun = A.nextHorizonEvent(.sun, lat: 51.5074, lon: -0.1278, from: now)!
  let moon = A.nextHorizonEvent(.moon, lat: 51.5074, lon: -0.1278, from: now)!
  #expect(sun.rising == false)
  #expect(moon.rising == true)
  #expect(Int(floor((sun.ms - now) / MIN)) == 5 * 60 + 59)
  #expect(Int(floor((moon.ms - now) / MIN)) == 5 * 60 + 37)
}

@Test func astroPolarDayAndNight() {
  let june = A.dayEvents(lat: 78.22, lon: 15.65, dayStart: timeIsoMs("2026-06-21T00:00:00+02:00"))  // Longyearbyen
  #expect(june.polar == .up)
  #expect(june.sunrise == nil)
  #expect(june.daylight == DAY)
  let dec = A.dayEvents(lat: 78.22, lon: 15.65, dayStart: timeIsoMs("2026-12-21T00:00:00+01:00"))
  #expect(dec.polar == .down)
  #expect(dec.daylight == 0)
}

@Test func astroSubsolarAtEquinox() {
  let s = A.subSolar(timeIsoMs("2026-09-26T11:51:00Z"))
  #expect(abs(s.lat - -1.4) < 0.3)
  #expect(abs(s.lon) < 1.5)
  // The terminator runs almost pole to pole at the equinox.
  #expect(abs(A.terminatorLat(s.lon + 90, s)) < 1)
}
