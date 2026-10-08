import Foundation

/// Claude Code's saved sign-in, read-only. Only the access token (for the
/// probe's Authorization header), its expiry and the plan label are kept.
public struct ClaudeLogin: Sendable, Equatable {
  public var accessToken: String
  /// Epoch milliseconds; 0 when unknown.
  public var expiresAtMs: Double
  public var plan: String

  public static let empty = ClaudeLogin(accessToken: "", expiresAtMs: 0, plan: "")

  /// The `claudeAiOauth` object from the credentials JSON.
  public static func parse(_ data: Data) -> ClaudeLogin? {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let login = obj["claudeAiOauth"] as? [String: Any]
    else { return nil }
    let plan = UsageLimits.planLabel(
      tier: (login["rateLimitTier"] as? String) ?? "",
      subscription: (login["subscriptionType"] as? String) ?? "")
    return ClaudeLogin(
      accessToken: (login["accessToken"] as? String) ?? "",
      expiresAtMs: (login["expiresAt"] as? NSNumber)?.doubleValue ?? 0,
      plan: plan)
  }
}

public enum ClaudeCredentials {
  public static var claudeDir: URL {
    if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
      return URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
  }

  public static let keychainService = "Claude Code-credentials"

  /// The credentials file wins when present (Linux-style installs and
  /// CLAUDE_CONFIG_DIR setups); otherwise the login Keychain, where Claude
  /// Code on macOS keeps it.
  ///
  /// The Keychain item is read through /usr/bin/security rather than
  /// SecItemCopyMatching: Claude Code writes the item with that tool, so it
  /// is already on the item's access list and the read needs no prompt —
  /// and no "Always Allow" that every ad-hoc-signed rebuild would reset.
  /// Never writes or refreshes anything: refreshing would rotate Claude
  /// Code's refresh token out from under it.
  public static func load() -> ClaudeLogin {
    if let data = try? Data(contentsOf: claudeDir.appendingPathComponent(".credentials.json")),
       let login = ClaudeLogin.parse(data) {
      return login
    }
    if ProcessInfo.processInfo.environment["MENU_WIDGETS_NO_KEYCHAIN"] == "1" { return .empty }
    return keychain() ?? .empty
  }

  static func keychain() -> ClaudeLogin? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return ClaudeLogin.parse(data)
  }
}

/// Builds the usage record: local stats from transcripts plus limits from
/// Anthropic's OAuth usage endpoint, with the collector's caching and
/// failure rules.
public final class ClaudeUsageCollector: @unchecked Sendable {
  public static let authHelp = "Run `claude auth login` to restore authoritative usage."
  /// Repeated popup opens reuse a probe this recent.
  public static let probeMinInterval: TimeInterval = 15

  struct LimitsCache: Codable {
    var fetchedAt: Date
    var limits: [UsageLimit]
  }

  private let scanner: TranscriptScanner
  private let cacheDir: URL
  private let session: URLSession
  private let lock = NSLock()
  private var lastStats: UsageStats?

  public init(cacheDir: URL = ClaudeUsageCollector.defaultCacheDir, session: URLSession = .shared) {
    self.cacheDir = cacheDir
    self.session = session
    scanner = TranscriptScanner(
      projectsDir: ClaudeCredentials.claudeDir.appendingPathComponent("projects"),
      cacheURL: cacheDir.appendingPathComponent("claude-scan.json"))
  }

  public static var defaultCacheDir: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.ianneub.menu-widgets")
  }

  public enum Mode: Sendable { case normal, limitsOnly, force }

  public func collect(mode: Mode, now: Date = Date()) async -> UsageRecord {
    let stats = localStats(mode: mode, now: now)
    let login = ClaudeCredentials.load()
    var record = UsageRecord()
    record.stats = stats
    record.tierLabel = login.plan
    record.updatedAt = now
    await collectLimits(login: login, force: mode == .force, now: now, into: &record)
    return record
  }

  private func localStats(mode: Mode, now: Date) -> UsageStats {
    lock.lock()
    let cached = lastStats
    lock.unlock()
    // Opening the popup wants fresh limits, not another pass over the disk.
    if mode == .limitsOnly, let cached, cached.recentDays.last?.date == UsageFormat.dateString(now) {
      return cached
    }
    var stats = scanner.scan(now: now, force: mode == .force)
    let claudeDir = ClaudeCredentials.claudeDir
    if stats.totalPrompts <= 0 {
      if let fallback = ClaudeLocalFallback.statsCache(claudeDir: claudeDir, now: now) {
        stats = fallback
      } else {
        let (p, s) = ClaudeLocalFallback.todayFromHistory(claudeDir: claudeDir, now: now)
        stats.todayPrompts = p
        stats.todaySessions = s
      }
    }
    lock.lock()
    lastStats = stats
    lock.unlock()
    return stats
  }

  private var limitsCacheURL: URL { cacheDir.appendingPathComponent("claude-limits.json") }

  private func readLimitsCache() -> LimitsCache? {
    guard let data = try? Data(contentsOf: limitsCacheURL) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .secondsSince1970
    return try? dec.decode(LimitsCache.self, from: data)
  }

  private func writeLimitsCache(_ c: LimitsCache) {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .secondsSince1970
    guard let data = try? enc.encode(c) else { return }
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try? data.write(to: limitsCacheURL, options: .atomic)
  }

  func collectLimits(login: ClaudeLogin, force: Bool, now: Date, into record: inout UsageRecord) async {
    record.authHelpText = Self.authHelp
    let cached = readLimitsCache()
    let fallback = (cached?.limits ?? []).filter { UsageLimits.windowOpen($0, now: now) }

    if login.accessToken.isEmpty {
      record.limits = fallback
      record.usageStatusText = "Waiting for auth"
      return
    }
    if login.expiresAtMs > 0, login.expiresAtMs <= now.timeIntervalSince1970 * 1000 {
      record.limits = fallback
      record.usageStatusText = "Sign-in expired"
      record.authHelpText = "Claude Code's saved sign-in expired"
        + (fallback.isEmpty ? "." : " — showing the last known limits.")
        + " Start Claude Code, or run `claude auth login`, to refresh it."
      return
    }
    if !force, !fallback.isEmpty, let cached, now.timeIntervalSince(cached.fetchedAt) < Self.probeMinInterval {
      record.limits = fallback
      return
    }

    switch await probe(token: login.accessToken) {
    case let .success(limits):
      record.limits = limits
      writeLimitsCache(LimitsCache(fetchedAt: now, limits: limits))
    case let .failure(error):
      if error == .transport { record.retryAdvised = true }
      if !fallback.isEmpty {
        record.limits = fallback
      } else {
        record.usageStatusText = "Claude limits unavailable"
        record.authHelpText = error.helpText
      }
    }
  }

  func probe(token: String) async -> Result<[UsageLimit], UsageLimits.ProbeError> {
    var req = URLRequest(url: UsageLimits.endpoint, timeoutInterval: 10)
    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await session.data(for: req)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        return .failure(.status(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "retry-after")))
      }
      return UsageLimits.parse(data)
    } catch {
      return .failure(.transport)
    }
  }
}
