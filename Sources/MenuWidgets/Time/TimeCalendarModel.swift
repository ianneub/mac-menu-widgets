import AppKit
import EventKit
import WidgetsCore

/// The month shown at the top of the time popup and the day picked in it,
/// with that month's events read from the Mac's calendars (iCloud and any
/// other account in Internet Accounts) through EventKit. Calendar access is
/// asked for the first time the popup opens, not at launch.
@MainActor
final class TimeCalendarModel: ObservableObject {
  enum Access { case unknown, granted, denied }

  /// Midnight on the first of the shown month.
  @Published private(set) var month = MonthCalendar.monthStart(Date())
  /// Midnight starting the picked day.
  @Published private(set) var selected = Calendar.current.startOfDay(for: Date())
  /// The events in the shown month's six-week grid (and on the picked day).
  @Published private(set) var events: [CalendarEvent] = []
  @Published private(set) var access: Access =
    EKEventStore.authorizationStatus(for: .event) == .fullAccess ? .granted : .unknown
  /// The event row under the pointer.
  @Published var hoveredEvent: String?
  /// The day list's natural height, which sets its scroll view's.
  @Published var listHeight: CGFloat = 0
  /// Calendar names left out (`time.hiddenCalendars`).
  var hidden: [String] = [] {
    didSet { if hidden != oldValue { fetch() } }
  }

  private let store = EKEventStore()
  private let queue = DispatchQueue(label: "com.ianneub.menu-widgets.calendar")
  private var observer: NSObjectProtocol?
  /// Bumped per fetch, so a slow read for a month already left is dropped.
  private var generation = 0
  private var isOpen = false

  init() {
    observer = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: store, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { if self?.isOpen == true { self?.fetch() } }
    }
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    generation += 1
  }

  /// Each time the popup opens it starts over on today, in today's month.
  func popupWillOpen() {
    isOpen = true
    let today = Calendar.current.startOfDay(for: Date())
    selected = today
    show(month: today)
    requestAccessIfNeeded()
  }

  func popupDidClose() {
    isOpen = false
    hoveredEvent = nil
  }

  /// Opens `event` in Calendar.
  func open(_ event: CalendarEvent) {
    guard let url = MonthCalendar.calendarAppURL(event) else { return }
    NSWorkspace.shared.open(url)
  }

  func step(month delta: Int) { show(month: MonthCalendar.shift(month, by: delta)) }

  func goToToday() {
    selected = Calendar.current.startOfDay(for: Date())
    show(month: selected)
  }

  /// Picks a day; one from the month before or after turns the page to it.
  func select(_ day: Date) {
    selected = Calendar.current.startOfDay(for: day)
    if MonthCalendar.monthStart(day) != month { show(month: day) }
  }

  private func show(month date: Date) {
    let m = MonthCalendar.monthStart(date)
    if m != month {
      month = m
      events = []
    }
    fetch()
  }

  /// MENU_WIDGETS_CALENDAR_DEMO=1: made-up events around today in place of
  /// EventKit, for checking the layout without calendar access.
  private static let demo = ProcessInfo.processInfo.environment["MENU_WIDGETS_CALENDAR_DEMO"] == "1"

  private func requestAccessIfNeeded() {
    if Self.demo {
      if access != .granted { access = .granted; fetch() }
      return
    }
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      if access != .granted { access = .granted; fetch() }
    case .notDetermined:
      store.requestFullAccessToEvents { granted, error in
        if let error { NSLog("Calendar access request failed: \(error)") }
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self.access = granted ? .granted : .denied
            if granted { self.fetch() }
          }
        }
      }
    default:
      access = .denied
    }
  }

  private func fetch() {
    guard access == .granted else { return }
    if Self.demo { events = Self.demoEvents(); return }
    generation += 1
    let gen = generation
    // The picked day's list stays filled while paging through other months.
    let grid = MonthCalendar.gridRange(month)
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: selected)!
    let range = (start: min(grid.start, selected), end: max(grid.end, dayEnd))
    let hidden = Set(hidden.map { $0.lowercased() })
    let store = store
    queue.async {
      let calendars = store.calendars(for: .event).filter { !hidden.contains($0.title.lowercased()) }
      var found: [CalendarEvent] = []
      if !calendars.isEmpty {
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        found = store.events(matching: predicate).map(Self.event)
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard gen == self.generation else { return }
          self.events = found
        }
      }
    }
  }

  private static func demoEvents() -> [CalendarEvent] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
      cal.date(byAdding: .minute, value: h * 60 + m, to: cal.date(byAdding: .day, value: day, to: today)!)!
    }
    let home = ("home", "Home", [0.20, 0.55, 0.95]), work = ("work", "Work", [0.95, 0.55, 0.15])
    let family = ("family", "Family", [0.35, 0.75, 0.30]), birthdays = ("bday", "Birthdays", [0.60, 0.45, 0.85])
    let list: [(String, (String, String, [Double]), Date, Date, Bool, String)] = [
      ("Columbus Day", family, at(1, 0), at(1, 23, 59), true, ""),
      ("Sam's birthday", birthdays, at(0, 0), at(0, 23, 59), true, ""),
      ("Beach trip", family, at(-1, 8), at(1, 18), false, ""),
      ("Late flight", home, at(-1, 22), at(0, 1, 30), false, ""),
      ("Breakfast with Alex", home, at(0, 8), at(0, 9), false, "Cafe Intermezzo"),
      ("Standup", work, at(0, 9, 30), at(0, 9, 45), false, ""),
      ("Design review", work, at(0, 11, 30), at(0, 13), false, "Zoom"),
      ("Soccer practice", family, at(0, 17), at(0, 18, 30), false, "Piedmont Park"),
      ("Dinner", home, at(0, 19), at(0, 20, 30), false, ""),
      ("Dentist", home, at(3, 10), at(3, 11), false, ""),
      ("Planning", work, at(4, 14), at(4, 15), false, ""),
      ("Party", family, at(6, 18), at(6, 22), false, ""),
      ("Review", work, at(-5, 9), at(-5, 10), false, ""),
    ]
    return list.enumerated().map { i, e in
      CalendarEvent(id: "demo\(i)", title: e.0, start: e.2, end: e.3, allDay: e.4,
                    calendarID: e.1.0, calendarTitle: e.1.1, rgb: e.1.2, location: e.5)
    }
  }

  private nonisolated static func event(_ e: EKEvent) -> CalendarEvent {
    let color = e.calendar.flatMap { NSColor(cgColor: $0.cgColor)?.usingColorSpace(.sRGB) }
    // A repeating event's occurrences share one identifier; the start tells them apart.
    let id = (e.eventIdentifier ?? e.calendarItemIdentifier) + "@\(e.startDate.timeIntervalSince1970)"
    return CalendarEvent(
      id: id, title: e.title?.isEmpty == false ? e.title! : "New Event",
      start: e.startDate, end: e.endDate ?? e.startDate, allDay: e.isAllDay,
      calendarID: e.calendar?.calendarIdentifier ?? "", calendarTitle: e.calendar?.title ?? "",
      rgb: color.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } ?? [0.5, 0.5, 0.5],
      location: e.location?.split(separator: "\n").first.map(String.init) ?? "",
      itemID: e.calendarItemIdentifier, recurring: e.hasRecurrenceRules || e.isDetached)
  }
}
