import Foundation

/// Gmail as PIM Bridge reports it: the accounts the bridge has signed in,
/// and each one's unread inbox messages, grouped into one item per thread.
public enum GmailMail {
  public static func accountID(_ email: String) -> String { "gmail:" + email.lowercased() }

  /// The search for an inbox's unread mail; `primaryOnly` keeps to the
  /// Primary category, like HEY's Imbox.
  public static func unreadQuery(primaryOnly: Bool) -> String {
    primaryOnly ? "is:unread in:inbox category:primary" : "is:unread in:inbox"
  }

  /// Opens an account's inbox, or one thread in it, in Gmail. Workspace
  /// accounts go by domain (`/a/<domain>/`), which picks the right signed-in
  /// account whatever its `u/N` index is. (The bridge's own links use
  /// `/mail/u/<email>/`, which Gmail answers with a 404 for Workspace
  /// accounts.)
  public static func webURL(email: String, threadID: String? = nil) -> URL {
    let domain = email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
    let base = ["gmail.com", "googlemail.com"].contains(domain) || domain.isEmpty
      ? "https://mail.google.com/mail/?authuser=" + (email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email)
      : "https://mail.google.com/a/\(domain)/"
    return URL(string: base + (threadID.map { "#inbox/" + $0 } ?? "#inbox"))!
  }

  public struct Account: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable {
      case signedIn = "signed_in", signingIn = "signing_in", needsSignIn = "needs_sign_in"
    }
    public var name: String
    public var email: String
    public var status: Status
    /// Why the account needs signing in again, in plain English.
    public var problem: String?
    public init(name: String, email: String, status: Status, problem: String? = nil) {
      self.name = name; self.email = email; self.status = status; self.problem = problem
    }

    public init(from decoder: Decoder) throws {
      enum K: String, CodingKey { case name, email, status, problem }
      let c = try decoder.container(keyedBy: K.self)
      email = try c.decode(String.self, forKey: .email)
      name = (try? c.decode(String.self, forKey: .name)) ?? email
      // A status this build doesn't know yet reads as "sign in again".
      status = (try? c.decode(Status.self, forKey: .status)) ?? .needsSignIn
      problem = try? c.decode(String.self, forKey: .problem)
    }
  }

  public struct Accounts: Decodable, Equatable, Sendable {
    public var accounts: [Account]
    /// A problem with Gmail as a whole (no OAuth client in the bridge, say).
    public var problem: String?
  }

  public static func accounts(json data: Data) throws -> Accounts {
    try JSONDecoder().decode(Accounts.self, from: data)
  }

  public struct Message: Equatable, Sendable {
    public var id: String
    public var threadID: String
    public var from: String
    public var subject: String
    public var snippet: String
    public var date: Date
    public init(id: String, threadID: String, from: String, subject: String, snippet: String, date: Date) {
      self.id = id; self.threadID = threadID; self.from = from; self.subject = subject
      self.snippet = snippet; self.date = date
    }
  }

  /// The bridge's `search` reply.
  public static func messages(searchJSON data: Data) throws -> [Message] {
    struct Raw: Decodable {
      let id: String
      let thread_id: String
      let from: String?
      let subject: String?
      let snippet: String?
      let date: String?
    }
    struct Reply: Decodable { let messages: [Raw]? }
    let iso = ISO8601DateFormatter()
    return try JSONDecoder().decode(Reply.self, from: data).messages?.map { r in
      Message(id: r.id, threadID: r.thread_id, from: r.from ?? "", subject: r.subject ?? "",
              snippet: r.snippet ?? "", date: r.date.flatMap(iso.date(from:)) ?? .distantPast)
    } ?? []
  }

  /// One item per thread, from its unread messages: the newest one's
  /// sender, subject and snippet, and how many are unread.
  public static func items(email: String, messages: [Message]) -> [MailItem] {
    let account = accountID(email)
    return Dictionary(grouping: messages, by: \.threadID).values.compactMap { msgs -> MailItem? in
      guard let newest = msgs.max(by: { $0.date < $1.date }) else { return nil }
      let subject = newest.subject.isEmpty ? "(no subject)" : newest.subject
      return MailItem(
        id: itemID(account: account, threadID: newest.threadID), account: account, revision: newest.id,
        sender: MailText.displayName(fromHeader: newest.from), subject: subject,
        snippet: MailText.cleanSnippet(newest.snippet), date: newest.date,
        url: webURL(email: email, threadID: newest.threadID), unread: msgs.count, trashID: newest.threadID)
    }
    .sorted { $0.date > $1.date }
  }

  static func itemID(account: String, threadID: String) -> String { "\(account):\(threadID)" }
}
