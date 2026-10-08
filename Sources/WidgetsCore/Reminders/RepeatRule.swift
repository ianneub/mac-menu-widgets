import Foundation

/// A reminder's repeat rule, in the shape the Omarchy widget's bridge used:
/// days_of_week entries are mon..sun, with a week number for monthly and
/// yearly rules ("1mon" = first Monday, "-1fri" = last Friday). Empty lists
/// mean "the due date's", as in EventKit.
public struct RepeatRule: Equatable, Sendable {
  public var frequency: String
  public var interval: Int = 1
  public var daysOfWeek: [String] = []
  public var daysOfMonth: [Int] = []
  public var monthsOfYear: [Int] = []
  public var setPositions: [Int] = []
  /// The last day it repeats: "yyyy-MM-dd" from EventKit, or what was typed.
  public var until: String? = nil
  public var count: Int? = nil
  /// Parts Reminders.app never makes (weeks or days of the year).
  public var custom: Bool = false

  public init(frequency: String, interval: Int = 1, daysOfWeek: [String] = [], daysOfMonth: [Int] = [],
              monthsOfYear: [Int] = [], setPositions: [Int] = [], until: String? = nil, count: Int? = nil,
              custom: Bool = false) {
    self.frequency = frequency; self.interval = interval; self.daysOfWeek = daysOfWeek
    self.daysOfMonth = daysOfMonth; self.monthsOfYear = monthsOfYear; self.setPositions = setPositions
    self.until = until; self.count = count; self.custom = custom
  }

  public static let ruleDays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
  static let weekdays = ["mon", "tue", "wed", "thu", "fri"]
  static let weekend = ["sat", "sun"]

  /// The same rule with its lists in a fixed order, for comparing.
  public var normalized: RepeatRule {
    var r = self
    let plain = Self.ruleDays.filter { daysOfWeek.contains($0) }
    r.daysOfWeek = plain + daysOfWeek.filter { !Self.ruleDays.contains($0) }
    return r
  }

  // MARK: the phrase rows show

  private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  private static let units = ["daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"]
  private static let nth = [1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", -1: "last"]

  private static func dayOfMonth(_ n: Int) -> String {
    if n == -1 { return "last day" }
    let suffix = (10...20).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
    return "\(n)\(suffix)"
  }

  /// "weekly on Mon, Wed", "every 2 weeks", "monthly on the last Fri". Parts
  /// the phrases can't say (Reminders.app never makes them) end in "(custom)".
  public var phrase: String {
    let n = interval
    let plainSet = Set(daysOfWeek.filter { $0.allSatisfy(\.isLetter) })
    var plain = Self.ruleDays.filter { plainSet.contains($0) }
    let numbered: [(Int, String)] = daysOfWeek.filter { !$0.allSatisfy(\.isLetter) }.compactMap { d in
      let digits = d.prefix { "-+0123456789".contains($0) }
      guard let week = Int(digits) else { return nil }
      return (week, String(d.dropFirst(digits.count)))
    }
    var positions = setPositions
    var monthDays = daysOfMonth
    let monthList = Array(Set(monthsOfYear)).sorted()
    var isCustom = custom || Self.units[frequency] == nil
    if positions == [-1] && monthDays.sorted() == [28, 29, 30, 31] && daysOfWeek.isEmpty {
      monthDays = [-1]; positions = []  // the last of the 28th-31st: the last day
    }

    var text: String
    if frequency == "weekly" && n == 1 && numbered.isEmpty && positions.isEmpty
        && (plain == Self.weekdays || plain == Self.weekend) {
      text = plain == Self.weekdays ? "weekdays" : "weekends"
      plain = []
    } else {
      text = n == 1 ? frequency : "every \(n) \(Self.units[frequency] ?? frequency)s"
    }
    if !monthList.isEmpty {
      text += " in " + monthList.map { (1...12).contains($0) ? Self.months[$0 - 1].capitalized : "\($0)" }
        .joined(separator: ", ")
    }
    var on: [String] = []
    if !positions.isEmpty {
      let kind: String? = plain == Self.ruleDays ? "day" : plain == Self.weekdays ? "weekday"
        : plain == Self.weekend ? "weekend day" : plain.count == 1 ? plain[0].capitalized : nil
      if let kind, positions.count == 1, let word = Self.nth[positions[0]] {
        on.append("the \(word) \(kind)")
        plain = []
      } else {
        isCustom = true
      }
    }
    for (week, day) in numbered {
      if Self.nth[week] == nil { isCustom = true }
      on.append("the \(Self.nth[week] ?? String(week)) \(day.capitalized)")
    }
    if !plain.isEmpty { on.append(plain.map(\.capitalized).joined(separator: ", ")) }
    if !monthDays.isEmpty {
      if monthDays.contains(where: { $0 < -1 }) { isCustom = true }
      on.append("the " + monthDays.map(Self.dayOfMonth).joined(separator: ", "))
    }
    if !on.isEmpty { text += " on " + on.joined(separator: ", ") }
    if let until, !until.isEmpty {
      text += " until " + Self.untilLabel(until)
    } else if let count, count > 0 {
      text += ", \(count) times"
    }
    return text + (isCustom ? " (custom)" : "")
  }

  private static func untilLabel(_ until: String) -> String {
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.dateFormat = "yyyy-MM-dd"
    guard let date = iso.date(from: until) else { return until }
    iso.dateFormat = "MMM d, yyyy"
    return iso.string(from: date)
  }
}
