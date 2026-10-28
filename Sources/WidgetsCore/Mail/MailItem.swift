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
  /// The sender's name, or their address when there's no name.
  public var sender: String
  /// The sender's email address; empty when the inbox doesn't say.
  public var address: String
  public var subject: String
  public var snippet: String
  public var date: Date
  /// Opens the conversation in the browser.
  public var url: URL
  /// Unread messages in the thread (Gmail); 1 for HEY.
  public var unread: Int
  /// What its inbox moves to the Trash: the Gmail thread id, or HEY's box
  /// item id. nil when it can't be trashed (a HEY bundle stands for a
  /// sender's stream, not one thread).
  public var trashID: String?

  public init(id: String, account: String, revision: String, sender: String, address: String = "", subject: String,
              snippet: String, date: Date, url: URL, unread: Int = 1, trashID: String? = nil) {
    self.id = id; self.account = account; self.revision = revision; self.sender = sender; self.address = address
    self.subject = subject; self.snippet = snippet; self.date = date; self.url = url; self.unread = unread
    self.trashID = trashID
  }

  /// The name with the address, as `Jane Doe <jane@example.com>`. The name
  /// alone is whatever the sender typed, so anyone can call themselves
  /// "PayPal"; the address says who it's really from.
  public var from: String {
    address.isEmpty || address.caseInsensitiveCompare(sender) == .orderedSame ? sender : "\(sender) <\(address)>"
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

/// What the mail widget opens: HEY's and Google's pages over https, and
/// nothing else, whatever a reply says. A link from HEY's server or PIM
/// Bridge that pointed at a file, a network share or another app would
/// otherwise open on a click.
public enum MailLinks {
  static let hosts = ["hey.com", "google.com"]

  public static func opens(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
    return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
  }
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

  /// "jane@example.com" from `"Jane Doe" <jane@example.com>`, or from a bare
  /// address; empty when the header has none.
  public static func address(fromHeader raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if let lt = s.lastIndex(of: "<") {
      return String(s[s.index(after: lt)...].prefix { $0 != ">" }).trimmingCharacters(in: .whitespaces)
    }
    let bare = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return bare.contains("@") && !bare.contains(" ") ? bare : ""
  }

  /// A sender, subject or snippet made safe to show on one line: no bidi
  /// controls, which can make text read differently from what it is (an
  /// override turns "\u{202E}fdp.exe" into "exe.pdf" on screen), no
  /// invisible characters, and line breaks and control characters as
  /// spaces. Joiners stay, since emoji and some scripts need them.
  public static func plain(_ s: String) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: s.unicodeScalars.filter { !hidden($0) })
    return String(scalars)
      .replacingOccurrences(of: "[\\s\\p{Cc}]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  static func hidden(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x061C, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF: return true
    default: return false
    }
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
    // Entities can spell out bidi controls too, so this comes after them.
    return plain(out.replacingOccurrences(of: "[\\s\u{200C}\u{034F}]+", with: " ", options: .regularExpression))
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
