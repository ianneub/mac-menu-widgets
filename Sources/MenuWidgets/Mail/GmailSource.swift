import AppKit
import Foundation
import Network
import WidgetsCore

/// One Gmail account through the Gmail API, polled every `interval`
/// seconds: list the unread Primary inbox messages, then fetch headers for
/// the ones not seen before. Signs in with the browser (OAuth, loopback
/// redirect); the refresh token lives in the Keychain.
@MainActor
final class GmailSource: MailSource {
  let email: String
  private let primaryOnly: Bool
  private let interval: TimeInterval
  private var access: GoogleOAuth.Token?
  /// The refresh token, read from the Keychain once and kept here.
  private var refreshToken: String?
  private var cache: [String: GmailMail.Message] = [:]
  private var poll: Timer?
  private var fetching = false
  private var signIn: LoopbackSignIn?

  /// The "Desktop app" OAuth client from the Google Cloud console, saved
  /// as downloaded.
  static var clientFile: URL { WidgetsConfig.directory.appendingPathComponent("google-oauth-client.json") }

  static func loadClient() -> GoogleOAuth.Client? {
    (try? Data(contentsOf: clientFile)).flatMap(GoogleOAuth.client(json:))
  }

  init(account: WidgetsConfig.MailSettings.GmailAccount, primaryOnly: Bool, interval: TimeInterval) {
    email = account.email.lowercased()
    self.primaryOnly = primaryOnly
    self.interval = interval
    super.init(id: GmailMail.accountID(account.email), name: account.name,
               inboxURL: GmailMail.webURL(email: account.email))
    refreshToken = Keychain.read(email)
  }

  var signedIn: Bool { refreshToken != nil }

  override func start() {
    refresh()
    let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    RunLoop.main.add(t, forMode: .common)
    poll = t
  }

  override func stop() {
    poll?.invalidate()
    poll = nil
    signIn?.cancel()
    signIn = nil
  }

  override func refresh() {
    guard !fetching, status != .signingIn else { return }
    guard let client = Self.loadClient() else { status = .needsSetup; return }
    guard let refreshToken else { status = .needsSignIn; return }
    fetching = true
    Task {
      defer { fetching = false }
      do {
        publish(try await fetchItems(client: client, refreshToken: refreshToken))
      } catch let e as GoogleOAuth.TokenError {
        if case .invalidGrant = e {
          Keychain.delete(email)
          self.refreshToken = nil
          clear()
          status = .needsSignIn
        } else if case .other(let msg) = e {
          status = .error(msg)
        }
      } catch let e as GmailError {
        status = .error(e.message)
      } catch {
        // Offline and the like: keep the last list, say so in the panel.
        status = .error(error.localizedDescription)
      }
    }
  }

  // MARK: Gmail API

  struct GmailError: Error { let message: String }

  private func fetchItems(client: GoogleOAuth.Client, refreshToken: String) async throws -> [MailItem] {
    let list = try await get(GmailMail.listURL(primaryOnly: primaryOnly), client: client, refreshToken: refreshToken)
    let refs = try GmailMail.refs(listJSON: list)
    let missing = refs.map(\.id).filter { cache[$0] == nil }
    if !missing.isEmpty {
      let token = try await accessToken(client: client, refreshToken: refreshToken)
      let fetched = try await withThrowingTaskGroup(of: GmailMail.Message.self) { group in
        for id in missing {
          group.addTask { try await Self.fetchMessage(id: id, token: token) }
        }
        var out: [GmailMail.Message] = []
        for try await m in group { out.append(m) }
        return out
      }
      for m in fetched { cache[m.id] = m }
    }
    let live = Set(refs.map(\.id))
    cache = cache.filter { live.contains($0.key) }
    return GmailMail.items(email: email, messages: Array(cache.values))
  }

  private nonisolated static func fetchMessage(id: String, token: String) async throws -> GmailMail.Message {
    var req = URLRequest(url: GmailMail.messageURL(id: id))
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
      throw GmailError(message: GmailMail.errorMessage(json: data) ?? "Gmail returned an error")
    }
    return try GmailMail.message(json: data)
  }

  /// GET with the account's token; a 401 drops the token and tries once more.
  private func get(_ url: URL, client: GoogleOAuth.Client, refreshToken: String, retried: Bool = false) async throws -> Data {
    let token = try await accessToken(client: client, refreshToken: refreshToken)
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401, !retried {
      access = nil
      return try await get(url, client: client, refreshToken: refreshToken, retried: true)
    }
    guard code == 200 else {
      throw GmailError(message: GmailMail.errorMessage(json: data) ?? "Gmail returned HTTP \(code)")
    }
    return data
  }

  private func accessToken(client: GoogleOAuth.Client, refreshToken: String) async throws -> String {
    if let a = access, a.expires > Date() { return a.access }
    let t = try await Self.tokenRequest(GoogleOAuth.refreshBody(client: client, refreshToken: refreshToken))
    access = t
    return t.access
  }

  nonisolated static func tokenRequest(_ body: Data) async throws -> GoogleOAuth.Token {
    var req = URLRequest(url: GoogleOAuth.tokenEndpoint)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    let (data, _) = try await URLSession.shared.data(for: req)
    return try GoogleOAuth.token(json: data).get()
  }

  // MARK: sign-in

  func startSignIn() {
    guard let client = Self.loadClient() else { status = .needsSetup; return }
    signIn?.cancel()
    status = .signingIn
    let flow = LoopbackSignIn(client: client, email: email)
    signIn = flow
    flow.run { [weak self] result in
      guard let self else { return }
      self.signIn = nil
      switch result {
      case .success(let token):
        guard let refresh = token.refresh else { self.status = .error("Google didn't return a refresh token."); return }
        Keychain.save(self.email, refresh)
        self.refreshToken = refresh
        self.access = token
        self.status = .loading
        self.refresh()
      case .failure(let e):
        self.status = e.message.isEmpty ? .needsSignIn : .error(e.message)
      }
    }
  }

  func cancelSignIn() {
    signIn?.cancel()
    signIn = nil
    status = signedIn ? .ok : .needsSignIn
  }

  func signOut() {
    Keychain.delete(email)
    refreshToken = nil
    access = nil
    cache = [:]
    clear()
    status = .needsSignIn
  }
}

