import Foundation
import Testing
@testable import WidgetsCore

// Ported from ianneub.reminders/Model.test.js and reminders-bridge's CLI tests.

private let cal = Calendar.current

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
  cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private let NOW = at(2026, 9, 25, 12, 0)
private let HOUR: TimeInterval = 3600

private func item(_ id: String = "A", title: String = "Call mom", due: Date? = at(2026, 9, 25, 17, 0), hasTime: Bool = true,
                  notes: String = "", url: String = "", rule: RepeatRule? = nil) -> ReminderItem {
  ReminderItem(id: id, title: title, list: "Reminders", notes: notes, url: url, due: due, hasTime: hasTime, rule: rule)
}

private func entry(_ i: ReminderItem, now: Date = NOW) -> AgendaEntry {
  Agenda.entries([i], now: now)[0]
}

// MARK: - agenda

@Test func remindersBuckets() {
  #expect(entry(item(due: at(2026, 9, 24, 17))).bucket == .overdue)
  #expect(entry(item(due: at(2026, 9, 20), hasTime: false)).bucket == .overdue)
  #expect(entry(item(due: at(2026, 9, 25, 8))).bucket == .today)
  #expect(entry(item(due: at(2026, 9, 25), hasTime: false)).bucket == .today)
  #expect(entry(item(due: at(2026, 9, 26, 9, 30))).bucket == .tomorrow)
  #expect(Agenda.entries([item(due: at(2026, 9, 27, 0, 0)), item(due: nil)], now: NOW).isEmpty)
}

@Test func remindersLabels() {
  #expect(entry(item(due: at(2026, 9, 25, 17))).label == "5:00 PM")
  #expect(entry(item(due: at(2026, 9, 26, 9, 30))).label == "9:30 AM")
  #expect(entry(item(due: at(2026, 9, 23, 12, 5))).label == "Wed Sep 23, 12:05 PM")
  #expect(entry(item(due: at(2026, 9, 20), hasTime: false)).label == "Sun Sep 20")
  #expect(entry(item(due: at(2026, 9, 25), hasTime: false)).label == "")
}

@Test func remindersAlertTime() {
  #expect(entry(item(due: at(2026, 9, 25, 17))).alertDate == at(2026, 9, 25, 17))
  // Apple alerts date-only reminders at 9:00.
  #expect(entry(item(due: at(2026, 9, 25), hasTime: false)).alertDate == at(2026, 9, 25, 9))
}

@Test func remindersOrder() {
  let rows: [(Date, Bool, String)] = [
    (at(2026, 9, 26, 8), true, "tomorrow timed"),
    (at(2026, 9, 25), false, "today all day"),
    (at(2026, 9, 25, 17), true, "today 5pm"),
    (at(2026, 9, 25, 9), true, "today 9am"),
    (at(2026, 9, 20), false, "overdue all day"),
    (at(2026, 9, 20, 10), true, "overdue timed"),
  ]
  let items = rows.enumerated().map { i, r in item("\(i)", title: r.2, due: r.0, hasTime: r.1) }
  #expect(Agenda.entries(items, now: NOW).map(\.item.title) == [
    "overdue all day", "overdue timed", "today 9am", "today 5pm", "today all day", "tomorrow timed",
  ])
}

@Test func remindersLate() {
  #expect(Agenda.isLate(entry(item(due: at(2026, 9, 20, 10))), now: NOW))
  #expect(Agenda.isLate(entry(item(due: NOW.addingTimeInterval(-60))), now: NOW))
  #expect(!Agenda.isLate(entry(item(due: NOW.addingTimeInterval(HOUR))), now: NOW))
  #expect(!Agenda.isLate(entry(item(due: at(2026, 9, 26, 8))), now: NOW))
}

@Test func remindersSummaryAndTooltip() {
  let items = [
    item("1", due: at(2026, 9, 20, 10)),
    item("2", due: NOW.addingTimeInterval(-HOUR)),
    item("3", due: NOW.addingTimeInterval(HOUR)),
    item("4", due: at(2026, 9, 26, 8)),
    item("5", due: at(2026, 9, 25, 18)),
  ]
  let s = Agenda.summary(Agenda.entries(items, now: NOW), done: ["5"], now: NOW)
  #expect(s == Agenda.Summary(overdue: 1, today: 2, tomorrow: 1, late: 2))
  #expect(s.due == 3 && s.upcoming == 1)
  #expect(Agenda.tooltip(s) == "Reminders: 2 past due · 1 left today · 1 tomorrow")
  #expect(Agenda.tooltip(Agenda.Summary()) == "Reminders: nothing left today")
  #expect(Agenda.barCount(s) == 2)
  #expect(Agenda.barCount(Agenda.Summary(today: 3)) == 3)
  #expect(Agenda.dueParts(Agenda.Summary(tomorrow: 1)) == [])
}

