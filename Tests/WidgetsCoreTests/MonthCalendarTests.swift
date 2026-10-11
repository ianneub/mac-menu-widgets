import Foundation
import Testing
@testable import WidgetsCore

private let C = MonthCalendar.self

private func cal(firstWeekday: Int = 1) -> Calendar {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "America/New_York")!
  c.locale = Locale(identifier: "en_US")
  c.firstWeekday = firstWeekday
  return c
}

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
  cal().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false,
                   calendar: String = "Home", rgb: [Double] = [1, 0, 0]) -> CalendarEvent {
  CalendarEvent(id: id, title: id, start: start, end: end, allDay: allDay,
                calendarID: calendar, calendarTitle: calendar, rgb: rgb)
}

@Test func monthGridStartsOnFirstWeekday() {
  // October 2026 begins on a Thursday.
  let g = C.grid(at(2026, 10, 11), calendar: cal())
  #expect(g.count == 42)
  #expect(g[0].date == at(2026, 9, 27))
  #expect(!g[0].inMonth)
  #expect(g[4].number == 1 && g[4].inMonth)
  #expect(g[34].number == 31 && g[34].inMonth)
  #expect(g[35].number == 1 && !g[35].inMonth)

  let monday = C.grid(at(2026, 10, 11), calendar: cal(firstWeekday: 2))
  #expect(monday[0].date == at(2026, 9, 28))
  #expect(C.weekdaySymbols(calendar: cal(firstWeekday: 2)) == ["M", "T", "W", "T", "F", "S", "S"])
}

@Test func monthGridAcrossDaylightSavingAndShift() {
  // November 2026: DST ends on the 1st; every square is still a midnight.
  let c = cal()
  for day in C.grid(at(2026, 11, 1), calendar: c) {
    #expect(c.component(.hour, from: day.date) == 0)
  }
  #expect(C.shift(at(2026, 1, 31), by: 1, calendar: c) == at(2026, 2, 1))
  #expect(C.shift(at(2026, 1, 15), by: -1, calendar: c) == at(2025, 12, 1))
  let r = C.gridRange(at(2026, 10, 1), calendar: c)
  #expect(r.start == at(2026, 9, 27) && r.end == at(2026, 11, 8))
}

@Test func dayEventsAllDayFirstThenByStart() {
  let c = cal()
  let events = [
    event("Lunch", at(2026, 10, 11, 12), at(2026, 10, 11, 13)),
    event("Standup", at(2026, 10, 11, 9), at(2026, 10, 11, 9, 15)),
    // EventKit's all-day events end at 23:59:59 on their last day.
    event("Holiday", at(2026, 10, 11), at(2026, 10, 11, 23, 59), allDay: true, calendar: "Holidays"),
    event("Trip", at(2026, 10, 10, 8), at(2026, 10, 12, 18)),
    event("Late", at(2026, 10, 10, 22), at(2026, 10, 11, 1)),
    event("Yesterday", at(2026, 10, 10, 9), at(2026, 10, 10, 10)),
    event("Ends at midnight", at(2026, 10, 10, 23), at(2026, 10, 11)),
    event("Tomorrow", at(2026, 10, 12), at(2026, 10, 12, 23, 59), allDay: true),
  ]
  let d = C.events(on: at(2026, 10, 11), events, calendar: c)
  #expect(d.allDay.map(\.id) == ["Holiday", "Trip"])
  #expect(d.timed.map(\.id) == ["Late", "Standup", "Lunch"])
  #expect(C.events(on: at(2026, 10, 13), events, calendar: c).isEmpty)
}

