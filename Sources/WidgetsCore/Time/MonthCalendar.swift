import Foundation

/// One calendar event, copied out of EventKit so the grid and the day list
/// can be worked out (and tested) without it.
public struct CalendarEvent: Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var start: Date
  public var end: Date
  public var allDay: Bool
  public var calendarID: String
  public var calendarTitle: String
  /// The calendar's color as sRGB 0...1.
  public var rgb: [Double]
  public var location: String
  /// EventKit's `calendarItemIdentifier`, for opening the event in Calendar.
  public var itemID: String
  /// One occurrence of a repeating event (or a changed one), which Calendar
  /// finds by its start as well.
  public var recurring: Bool

  public init(id: String, title: String, start: Date, end: Date, allDay: Bool,
              calendarID: String, calendarTitle: String = "", rgb: [Double] = [0.5, 0.5, 0.5],
              location: String = "", itemID: String = "", recurring: Bool = false) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
    self.allDay = allDay
    self.calendarID = calendarID
    self.calendarTitle = calendarTitle
    self.rgb = rgb
    self.location = location
    self.itemID = itemID
    self.recurring = recurring
  }
}

/// The month grid at the top of the time popup and the events listed under
/// it for the picked day.
public enum MonthCalendar {
  /// One square of the grid.
  public struct Day: Equatable, Sendable, Identifiable {
    /// Midnight starting the day.
    public var date: Date
    public var number: Int
    /// False for the days of the months before and after, drawn dimmed.
    public var inMonth: Bool
    public var id: Date { date }
  }

  /// A day's events: all-day ones first, then the timed ones by start.
  public struct DayEvents: Equatable, Sendable {
    public var allDay: [CalendarEvent]
    public var timed: [CalendarEvent]
    public var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
  }

  /// Midnight on the first of `date`'s month.
  public static func monthStart(_ date: Date, calendar cal: Calendar = .current) -> Date {
    cal.date(from: cal.dateComponents([.year, .month], from: date))!
  }

  /// The first of the month `months` away from `month`'s.
  public static func shift(_ month: Date, by months: Int, calendar cal: Calendar = .current) -> Date {
    cal.date(byAdding: .month, value: months, to: monthStart(month, calendar: cal))!
  }

  /// Six whole weeks starting on the calendar's first weekday, the month
  /// somewhere inside: always six rows, so the popup keeps its height from
  /// month to month.
  public static func grid(_ month: Date, calendar cal: Calendar = .current) -> [Day] {
    let first = monthStart(month, calendar: cal)
    let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
    let start = cal.date(byAdding: .day, value: -lead, to: first)!
    let m = cal.component(.month, from: first)
    return (0..<42).map { i in
      let d = cal.date(byAdding: .day, value: i, to: start)!
      let c = cal.dateComponents([.month, .day], from: d)
      return Day(date: d, number: c.day!, inMonth: c.month == m)
    }
  }

  /// Short weekday names in grid order ("S", "M", … or "M", "T", …).
  public static func weekdaySymbols(calendar cal: Calendar = .current) -> [String] {
    let s = cal.veryShortStandaloneWeekdaySymbols
    return (0..<7).map { s[(cal.firstWeekday - 1 + $0) % 7] }
  }

  /// The span covered by `grid(month)`, for fetching its events in one go.
  public static func gridRange(_ month: Date, calendar cal: Calendar = .current) -> (start: Date, end: Date) {
    let g = grid(month, calendar: cal)
    return (g[0].date, cal.date(byAdding: .day, value: 1, to: g[g.count - 1].date)!)
  }

  /// True if `event` takes up any of the day starting at `day`. An event
  /// with no length counts on the day it starts.
  public static func occurs(_ event: CalendarEvent, on day: Date, calendar cal: Calendar = .current) -> Bool {
    let dayStart = cal.startOfDay(for: day)
    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
    if event.end <= event.start { return event.start >= dayStart && event.start < dayEnd }
    return event.start < dayEnd && event.end > dayStart
  }