@Test func remindersWhenTextPrefill() {
  #expect(Agenda.whenText(entry(item(due: at(2026, 9, 25, 17)))) == "today 5:00pm")
  #expect(Agenda.whenText(entry(item(due: at(2026, 9, 26, 0, 30)))) == "tomorrow 12:30am")
  #expect(Agenda.whenText(entry(item(due: at(2026, 9, 25, 12, 5)))) == "today 12:05pm")
  #expect(Agenda.whenText(entry(item(due: at(2026, 9, 23, 9)))) == "2026-09-23 9:00am")
  #expect(Agenda.whenText(entry(item(due: at(2026, 9, 26), hasTime: false))) == "tomorrow")
  #expect(Agenda.whenText(entry(item(due: at(2026, 9, 20), hasTime: false))) == "2026-09-20")
}

@Test func remindersEditSendsOnlyWhatChanged() {
  let e = entry(item(notes: "a\nb", url: "https://x.io"))
  func edit(title: String = "Call mom", when: String = "today 5:00pm", notes: String = "a\nb",
            url: String = "https://x.io", rep: RepeatState? = nil) -> Agenda.Edit {
    Agenda.edit(for: e, title: title, when: when, notes: notes, url: url, repeat: rep)
  }
  #expect(edit().isEmpty)
  #expect(edit(title: "Call dad") == Agenda.Edit(title: "Call dad"))
  #expect(edit(when: "sep 30 @ 3pm") == Agenda.Edit(due: "sep 30 @ 3pm"))
  #expect(edit(when: "") == Agenda.Edit(due: ""))
  #expect(edit(notes: "a\nc\n\n", url: "") == Agenda.Edit(notes: "a\nc", url: ""))
  #expect(edit(rep: Agenda.repeatState(e)).isEmpty)
  #expect(edit(rep: Agenda.repeatState(e).applying(preset: "week")).rule == .some(RepeatRule(frequency: "weekly")))
  // No date: the repeat isn't sent (clearing the date stops it anyway).
  #expect(edit(when: "", rep: Agenda.repeatState(e).applying(preset: "week")) == Agenda.Edit(due: ""))
}

@Test func remindersRepeatStopIsSent() {
  let e = entry(item(rule: RepeatRule(frequency: "weekly")))
  let stop = Agenda.repeatState(e).applying(preset: "never")
  let out = Agenda.edit(for: e, title: "Call mom", when: "today 5:00pm", notes: "", url: "", repeat: stop)
  #expect(out == Agenda.Edit(rule: .some(nil)))
}

@Test func remindersCleanNotes() {
  #expect(Agenda.cleanNotes("\n\n  first  \n\nsecond \t\n\n") == "  first\n\nsecond")
  #expect(Agenda.cleanNotes("   ") == "")
  #expect(Agenda.cleanNotes("") == "")
}

@Test func remindersMisc() {
  #expect(Agenda.defaultList([("A", false), ("B", true)]) == "B")
  #expect(Agenda.defaultList([("A", false)]) == "A")
  #expect(Agenda.defaultList([]) == "Reminders")
  #expect(Agenda.priorityMark("high") == "!!! ")
  #expect(Agenda.priorityMark("none") == "")
}

// MARK: - links

@Test func remindersLinks() {
  func links(_ s: String) -> [String] { Links.segments(s).compactMap(\.url) }
  #expect(Links.segments("").isEmpty)
  #expect(links("see https://x.com/a?b=1&c=2.") == ["https://x.com/a?b=1&c=2"])
  #expect(links("(www.example.com)") == ["https://www.example.com"])
  #expect(links("http://en.wikipedia.org/wiki/Foo_(bar), ok") == ["http://en.wikipedia.org/wiki/Foo_(bar)"])
  #expect(links("two: http://a.io http://b.io/") == ["http://a.io", "http://b.io/"])
  #expect(Links.segments("see https://x.com/a.").map(\.text) == ["see ", "https://x.com/a", "."])
  #expect(Links.label("https://www.st.com/en/nucleo.html") == "st.com/en/nucleo.html")
  #expect(Links.label("http://example.com/") == "example.com")
  #expect(Links.openable("https://a.io"))
  #expect(Links.openable("message://%3cid%3e"))
  #expect(!Links.openable("--help"))
  #expect(!Links.openable(""))
  #expect(Links.firstLink(item(notes: "https://b.io", url: "https://a.io")) == "https://a.io")
  #expect(Links.firstLink(item(notes: "see www.b.io/x_(y).")) == "https://www.b.io/x_(y)")
  #expect(Links.firstLink(item(notes: "no links")) == "")
  let a = Links.attributed("go to www.a.io now")
  #expect(String(a.characters) == "go to www.a.io now")
  #expect(a.runs.compactMap(\.link).map(\.absoluteString) == ["https://www.a.io"])
}

