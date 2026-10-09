import Foundation

// The Claude usage record: the Mac counterpart of what Omarchy's
// `omarchy-agent-usage-claude` collector prints. The panel only ever reads
// this; the collector side (ClaudeUsageCollector) fills it in.

public struct TokenBucket: Codable, Sendable, Equatable {
  public var inputTokens = 0
  public var outputTokens = 0
  public var cacheReadInputTokens = 0
  public var cacheCreationInputTokens = 0

  public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
    inputTokens = input
    outputTokens = output
    cacheReadInputTokens = cacheRead
    cacheCreationInputTokens = cacheWrite
  }

  public var total: Int { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }

  public mutating func add(_ other: TokenBucket) {
    inputTokens += other.inputTokens
    outputTokens += other.outputTokens
    cacheReadInputTokens += other.cacheReadInputTokens
    cacheCreationInputTokens += other.cacheCreationInputTokens
  }
}

/// One day of the "tokens by day" chart. (The collector's legacy field name
/// is messageCount, but it holds a token total.)
public struct DayTokens: Codable, Sendable, Equatable {
  public var date: String
  public var tokens: Int
  public init(date: String, tokens: Int) { self.date = date; self.tokens = tokens }
}

public struct UsageStats: Codable, Sendable, Equatable {
  public var todayPrompts = 0
  public var todaySessions = 0
  public var todayTotalTokens = 0
  public var todayTokensByModel: [String: Int] = [:]
  public var recentDays: [DayTokens] = []
  public var modelUsage: [String: TokenBucket] = [:]
  public var totalPrompts = 0
  public var totalSessions = 0
  public var activeDays = 0
  public var activeDates: [String] = []
  public init() {}
}

/// One rate-limit window. `percent` is 0...1.
public struct UsageLimit: Codable, Sendable, Equatable {
  public var label: String
  /// Set when the collector already knows the window (model-scoped limits).
  public var title: String?
  public var percent: Double
  public var resetsAt: Date?

  public init(label: String, title: String? = nil, percent: Double, resetsAt: Date?) {
    self.label = label; self.title = title; self.percent = percent; self.resetsAt = resetsAt
  }

  /// The panel's title: an explicit one wins, else read from the label.
  public var displayTitle: String {
    if let title, !title.isEmpty { return title }
    return UsageFormat.windowTitle(label)
  }

  /// The window's full length, for pace.
  public var spanSeconds: TimeInterval { UsageFormat.windowSpan(title ?? label) }
}

public struct UsageRecord: Sendable, Equatable {
  public var name = "Claude Code"
  public var tierLabel = ""
  public var usageStatusText = ""
  public var authHelpText = ""
  public var limits: [UsageLimit] = []
  public var stats = UsageStats()
  public var retryAdvised = false
  public var updatedAt = Date()
  public init() {}

  public var hasData: Bool {
    stats.totalPrompts > 0 || stats.totalSessions > 0 || stats.activeDays > 0
      || stats.todayPrompts > 0 || stats.todaySessions > 0 || !limits.isEmpty
  }

  /// The fullest window: the one that stops the next prompt.
  public var bindingLimit: UsageLimit? { limits.max { $0.percent < $1.percent } }

  public var heroMeta: String {
    if !usageStatusText.isEmpty { return usageStatusText }
    if tierLabel.isEmpty { return "Subscription" }
    return tierLabel.prefix(1).uppercased() + tierLabel.dropFirst()
  }
}

// MARK: - formatting

public enum UsageFormat {
  public static func tokenCount(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
    return String(n)
  }

