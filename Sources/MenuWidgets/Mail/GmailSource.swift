import AppKit
import Foundation
import WidgetsCore

/// Gmail through PIM Bridge, which owns the Google sign-in: the accounts
/// are whatever the bridge has, and each poll asks it for the account list
/// and then each signed-in account's unread inbox. Polls every `interval`
/// seconds, and every few seconds while an account is signing in.
@MainActor
final class GmailHub: ObservableObject {
  enum State: Equatable {
    case connecting
    case ok
    case failed(BridgeClient.Failure)
  }

  @Published private(set) var state: State = .connecting
  /// The bridge's word on Gmail as a whole (no OAuth client set up, say).
  @Published private(set) var problem: String?
  /// One per account, in the bridge's order.
  @Published private(set) var sources: [GmailSource] = []
  /// Called when accounts come or go, so the model can watch the new ones.
  var onSourcesChanged: () -> Void = {}

  private let client = BridgeClient()
  private let primaryOnly: Bool
  private let interval: TimeInterval
  private var timer: Timer?
  private var fetching = false
  private var again = false
  private var stopped = false

  init(primaryOnly: Bool, interval: TimeInterval) {
    self.primaryOnly = primaryOnly
    self.interval = interval
  }

  var needsAttention: Bool {
    if case .failed = state { return true }
    return problem != nil
  }

  var lastFetch: Date? { sources.compactMap(\.lastFetch).max() }

  func start() { refresh() }

  func stop() {
    stopped = true
    timer?.invalidate()
    timer = nil
    client.disconnect()
  }

  func refresh() {
    guard !stopped else { return }
    if fetching { again = true; return }
    fetching = true
    timer?.invalidate()
    Task {
      await poll()
      fetching = false
      if again { again = false; refresh() } else { schedule() }
    }
  }

  private func schedule() {
    guard !stopped else { return }
    let signingIn = sources.contains { $0.status == .signingIn }
    let t = Timer(timeInterval: signingIn ? 3 : interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func poll() async {
    let list: GmailMail.Accounts
    do {
      list = try GmailMail.accounts(json: try await client.call("accounts"))
    } catch {
      // Keep the accounts and their last lists; the panel says what's wrong.
      state = .failed(Self.failure(error))
      return
    }
    state = .ok
    problem = list.problem
    reconcile(list.accounts)
    for s in sources where s.account.status == .signedIn {
      do {
        let data = try await client.call("search", [
          "account": s.email, "query": GmailMail.unreadQuery(primaryOnly: primaryOnly), "max": 100,
        ])
        s.publishFromBridge(GmailMail.items(email: s.email, messages: try GmailMail.messages(searchJSON: data)))
      } catch {
        let f = Self.failure(error)
        if f == .notRunning || f == .refused { state = .failed(f); return }
        s.status = .error(f.message)
      }
    }
  }

  /// Matches the bridge's accounts to sources, keeping a source (and its
  /// last list, which the diff needs) while its account stays the same.
  private func reconcile(_ accounts: [GmailMail.Account]) {
    let old = Dictionary(sources.map { ($0.email, $0) }, uniquingKeysWith: { a, _ in a })
    let next = accounts.map { a -> GmailSource in
      let email = a.email.lowercased()
      if let s = old[email], s.name == a.name { s.update(a); return s }
      let s = GmailSource(account: a, hub: self)
      s.update(a)
      return s
    }
    if next.map(ObjectIdentifier.init) != sources.map(ObjectIdentifier.init) {
      sources = next
      onSourcesChanged()
    }
  }

  static func failure(_ error: Error) -> BridgeClient.Failure {
    if let f = error as? BridgeClient.Failure { return f }
    if error is DecodingError { return .other("PIM Bridge sent a reply MenuWidgets can't read.") }
    return .other(error.localizedDescription)
  }

  // MARK: actions

  func signIn(_ s: GmailSource) {
    s.status = .signingIn
    Task {
      do {
        let data = try await client.call("sign_in", ["email": s.email])
        struct Reply: Decodable { let url: String? }
        s.signInURL = (try? JSONDecoder().decode(Reply.self, from: data))?.url.flatMap(URL.init(string:))
      } catch {
        s.status = .error(Self.failure(error).message)
      }
      refresh()
    }
  }

  func signOut(_ s: GmailSource) {
    Task {
      do {
        _ = try await client.call("sign_out", ["account": s.email])
      } catch {
        s.status = .error(Self.failure(error).message)
      }
      refresh()
    }
  }

  /// Moves whole threads to the Trash, or back out of it (`undo`).
  func move(threads: [String], in s: GmailSource, undo: Bool) async throws {
    let data = try await client.call(undo ? "untrash_thread" : "trash_thread",
                                     ["account": s.email, "thread_ids": threads])
    let result = try PIMBridge.threadMove(json: data)
    if let first = result.failed.first { throw BridgeClient.Failure.tool(first.error) }
  }
}

/// One Gmail account as the bridge reports it.
@MainActor
final class GmailSource: MailSource {
  let email: String
  private(set) var account: GmailMail.Account
  /// Why the account has to sign in again, from the bridge.
  @Published private(set) var problem: String?
  /// The Google page for a sign-in under way, to open it again.
  @Published var signInURL: URL?
  private weak var hub: GmailHub?
  /// Threads trashed from the panel, kept out of the list until the
  /// bridge's search stops returning them (one already under way may not).
  private var trashed: Set<String> = []

  init(account: GmailMail.Account, hub: GmailHub) {
    email = account.email.lowercased()
    self.account = account
    self.hub = hub
    super.init(id: GmailMail.accountID(account.email), name: account.name,
               inboxURL: GmailMail.webURL(email: account.email))
  }

  var signedIn: Bool { account.status == .signedIn }

  func update(_ a: GmailMail.Account) {
    let was = account.status
    account = a
    problem = a.problem
    switch a.status {
    case .signedIn:
      signInURL = nil
      if was != .signedIn || status == .needsSignIn || status == .signingIn { status = .loading }
    case .signingIn:
      status = .signingIn
    case .needsSignIn:
      // Forget the list: after signing in again the backlog isn't news.
      clear()
      signInURL = nil
      status = .needsSignIn
    }
  }

  func publishFromBridge(_ items: [MailItem]) {
    let ids = Set(items.map(\.id))
    trashed.formIntersection(ids)
    publish(items.filter { !trashed.contains($0.id) })
  }

  override func refresh() { hub?.refresh() }

  func signIn() { hub?.signIn(self) }
  func signOut() { hub?.signOut(self) }

  /// Trashes an item's thread: off the list at once, then over the socket.
  /// On failure it comes back with the error shown.
  func trash(_ item: MailItem) async -> Bool {
    guard let hub, let thread = GmailMail.threadID(itemID: item.id, email: email) else { return false }
    trashed.insert(item.id)
    remove(ids: [item.id])
    do {
      try await hub.move(threads: [thread], in: self, undo: false)
      return true
    } catch {
      trashed.remove(item.id)
      restore([item])
      status = .error(GmailHub.failure(error).message)
      return false
    }
  }

  func untrash(_ item: MailItem) async {
    guard let hub, let thread = GmailMail.threadID(itemID: item.id, email: email) else { return }
    do {
      try await hub.move(threads: [thread], in: self, undo: true)
      trashed.remove(item.id)
      restore([item])
    } catch {
      status = .error(GmailHub.failure(error).message)
    }
    hub.refresh()
  }
}
