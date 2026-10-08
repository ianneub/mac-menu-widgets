import Foundation

/// Local Claude Code stats from ~/.claude/projects/**/*.jsonl, with the same
/// rules as omarchy-agent-usage-claude's scan: assistant messages with a
/// usage block, deduped by message id across every file (Claude Code copies
/// earlier turns into resumed sessions), zero-token entries skipped.
///
/// Unlike the collector, the scan is incremental: transcripts are
/// append-only, so each file remembers how far it was read and only new
/// complete lines are parsed. The per-file results persist in a cache file,
/// so a relaunch rereads nothing that hasn't changed.
public final class TranscriptScanner: @unchecked Sendable {
  public struct Entry: Codable, Sendable, Equatable {
    public var key: String
    /// Epoch seconds; nil when the line had no parseable timestamp (counted
    /// as "today", like the collector).
    public var ts: Double?
    public var model: String
    public var bucket: TokenBucket
    public var session: String
  }

  struct FileState: Codable {
    var size: UInt64
    var mtime: Double
    /// Bytes consumed, up to the last complete line.
    var offset: UInt64
    var lines: Int
    var entries: [Entry]
  }

  struct CacheFile: Codable {
    var version: Int
    var root: String
    var files: [String: FileState]
  }

  static let cacheVersion = 1

  public let projectsDir: URL
  private let cacheURL: URL?
  private var files: [String: FileState] = [:]
  private let lock = NSLock()

  public init(projectsDir: URL, cacheURL: URL?) {
    self.projectsDir = projectsDir
    self.cacheURL = cacheURL
    if let cacheURL, let data = try? Data(contentsOf: cacheURL),
       let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
       cache.version == Self.cacheVersion, cache.root == projectsDir.path {
      files = cache.files
    }
  }

  /// Bring every file up to date and aggregate. `force` rereads all files
  /// from the start.
  public func scan(now: Date = Date(), force: Bool = false) -> UsageStats {
    lock.lock()
    defer { lock.unlock() }
    if force { files = [:] }
    var changed = false
    var present = Set<String>()
    for url in transcriptFiles() {
      let path = url.path
      present.insert(path)
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
      let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      var state = files[path]
      if let s = state, s.size == size, s.mtime == mtime { continue }
      // Shrunk or rewritten: start over.
      if let s = state, size < s.offset { state = nil }
      var st = state ?? FileState(size: 0, mtime: 0, offset: 0, lines: 0, entries: [])
      read(path: path, from: &st)
      st.size = size
      st.mtime = mtime
      files[path] = st
      changed = true
    }
    for gone in Set(files.keys).subtracting(present) {
      files.removeValue(forKey: gone)
      changed = true
    }
    if changed { saveCache() }
    let ordered = files.keys.sorted().map { files[$0]! }
    return Self.aggregate(ordered.flatMap(\.entries), now: now)
  }

