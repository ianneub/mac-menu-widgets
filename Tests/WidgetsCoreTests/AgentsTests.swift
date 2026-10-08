import Foundation
import Testing
@testable import WidgetsCore

@Suite struct AgentsFormatTests {
  @Test func planLabels() {
    #expect(UsageLimits.planLabel(tier: "default_claude_max_20x", subscription: "max") == "Max 20x")
    #expect(UsageLimits.planLabel(tier: "", subscription: "pro") == "Pro")
    #expect(UsageLimits.planLabel(tier: "default", subscription: "") == "")
  }

  @Test func tokenCounts() {
    #expect(UsageFormat.tokenCount(999) == "999")
    #expect(UsageFormat.tokenCount(1500) == "1.5K")
    #expect(UsageFormat.tokenCount(2_345_678) == "2.3M")
    #expect(UsageFormat.tokenCount(3_000_000_000) == "3.0B")
  }

  @Test func friendlyModelNames() {
    #expect(UsageFormat.friendlyModelName("claude-opus-4-8") == "Opus 4.8")
    #expect(UsageFormat.friendlyModelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
    #expect(UsageFormat.friendlyModelName("claude-fable-5-1") == "Fable 5.1")
    #expect(UsageFormat.friendlyModelName("gpt-5.6-sol") == "GPT 5.6 Sol")
    #expect(UsageFormat.friendlyModelName("") == "Unknown")
  }

  @Test func windowTitlesAndSpans() {
    #expect(UsageFormat.windowTitle("Session (5-hour)") == "Session")
    #expect(UsageFormat.windowTitle("Weekly (7-day)") == "Weekly")
    #expect(UsageFormat.windowSpan("Session (5-hour)") == 5 * 3600)
    #expect(UsageFormat.windowSpan("Weekly (7-day)") == 7 * 86400)
    // An explicit title wins: "1M context" must not read as a minute window.
    let scoped = UsageLimit(label: "Opus 5 (1M context) Weekly", title: "Opus 5 (1M context) Weekly", percent: 0.1, resetsAt: nil)
    #expect(scoped.displayTitle == "Opus 5 (1M context) Weekly")
  }

  @Test func durations() {
    #expect(UsageFormat.duration(0) == "now")
    #expect(UsageFormat.duration(30) == "1m")
    #expect(UsageFormat.duration(2 * 3600 + 15 * 60) == "2h 15m")
    #expect(UsageFormat.duration(3 * 86400 + 4 * 3600 + 60) == "3d 4h")
  }

  @Test func pace() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // Halfway through a 5-hour window at 50% used: on pace.
    let half = UsageLimit(label: "Session (5-hour)", percent: 0.5, resetsAt: now.addingTimeInterval(2.5 * 3600))
    #expect(UsageFormat.paceFraction(half, now: now)! == 0.5)
  }

  @Test func projection() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func session(_ used: Double, resetsIn: TimeInterval) -> UsageLimit {
      UsageLimit(label: "Session (5-hour)", percent: used, resetsAt: now.addingTimeInterval(resetsIn))
    }
    // The screenshot: 8% used, resets in 2h 6m of a 5h window (58% gone).
    let easy = UsageFormat.projection(session(0.08, resetsIn: 2 * 3600 + 6 * 60), now: now)!
    #expect(easy.level == .fine)
    #expect(easy.text == "~14% by reset")
    // Halfway through at 45%: ~90% by reset.
    let tight = UsageFormat.projection(session(0.45, resetsIn: 2.5 * 3600), now: now)!
    #expect(tight.level == .tight)
    #expect(tight.text == "~90% by reset")
    // Halfway through at 80% (32%/hour): the remaining 20% lasts 37 minutes.
    let over = UsageFormat.projection(session(0.8, resetsIn: 2.5 * 3600), now: now)!
    #expect(over.level == .over)
    #expect(over.text == "At this rate, out in 37m")
    #expect(UsageFormat.projection(session(1.0, resetsIn: 3600), now: now)!.text == "Limit reached")
    // Too early in the window to call (5% gone), or no reset known.
    #expect(UsageFormat.projection(session(0.02, resetsIn: 4.75 * 3600), now: now) == nil)
    #expect(UsageFormat.projection(UsageLimit(label: "Session (5-hour)", percent: 0.5, resetsAt: nil), now: now) == nil)
    // A weekly window: 7% used, 1d 5h into 7 days → ~41%.
    let week = UsageLimit(label: "Weekly (7-day)", percent: 0.07, resetsAt: now.addingTimeInterval(5 * 86400 + 19 * 3600))
    #expect(UsageFormat.projection(week, now: now)!.text == "~41% by reset")
  }

  @Test func modelRowsTopFourByTotal() {
    let usage: [String: TokenBucket] = [
      "claude-a-1": .init(input: 1), "claude-b-1": .init(input: 5), "claude-c-1": .init(output: 3),
      "claude-d-1": .init(cacheRead: 4), "claude-e-1": .init(cacheWrite: 2),
    ]
    let rows = UsageFormat.modelRows(usage)
    #expect(rows.map(\.id) == ["claude-b-1", "claude-d-1", "claude-c-1", "claude-e-1"])
    #expect(UsageFormat.modelTooltip(rows[0]) == "In 5 · out 0 · cache read 0 · cache write 0")
  }
}

