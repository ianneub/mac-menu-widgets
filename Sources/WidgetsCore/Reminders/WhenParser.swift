import Foundation

/// Reads the "when" people type into the reminders widget: "5pm", "55m",
/// "sep 23 @ 3pm", "tomorrow", "2026-10-12 9:30am". Ported from the Omarchy
/// widget's CLI (normalize, then GNU date); here NSDataDetector does what GNU
/// date did, after the same rewrites.
public enum WhenParser {
  /// A moment, and whether it has a time of day or is just a date.
  public struct When: Equatable, Sendable {
    public var date: Date
    public var hasTime: Bool
    public init(date: Date, hasTime: Bool) { self.date = date; self.hasTime = hasTime }
  }

  public struct ParseError: Error, Equatable, CustomStringConvertible {
    public let description: String
  }

  private static let units: [Character: String] = ["h": "hours", "m": "minutes", "d": "days", "w": "weeks"]
  private static let month = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#

  /// A bare "at 3": hours 1-7 are afternoon, 8-11 morning, 12 noon, the rest 24-hour.
  static func clock(_ hour: String, _ minute: String?) -> String {
    let h = Int(hour) ?? 99
    if h > 23 { return hour + (minute ?? "") }  // not a time; the parser rejects it
    let suffix = (1...7).contains(h) || h == 12 ? "pm" : (8...11).contains(h) ? "am" : ""
    return "\(h)\(minute ?? ":00")\(suffix)"
  }

  /// Rewrites the phrasings people type into ones the parser reads.
  public static func normalize(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: " ")
    t = replace(t, #"\b([ap])\.?m\.?(?=\s|$)"#) { "\($0[1])m" }                  // p.m. -> pm
    t = replace(t, #"(\d)\s*([ap])(?=\s|$)"#) { "\($0[1])\($0[2])m" }             // 3p -> 3pm
    t = replace(t, #"\bnoon\b"#) { _ in "12:00pm" }
    t = replace(t, #"\bmidnight\b"#) { _ in "12:00am" }
    t = replace(t, #"\b(\d{1,2})(st|nd|rd|th)\b"#) { $0[1] }                        // 23rd -> 23
    t = replace(t, #"(?<![\d.:])(\d+)\s*(h|hrs?|m|mins?|d|w)(?![a-z])"#) {          // 1h22m -> 1 hours 22 minutes
      " \($0[1]) \(units[$0[2].first!]!) "
    }
    // "at 3" / "@ 3:30" with no am/pm; "at 3pm" and "@ 15:00" fall through.
    t = replace(t, #"(?:@|\bat\b)\s*(\d{1,2})(:\d\d)?(?![\d:])(?!\s*[ap]m)"#) {
      clock($0[1], $0[2].isEmpty ? nil : $0[2])
    }
    t = replace(t, #"@|\b(at|on|in|of)\b"#) { _ in " " }                           // filler
    t = replace(t, #"(?<![\d:])\b(\d{1,2})\s+"# + month) { m in                     // 23 sep -> sep 23
      let words = m[0].split(separator: " ", omittingEmptySubsequences: true)
      return "\(words.last!) \(m[1])"
    }
    return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static let timeWords = try! NSRegularExpression(pattern:
    #"\d\s*(am|pm)\b|\d:\d\d|\b(now|tonight|morning|afternoon|evening)\b"#, options: [.caseInsensitive])
  private static let relativePart = try! NSRegularExpression(pattern:
    #"^(\d+) (weeks|days|hours|minutes)$"#)

  /// "55 minutes", "1 hours 22 minutes" (normalized) as seconds from now, and
  /// whether it reaches below a day; nil if it isn't only durations.
  static func relative(_ normalized: String) -> (seconds: TimeInterval, hasTime: Bool)? {
    let words = normalized.split(separator: " ").map(String.init)
    guard !words.isEmpty, words.count % 2 == 0 else { return nil }
    var total: TimeInterval = 0
    var hasTime = false
    for i in stride(from: 0, to: words.count, by: 2) {
      guard let n = Double(words[i]) else { return nil }
      switch words[i + 1] {
      case "weeks": total += n * 604_800
      case "days": total += n * 86_400
      case "hours": total += n * 3_600; hasTime = true
      case "minutes": total += n * 60; hasTime = true
      default: return nil
      }
    }
    return (total, hasTime)
  }

  private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

  /// Parses `raw` in the local time zone (NSDataDetector has no other);
  /// `now` is injectable for tests.
  public static func parse(_ raw: String, now: Date = Date()) throws -> When {
    let calendar = Calendar.current
    let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty else { throw ParseError(description: "empty date") }
    let text = normalize(original)
    let today = calendar.startOfDay(for: now)

    func fixed(_ format: String) -> DateFormatter {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = calendar.timeZone
      f.calendar = calendar
      f.dateFormat = format
      f.isLenient = false
      return f
    }
    if let date = fixed("yyyy-MM-dd").date(from: text) { return When(date: date, hasTime: false) }
    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm"] {
      if let date = fixed(format).date(from: text) { return When(date: date, hasTime: true) }
    }
    switch text {
    case "now": return When(date: now, hasTime: true)
    case "today": return When(date: today, hasTime: false)
    case "tomorrow": return When(date: calendar.date(byAdding: .day, value: 1, to: today)!, hasTime: false)
    case "yesterday": return When(date: calendar.date(byAdding: .day, value: -1, to: today)!, hasTime: false)
    default: break
    }
    if let rel = relative(text) {
      let date = now.addingTimeInterval(rel.seconds)
      return When(date: rel.hasTime ? date : calendar.startOfDay(for: date), hasTime: rel.hasTime)
    }

    let range = NSRange(text.startIndex..., in: text)
    guard let match = detector.firstMatch(in: text, options: [], range: range), let date = match.date else {
      throw ParseError(description: "Can't read the date “\(original)”")
    }
    // Words outside what the detector understood mean it guessed at part of it.
    let outside = (text as NSString).replacingCharacters(in: match.range, with: " ")
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty && !["the", "this", "next"].contains($0) }
    if !outside.isEmpty {
      throw ParseError(description: "Can't read “\(outside.joined(separator: " "))” in “\(original)”")
    }
    let hasTime = timeWords.firstMatch(in: text, options: [], range: range) != nil
    return When(date: hasTime ? date : calendar.startOfDay(for: date), hasTime: hasTime)
  }

  /// Regex replace with a closure over the match's groups ("" for a group
  /// that didn't take part).
  private static func replace(_ s: String, _ pattern: String, _ with: ([String]) -> String) -> String {
    let re = try! NSRegularExpression(pattern: pattern, options: [])
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
      out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
      let groups = (0..<m.numberOfRanges).map { i -> String in
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
      }
      out += with(groups)
      last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
  }
}