/// The browser half of Google sign-in: listen on 127.0.0.1, send the
/// browser to Google, take the code from the redirect, trade it for tokens,
/// and check the account is the one asked for.
@MainActor
final class LoopbackSignIn {
  struct Failure: Error { let message: String }

  private let client: GoogleOAuth.Client
  private let email: String
  private let verifier = GoogleOAuth.makeVerifier()
  private let state = UUID().uuidString
  private var listener: NWListener?
  private var timeout: DispatchWorkItem?
  private var done: ((Result<GoogleOAuth.Token, Failure>) -> Void)?

  init(client: GoogleOAuth.Client, email: String) {
    self.client = client
    self.email = email
  }

  func run(_ completion: @escaping (Result<GoogleOAuth.Token, Failure>) -> Void) {
    done = completion
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    guard let l = try? NWListener(using: params) else { finish(.failure(Failure(message: "Couldn't listen for the sign-in."))); return }
    listener = l
    l.stateUpdateHandler = { [weak self] st in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          switch st {
          case .ready:
            guard let port = self.listener?.port?.rawValue else { return }
            let redirect = "http://127.0.0.1:\(port)"
            NSWorkspace.shared.open(GoogleOAuth.authURL(client: self.client, redirect: redirect,
                                                        verifier: self.verifier, state: self.state, loginHint: self.email))
          case .failed(let e):
            self.finish(.failure(Failure(message: "Sign-in listener failed: \(e.localizedDescription)")))
          default: break
          }
        }
      }
    }
    l.newConnectionHandler = { [weak self] conn in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
    }
    l.start(queue: .main)
    let t = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.finish(.failure(Failure(message: "Sign-in timed out."))) }
    }
    timeout = t
    DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: t)
  }

  func cancel() {
    done = nil
    stop()
  }

  private func stop() {
    timeout?.cancel()
    listener?.cancel()
    listener = nil
  }

  private func finish(_ r: Result<GoogleOAuth.Token, Failure>) {
    stop()
    let d = done
    done = nil
    d?(r)
  }

  private func accept(_ conn: NWConnection) {
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.handle(conn, String(decoding: data ?? Data(), as: UTF8.self)) }
      }
    }
  }

  private func handle(_ conn: NWConnection, _ request: String) {
    let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
    switch GoogleOAuth.callback(requestLine: firstLine) {
    case .unrelated:
      respond(conn, status: "404 Not Found", body: "")
    case .error(let e):
      respond(conn, body: page("Sign-in cancelled", "Google said: \(e). You can close this tab."))
      finish(.failure(Failure(message: e == "access_denied" ? "" : "Google sign-in failed: \(e)")))
    case .code(let code, let st):
      guard st == state else {
        respond(conn, status: "400 Bad Request", body: page("Sign-in failed", "The reply didn't match this sign-in."))
        return
      }
      respond(conn, body: page("Signed in", "MenuWidgets can now check \(email) for new mail. You can close this tab."))
      exchange(code: code, redirect: "http://127.0.0.1:\(listener?.port?.rawValue ?? 0)")
    }
  }

  private func exchange(code: String, redirect: String) {
    let body = GoogleOAuth.exchangeBody(client: client, code: code, verifier: verifier, redirect: redirect)
    listener?.cancel()
    Task {
      do {
        let token = try await GmailSource.tokenRequest(body)
        // Make sure the browser signed in the account this row is for.
        var req = URLRequest(url: GmailMail.profileURL)
        req.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let got = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["emailAddress"] as? String ?? ""
        guard got.lowercased() == email else {
          finish(.failure(Failure(message: got.isEmpty ? "Couldn't confirm the account." : "Signed in as \(got), not \(email). Try again and pick \(email).")))
          return
        }
        finish(.success(token))
      } catch let e as GoogleOAuth.TokenError {
        if case .invalidGrant(let m) = e { finish(.failure(Failure(message: m))) }
        else if case .other(let m) = e { finish(.failure(Failure(message: m))) }
      } catch {
        finish(.failure(Failure(message: error.localizedDescription)))
      }
    }
  }

  private func page(_ title: String, _ text: String) -> String {
    let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
    return """
    <!doctype html><meta charset="utf-8"><title>\(esc(title))</title>
    <body style="font: 15px -apple-system, system-ui, sans-serif; max-width: 32em; margin: 15vh auto; padding: 0 16px">
    <h2>\(esc(title))</h2><p>\(esc(text))</p></body>
    """
  }

  private func respond(_ conn: NWConnection, status: String = "200 OK", body: String) {
    let bytes = Data(body.utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
  }
}
