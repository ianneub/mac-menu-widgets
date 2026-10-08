import Foundation
import WidgetsCore

/// The HEY Imbox through the `hey` CLI: `hey watch --box imbox` pushes a
/// line whenever the box changes, and each one (debounced) rereads the
/// unseen threads with `hey box view imbox`. The watch is restarted if it
/// exits; a slow poll covers anything it misses.
@MainActor
final class HeySource: MailSource {
  private let command: String
  private var watcher: Process?
  private var watcherOut: Pipe?
  private var lineBuffer = Data()
  private var debounce: DispatchWorkItem?
  private var restartDelay: TimeInterval = 5
  private var restartWork: DispatchWorkItem?
  private var poll: Timer?
  private var fetching = false
  private var fetchAgain = false
  private var running = false

  static let pollInterval: TimeInterval = 5 * 60

  init(command: String) {
    self.command = command
    super.init(id: HeyMail.accountID, name: "HEY", inboxURL: URL(string: "https://app.hey.com/imbox")!)
  }

  override func start() {
    guard !running else { return }
    running = true
    refresh()
    startWatch()
    let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    RunLoop.main.add(t, forMode: .common)
    poll = t
  }

  override func stop() {
    running = false
    poll?.invalidate()
    poll = nil
    restartWork?.cancel()
    debounce?.cancel()
    watcherOut?.fileHandleForReading.readabilityHandler = nil
    watcherOut = nil
    if let w = watcher { w.terminationHandler = nil; w.terminate() }
    watcher = nil
  }

  override func refresh() {
    if fetching { fetchAgain = true; return }
    guard let path = Command.resolve(command) else {
      status = .error("The hey CLI wasn't found (set mail.heyCommand to its path).")
      return
    }
    fetching = true
    Task {
      defer {
        fetching = false
        if fetchAgain { fetchAgain = false; refresh() }
      }
      do {
        let out = try await Command.run(path, ["box", "view", "imbox", "--json", "--limit", "50"])
        guard out.status == 0 else {
          let msg = String(decoding: out.stderr.isEmpty ? out.stdout : out.stderr, as: UTF8.self)
          status = .error(Self.firstLine(msg, fallback: "hey exited with \(out.status)"))
          return
        }
        publish(try HeyMail.unseen(boxJSON: out.stdout))
      } catch {
        status = .error("Couldn't read the Imbox: \(error.localizedDescription)")
      }
    }
  }

  // MARK: watch

  private func startWatch() {
    guard running, watcher == nil, let path = Command.resolve(command) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", Self.leash, "hey-watch", path, "watch", "--box", "imbox"]
    var env = Command.environment
    env["MENU_WIDGETS_PID"] = String(ProcessInfo.processInfo.processIdentifier)
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let out = Pipe()
    p.standardOutput = out
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      // End of file: the process is gone. Without this the handler fires
      // again and again with nothing to read.
      if data.isEmpty { h.readabilityHandler = nil; return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.received(data) }
      }
    }
    p.terminationHandler = { [weak self] _ in
      out.fileHandleForReading.readabilityHandler = nil
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.watchEnded() }
      }
    }
    do {
      try p.run()
      watcher = p
      watcherOut = out
      lineBuffer = Data()
    } catch {
      scheduleRestart()
    }
  }

  private func received(_ data: Data) {
    lineBuffer.append(data)
    while let nl = lineBuffer.firstIndex(of: 0x0A) {
      let line = String(decoding: lineBuffer[lineBuffer.startIndex..<nl], as: UTF8.self)
      lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
      switch HeyMail.watchSignal(line: line) {
      case .ready:
        restartDelay = 5
        scheduleFetch()
      case .changed:
        scheduleFetch()
      case .disconnected, .other:
        break
      }
    }
  }

  /// Changes come in bursts (a thread is added, then updated); read once.
  private func scheduleFetch() {
    debounce?.cancel()
    let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    debounce = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
  }

  private func watchEnded() {
    watcher = nil
    watcherOut = nil
    scheduleRestart()
  }

  private func scheduleRestart() {
    guard running else { return }
    restartWork?.cancel()
    let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startWatch() } }
    restartWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: w)
    restartDelay = min(restartDelay * 2, 300)
  }

  /// Runs the command and ends it when the app goes away, however it went:
  /// Process puts children in their own process group, so neither launchd
  /// nor a force quit would take `hey watch` down with the app, and it
  /// would keep its connection open with no one reading.
  static let leash = """
    "$@" & child=$!
    trap 'kill $child 2>/dev/null; exit 0' TERM INT HUP
    while kill -0 "$MENU_WIDGETS_PID" 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 2; done
    kill $child 2>/dev/null
    wait $child
    """

  static func firstLine(_ s: String, fallback: String) -> String {
    // The CLI's errors are JSON ({"ok": false, "error": "..."}) or plain text.
    if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
       let e = obj["error"] as? String { return e }
    return s.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? fallback
  }
}