@Test func dotsOnePerCalendarInSteadyOrder() {
  let c = cal()
  let events = [
    event("a", at(2026, 10, 11, 9), at(2026, 10, 11, 10), calendar: "Work", rgb: [0, 0, 1]),
    event("b", at(2026, 10, 11, 11), at(2026, 10, 11, 12), calendar: "Work", rgb: [0, 0, 1]),
    event("c", at(2026, 10, 11, 13), at(2026, 10, 11, 14), calendar: "Family", rgb: [0, 1, 0]),
    event("d", at(2026, 10, 12, 13), at(2026, 10, 12, 14), calendar: "Home"),
  ]
  #expect(C.dots(on: at(2026, 10, 11), events, calendar: c) == [[0, 1, 0], [0, 0, 1]])
  #expect(C.dots(on: at(2026, 10, 11), events, limit: 1, calendar: c) == [[0, 1, 0]])
  #expect(C.dots(on: at(2026, 10, 13), events, calendar: c).isEmpty)
  // A point-in-time event counts on its day only.
  let point = [event("p", at(2026, 10, 12), at(2026, 10, 12))]
  #expect(C.dots(on: at(2026, 10, 12), point, calendar: c).count == 1)
  #expect(C.dots(on: at(2026, 10, 11), point, calendar: c).isEmpty)
}

@Test func eventTimeLabels() {
  let c = cal()
  let day = at(2026, 10, 11)
  func label(_ s: Date, _ e: Date, _ h24: Bool = false) -> String {
    C.timeLabel(event("x", s, e), on: day, use24h: h24, calendar: c)
  }
  #expect(label(at(2026, 10, 11, 9), at(2026, 10, 11, 10, 30)) == "9:00 – 10:30 AM")
  #expect(label(at(2026, 10, 11, 11, 30), at(2026, 10, 11, 13)) == "11:30 AM – 1:00 PM")
  #expect(label(at(2026, 10, 11, 9), at(2026, 10, 11, 10, 30), true) == "09:00 – 10:30")
  #expect(label(at(2026, 10, 10, 22), at(2026, 10, 11, 15)) == "Until 3:00 PM")
  #expect(label(at(2026, 10, 11, 21), at(2026, 10, 12, 2)) == "From 9:00 PM")
  #expect(label(at(2026, 10, 11, 23), at(2026, 10, 12)) == "11:00 PM – 12:00 AM")
  #expect(label(at(2026, 10, 11, 14), at(2026, 10, 11, 14)) == "2:00 PM")
}

@Test func dayHeadings() {
  let c = cal()
  let now = at(2026, 10, 11, 15)
  #expect(C.dayHeading(at(2026, 10, 11), now: now, calendar: c) == "Today · Sunday, October 11")
  #expect(C.dayHeading(at(2026, 10, 12), now: now, calendar: c) == "Tomorrow · Monday, October 12")
  #expect(C.dayHeading(at(2026, 10, 20), now: now, calendar: c) == "Tuesday, October 20")
  #expect(C.dayHeading(at(2027, 1, 4), now: now, calendar: c) == "Monday, January 4, 2027")
  #expect(C.monthTitle(at(2026, 10, 1), calendar: c) == "October 2026")
}

@Test func calendarAppLinks() {
  let tz = TimeZone(identifier: "America/New_York")!
  var e = event("x", at(2026, 10, 11, 9), at(2026, 10, 11, 10))
  #expect(C.calendarAppURL(e, timeZone: tz) == nil)
  e.itemID = "AB12-CD34"
  #expect(C.calendarAppURL(e, timeZone: tz)?.absoluteString == "ical://ekevent/AB12-CD34?method=show&options=more")
  e.recurring = true
  #expect(C.calendarAppURL(e, timeZone: tz)?.absoluteString
    == "ical://ekevent/20261011T130000Z/AB12-CD34?method=show&options=more")
  var day = event("y", at(2026, 10, 11), at(2026, 10, 11, 23, 59), allDay: true)
  day.itemID = "EF56"
  day.recurring = true
  #expect(C.calendarAppURL(day, timeZone: tz)?.absoluteString
    == "ical://ekevent/20261011T000000Z/EF56?method=show&options=more")
}
