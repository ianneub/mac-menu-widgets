import Foundation

/// One open reminder, as the widget reads it from EventKit.
public struct ReminderItem: Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var list: String
  public var notes: String = ""
  /// Reminders.app's URL field.
  public var url: String = ""
  /// "none", "low", "medium" or "high".
  public var priority: String = "none"
  /// The due moment; a date-only reminder is due at the start of its day.
  public var due: Date?
  public var hasTime: Bool = false
  public var rule: RepeatRule?

  public init(id: String, title: String, list: String, notes: String = "", url: String = "", priority: String = "none",
              due: Date?, hasTime: Bool = false, rule: RepeatRule? = nil) {
    self.id = id; self.title = title; self.list = list; self.notes = notes; self.url = url
    self.priority = priority; self.due = due; self.hasTime = hasTime; self.rule = rule
  }
}

public enum Bucket: String, Sendable, CaseIterable {
  case overdue, today, tomorrow
}

/// A reminder in the panel: its day bucket, the label under its title and
/// when it counts as past due.
public struct AgendaEntry: Equatable, Sendable, Identifiable {
  public var item: ReminderItem
  public var bucket: Bucket
  /// "5:00 PM" today and tomorrow; "Wed Sep 23, 12:05 PM" or "Sun Sep 20" when overdue.
  public var label: String
  /// Its due time, or 9:00 for a date-only reminder (when Apple alerts).
  public var alertDate: Date
  public var id: String { item.id }
}

/// Ported from the Omarchy widget's Model.js and its CLI's `agenda`.
public enum Agenda {
  /// When Apple alerts for a date-only reminder.
  public static let allDayAlertHour = 9

  private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = format
    return f
  }

  /// Open reminders due through tomorrow, oldest day first; within a day,
  /// timed reminders before date-only ones (except overdue).
  public static func entries(_ items: [ReminderItem], now: Date, calendar: Calendar = .current) -> [AgendaEntry] {
    let today = calendar.startOfDay(for: now)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
    let after = calendar.date(byAdding: .day, value: 2, to: today)!
    let day = formatter("yyyy-MM-dd", calendar)
    let rows: [(AgendaEntry, String)] = items.compactMap { item in
      guard let due = item.due, due < after else { return nil }
      let dayStart = calendar.startOfDay(for: due)
      let bucket: Bucket = dayStart < today ? .overdue : dayStart < tomorrow ? .today : .tomorrow
      let alert = item.hasTime ? due : calendar.date(bySettingHour: allDayAlertHour, minute: 0, second: 0, of: dayStart)!
      let label: String
      if !item.hasTime {
        label = bucket == .overdue ? formatter("EEE MMM d", calendar).string(from: due) : ""
      } else if bucket == .overdue {
        label = formatter("EEE MMM d, h:mm a", calendar).string(from: due)
      } else {
        label = formatter("h:mm a", calendar).string(from: due)
      }
      return (AgendaEntry(item: item, bucket: bucket, label: label, alertDate: alert), day.string(from: due))
    }
    return rows.sorted { a, b in
      if a.1 != b.1 { return a.1 < b.1 }
      let aLast = !a.0.item.hasTime && a.0.bucket != .overdue
      let bLast = !b.0.item.hasTime && b.0.bucket != .overdue
      if aLast != bLast { return !aLast }
      if a.0.item.due != b.0.item.due { return a.0.item.due! < b.0.item.due! }
      return a.0.item.title.lowercased() < b.0.item.title.lowercased()
    }.map(\.0)
  }

  /// Past its alert time and not yet done: shown in red.
  public static func isLate(_ e: AgendaEntry, now: Date) -> Bool {
    e.bucket == .overdue || (e.bucket == .today && e.alertDate <= now)
  }

  public struct Summary: Equatable, Sendable {
    public var overdue = 0, today = 0, tomorrow = 0, late = 0
    public var due: Int { overdue + today }
    public var upcoming: Int { due - late }
    public init(overdue: Int = 0, today: Int = 0, tomorrow: Int = 0, late: Int = 0) {
      self.overdue = overdue; self.today = today; self.tomorrow = tomorrow; self.late = late
    }
  }

  /// Counts per bucket, skipping the ones checked off in the panel.
  public static func summary(_ entries: [AgendaEntry], done: Set<String>, now: Date) -> Summary {
    var s = Summary()
    for e in entries where !done.contains(e.id) {
      switch e.bucket {
      case .overdue: s.overdue += 1
      case .today: s.today += 1
      case .tomorrow: s.tomorrow += 1
      }
      if isLate(e, now: now) { s.late += 1 }
    }
    return s
  }

  /// What's past its alert time, and what's still to come today.
  public static func dueParts(_ s: Summary) -> [String] {
    var parts: [String] = []
    if s.late > 0 { parts.append("\(s.late) past due") }
    if s.upcoming > 0 { parts.append("\(s.upcoming) left today") }
    return parts
  }

  public static func tooltip(_ s: Summary) -> String {
    var parts = dueParts(s)
    if parts.isEmpty { parts.append("nothing left today") }
    if s.tomorrow > 0 { parts.append("\(s.tomorrow) tomorrow") }
    return "Reminders: " + parts.joined(separator: " · ")
  }

  /// The number in the menu bar: while something is past due (red bell),
  /// only those; otherwise everything left today.
  public static func barCount(_ s: Summary) -> Int { s.late > 0 ? s.late : s.due }

  /// "!!! " for high priority and so on, before the title.
  public static func priorityMark(_ priority: String) -> String {
    ["high": "!!! ", "medium": "!! ", "low": "! "][priority] ?? ""
  }

  /// The due time as text the "when" field reads back, to prefill the edit
  /// form: "today 5:00pm", "tomorrow", "2026-09-23 9:30am".
  public static func whenText(_ e: AgendaEntry, calendar: Calendar = .current) -> String {
    guard let due = e.item.due else { return "" }
    let day = e.bucket == .today || e.bucket == .tomorrow ? e.bucket.rawValue : formatter("yyyy-MM-dd", calendar).string(from: due)
    guard e.item.hasTime else { return day }
    return day + " " + formatter("h:mma", calendar).string(from: due).lowercased()
  }

  public static func defaultList(_ lists: [(name: String, isDefault: Bool)]) -> String {
    lists.first { $0.isDefault }?.name ?? lists.first?.name ?? "Reminders"
  }

  /// Trims the edit form's notes the way Reminders.app shows them: no blank
  /// lines at either end, no trailing spaces, inner line breaks kept.
  public static func cleanNotes(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n").map { line -> String in
      var l = Substring(line)
      while let last = l.last, last == " " || last == "\t" || last == "\r" { l = l.dropLast() }
      return String(l)
    }
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    return lines.joined(separator: "\n")
  }

  // MARK: editing

  /// What the edit form changed. A nil field is unchanged; an empty string
  /// clears it. `rule` is .some(nil) to stop repeating.
  public struct Edit: Equatable, Sendable {
    public var title: String?
    public var due: String?
    public var notes: String?
    public var url: String?
    public var rule: RepeatRule??
    public var isEmpty: Bool { title == nil && due == nil && notes == nil && url == nil && rule == nil }
    public init(title: String? = nil, due: String? = nil, notes: String? = nil, url: String? = nil, rule: RepeatRule?? = nil) {
      self.title = title; self.due = due; self.notes = notes; self.url = url; self.rule = rule
    }
  }

  /// The when text only counts if it was touched, so an untouched date isn't
  /// rewritten. The repeat editor is hidden without a date, and clearing the
  /// date stops the repeat anyway, so `repeat` is ignored then.
  public static func edit(for e: AgendaEntry, title: String, when: String, notes: String, url: String,
                          repeat rep: RepeatState?, calendar: Calendar = .current) -> Edit {
    var out = Edit()
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let when = when.trimmingCharacters(in: .whitespacesAndNewlines)
    let notes = cleanNotes(notes)
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if title != e.item.title { out.title = title }
    if when != whenText(e, calendar: calendar) { out.due = when }
    if let rep, !when.isEmpty, rep.differs(from: repeatState(e, calendar: calendar)) { out.rule = .some(rep.rule) }
    if notes != e.item.notes { out.notes = notes }
    if url != e.item.url { out.url = url }
    return out
  }

  public static func repeatState(_ e: AgendaEntry, calendar: Calendar = .current) -> RepeatState {
    RepeatState(rule: e.item.rule, defaults: .init(due: e.item.due, calendar: calendar))
  }
}