  /// "claude-opus-4-8-20260101" → "Opus 4.8".
  public static func friendlyModelName(_ id: String) -> String {
    if id.isEmpty { return "Unknown" }
    var name = id
    if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
    if let r = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(r) }
    var words: [String] = []
    var version: [String] = []
    for part in name.split(separator: "-", omittingEmptySubsequences: true).map(String.init) {
      if part.first?.isNumber == true {
        version.append(part)
        continue
      }
      if !version.isEmpty {
        words.append(version.joined(separator: "."))
        version = []
      }
      words.append(wordCase(part))
    }
    if !version.isEmpty { words.append(version.joined(separator: ".")) }
    return words.isEmpty ? "Unknown" : words.joined(separator: " ")
  }

  private static func wordCase(_ w: String) -> String {
    if w == "gpt" { return "GPT" }
    if w == "deepseek" { return "DeepSeek" }
    return w.prefix(1).uppercased() + w.dropFirst()
  }

  static func windowIsLong(_ text: String) -> Bool {
    ["week", "7-day", "seven", "month", "30-day"].contains { text.contains($0) }
  }

  public static func windowSpan(_ label: String) -> TimeInterval {
    let text = label.lowercased()
    if text.contains("month") || text.contains("30-day") { return 30 * 86400 }
    if windowIsLong(text) { return 7 * 86400 }
    if let m = text.firstMatch(of: try! Regex(#"(\d+)\s*-?\s*h(?:our)?\b"#)), let n = Double(m.output[1].substring ?? "") { return n * 3600 }
    if let m = text.firstMatch(of: try! Regex(#"(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b"#)), let n = Double(m.output[1].substring ?? "") { return n * 60 }
    return 0
  }

  public static func windowTitle(_ label: String) -> String {
    let text = label.lowercased()
    if text.contains("month") { return "Monthly" }
    if windowIsLong(text) { return "Weekly" }
    if text.contains("session") || windowSpan(label) > 0 { return "Session" }
    let plain = label.replacingOccurrences(of: #"\s*\(.*\)\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    return plain.isEmpty ? "Limit" : plain
  }

  /// "3d 4h", "2h 15m", "7m"; "now" once the time has passed.
  public static func duration(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "now" }
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    let days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(max(1, minutes))m"
  }

  /// How far through its window a limit is (0...1), or nil without a reset
  /// time or a known span. A meter ahead of this is burning faster than the
  /// allowance refills.
  public static func paceFraction(_ limit: UsageLimit, now: Date) -> Double? {
    guard let reset = limit.resetsAt else { return nil }
    let span = limit.spanSeconds
    guard span > 0 else { return nil }
    let remaining = reset.timeIntervalSince(now)
    guard remaining > 0, remaining <= span else { return nil }
    return min(1, max(0, 1 - remaining / span))
  }

  /// Where a limit is headed if usage keeps its average rate since the
  /// window opened: the share used by the reset, or when it runs out first.
  public struct Projection: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
      /// Under 80% by the reset: room to spare.
      case fine
      /// 80–100% by the reset.
      case tight
      /// Runs out before the reset (or already has).
      case over
    }
    /// Fraction used by the reset (may exceed 1).
    public var atReset: Double
    /// Time until the limit is reached, when that comes before the reset.
    public var runsOutIn: TimeInterval?
    public var level: Level
    /// "14% by reset", "At this rate, out in 1h 20m".
    public var text: String {
      if let t = runsOutIn {
        return t <= 0 ? "Limit reached" : "At this rate, out in \(UsageFormat.duration(t))"
      }
      return "\(Int((atReset * 100).rounded()))% by reset"
    }
  }

  /// How worrying a limit is, worst first: at 90% or more, or projected to
  /// run out before its reset (.over); headed for 80–100% (.tight); else
  /// .fine. The bar, the projection text and the menu bar label share it.
  public static func concern(_ limit: UsageLimit, now: Date) -> Projection.Level {
    if limit.percent >= 0.9 { return .over }
    return projection(limit, now: now)?.level ?? .fine
  }

  /// Too little of the window has gone by before this to call a rate.
  public static let projectionMinElapsed = 0.1

  /// The projection for a limit, or nil without a reset time, a known span,
  /// or enough of the window behind it.
  public static func projection(_ limit: UsageLimit, now: Date) -> Projection? {
    if limit.percent >= 1 { return Projection(atReset: limit.percent, runsOutIn: 0, level: .over) }
    guard let elapsed = paceFraction(limit, now: now), elapsed >= projectionMinElapsed,
          let reset = limit.resetsAt
    else { return nil }
    let atReset = limit.percent / elapsed
    guard atReset >= 1 else {
      return Projection(atReset: atReset, runsOutIn: nil, level: atReset >= 0.8 ? .tight : .fine)
    }
    // Used `percent` over `elapsed` of the span: the rest at the same rate.
    let ratePerSecond = limit.percent / (elapsed * limit.spanSeconds)
    let out = (1 - limit.percent) / ratePerSecond
    let untilReset = reset.timeIntervalSince(now)
    return Projection(atReset: atReset, runsOutIn: min(out, untilReset), level: .over)
  }

  public static func dayName(_ date: String) -> String {
    guard let d = dayFormatter.date(from: date) else { return date }
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][Calendar.current.component(.weekday, from: d) - 1]
  }

  /// "Wed 10/8 · 1.2M tokens", plus prompts and sessions for today.
  public static func dayTooltip(_ day: DayTokens, today: Bool, stats: UsageStats) -> String {
    var label = day.date
    if let d = dayFormatter.date(from: day.date) {
      let c = Calendar.current.dateComponents([.month, .day], from: d)
      label = "\(dayName(day.date)) \(c.month ?? 0)/\(c.day ?? 0)"
    }
    var text = "\(label) · \(tokenCount(day.tokens)) tokens"
    if today { text += " · \(stats.todayPrompts) prompts · \(stats.todaySessions) sessions" }
    return text
  }

  public struct ModelRow: Equatable, Sendable {
    public var id: String
    public var name: String
    public var bucket: TokenBucket
    public var total: Int { bucket.total }
  }

  /// The four heaviest models, heaviest first.
  public static func modelRows(_ usage: [String: TokenBucket]) -> [ModelRow] {
    usage.map { ModelRow(id: $0.key, name: friendlyModelName($0.key), bucket: $0.value) }
      .sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
      .prefix(4).map { $0 }
  }

  public static func modelTooltip(_ row: ModelRow) -> String {
    "In \(tokenCount(row.bucket.inputTokens)) · out \(tokenCount(row.bucket.outputTokens))"
      + " · cache read \(tokenCount(row.bucket.cacheReadInputTokens))"
      + " · cache write \(tokenCount(row.bucket.cacheCreationInputTokens))"
  }

  public static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .autoupdatingCurrent
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  public static func dateString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
