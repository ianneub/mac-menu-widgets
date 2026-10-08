import Foundation

/// The repeat editor's state, laid out like Reminders.app on the Mac: a
/// Repeat menu of presets plus Custom, End Repeat, and Custom's frequency /
/// every N / days / months / "on the". Lists left empty mean "the due
/// date's", the way the rule itself reads, and the editor shows that day
/// selected. Ported from the Omarchy widget's Model.js.
public struct RepeatState: Equatable, Sendable {
  /// The due date's weekday, day of month and month: what an empty list means.
  public struct Defaults: Equatable, Sendable {
    public var weekday: String
    public var day: Int
    public var month: Int
    public init(weekday: String, day: Int, month: Int) { self.weekday = weekday; self.day = day; self.month = month }

    public init(due: Date?, calendar: Calendar = .current) {
      let d = due ?? Date()
      self.init(weekday: RepeatState.week[calendar.component(.weekday, from: d) - 1],
                day: calendar.component(.day, from: d), month: calendar.component(.month, from: d))
    }
  }

  /// "never", "daily", "weekly", "monthly" or "yearly".
  public var freq = "never"
  public var interval = 1
  public var days: [String] = []
  /// Monthly: "each" (days of the month) or "onthe" (On the first Monday).
  public var monthMode = "each"
  public var monthDays: [Int] = []
  public var ordinal = 1
  public var ordDay: String
  public var months: [Int] = []
  public var yearOnThe = false
  /// "never", "until" or "count".
  public var end = "never"
  public var until = ""
  public var count = 0
  /// The rule has parts the editor can't show.
  public var custom = false
  public var defaults: Defaults

  public init(rule: RepeatRule?, defaults: Defaults) {
    self.defaults = defaults
    ordDay = defaults.weekday
    guard let rule else { return }
    let raw = rule.daysOfWeek
    var pos = rule.setPositions, md = rule.daysOfMonth
    let mo = rule.monthsOfYear
    if pos == [-1] && raw.isEmpty && Set(md) == [28, 29, 30, 31] { md = [-1]; pos = [] }
    let on = Self.onThe(raw, pos)
    let known = Self.frequencies.contains { $0.key == rule.frequency }
    var custom = rule.custom || !known
    freq = known ? rule.frequency : "daily"
    interval = max(1, rule.interval)
    switch freq {
    case "daily":
      custom = custom || !raw.isEmpty || !md.isEmpty || !mo.isEmpty
    case "weekly":
      custom = custom || !pos.isEmpty || !md.isEmpty || !mo.isEmpty || raw.contains { !Self.isPlain($0) }
      days = Self.sortedDays(raw)
    case "monthly":
      custom = custom || !mo.isEmpty
      if let on { monthMode = "onthe"; ordinal = on.ordinal; ordDay = on.ordDay }
      else if !raw.isEmpty || !pos.isEmpty { custom = true }
      if !md.isEmpty && raw.isEmpty && pos.isEmpty { monthDays = Self.sortedNumbers(md) }
      custom = custom || md.contains { $0 < -1 } || (on != nil && !md.isEmpty)
    case "yearly":
      months = mo.sorted()
      if let on { yearOnThe = true; ordinal = on.ordinal; ordDay = on.ordDay }
      else if !raw.isEmpty || !pos.isEmpty { custom = true }
      custom = custom || !md.isEmpty
    default: break
    }
    if let until = rule.until, !until.isEmpty { end = "until"; self.until = until }
    else if let count = rule.count, count > 0 { end = "count"; self.count = count }
    self.custom = custom
  }

  // MARK: menus

  public struct Option: Hashable, Sendable {
    public let key: String
    public let label: String
    public let separator: Bool
    init(_ key: String, _ label: String) { self.key = key; self.label = label; separator = false }
    static let sep = Option(separator: true)
    private init(separator: Bool) { key = ""; label = ""; self.separator = separator }
  }

