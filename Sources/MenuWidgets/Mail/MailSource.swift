import AppKit
import Foundation
import WidgetsCore

/// One inbox the widget watches (HEY, or a Gmail account): its unread
/// threads and whether it can be read at all. Subclasses fetch; the model
/// listens through `onUpdate` to diff and notify.
@MainActor
class MailSource: ObservableObject, Identifiable {
  enum Status: Equatable {
    case loading
    case ok
    /// Gmail: no OAuth client file yet (see the README).
    case needsSetup
    case needsSignIn
    case signingIn
    case error(String)

    var needsAttention: Bool {
      switch self {
      case .needsSetup, .needsSignIn, .error: return true
      default: return false
      }
    }
  }

  let id: String
  let name: String
  /// The inbox in the browser.
  let inboxURL: URL

  /// nil until the first successful read.
  @Published private(set) var items: [MailItem]?
  @Published var status: Status = .loading
  @Published private(set) var lastFetch: Date?

  /// Called after each successful read with the items before and after.
  var onUpdate: (MailSource, _ previous: [MailItem]?, _ previousFetch: Date?) -> Void = { _, _, _ in }

  init(id: String, name: String, inboxURL: URL) {
    self.id = id
    self.name = name
    self.inboxURL = inboxURL
  }

  var unread: Int { items?.count ?? 0 }

  func publish(_ new: [MailItem]) {
    let before = items
    let beforeFetch = lastFetch
    items = new
    lastFetch = Date()
    status = .ok
    onUpdate(self, before, beforeFetch)
  }

  /// Forget the list (signed out): the next read is a first look again, so
  /// the backlog doesn't come back as news.
  func clear() {
    items = nil
    lastFetch = nil
  }

  func refresh() {}
  func start() {}
  func stop() {}
}

/// Runs a command line tool and collects its output, off the main thread.
enum Command {
  struct Output { let status: Int32; let stdout: Data; let stderr: Data }

  /// launchd starts the app with a bare PATH; these are where tools usually live.
  static let searchPath: [String] = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let fromEnv = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return fromEnv + ["\(home)/.local/share/mise/shims", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
  }()

  static func resolve(_ name: String) -> String? {
    if name.contains("/") {
      let path = (name as NSString).expandingTildeInPath
      return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    return searchPath.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  static var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    var seen = Set<String>()
    env["PATH"] = searchPath.filter { seen.insert($0).inserted }.joined(separator: ":")
    return env
  }

  static func run(_ path: String, _ args: [String]) async throws -> Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = environment
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    return await withCheckedContinuation { cont in
      DispatchQueue.global().async {
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        cont.resume(returning: Output(status: p.terminationStatus, stdout: o, stderr: e))
      }
    }
  }
}
