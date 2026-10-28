import Darwin
import Foundation
import WidgetsCore

/// One connection to PIM Bridge's socket, kept open between requests and
/// used one request at a time (the bridge answers in order). Blocking
/// socket calls run on a serial queue, off the main thread.
final class BridgeClient: @unchecked Sendable {
  enum Failure: Error, Equatable {
    /// Nothing at the socket: PIM Bridge isn't running (or isn't installed).
    case notRunning
    /// The bridge took the connection and closed it without a reply: it
    /// checks every caller's code signature and refused this one.
    case refused
    /// Something other than PIM Bridge is at the socket (by its path).
    case impostor(String)
    /// MenuWidgets is signed ad hoc, so it can't check who's at the socket.
    case unpinned
    /// The tool ran and said no, in the bridge's words.
    case tool(String)
    case other(String)

    var message: String {
      switch self {
      case .notRunning: return "PIM Bridge isn't running. Gmail is read through it."
      case .refused: return "PIM Bridge refused MenuWidgets. Its signature may not match what the bridge expects; \(PIMBridge.logPath) says why."
      case .impostor(let who): return "Something other than PIM Bridge is answering at its socket (\(who)), so MenuWidgets won't use it."
      case .unpinned: return "MenuWidgets is signed ad hoc, so it can't tell PIM Bridge from an impostor. Sign it with your identity (see Gmail setup in the README)."
      case .tool(let m), .other(let m): return m
      }
    }

    /// The connection failed, rather than one request.
    var isConnection: Bool {
      switch self {
      case .notRunning, .refused, .impostor, .unpinned: return true
      case .tool, .other: return false
      }
    }
  }

  private let queue = DispatchQueue(label: "menu-widgets.pim-bridge")
  private let path: String
  // Touched only on `queue`.
  private var fd: Int32 = -1
  private var nextID = 1
  private var buffer = Data()

  init(path: String = PIMBridge.socketPath) { self.path = path }

  deinit { if fd >= 0 { close(fd) } }

  /// Runs one tool and returns its JSON.
  func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> Data {
    let args = UncheckedSendable(arguments)
    return try await withCheckedThrowingContinuation { cont in
      queue.async {
        cont.resume(with: Result { try self.callOnQueue(tool, args.value) })
      }
    }
  }

  func disconnect() {
    queue.async { self.drop() }
  }

  // MARK: on the queue

  private func callOnQueue(_ tool: String, _ arguments: [String: Any]) throws -> Data {
    // The bridge may have closed an idle connection (or restarted): a
    // failure on a reused one gets one more try on a fresh one, which is
    // the one that decides between "refused" and a real error.
    let reused = fd >= 0
    do {
      return try exchange(tool, arguments)
    } catch Failure.refused where reused {
      drop()
      return try exchange(tool, arguments)
    }
  }

  private func exchange(_ tool: String, _ arguments: [String: Any]) throws -> Data {
    if fd < 0 { try connect() }
    let id = nextID
    nextID += 1
    try send(PIMBridge.request(id: id, tool: tool, arguments: arguments))
    while true {
      let line = try readLine()
      let (replyID, result) = PIMBridge.reply(line)
      // Anything not answering this request (a stray notification) is skipped.
      if replyID != nil && replyID != id { continue }
      switch result {
      case .success(let data): return data
      case .failure(.tool(let m)): throw Failure.tool(m)
      case .failure(.rpc(let m)): throw Failure.other("PIM Bridge: \(m)")
      case .failure(.malformed): drop(); throw Failure.other("PIM Bridge sent a reply MenuWidgets can't read.")
      }
    }
  }

  private func connect() throws {
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { throw Failure.other(String(cString: strerror(errno))) }
    var on: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    // Sign-in and search can take a while on Google's side; anything past
    // this is a hung bridge.
    var timeout = timeval(tv_sec: 60, tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { close(s); throw Failure.other("PIM Bridge's socket path is too long.") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard ok == 0 else {
      let err = errno
      close(s)
      if err == ENOENT || err == ECONNREFUSED { throw Failure.notRunning }
      throw Failure.other("Can't reach PIM Bridge: \(String(cString: strerror(err)))")
    }
    switch BridgeIdentity.check(s) {
    case .genuine:
      break
    case .impostor(let who):
      close(s)
      NSLog("mail: \(who) is at PIM Bridge's socket and isn't PIM Bridge; not using it")
      throw Failure.impostor(who)
    case .unpinned:
      close(s)
      throw Failure.unpinned
    }
    fd = s
    buffer = Data()
  }

  private func send(_ data: Data) throws {
    var sent = 0
    while sent < data.count {
      let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
      if n < 0 {
        if errno == EINTR { continue }
        let err = errno
        drop()
        // A peer that hung up is the bridge turning this caller away.
        if err == EPIPE || err == ECONNRESET { throw Failure.refused }
        throw Failure.other("Can't talk to PIM Bridge: \(String(cString: strerror(err)))")
      }
      sent += n
    }
  }

  private func readLine() throws -> Data {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let nl = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<nl]
        buffer = Data(buffer[(nl + 1)...])
        if line.isEmpty { continue }
        return Data(line)
      }
      let n = read(fd, &chunk, chunk.count)
      if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
      if n < 0 && errno == EINTR { continue }
      let err = errno
      drop()
      if n == 0 || err == ECONNRESET { throw Failure.refused }
      if err == EAGAIN || err == EWOULDBLOCK { throw Failure.other("PIM Bridge didn't answer in time.") }
      throw Failure.other("Can't talk to PIM Bridge: \(String(cString: strerror(err)))")
    }
  }

  private func drop() {
    if fd >= 0 { close(fd) }
    fd = -1
    buffer = Data()
  }
}

/// Carries the request's arguments (plain JSON values) onto the queue.
private struct UncheckedSendable<T>: @unchecked Sendable {
  let value: T
  init(_ value: T) { self.value = value }
}