// MARK: - links

/// Web addresses in notes as links; ported from Model.js's linkify.
public enum Links {
  private static let link = try! NSRegularExpression(pattern: #"\b(?:https?://|www\.)[^\s<>"]+"#, options: [.caseInsensitive])
  private static let trailing = try! NSRegularExpression(pattern: #"[.,;:!?'")\]}>]+$"#)

  /// A link's target: bare "www." addresses get https.
  public static func href(_ link: String) -> String {
    link.lowercased().hasPrefix("www.") ? "https://" + link : link
  }

  /// Only real schemes are opened.
  public static func openable(_ url: String) -> Bool {
    url.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// A match minus trailing punctuation, keeping a closing paren that
  /// belongs to the address, as in wiki links.
  static func trim(_ match: String) -> String {
    let ns = match as NSString
    var link = trailing.stringByReplacingMatches(in: match, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    var rest = Substring(match.dropFirst(link.count))
    var opens = link.filter { $0 == "(" }.count
    let closes = link.filter { $0 == ")" }.count
    while opens > closes, rest.first == ")" { link += ")"; rest = rest.dropFirst(); opens -= 1 }
    return link
  }

  /// The text split into plain runs and links (display text, target).
  public static func segments(_ text: String) -> [(text: String, url: String?)] {
    let ns = text as NSString
    var out: [(String, String?)] = []
    var last = 0
    for m in link.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let shown = trim(ns.substring(with: m.range))
      if m.range.location > last { out.append((ns.substring(with: NSRange(location: last, length: m.range.location - last)), nil)) }
      out.append((shown, href(shown)))
      last = m.range.location + (shown as NSString).length
    }
    if last < ns.length { out.append((ns.substring(from: last), nil)) }
    return out
  }

  /// Notes with their web addresses as links, for SwiftUI's Text.
  public static func attributed(_ text: String) -> AttributedString {
    var out = AttributedString()
    for s in segments(text) {
      var part = AttributedString(s.text)
      if let url = s.url, let u = URL(string: url) { part.link = u }
      out += part
    }
    return out
  }

  /// What `o` opens: the URL field, else the first address in the notes.
  public static func firstLink(_ item: ReminderItem) -> String {
    if openable(item.url) { return item.url }
    return segments(item.notes).first { $0.url != nil }?.url ?? ""
  }

  /// A URL shortened for display: no scheme, no "www.", no trailing slash.
  public static func label(_ url: String) -> String {
    var s = url
    for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
    if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
    if s.hasSuffix("/") { s = String(s.dropLast()) }
    return s
  }
}
