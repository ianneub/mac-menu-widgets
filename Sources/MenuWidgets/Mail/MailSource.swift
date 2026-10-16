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
    case needsSignIn
    case signingIn
    case error(String)

    var needsAttention: Bool {
      switch self {
      case .needsSignIn, .error: return true
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
  /// Trashed from the panel: kept off the list until a read stops
  /// returning them (one already under way may not know yet).
  private var hidden: Set<String> = []

  /// A failed action, in words for the panel.
  struct ActionError: Error { let message: String }

  init(id: String, name: String, inboxURL: URL) {
    self.id = id
    self.name = name
    self.inboxURL = inboxURL
  }

  var unread: Int { items?.count ?? 0 }

  func publish(_ fresh: [MailItem]) {
    hidden.formIntersection(fresh.map(\.id))
    let new = fresh.filter { !hidden.contains($0.id) }
    let before = items
    let beforeFetch = lastFetch
    items = new
    lastFetch = Date()
    status = .ok
    onUpdate(self, before, beforeFetch)
  }

  /// Takes items off the list now (trashed from the panel) without
  /// waiting for the next read; their banners are withdrawn.
  func remove(ids: Set<String>) {
    hidden.formUnion(ids)
    guard let before = items else { return }
    items = before.filter { !ids.contains($0.id) }
    onUpdate(self, before, lastFetch)
  }

  /// Puts items back (an undone trash) quietly: they aren't news.
  func restore(_ back: [MailItem]) {
    hidden.subtract(back.map(\.id))
    guard let current = items else { return }
    let have = Set(current.map(\.id))
    items = current + back.filter { !have.contains($0.id) }
  }

  // MARK: trash

  /// Whether this inbox can trash an item, and take it back out.
  var canTrash: Bool { false }
  var canUndoTrash: Bool { false }

  /// Subclasses do the moving; they throw ActionError.
  func moveToTrash(_ ids: [String]) async throws { throw ActionError(message: "This inbox can't trash mail.") }
  func moveOutOfTrash(_ ids: [String]) async throws { throw ActionError(message: "This inbox can't undo a trash.") }

  /// Trashes an item: off the list at once, then in the service. On
  /// failure it comes back with the error shown.
  func trash(_ item: MailItem) async -> Bool {
    guard canTrash, let key = item.trashID else { return false }
    remove(ids: [item.id])
    do {
      try await moveToTrash([key])
      return true
    } catch {
      restore([item])
      status = .error((error as? ActionError)?.message ?? error.localizedDescription)
      return false
    }
  }

  func untrash(_ item: MailItem) async {
    guard canUndoTrash, let key = item.trashID else { return }
    do {
      try await moveOutOfTrash([key])
      restore([item])
    } catch {
      status = .error((error as? ActionError)?.message ?? error.localizedDescription)
    }
    refresh()
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
    let exited = try p.runSignalingExit()
    return await withCheckedContinuation { cont in
      DispatchQueue.global().async {
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        cont.resume(returning: Output(status: p.terminationStatus, stdout: o, stderr: e))
      }
    }
  }
}