  public static let week = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]  // US Mac order, for the editor
  public static let dayNames = ["sun": "Sunday", "mon": "Monday", "tue": "Tuesday", "wed": "Wednesday",
                                "thu": "Thursday", "fri": "Friday", "sat": "Saturday",
                                "day": "day", "weekday": "weekday", "weekend": "weekend day"]
  public static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                                  "September", "October", "November", "December"]
  public static let ordinals: [(key: Int, label: String)] =
    [(1, "first"), (2, "second"), (3, "third"), (4, "fourth"), (5, "fifth"), (-1, "last")]
  public static let frequencies: [(key: String, label: String, unit: String)] =
    [("daily", "Daily", "day"), ("weekly", "Weekly", "week"), ("monthly", "Monthly", "month"), ("yearly", "Yearly", "year")]

  /// Reminders.app's Repeat menu; `nil` rule is Custom…, separators split groups.
  public static let presets: [(option: Option, rule: RepeatRule??)] = [
    (Option("never", "Never"), .some(nil)),
    (.sep, nil),
    (Option("day", "Every Day"), RepeatRule(frequency: "daily")),
    (Option("weekday", "Every Weekday"), RepeatRule(frequency: "weekly", daysOfWeek: RepeatRule.weekdays)),
    (Option("weekend", "Every Weekend Day"), RepeatRule(frequency: "weekly", daysOfWeek: RepeatRule.weekend)),
    (.sep, nil),
    (Option("week", "Every Week"), RepeatRule(frequency: "weekly")),
    (Option("2weeks", "Every 2 Weeks"), RepeatRule(frequency: "weekly", interval: 2)),
    (.sep, nil),
    (Option("month", "Every Month"), RepeatRule(frequency: "monthly")),
    (Option("3months", "Every 3 Months"), RepeatRule(frequency: "monthly", interval: 3)),
    (Option("6months", "Every 6 Months"), RepeatRule(frequency: "monthly", interval: 6)),
    (.sep, nil),
    (Option("year", "Every Year"), RepeatRule(frequency: "yearly")),
    (.sep, nil),
    (Option("custom", "Custom…"), nil),
  ]

  /// The "On the [first] [Monday]" day menu.
  public static let onTheDays: [Option] = week.map { Option($0, dayNames[$0]!) }
    + [.sep, Option("day", "day"), Option("weekday", "weekday"), Option("weekend", "weekend day")]

  public static func presetLabel(_ key: String) -> String {
    presets.first { $0.option.key == key }?.option.label ?? "Custom"
  }

  /// End Repeat's menu: Never and On Date as on the Mac, plus a count when
  /// the rule came with one (Reminders.app doesn't offer it, other apps do).
  public var endOptions: [Option] {
    var o = [Option("never", "Never"), Option("until", "On Date")]
    if count > 0 { o.append(Option("count", "After a Number of Times")) }
    return o
  }

  public static func unitLabel(_ freq: String, _ n: Int) -> String {
    let unit = frequencies.first { $0.key == freq }?.unit ?? "time"
    return n == 1 ? unit : unit + "s"
  }

  // MARK: reading and writing rules

  static func isPlain(_ d: String) -> Bool { !d.isEmpty && d.allSatisfy { $0.isLetter } }

  static func sortedDays(_ list: [String]) -> [String] { RepeatRule.ruleDays.filter { list.contains($0) } }

  /// -1 (the last day) after the numbered days.
  static func sortedNumbers(_ list: [Int]) -> [Int] { list.sorted { ($0 < 0 ? 99 : $0) < ($1 < 0 ? 99 : $1) } }

  /// A rule's "on the first Monday" part, whichever way it's written: "1mon",
  /// or Reminders.app's own days + set position ("tue" + [2], mon..fri + [-1]).
  static func onThe(_ raw: [String], _ positions: [Int]) -> (ordinal: Int, ordDay: String)? {
    let plain = raw.filter(isPlain)
    let numbered = raw.filter { !isPlain($0) }
    var found: (ordinal: Int, ordDay: String)?
    if numbered.count == 1 && plain.isEmpty && positions.isEmpty {
      let d = numbered[0]
      let digits = d.prefix { "-+0123456789".contains($0) }
      if let n = Int(digits) { found = (n, String(d.dropFirst(digits.count))) }
    } else if positions.count == 1 && numbered.isEmpty && !plain.isEmpty {
      let set = Set(plain)
      let kind: String? = plain.count == 1 ? plain[0] : set == Set(RepeatRule.ruleDays) ? "day"
        : set == Set(RepeatRule.weekdays) ? "weekday" : set == Set(RepeatRule.weekend) ? "weekend" : nil
      if let kind { found = (positions[0], kind) }
    }
    if let f = found, !ordinals.contains(where: { $0.key == f.ordinal }) { return nil }
    return found
  }

  /// The lists as the editor shows them: empty means the due date's.
  public var shownDays: [String] { days.isEmpty ? [defaults.weekday] : days }
  public var shownMonthDays: [Int] { monthDays.isEmpty ? [defaults.day] : monthDays }
  public var shownMonths: [Int] { months.isEmpty ? [defaults.month] : months }

  private func onTheRule(_ rule: inout RepeatRule) {
    switch ordDay {
    case "day": rule.daysOfWeek = RepeatRule.ruleDays
    case "weekday": rule.daysOfWeek = RepeatRule.weekdays
    case "weekend": rule.daysOfWeek = RepeatRule.weekend
    default: rule.daysOfWeek = [ordDay]
    }
    rule.setPositions = [ordinal]
  }

  /// The editor's state as a rule; nil for Never.
  public var rule: RepeatRule? {
    if freq == "never" { return nil }
    var rule = RepeatRule(frequency: freq, interval: max(1, interval))
    if freq == "weekly" && !days.isEmpty { rule.daysOfWeek = Self.sortedDays(days) }
    if freq == "monthly" {
      if monthMode == "onthe" { onTheRule(&rule) }
      else if !monthDays.isEmpty { rule.daysOfMonth = Self.sortedNumbers(monthDays) }
    }
    if freq == "yearly" {
      if !months.isEmpty { rule.monthsOfYear = months.sorted() }
      if yearOnThe { onTheRule(&rule) }
    }
    let typed = until.trimmingCharacters(in: .whitespaces)
    if end == "until" && !typed.isEmpty { rule.until = typed }
    else if end == "count" && count > 0 { rule.count = count }
    return rule
  }

  /// Which Repeat menu item the state is ("custom" when none fits). The end
  /// doesn't count: Every Week ending Dec 31 is still Every Week.
  public var presetKey: String {
    if freq == "never" { return "never" }
    var bare = self
    bare.end = "never"
    let mine = bare.rule?.normalized
    for p in Self.presets {
      if case .some(.some(let r)) = p.rule, r.normalized == mine { return p.option.key }
    }
    return "custom"
  }

  /// Picking a Repeat menu item; the end and the due-date defaults carry over.
  public func applying(preset key: String) -> RepeatState {
    guard let p = Self.presets.first(where: { $0.option.key == key }), case .some(let rule) = p.rule else { return self }
    var next = RepeatState(rule: rule, defaults: defaults)
    next.end = end; next.until = until; next.count = count
    return next
  }

  /// Switching frequency in Custom starts that frequency's lists fresh.
  public func withFrequency(_ key: String) -> RepeatState {
    guard key != freq else { return self }
    var next = self
    next.freq = key
    next.days = []; next.monthDays = []; next.months = []; next.monthMode = "each"; next.yearOnThe = false
    next.custom = false
    return next
  }

  /// Toggles one entry of a list the editor shows; the last one can't be
  /// turned off, as in Reminders.app.
  public static func toggled<T: Equatable>(_ shown: [T], _ item: T) -> [T] {
    guard shown.contains(item) else { return shown + [item] }
    if shown.count == 1 { return shown }
    return shown.filter { $0 != item }
  }

  /// Whether the edited state is a different rule from `original`'s.
  public func differs(from original: RepeatState) -> Bool {
    rule?.normalized != original.rule?.normalized
  }
}