@Suite struct UsageLimitsParseTests {
  static let payload = """
  {
    "five_hour": {"utilization": 2.0, "resets_at": "2026-10-08T15:19:59.853584+00:00"},
    "seven_day": {"utilization": 37.0, "resets_at": "2026-10-14T18:59:59.853604+00:00"},
    "seven_day_oauth_apps": null,
    "limits": [
      {"kind": "session", "percent": 2, "scope": null, "resets_at": "2026-10-08T15:19:59Z"},
      {"kind": "weekly_scoped", "percent": 0, "resets_at": "2026-10-14T19:00:00+00:00",
       "scope": {"model": {"id": null, "display_name": "Fable"}}},
      {"kind": "weekly_scoped", "percent": 5, "resets_at": "2026-10-14T19:00:00+00:00",
       "scope": {"model": {"id": null, "display_name": "Fable"}}}
    ]
  }
  """

  @Test func parsesBucketsAndScopedWindows() throws {
    let limits = try UsageLimits.parse(Data(Self.payload.utf8)).get()
    #expect(limits.count == 3)
    #expect(limits[0].label == "Session (5-hour)")
    #expect(abs(limits[0].percent - 0.02) < 1e-9)
    #expect(limits[1].displayTitle == "Weekly")
    #expect(abs(limits[1].percent - 0.37) < 1e-9)
    #expect(limits[2].displayTitle == "Fable Weekly")
    #expect(limits[2].percent == 0)
    #expect(limits[0].resetsAt == UsageLimits.isoDate("2026-10-08T15:19:59.853Z"))
  }

  @Test func oauthAppsBucketWinsAndFractionsStayFractions() throws {
    let json = #"{"five_hour": {"utilization": 0.25}, "seven_day": {"utilization": 0.9}, "seven_day_oauth_apps": {"utilization": 0.5}}"#
    let limits = try UsageLimits.parse(Data(json.utf8)).get()
    #expect(limits.map(\.percent) == [0.25, 0.5])
  }

  @Test func percentScaleAppliesToOne() throws {
    // 1.0 beside a 40 is one percent, not a full window.
    let json = #"{"five_hour": {"utilization": 1.0}, "seven_day": {"utilization": 40}}"#
    let limits = try UsageLimits.parse(Data(json.utf8)).get()
    #expect(limits.map(\.percent) == [0.01, 0.4])
  }

  @Test func noLimits() {
    #expect(UsageLimits.parse(Data("{}".utf8)) == .failure(.noLimits))
    #expect(UsageLimits.parse(Data("nope".utf8)) == .failure(.badPayload))
  }

  @Test func errorHelpText() {
    #expect(UsageLimits.ProbeError.status(429, retryAfter: "30").helpText.contains("(retry after 30s)"))
    #expect(UsageLimits.ProbeError.status(500, retryAfter: nil).helpText.contains("status 500"))
  }

  @Test func closedWindowsDropFromCache() {
    let now = Date()
    #expect(UsageLimits.windowOpen(.init(label: "x", percent: 0.5, resetsAt: now.addingTimeInterval(60)), now: now))
    #expect(!UsageLimits.windowOpen(.init(label: "x", percent: 0.5, resetsAt: now.addingTimeInterval(-60)), now: now))
    #expect(UsageLimits.windowOpen(.init(label: "x", percent: 0.5, resetsAt: nil), now: now))
  }