  /// `day`'s events. A timed event that covers the whole day (the middle of
  /// a three-day trip) goes with the all-day ones, as in Calendar.
  public static func events(on day: Date, _ events: [CalendarEvent], calendar cal: Calendar = .current) -> DayEvents {
    let dayStart = cal.startOfDay(for: day)
    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
    var allDay: [CalendarEvent] = [], timed: [CalendarEvent] = []
    for e in events where occurs(e, on: dayStart, calendar: cal) {
      if e.allDay || (e.start <= dayStart && e.end >= dayEnd) { allDay.append(e) } else { timed.append(e) }
    }
    allDay.sort { ($0.calendarTitle, $0.title, $0.id) < ($1.calendarTitle, $1.title, $1.id) }
    timed.sort {
      if $0.start != $1.start { return $0.start < $1.start }
      if $0.end != $1.end { return $0.end < $1.end }
      return ($0.title, $0.id) < ($1.title, $1.id)
    }
    return DayEvents(allDay: allDay, timed: timed)
  }

  /// One dot per calendar with something on `day`, at most `limit`, in a
  /// steady order (by calendar title) so a calendar's dot doesn't jump
  /// around from day to day. Each is that calendar's color.
  public static func dots(on day: Date, _ events: [CalendarEvent], limit: Int = 4,
                          calendar cal: Calendar = .current) -> [[Double]] {
    var seen: [String: CalendarEvent] = [:]
    for e in events where seen[e.calendarID] == nil && occurs(e, on: day, calendar: cal) {
      seen[e.calendarID] = e
    }
    return seen.values
      .sorted { ($0.calendarTitle, $0.calendarID) < ($1.calendarTitle, $1.calendarID) }
      .prefix(limit)
      .map(\.rgb)
  }

  /// The time line under a timed event's title, as seen from `day`:
  /// "9:00 – 10:30 AM", "11:30 AM – 1:00 PM", "Until 3:00 PM" (began on an
  /// earlier day), "From 9:00 PM" (runs past midnight), or "2:00 PM" for an
  /// event with no length.
  public static func timeLabel(_ event: CalendarEvent, on day: Date, use24h: Bool,
                               calendar cal: Calendar = .current) -> String {
    let dayStart = cal.startOfDay(for: day)
    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
    func hm(_ d: Date) -> (Int, Int) {
      let c = cal.dateComponents([.hour, .minute], from: d)
      return (c.hour!, c.minute!)
    }
    let s = hm(event.start), e = hm(event.end)
    let startsBefore = event.start < dayStart, endsAfter = event.end > dayEnd
    if startsBefore { return "Until " + TimeModel.clockLabel(e.0, e.1, use24h) }
    if endsAfter { return "From " + TimeModel.clockLabel(s.0, s.1, use24h) }
    if event.end <= event.start { return TimeModel.clockLabel(s.0, s.1, use24h) }
    if use24h { return TimeModel.clockLabel(s.0, s.1, true) + " – " + TimeModel.clockLabel(e.0, e.1, true) }
    let a = TimeModel.clockText(s.0, s.1, false), b = TimeModel.clockText(e.0, e.1, false)
    return (a.suffix == b.suffix ? a.time : a.time + " " + a.suffix) + " – " + b.time + " " + b.suffix
  }

  /// "Sunday, October 11", with "Today" or "Tomorrow" in front when it is.
  public static func dayHeading(_ day: Date, now: Date, calendar cal: Calendar = .current) -> String {
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.setLocalizedDateFormatFromTemplate(
      cal.component(.year, from: day) == cal.component(.year, from: now) ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
    let text = f.string(from: day)
    let delta = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: day)).day ?? 0
    switch delta {
    case 0: return "Today · " + text
    case 1: return "Tomorrow · " + text
    case -1: return "Yesterday · " + text
    default: return text
    }
  }

  /// The link that opens `event` in Calendar: `ical://ekevent/<id>`, with
  /// the occurrence's start for a repeating event (in UTC for a timed one,
  /// the wall clock for an all-day one, both written with a "Z"). Calendar
  /// doesn't document this scheme; it is what Calendr and MeetingBar use.
  public static func calendarAppURL(_ event: CalendarEvent, timeZone: TimeZone = .current) -> URL? {
    guard !event.itemID.isEmpty,
          let id = event.itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    var date = ""
    if event.recurring {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.calendar = Calendar(identifier: .gregorian)
      f.timeZone = event.allDay ? timeZone : TimeZone(identifier: "UTC")!
      f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
      date = "/" + f.string(from: event.start)
    }
    return URL(string: "ical://ekevent\(date)/\(id)?method=show&options=more")
  }

  /// "October 2026".
  public static func monthTitle(_ month: Date, calendar cal: Calendar = .current) -> String {
    let f = DateFormatter()
    f.calendar = cal
    f.timeZone = cal.timeZone
    f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
    return f.string(from: month)
  }
}
