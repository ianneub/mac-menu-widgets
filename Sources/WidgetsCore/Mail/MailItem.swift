import Foundation

/// One unread conversation in one inbox: a HEY Imbox thread not yet seen,
/// or a Gmail thread with unread mail in the Primary inbox.
public struct MailItem: Equatable, Sendable, Identifiable {
  /// Unique across accounts ("gmail:<email>:<thread>", "hey:<topic>").
  public var id: String
  /// The account it belongs to (MailAccountID).
  public var account: String
  /// What changes when new mail lands on the thread: Gmail's newest unread
  /// message id, HEY's posting activity time. A change means "notify again".
  public var revision: String
  public var sender: String
  public var subject: String
  public var snippet: String
  public var date: Date
  /// Opens the conversation in the browser.
  public var url: URL
  /// Unread messages in the thread (Gmail); 1 for HEY.
  public var unread: Int

  public init(id: String, account: String, revision: String, sender: String, subject: String,
              snippet: String, date: Date, url: URL, unread: Int = 1) {
    self.id = id; self.account = account; self.revision = revision; self.sender = sender
    self.subject = subject; self.snippet = snippet; self.date = date; self.url = url; self.unread = unread
  }
}

/// What to tell the user about one refresh of an inbox.
public struct MailNews: Equatable, Sendable {
  /// Threads that are new, or have new mail, since the last look.
  public var fresh: [MailItem]
  /// Ids of threads that were unread and no longer are (read elsewhere,
  /// archived): their notifications can be withdrawn.
  public var gone: [String]
}

public enum MailDiff {
  /// Compares an inbox's unread threads with the previous look, taken at
  /// `since`. `previous` nil means this is the first look: everything is a
  /// backlog, nothing is news. Mail dated well before the previous look is
  /// old mail marked unread again, not news either.
  public static func news(previous: [MailItem]?, since: Date?, current: [MailItem]) -> MailNews {
    guard let previous else { return MailNews(fresh: [], gone: []) }
    let before = Dictionary(previous.map { ($0.id, $0.revision) }, uniquingKeysWith: { a, _ in a })
    let cutoff = since.map { $0.addingTimeInterval(-staleSlack) } ?? .distantPast
    let fresh = current.filter { before[$0.id] != $0.revision && $0.date >= cutoff }
    let now = Set(current.map(\.id))
    let gone = previous.map(\.id).filter { !now.contains($0) }
    return MailNews(fresh: fresh.sorted { $0.date > $1.date }, gone: gone)
  }

  /// Allowance for clock skew and delivery delay between a message's date
  /// and when it shows up in the inbox.
  public static let staleSlack: TimeInterval = 15 * 60

  /// Above this many fresh threads at once (say, after the Mac wakes), an
  /// account gets one summary banner instead of one per thread.
  public static let bannerLimit = 3
}

public enum MailText {
  /// "Jane Doe" from `"Jane Doe" <jane@example.com>`; the address when
  /// there's no name.
  public static func displayName(fromHeader raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if let lt = s.firstIndex(of: "<") {
      let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
      if !name.isEmpty { return name }
      let rest = s[s.index(after: lt)...]
      return String(rest.prefix { $0 != ">" })
    }
    return s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  /// Gmail and HEY snippets carry HTML entities (`&#39;`, `&amp;`) and runs
  /// of whitespace.
  public static func cleanSnippet(_ s: String) -> String {
    var out = s
    let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
    for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
    while let r = out.range(of: "&#(x?[0-9A-Fa-f]+);", options: .regularExpression) {
      let body = out[r].dropFirst(2).dropLast()
      let code = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
      out.replaceSubrange(r, with: code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
    }
    out = out.replacingOccurrences(of: "[\\s\u{200C}\u{034F}]+", with: " ", options: .regularExpression)
    return out.trimmingCharacters(in: .whitespaces)
  }

  /// "3:04 PM" today, "Yesterday", "Tue", or "Sep 23" in the panel.
  public static func age(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) {
      f.dateFormat = "h:mm a"
    } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
      return "Yesterday"
    } else if now.timeIntervalSince(date) < 6 * 86400 {
      f.dateFormat = "EEE"
    } else {
      f.dateFormat = "MMM d"
    }
    return f.string(from: date)
  }
}
