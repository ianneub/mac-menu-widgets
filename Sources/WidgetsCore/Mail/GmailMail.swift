import CryptoKit
import Foundation

/// The Gmail API calls the mail widget makes, and parsing their replies.
/// Read-only: the `gmail.metadata` scope sees labels, headers and snippets,
/// never message bodies.
public enum GmailMail {
  public static let api = "https://gmail.googleapis.com/gmail/v1/users/me"

  public static func accountID(_ email: String) -> String { "gmail:" + email.lowercased() }

  /// Unread inbox messages, newest first; Primary only unless `primaryOnly`
  /// is off. (Label ids AND together; `q` isn't allowed with this scope.)
  public static func listURL(primaryOnly: Bool, max: Int = 100) -> URL {
    var c = URLComponents(string: api + "/messages")!
    var labels = ["INBOX", "UNREAD"]
    if primaryOnly { labels.append("CATEGORY_PERSONAL") }
    c.queryItems = labels.map { URLQueryItem(name: "labelIds", value: $0) } + [URLQueryItem(name: "maxResults", value: String(max))]
    return c.url!
  }

  public static func messageURL(id: String) -> URL {
    var c = URLComponents(string: api + "/messages/" + id)!
    c.queryItems = [URLQueryItem(name: "format", value: "metadata")]
      + ["From", "Subject"].map { URLQueryItem(name: "metadataHeaders", value: $0) }
    return c.url!
  }

  public static let profileURL = URL(string: api + "/profile")!

  /// Opens a thread in Gmail for that account. Workspace accounts go by
  /// domain (`/a/<domain>/`), which picks the right signed-in account
  /// whatever its `u/N` index is.
  public static func webURL(email: String, threadID: String? = nil) -> URL {
    let domain = email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
    let base = ["gmail.com", "googlemail.com"].contains(domain) || domain.isEmpty
      ? "https://mail.google.com/mail/?authuser=" + (email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email)
      : "https://mail.google.com/a/\(domain)/"
    return URL(string: base + (threadID.map { "#inbox/" + $0 } ?? "#inbox"))!
  }

  public struct Ref: Decodable, Equatable, Sendable {
    public let id: String
    public let threadId: String
    public init(id: String, threadId: String) { self.id = id; self.threadId = threadId }
  }

  public static func refs(listJSON data: Data) throws -> [Ref] {
    struct List: Decodable { let messages: [Ref]? }
    return try JSONDecoder().decode(List.self, from: data).messages ?? []
  }

  public struct Message: Equatable, Sendable {
    public var id: String
    public var threadID: String
    public var from: String
    public var subject: String
    public var snippet: String
    public var date: Date
    public init(id: String, threadID: String, from: String, subject: String, snippet: String, date: Date) {
      self.id = id; self.threadID = threadID; self.from = from; self.subject = subject; self.snippet = snippet; self.date = date
    }
  }

  public static func message(json data: Data) throws -> Message {
    struct Header: Decodable { let name: String; let value: String }
    struct Payload: Decodable { let headers: [Header]? }
    struct Raw: Decodable {
      let id: String
      let threadId: String
      let snippet: String?
      let internalDate: String?
      let payload: Payload?
    }
    let r = try JSONDecoder().decode(Raw.self, from: data)
    func header(_ name: String) -> String {
      r.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
    let ms = Double(r.internalDate ?? "") ?? 0
    return Message(id: r.id, threadID: r.threadId, from: header("From"), subject: header("Subject"),
                   snippet: r.snippet ?? "", date: Date(timeIntervalSince1970: ms / 1000))
  }

  /// One item per thread, from its unread messages: the newest one's
  /// sender, subject and snippet, and how many are unread.
  public static func items(email: String, messages: [Message]) -> [MailItem] {
    let account = accountID(email)
    return Dictionary(grouping: messages, by: \.threadID).values.compactMap { msgs -> MailItem? in
      guard let newest = msgs.max(by: { $0.date < $1.date }) else { return nil }
      let subject = newest.subject.isEmpty ? "(no subject)" : newest.subject
      return MailItem(
        id: "\(account):\(newest.threadID)", account: account, revision: newest.id,
        sender: MailText.displayName(fromHeader: newest.from), subject: subject,
        snippet: MailText.cleanSnippet(newest.snippet), date: newest.date,
        url: webURL(email: email, threadID: newest.threadID), unread: msgs.count)
    }
    .sorted { $0.date > $1.date }
  }

  /// Google's error reply, `{"error": {"code": 403, "message": "..."}}`.
  public static func errorMessage(json data: Data) -> String? {
    struct E: Decodable { struct Body: Decodable { let message: String? }; let error: Body }
    return (try? JSONDecoder().decode(E.self, from: data))?.error.message
  }
}

/// Google OAuth for an installed app: the loopback redirect with PKCE, as
/// Google documents for desktop clients. The client id and secret come from
/// the "Desktop app" OAuth client the user creates (for installed apps the
/// secret isn't confidential; Google still asks for it).
public enum GoogleOAuth {
  public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
  public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
  public static let scope = "https://www.googleapis.com/auth/gmail.metadata"