// MARK: - repeat rules

@Test func remindersRepeatPhrases() {
  let cases: [(RepeatRule, String)] = [
    (RepeatRule(frequency: "daily"), "daily"),
    (RepeatRule(frequency: "daily", interval: 3), "every 3 days"),
    (RepeatRule(frequency: "weekly", daysOfWeek: ["mon", "tue", "wed", "thu", "fri"]), "weekdays"),
    (RepeatRule(frequency: "weekly", daysOfWeek: ["sat", "sun"]), "weekends"),
    (RepeatRule(frequency: "weekly", interval: 2), "every 2 weeks"),
    (RepeatRule(frequency: "weekly", interval: 2, daysOfWeek: ["mon", "wed"]), "every 2 weeks on Mon, Wed"),
    (RepeatRule(frequency: "weekly", daysOfWeek: ["wed", "mon"]), "weekly on Mon, Wed"),
    (RepeatRule(frequency: "monthly", daysOfMonth: [1, 15]), "monthly on the 1st, 15th"),
    (RepeatRule(frequency: "monthly", daysOfMonth: [-1]), "monthly on the last day"),
    (RepeatRule(frequency: "monthly", daysOfWeek: ["-1fri"]), "monthly on the last Fri"),
    (RepeatRule(frequency: "monthly", daysOfWeek: ["mon", "tue", "wed", "thu", "fri"], setPositions: [1]),
     "monthly on the first weekday"),
    (RepeatRule(frequency: "yearly", daysOfWeek: ["4thu"], monthsOfYear: [11]), "yearly in Nov on the fourth Thu"),
    (RepeatRule(frequency: "weekly", count: 10), "weekly, 10 times"),
    (RepeatRule(frequency: "daily", until: "2026-12-31"), "daily until Dec 31, 2026"),
    (RepeatRule(frequency: "monthly", daysOfWeek: ["-2fri"]), "monthly on the -2 Fri (custom)"),
    (RepeatRule(frequency: "monthly", daysOfWeek: ["tue"], setPositions: [2]), "monthly on the second Tue"),
    (RepeatRule(frequency: "monthly", interval: 6, daysOfMonth: [28, 29, 30, 31], setPositions: [-1]),
     "every 6 months on the last day"),
  ]
  for (rule, phrase) in cases { #expect(rule.phrase == phrase) }
  #expect(RepeatRule(frequency: "yearly", custom: true).phrase.hasSuffix("(custom)"))
}

private let monDefaults = RepeatState.Defaults(weekday: "mon", day: 12, month: 10)

@Test func remindersRepeatStateReadsRules() {
  func st(_ r: RepeatRule?) -> RepeatState { RepeatState(rule: r, defaults: monDefaults) }
  #expect(st(nil).freq == "never")
  var s = st(RepeatRule(frequency: "weekly", interval: 2, daysOfWeek: ["wed", "mon"]))
  #expect(s.freq == "weekly" && s.interval == 2 && s.days == ["mon", "wed"] && !s.custom)
  s = st(RepeatRule(frequency: "monthly", daysOfWeek: ["tue"], setPositions: [2]))
  #expect(s.monthMode == "onthe" && s.ordinal == 2 && s.ordDay == "tue" && !s.custom)
  s = st(RepeatRule(frequency: "monthly", daysOfWeek: ["-1fri"]))
  #expect(s.monthMode == "onthe" && s.ordinal == -1 && s.ordDay == "fri")
  s = st(RepeatRule(frequency: "monthly", daysOfWeek: ["mon", "tue", "wed", "thu", "fri"], setPositions: [-1]))
  #expect(s.ordinal == -1 && s.ordDay == "weekday" && !s.custom)
  s = st(RepeatRule(frequency: "monthly", interval: 6, daysOfMonth: [28, 29, 30, 31], setPositions: [-1]))
  #expect(s.monthMode == "each" && s.monthDays == [-1] && !s.custom)
  s = st(RepeatRule(frequency: "yearly", interval: 5, daysOfWeek: ["mon"], monthsOfYear: [2], setPositions: [1]))
  #expect(s.months == [2] && s.yearOnThe && s.ordinal == 1 && s.ordDay == "mon")
  s = st(RepeatRule(frequency: "daily", until: "2026-12-31"))
  #expect(s.end == "until" && s.until == "2026-12-31")
  #expect(st(RepeatRule(frequency: "monthly", daysOfWeek: ["mon", "wed"], setPositions: [1, 2])).custom)
  #expect(st(RepeatRule(frequency: "yearly", custom: true)).custom)
}

@Test func remindersUntouchedRepeatIsNotSent() {
  let rules: [RepeatRule?] = [
    nil,
    RepeatRule(frequency: "weekly"),
    RepeatRule(frequency: "monthly", daysOfWeek: ["tue"], setPositions: [2]),
    RepeatRule(frequency: "monthly", interval: 6, daysOfMonth: [28, 29, 30, 31], setPositions: [-1]),
    RepeatRule(frequency: "monthly", daysOfWeek: ["mon", "wed"], setPositions: [1, 2]),
    RepeatRule(frequency: "yearly", daysOfWeek: ["4thu"], monthsOfYear: [11], count: 3),
  ]
  for rule in rules {
    let e = entry(item(due: at(2026, 10, 12, 8), rule: rule), now: at(2026, 10, 12, 7))
    let s = Agenda.repeatState(e)
    #expect(!s.differs(from: Agenda.repeatState(e)))
    #expect(Agenda.edit(for: e, title: "Call mom", when: Agenda.whenText(e), notes: "", url: "", repeat: s).isEmpty)
  }
}

@Test func remindersPresets() {
  let s = RepeatState(rule: nil, defaults: monDefaults)
  #expect(s.presetKey == "never")
  for key in ["day", "weekday", "weekend", "week", "2weeks", "month", "3months", "6months", "year"] {
    #expect(s.applying(preset: key).presetKey == key)
  }
  var weekly = s.applying(preset: "week")
  weekly.days = ["mon", "thu"]
  #expect(weekly.presetKey == "custom")
  var ending = s.applying(preset: "week")
  ending.end = "until"; ending.until = "dec 31"
  #expect(ending.presetKey == "week")
  #expect(RepeatState.presetLabel("2weeks") == "Every 2 Weeks")
}

@Test func remindersEditorStateBecomesRule() {
  let s = RepeatState(rule: nil, defaults: monDefaults).applying(preset: "month")
  var m = s
  m.monthMode = "onthe"; m.ordinal = -1; m.ordDay = "weekday"
  #expect(m.rule == RepeatRule(frequency: "monthly", daysOfWeek: ["mon", "tue", "wed", "thu", "fri"], setPositions: [-1]))
  m = s
  m.monthDays = [15, -1, 1]
  #expect(m.rule == RepeatRule(frequency: "monthly", daysOfMonth: [1, 15, -1]))
  var y = s.applying(preset: "year")
  y.months = [11]; y.yearOnThe = true; y.ordinal = 4; y.ordDay = "thu"; y.end = "count"; y.count = 3
  #expect(y.rule == RepeatRule(frequency: "yearly", daysOfWeek: ["thu"], monthsOfYear: [11], setPositions: [4], count: 3))
  #expect(s.applying(preset: "never").rule == nil)
  // Changing frequency in Custom starts its lists fresh.
  var w = s.applying(preset: "weekday")
  w = w.withFrequency("monthly")
  #expect(w.rule == RepeatRule(frequency: "monthly"))
}

@Test func remindersEditorShownLists() {
  let s = RepeatState(rule: nil, defaults: monDefaults)
  #expect(s.shownDays == ["mon"])
  #expect(s.shownMonthDays == [12])
  #expect(s.shownMonths == [10])
  #expect(RepeatState.toggled(["mon"], "mon") == ["mon"])
  #expect(RepeatState.toggled(["mon"], "wed") == ["mon", "wed"])
  #expect(RepeatState.toggled(["mon", "wed"], "mon") == ["wed"])
  #expect(RepeatState.unitLabel("weekly", 1) == "week")
  #expect(RepeatState.unitLabel("monthly", 3) == "months")
  #expect(RepeatState.Defaults(due: at(2026, 10, 12, 8)) == monDefaults)
}

// MARK: - when parsing

@Test func remindersNormalize() {
  let cases: [(String, String)] = [
    ("sep 23 @ 3pm", "sep 23 3pm"),
    ("3pm on sep 23", "3pm sep 23"),
    ("fri at 9am", "fri 9am"),
    ("Oct 1, 2026 at 9:30am", "oct 1 2026 9:30am"),
    ("in 2 hours", "2 hours"),
    ("23rd of september @ 10am", "september 23 10am"),
    ("sep 23rd", "sep 23"),
    ("1st oct", "oct 1"),
    ("23 sep 3pm", "sep 23 3pm"),
    ("3 p.m.", "3 pm"),
    ("3p", "3pm"),
    ("9A", "9am"),
    ("noon", "12:00pm"),
    ("tomorrow at midnight", "tomorrow 12:00am"),
    ("at 3", "3:00pm"),
    ("at 7", "7:00pm"),
    ("at 8", "8:00am"),
    ("at 11:45", "11:45am"),
    ("at 12", "12:00pm"),
    ("at 0:30", "0:30"),
    ("@ 15", "15:00"),
    ("@ 15:00 sep 23", "15:00 sep 23"),
    ("sep 23 at 3:30 PM", "sep 23 3:30 pm"),
    ("55m", "55 minutes"),
    ("1h22m", "1 hours 22 minutes"),
    ("1h 22m", "1 hours 22 minutes"),
    ("in 2 hrs 5 mins", "2 hours 5 minutes"),
    ("3d", "3 days"),
    ("tomorrow 7:15am", "tomorrow 7:15am"),
    ("next fri 9am", "next fri 9am"),
    ("2026-09-23 12:05pm", "2026-09-23 12:05pm"),
    ("  Tomorrow   9AM ", "tomorrow 9am"),
  ]
  for (typed, expected) in cases { #expect(WhenParser.normalize(typed) == expected, "\(typed)") }
}

private func parsed(_ text: String) throws -> String {
  let w = try WhenParser.parse(text)
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.dateFormat = w.hasTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
  return f.string(from: w.date)
}

@Test func remindersParseAbsolute() throws {
  let cases: [(String, String)] = [
    ("2026-10-01 9:30", "2026-10-01T09:30"),
    ("2026-10-01", "2026-10-01"),
    ("Oct 1, 2026 at 9:30am", "2026-10-01T09:30"),
    ("sep 23 2026 at 3:30 PM", "2026-09-23T15:30"),
    ("23rd sep 2026 @ 3", "2026-09-23T15:00"),
    ("1 oct 2026 @ 9", "2026-10-01T09:00"),
    ("2026-09-23 12:05pm", "2026-09-23T12:05"),
    ("2026-09-23 9:30am", "2026-09-23T09:30"),
    ("sep 23 2026 12:15am", "2026-09-23T00:15"),
    ("9/23/2026 noon", "2026-09-23T12:00"),
  ]
  for (typed, expected) in cases { #expect(try parsed(typed) == expected, "\(typed)") }
}

@Test func remindersParseRelative() throws {
  let today = cal.startOfDay(for: Date())
  let iso = DateFormatter()
  iso.locale = Locale(identifier: "en_US_POSIX")
  iso.dateFormat = "yyyy-MM-dd"
  let tomorrow = iso.string(from: cal.date(byAdding: .day, value: 1, to: today)!)
  #expect(try parsed("tomorrow") == tomorrow)
  #expect(try parsed("tomorrow at noon") == tomorrow + "T12:00")
  #expect(try parsed("at 9 tomorrow") == tomorrow + "T09:00")
  #expect(try parsed("tomorrow 12:30am") == tomorrow + "T00:30")
  #expect(try parsed("today 5:00pm") == iso.string(from: today) + "T17:00")
  for text in ["sep 23", "next fri", "23rd sep", "fri"] {
    #expect(try !WhenParser.parse(text).hasTime, "\(text)")
  }
  for text in ["midnight", "in 2 hours", "in 30 min", "now", "3 p.m.", "3p", "at 9", "15:30", "5pm"] {
    #expect(try WhenParser.parse(text).hasTime, "\(text)")
  }
  let now = Date()
  for (text, minutes) in [("55m", 55.0), ("1h22m", 82), ("1h 22m", 82), ("in 2h", 120)] {
    let got = try WhenParser.parse(text, now: now)
    #expect(got.hasTime && got.date == now.addingTimeInterval(minutes * 60), "\(text)")
  }
  let days = try WhenParser.parse("3d", now: now)
  #expect(!days.hasTime && days.date == cal.startOfDay(for: now.addingTimeInterval(3 * 86_400)))
}

@Test func remindersParseNonsense() {
  for text in ["whenever", "at 99", "sep 32", "", "  "] {
    #expect(throws: WhenParser.ParseError.self, "\(text)") { try WhenParser.parse(text) }
  }
}