  @Test func credentialsParse() {
    let json = #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1790000000000, "rateLimitTier": "default_claude_max_5x", "subscriptionType": "max"}}"#
    let login = ClaudeLogin.parse(Data(json.utf8))
    #expect(login == ClaudeLogin(accessToken: "t", expiresAtMs: 1_790_000_000_000, plan: "Max 5x"))
  }
}

@Suite struct TranscriptScannerTests {
  func line(_ id: String?, ts: String, model: String = "claude-opus-4-8", input: Int = 10, output: Int = 5,
            session: String = "s1", type: String = "assistant") -> String {
    let msgID = id.map { #""id": "\#($0)","# } ?? ""
    return #"{"type": "\#(type)", "sessionId": "\#(session)", "timestamp": "\#(ts)", "uuid": "u-\#(UUID().uuidString)", "message": {\#(msgID) "role": "assistant", "model": "\#(model)", "usage": {"input_tokens": \#(input), "output_tokens": \#(output), "cache_read_input_tokens": 1, "cache_creation_input_tokens": 0}}}"#
  }

  func iso(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
  }

  @Test func scansDedupesAndAppendsIncrementally() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
    let proj = tmp.appendingPathComponent("projects/-Users-x")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let now = Date()
    let yesterday = now.addingTimeInterval(-86400)
    let a = proj.appendingPathComponent("a.jsonl")
    let b = proj.appendingPathComponent("b.jsonl")
    try ([
      line("m1", ts: iso(now)),
      line("m2", ts: iso(yesterday), model: "claude-sonnet-4-5", input: 100),
      #"{"type": "user", "message": {"role": "user", "content": "hi"}}"#,
      line("m0", ts: iso(now), input: 0, output: 0).replacingOccurrences(of: #""cache_read_input_tokens": 1"#, with: #""cache_read_input_tokens": 0"#),
    ].joined(separator: "\n") + "\n").write(to: a, atomically: true, encoding: .utf8)
    // A resumed session repeats m1; it must count once.
    try (line("m1", ts: iso(now), session: "s2") + "\n").write(to: b, atomically: true, encoding: .utf8)

    let cache = tmp.appendingPathComponent("cache.json")
    let scanner = TranscriptScanner(projectsDir: tmp.appendingPathComponent("projects"), cacheURL: cache)
    var s = scanner.scan(now: now)
    #expect(s.totalPrompts == 2)
    #expect(s.todayPrompts == 1)
    #expect(s.todayTotalTokens == 16)
    #expect(s.todaySessions == 1)
    #expect(s.recentDays.count == 7)
    #expect(s.recentDays.last?.tokens == 16)
    #expect(s.recentDays[5].tokens == 106)
    #expect(s.modelUsage["claude-sonnet-4-5"]?.inputTokens == 100)
    #expect(s.activeDays == 2)
    #expect(s.totalSessions == 1)

    // Append one complete line and one half-written one.
    let h = try FileHandle(forWritingTo: a)
    try h.seekToEnd()
    try h.write(contentsOf: Data((line("m3", ts: iso(now), session: "s3") + "\n" + #"{"type": "assist"#).utf8))
    try h.close()
    s = scanner.scan(now: now)
    #expect(s.totalPrompts == 3)
    #expect(s.todaySessions == 2)

    // A fresh scanner reads the persisted cache and agrees.
    let again = TranscriptScanner(projectsDir: tmp.appendingPathComponent("projects"), cacheURL: cache)
    #expect(again.scan(now: now) == s)
    #expect(again.scan(now: now, force: true) == s)
  }

  @Test func entriesWithoutMessageIdKeyByPathAndUuid() {
    let raw = line(nil, ts: "2026-10-08T12:00:00Z")
    let e = TranscriptScanner.parseLine(Data(raw.utf8), path: "/p/x.jsonl", lineNumber: 3)
    #expect(e?.key.hasPrefix("/p/x.jsonl:u-") == true)
    #expect(e?.bucket.total == 16)
  }
}

@Suite struct SVGPathTests {
  @Test func tokenizesPackedNumbers() {
    #expect(SVGPath.tokenize("m50.228 170.321.843-2.463") == [
      .command("m"), .number(50.228), .number(170.321), .number(0.843), .number(-2.463),
    ])
  }

  @Test func claudeMarkFitsItsViewBox() {
    let box = ClaudeMark.cgPath.boundingBoxOfPath
    #expect(box.minX >= -0.5 && box.minY >= -0.5)
    #expect(box.maxX <= 256.5 && box.maxY <= 257.5)
    #expect(box.width > 200 && box.height > 200)
  }
}