  public struct Client: Equatable, Sendable {
    public var id: String
    public var secret: String
    public init(id: String, secret: String) { self.id = id; self.secret = secret }
  }

  /// The JSON the Cloud console downloads (`{"installed": {...}}`), or a
  /// bare `{"client_id": ..., "client_secret": ...}`.
  public static func client(json data: Data) -> Client? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let body = (obj["installed"] ?? obj["web"]) as? [String: Any] ?? obj
    guard let id = body["client_id"] as? String, !id.isEmpty else { return nil }
    return Client(id: id, secret: body["client_secret"] as? String ?? "")
  }

  /// A PKCE code verifier (RFC 7636: 43–128 unreserved characters).
  public static func makeVerifier() -> String {
    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return String((0..<64).map { _ in chars.randomElement()! })
  }

  public static func challenge(verifier: String) -> String {
    base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64url(_ d: Data) -> String {
    d.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func authURL(client: Client, redirect: String, verifier: String, state: String, loginHint: String) -> URL {
    var c = URLComponents(string: authEndpoint)!
    c.queryItems = [
      .init(name: "client_id", value: client.id),
      .init(name: "redirect_uri", value: redirect),
      .init(name: "response_type", value: "code"),
      .init(name: "scope", value: scope),
      .init(name: "code_challenge", value: challenge(verifier: verifier)),
      .init(name: "code_challenge_method", value: "S256"),
      .init(name: "state", value: state),
      .init(name: "login_hint", value: loginHint),
      // A refresh token every time, even if this client was allowed before.
      .init(name: "access_type", value: "offline"),
      .init(name: "prompt", value: "consent"),
    ]
    return c.url!
  }

  public enum Callback: Equatable {
    case code(String, state: String)
    case error(String)
    /// Not the redirect (a favicon request, say).
    case unrelated
  }

  /// Reads the browser's request to the loopback redirect, from its first
  /// line (`GET /?state=...&code=... HTTP/1.1`).
  public static func callback(requestLine: String) -> Callback {
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET",
          let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/" || c.path.isEmpty
    else { return .unrelated }
    let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    if let e = q["error"] { return .error(e) }
    guard let code = q["code"], !code.isEmpty else { return .unrelated }
    return .code(code, state: q["state"] ?? "")
  }

  public static func formBody(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(fields.map { k, v in
      "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
    }.joined(separator: "&").utf8)
  }

  public static func exchangeBody(client: Client, code: String, verifier: String, redirect: String) -> Data {
    formBody([("client_id", client.id), ("client_secret", client.secret), ("code", code),
              ("code_verifier", verifier), ("redirect_uri", redirect), ("grant_type", "authorization_code")])
  }

  public static func refreshBody(client: Client, refreshToken: String) -> Data {
    formBody([("client_id", client.id), ("client_secret", client.secret),
              ("refresh_token", refreshToken), ("grant_type", "refresh_token")])
  }

  public struct Token: Equatable, Sendable {
    public var access: String
    public var refresh: String?
    public var expires: Date
  }

  public enum TokenError: Error, Equatable {
    /// The refresh token was revoked or expired: sign in again.
    case invalidGrant(String)
    case other(String)
  }

  public static func token(json data: Data, now: Date = Date()) -> Result<Token, TokenError> {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(.other("unreadable reply from Google"))
    }
    if let err = obj["error"] as? String {
      let detail = obj["error_description"] as? String ?? err
      return .failure(err == "invalid_grant" ? .invalidGrant(detail) : .other(detail))
    }
    guard let access = obj["access_token"] as? String else { return .failure(.other("no access token in reply")) }
    let ttl = (obj["expires_in"] as? Double) ?? 3600
    return .success(Token(access: access, refresh: obj["refresh_token"] as? String,
                          expires: now.addingTimeInterval(ttl - 60)))
  }
}
