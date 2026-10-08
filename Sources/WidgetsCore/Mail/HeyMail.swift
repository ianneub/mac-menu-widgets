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
      guard p.seen != true, let url = URL(string: p.app_url ?? "https://app.hey.com/imbox") else { return nil }
      let date = p.active_at.flatMap(parseDate) ?? Date.distantPast
      let thread = p.topic_id ?? p.id
      let sender = [p.alternative_sender_name, p.creator?.name].compactMap { $0 }.first { !$0.isEmpty } ?? "HEY"
      return MailItem(
        id: "hey:\(thread)", account: accountID, revision: p.active_at ?? "",
        sender: sender, subject: p.name ?? "(no subject)", snippet: MailText.cleanSnippet(p.summary ?? ""),
        date: date, url: url)
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
    let seen: Bool?
    let name: String?
    let summary: String?
    let alternative_sender_name: String?
    let creator: Creator?
    let active_at: String?
    let app_url: String?
  }
  private struct Creator: Decodable { let name: String? }
}
