import Foundation

/// PIM Bridge's local socket: JSON-RPC 2.0, one JSON object per line each
/// way, serving the bridge's Gmail tools. The bridge owns the Google
/// sign-in and tokens; MenuWidgets only asks it for things.
public enum PIMBridge {
  public static var socketPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/PIMBridge/bridge.sock").path
  }

  public static let logPath = "~/Library/Logs/PIMBridge.log"

  public static let identifier = "com.ianneub.pim-bridge"

  /// The code requirement the process at the socket must meet before
  /// MenuWidgets talks to it, the mirror of the bridge's check on
  /// MenuWidgets: PIM Bridge's identifier, signed with MenuWidgets' Apple
  /// Team ID, or with the same certificate when there's no team (a
  /// self-signed identity). nil when MenuWidgets is signed ad hoc, which
  /// leaves nothing to pin.
  public static func requirement(teamID: String?, leafSHA1: String?) -> String? {
    let signer: String
    if let teamID, !teamID.isEmpty {
      signer = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    } else if let leafSHA1, !leafSHA1.isEmpty {
      signer = "certificate leaf = H\"\(leafSHA1)\""
    } else {
      return nil
    }
    return "identifier \"\(identifier)\" and \(signer)"
  }

  /// Whether a running process's code-signing status (`kSecCodeInfoStatus`)
  /// is one to trust: valid, under the hardened runtime, and closed to
  /// debuggers (no get-task-allow), so no other code can be running inside it.
  public static func trustedStatus(_ status: UInt32) -> Bool {
    let valid: UInt32 = 0x1, getTaskAllow: UInt32 = 0x4, runtime: UInt32 = 0x10000
    return status & valid != 0 && status & runtime != 0 && status & getTaskAllow == 0
  }

  /// A `tools/call` request, newline included.
  public static func request(id: Int, tool: String, arguments: [String: Any]) -> Data {
    let body: [String: Any] = [
      "jsonrpc": "2.0", "id": id, "method": "tools/call",
      "params": ["name": tool, "arguments": arguments],
    ]
    var d = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    d.append(0x0A)
    return d
  }

  public enum ReplyError: Error, Equatable {
    /// The tool ran and failed; the bridge's plain-English message.
    case tool(String)
    /// JSON-RPC itself failed (unknown tool, bad arguments).
    case rpc(String)
    case malformed
  }

  /// One reply line: the tool's own JSON, which the bridge sends as a
  /// string inside `result.content[0].text`.
  public static func reply(_ line: Data) -> (id: Int?, result: Result<Data, ReplyError>) {
    struct Content: Decodable { let type: String?; let text: String? }
    struct ToolResult: Decodable { let content: [Content]?; let isError: Bool? }
    struct RPCError: Decodable { let message: String? }
    struct Reply: Decodable { let id: Int?; let result: ToolResult?; let error: RPCError? }
    guard let r = try? JSONDecoder().decode(Reply.self, from: line) else { return (nil, .failure(.malformed)) }
    if let e = r.error { return (r.id, .failure(.rpc(e.message ?? "PIM Bridge returned an error"))) }
    guard let result = r.result else { return (r.id, .failure(.malformed)) }
    let text = result.content?.first { $0.type == nil || $0.type == "text" }?.text ?? ""
    if result.isError == true { return (r.id, .failure(.tool(text.isEmpty ? "PIM Bridge returned an error" : text))) }
    return (r.id, .success(Data(text.utf8)))
  }

  /// `trash_thread` and `untrash_thread`: which threads moved, and why the
  /// others didn't.
  public struct ThreadMove: Equatable, Sendable {
    public var moved: [String]
    public var failed: [(id: String, error: String)]
    public static func == (a: Self, b: Self) -> Bool {
      a.moved == b.moved && a.failed.map(\.id) == b.failed.map(\.id) && a.failed.map(\.error) == b.failed.map(\.error)
    }
  }

  public static func threadMove(json data: Data) throws -> ThreadMove {
    struct Done: Decodable { let thread_id: String }
    struct Failed: Decodable { let thread_id: String; let error: String? }
    struct Reply: Decodable { let trashed: [Done]?; let untrashed: [Done]?; let failed: [Failed]? }
    let r = try JSONDecoder().decode(Reply.self, from: data)
    return ThreadMove(moved: (r.trashed ?? r.untrashed ?? []).map(\.thread_id),
                      failed: (r.failed ?? []).map { ($0.thread_id, $0.error ?? "failed") })
  }
}