  private func transcriptFiles() -> [URL] {
    guard let e = FileManager.default.enumerator(
      at: projectsDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants])
    else { return [] }
    var out: [URL] = []
    for case let url as URL in e where url.pathExtension == "jsonl" { out.append(url) }
    return out
  }

  private func read(path: String, from st: inout FileState) {
    guard let handle = FileHandle(forReadingAtPath: path) else { return }
    defer { try? handle.close() }
    do { try handle.seek(toOffset: st.offset) } catch { return }
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
    // Only complete lines; a half-written last line waits for next time.
    guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
    let complete = data[data.startIndex...lastNewline]
    var lineNumber = st.lines
    for line in complete.split(separator: 0x0A, omittingEmptySubsequences: false) {
      lineNumber += 1
      if let entry = Self.parseLine(Data(line), path: path, lineNumber: lineNumber) {
        st.entries.append(entry)
      }
    }
    // split yields one trailing empty piece after the final newline.
    st.lines = lineNumber - 1
    st.offset += UInt64(complete.count)
  }

  private static let usageMarker = Data(#""usage":"#.utf8)

  static func parseLine(_ line: Data, path: String, lineNumber: Int) -> Entry? {
    // Cheap pre-filter before JSON parsing.
    guard line.range(of: usageMarker) != nil,
          let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    else { return nil }
    let message = obj["message"] as? [String: Any] ?? [:]
    guard (obj["type"] as? String) == "assistant" || (message["role"] as? String) == "assistant" else { return nil }
    guard let usage = (message["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any]) else { return nil }

    func tok(_ snake: String, _ camel: String) -> Int {
      let v = usage[snake] ?? usage[camel]
      if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
      if let s = v as? String, let d = Double(s) { return Int(d.rounded()) }
      return 0
    }
    let bucket = TokenBucket(
      input: tok("input_tokens", "inputTokens"),
      output: tok("output_tokens", "outputTokens"),
      cacheRead: tok("cache_read_input_tokens", "cacheReadInputTokens"),
      cacheWrite: tok("cache_creation_input_tokens", "cacheCreationInputTokens"))
    guard bucket.total > 0 else { return nil }

    let messageID = nonEmpty(message["id"]) ?? nonEmpty(obj["messageId"])
    let key = messageID ?? "\(path):\(nonEmpty(obj["uuid"]) ?? nonEmpty(obj["requestId"]) ?? String(lineNumber))"
    let model = nonEmpty(message["model"]) ?? nonEmpty(obj["model"]) ?? "claude"
    let ts = timestamp(obj["timestamp"] ?? message["timestamp"])
    let session = nonEmpty(obj["sessionId"]) ?? path
    return Entry(key: key, ts: ts, model: model, bucket: bucket, session: session)
  }

  private static func nonEmpty(_ v: Any?) -> String? {
    if let s = v as? String, !s.isEmpty { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
  }

  static func timestamp(_ v: Any?) -> Double? {
    if let n = v as? NSNumber {
      let d = n.doubleValue
      return d > 10_000_000_000 ? d / 1000 : d
    }
    if let s = v as? String, let d = UsageLimits.isoDate(s.trimmingCharacters(in: .whitespaces)) {
      return d.timeIntervalSince1970
    }
    return nil
  }

  /// Dedupe by key (first wins) and roll up into the record's stats.
  public static func aggregate(_ entries: [Entry], now: Date) -> UsageStats {
    let today = UsageFormat.dateString(now)
    let recentDates = recentDateStrings(now: now)
    var recent = Dictionary(uniqueKeysWithValues: recentDates.map { ($0, 0) })
    var seen = Set<String>()
    var sessions = Set<String>()
    var activeDays = Set<String>()
    var todaySessions = Set<String>()
    var s = UsageStats()

    for e in entries {
      guard seen.insert(e.key).inserted else { continue }
      let total = e.bucket.total
      let day = e.ts.map { UsageFormat.dateString(Date(timeIntervalSince1970: $0)) } ?? today
      sessions.insert(e.session)
      activeDays.insert(day)
      s.totalPrompts += 1
      s.modelUsage[e.model, default: TokenBucket()].add(e.bucket)
      if recent[day] != nil { recent[day]! += total }
      if day == today {
        s.todayPrompts += 1
        todaySessions.insert(e.session)
        s.todayTotalTokens += total
        s.todayTokensByModel[e.model, default: 0] += total
      }
    }
    s.recentDays = recentDates.map { DayTokens(date: $0, tokens: recent[$0] ?? 0) }
    s.todaySessions = todaySessions.count
    s.totalSessions = sessions.count
    s.activeDays = activeDays.count
    s.activeDates = activeDays.sorted()
    return s
  }

  /// The last seven local dates, oldest first, ending today.
  public static func recentDateStrings(now: Date) -> [String] {
    let cal = Calendar.current
    return (0...6).reversed().compactMap { offset in
      cal.date(byAdding: .day, value: -offset, to: now).map(UsageFormat.dateString)
    }
  }

  private func saveCache() {
    guard let cacheURL else { return }
    let cache = CacheFile(version: Self.cacheVersion, root: projectsDir.path, files: files)
    guard let data = try? JSONEncoder().encode(cache) else { return }
    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheURL, options: .atomic)
  }
}

// MARK: - fallbacks for a machine without transcripts

public enum ClaudeLocalFallback {
  /// Claude Code's aggregate counters, used only when the scan finds nothing.
  public static func statsCache(claudeDir: URL, now: Date) -> UsageStats? {
    guard let data = try? Data(contentsOf: claudeDir.appendingPathComponent("stats-cache.json")),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let today = UsageFormat.dateString(now)
    var s = UsageStats()
    for e in (obj["dailyModelTokens"] as? [[String: Any]]) ?? [] where (e["date"] as? String) == today {
      for (k, v) in (e["tokensByModel"] as? [String: Any]) ?? [:] { s.todayTokensByModel[k] = int(v) }
      break
    }
    s.todayTotalTokens = s.todayTokensByModel.values.reduce(0, +)
    let activity = (obj["dailyActivity"] as? [[String: Any]]) ?? []
    s.activeDates = Set(activity.compactMap { d -> String? in
      guard let date = d["date"] as? String, int(d["messageCount"]) > 0 else { return nil }
      return date
    }).sorted()
    s.activeDays = s.activeDates.count
    s.recentDays = activity.suffix(7).map { DayTokens(date: ($0["date"] as? String) ?? "", tokens: int($0["messageCount"])) }
    for (model, raw) in (obj["modelUsage"] as? [String: [String: Any]]) ?? [:] {
      s.modelUsage[model] = TokenBucket(
        input: int(raw["inputTokens"]), output: int(raw["outputTokens"]),
        cacheRead: int(raw["cacheReadInputTokens"]), cacheWrite: int(raw["cacheCreationInputTokens"]))
    }
    s.totalPrompts = int(obj["totalMessages"])
    s.totalSessions = int(obj["totalSessions"])
    let (p, sess) = todayFromHistory(claudeDir: claudeDir, now: now)
    s.todayPrompts = p
    s.todaySessions = sess
    return s
  }

  /// Today's prompt and session counts from history.jsonl.
  public static func todayFromHistory(claudeDir: URL, now: Date) -> (prompts: Int, sessions: Int) {
    guard let text = try? String(contentsOf: claudeDir.appendingPathComponent("history.jsonl"), encoding: .utf8)
    else { return (0, 0) }
    let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000
    var prompts = 0
    var sessions = Set<String>()
    for line in text.split(separator: "\n").reversed() {
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
      if Double(int(obj["timestamp"])) < start { break }
      prompts += 1
      if let s = obj["sessionId"] as? String, !s.isEmpty { sessions.insert(s) }
    }
    return (prompts, sessions.count)
  }

  static func int(_ v: Any?) -> Int {
    if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
    if let s = v as? String, let d = Double(s) { return Int(d.rounded()) }
    return 0
  }
}
