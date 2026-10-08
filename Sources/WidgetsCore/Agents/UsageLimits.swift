import Foundation

// Parsing Anthropic's OAuth usage endpoint, ported from the limits half of
// omarchy-agent-usage-claude.

public enum UsageLimits {
  public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

  /// "default_claude_max_20x" → "Max 20x"; else the subscription type,
  /// capitalized ("pro" → "Pro").
  public static func planLabel(tier: String, subscription: String) -> String {
    if let m = tier.firstMatch(of: try! Regex(#"(?i)max_(\d+x)"#)), let n = m.output[1].substring { return "Max " + n }
    if !subscription.isEmpty { return subscription.prefix(1).uppercased() + subscription.dropFirst() }
    return ""
  }

  static func parseUtilization(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: return n.doubleValue
    case let s as String:
      return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    default: return nil
    }
  }

  /// The endpoint reports percentages (37.0); older payloads used fractions
  /// (0.37). A payload with any value >= 1 is percent-scaled, so 1.0 is 1%.
  static func normalize(_ value: Any?, percentScale: Bool) -> Double? {
    guard let n = parseUtilization(value), n >= 0, n.isFinite else { return nil }
    if percentScale || n > 1 { return min(1, n / 100) }
    return min(1, n)
  }

  static func parseDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber {
      var ts = n.doubleValue
      if ts >= 1e12 { ts /= 1000 }
      return Date(timeIntervalSince1970: ts)
    }
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if raw.allSatisfy(\.isNumber), var ts = Double(raw) {
      if ts >= 1e12 { ts /= 1000 }
      return Date(timeIntervalSince1970: ts)
    }
    return isoDate(raw)
  }

  /// ISO-8601 with or without fractional seconds (Python emits 6 digits,
  /// which ISO8601DateFormatter refuses, so trim to milliseconds first).
  public static func isoDate(_ raw: String) -> Date? {
    var s = raw.replacingOccurrences(of: "Z", with: "+00:00")
    if let r = s.range(of: #"\.(\d{3})\d+"#, options: .regularExpression) {
      let ms = s[r].prefix(4)
      s.replaceSubrange(r, with: ms)
    }
    if let d = isoFrac.date(from: s) { return d }
    if let d = isoPlain.date(from: s) { return d }
    // No offset at all: treat as UTC, like the collector.
    return isoNoZone.date(from: s)
  }

  // ISO8601DateFormatter is thread-safe, so these are shared.
  nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()
  nonisolated(unsafe) private static let isoNoZone: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")
    f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
    return f
  }()

  /// "weekly_scoped" → "Weekly", "five_hour_scoped" → "Session".
  static func scopedWindow(_ kind: String) -> String {
    let t = kind.lowercased()
    if t.contains("month") { return "Monthly" }
    if t.contains("week") || t.contains("day") { return "Weekly" }
    if t.contains("hour") || t.contains("session") { return "Session" }
    return ""
  }

  public enum ProbeError: Error, Equatable {
    case status(Int, retryAfter: String?)
    case transport
    case noLimits
    case badPayload

    public var helpText: String {
      switch self {
      case let .status(429, retry):
        return "Anthropic's usage endpoint is rate limiting checks right now"
          + (retry.map { " (retry after \($0)s)" } ?? "") + ". Local Claude Code stats are still shown."
      case let .status(code, _):
        return "Anthropic's usage endpoint returned status \(code). Local Claude Code stats are still shown."
      case .transport:
        return "Couldn't reach Anthropic's usage endpoint. Retrying shortly. Local Claude Code stats are still shown."
      case .noLimits, .badPayload:
        return "Anthropic's usage endpoint returned no limits. Local Claude Code stats are still shown."
      }
    }
  }

  /// The session and weekly buckets, then any model-scoped windows from the
  /// `limits` array (the only place a model-only allowance like a Fable
  /// weekly shows up).
  public static func parse(_ data: Data) -> Result<[UsageLimit], ProbeError> {
    guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return .failure(.badPayload)
    }
    let weekly = (payload["seven_day_oauth_apps"] as? [String: Any]) ?? (payload["seven_day"] as? [String: Any])
    let session = payload["five_hour"] as? [String: Any]
    var raw: [Any?] = [session?["utilization"], weekly?["utilization"]]
    let entries = (payload["limits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    raw += entries.map { $0["percent"] }
    let percentScale = raw.contains { (parseUtilization($0) ?? -1) >= 1 }

    var limits: [UsageLimit] = []
    if let session, let p = normalize(session["utilization"], percentScale: percentScale) {
      limits.append(.init(label: "Session (5-hour)", percent: p, resetsAt: parseDate(session["resets_at"])))
    }
    if let weekly, let p = normalize(weekly["utilization"], percentScale: percentScale) {
      limits.append(.init(label: "Weekly (7-day)", percent: p, resetsAt: parseDate(weekly["resets_at"])))
    }
    var seen = Set<String>()
    for entry in entries {
      guard let scope = entry["scope"] as? [String: Any], let model = scope["model"] as? [String: Any] else { continue }
      let name = ((model["display_name"] as? String) ?? (model["id"] as? String) ?? "")
        .trimmingCharacters(in: .whitespaces)
      let kind = ((entry["kind"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
      let key = name + "\u{0}" + kind
      guard !name.isEmpty, !seen.contains(key) else { continue }
      guard let p = normalize(entry["percent"], percentScale: percentScale) else { continue }
      seen.insert(key)
      let window = scopedWindow(kind)
      let title = window.isEmpty ? name : name + " " + window
      limits.append(.init(label: title, title: title, percent: p, resetsAt: parseDate(entry["resets_at"])))
    }
    return limits.isEmpty ? .failure(.noLimits) : .success(limits)
  }

  /// A cached figure outlives its probe only until its window resets.
  public static func windowOpen(_ limit: UsageLimit, now: Date) -> Bool {
    guard let reset = limit.resetsAt else { return true }
    return reset > now
  }
}
