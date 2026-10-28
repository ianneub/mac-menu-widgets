import Foundation

/// Reading the `hey` CLI's output: `hey box view imbox --json` for the
/// Imbox, and `hey watch --box imbox` lines as the signal to read it again.
public enum HeyMail {
  public static let accountID = "hey"

  /// The Imbox's unseen threads. HEY lists them first ("New for you"),
  /// then the seen ones; a posting without `"seen": true` is unseen.
  public static func unseen(boxJSON data: Data) throws -> [MailItem] {
    let root = try JSONDecoder().decode(Root.self, from: data)
    return root.data.postings.compactMap { p in
      guard p.seen != true else { return nil }
      let date = p.active_at.flatMap(parseDate) ?? Date.distantPast
      let thread = p.topic_id ?? p.id
      let sender = [p.alternative_sender_name, p.creator?.name].compactMap { $0.map(MailText.plain) }.first { !$0.isEmpty } ?? "HEY"
      let subject = MailText.plain(p.name ?? "")
      return MailItem(
        id: "hey:\(thread)", account: accountID, revision: p.active_at ?? "",
        sender: sender, address: MailText.plain(p.creator?.email_address ?? ""),
        subject: subject.isEmpty ? "(no subject)" : subject, snippet: MailText.cleanSnippet(p.summary ?? ""),
        date: date, url: webURL(p.app_url),
        // `hey trash` takes the box item id. A bundle row "trashes" with
        // success and nothing moves, so it gets no trash button.
        trashID: p.kind == nil || p.kind == "topic" ? String(p.id) : nil)
    }
  }

  /// What a `hey watch` line means for the widget.
  public enum WatchSignal: Equatable {
    /// The subscription is live (again): reread the box.
    case ready
    /// Something in the box changed: reread it.
    case changed
    case disconnected
    case other
  }

  public static func watchSignal(line: String) -> WatchSignal {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let change = obj["change"] as? String
    else { return .other }
    switch change {
    case "ready": return .ready
    case "disconnected": return .disconnected
    case "added", "updated", "deleted", "resync": return .changed
    default: return .other
    }
  }

  public static let imboxURL = URL(string: "https://app.hey.com/imbox")!

  /// A posting's page in HEY, or the Imbox when it has none (or one that
  /// isn't HEY's).
  static func webURL(_ s: String?) -> URL {
    guard let url = s.flatMap(URL.init(string:)), MailLinks.opens(url) else { return imboxURL }
    return url
  }

  static func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
  }

  private struct Root: Decodable { let data: Box }
  private struct Box: Decodable { let postings: [Posting] }
  private struct Posting: Decodable {
    let id: Int
    let topic_id: Int?
    let kind: String?
    let seen: Bool?
    let name: String?
    let summary: String?
    let alternative_sender_name: String?
    let creator: Creator?
    let active_at: String?
    let app_url: String?
  }
  private struct Creator: Decodable { let name: String?; let email_address: String? }
}
