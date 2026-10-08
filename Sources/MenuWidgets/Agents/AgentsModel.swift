import Combine
import Foundation
import WidgetsCore

/// Drives the Claude usage widget: runs the collector on a timer, on popup
/// open (limits only — cheap), and on demand (forced), collapsing requests
/// that arrive while a run is in flight.
@MainActor
final class AgentsModel: ObservableObject {
  @Published private(set) var record: UsageRecord?
  @Published private(set) var refreshing = false
  /// The panel's clock for countdowns; ticks while the popup is open.
  @Published private(set) var now = Date()
  /// Bumped on each popup open so the panel can retake keyboard focus.
  @Published private(set) var openCount = 0

  private let collector = ClaudeUsageCollector()
  private var pending: ClaudeUsageCollector.Mode?
  private var refreshTimer: Timer?
  private var retryTimer: Timer?
  private var clockTimer: Timer?
  private var interval: TimeInterval = 900
  private var configSub: AnyCancellable?

  init(config: ConfigStore) {
    configSub = config.$config
      .map { max(30, TimeInterval($0.agents.refreshIntervalSec)) }
      .removeDuplicates()
      .sink { [weak self] seconds in self?.schedule(every: seconds) }
  }

  private func schedule(every seconds: TimeInterval) {
    interval = seconds
    refreshTimer?.invalidate()
    let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.run(.normal) }
    }
    t.tolerance = min(30, seconds / 10)
    RunLoop.main.add(t, forMode: .common)
    refreshTimer = t
    run(.normal)
  }

  func run(_ mode: ClaudeUsageCollector.Mode) {
    if refreshing {
      // A forced refresh outranks whatever cheaper kind was queued.
      if mode == .force || pending == nil { pending = mode }
      return
    }
    refreshing = true
    let collector = collector
    Task.detached(priority: .utility) {
      let record = await collector.collect(mode: mode)
      await MainActor.run { self.finish(record) }
    }
  }

  private func finish(_ record: UsageRecord) {
    self.record = record
    now = Date()
    refreshing = false
    #if DEBUG
    AgentsSnapshot.writeIfRequested(self)
    #endif
    // Couldn't reach the endpoint at all (often right after wake, before the
    // network is up): one sooner retry instead of a full interval.
    retryTimer?.invalidate()
    retryTimer = nil
    if record.retryAdvised {
      let t = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.run(.limitsOnly) }
      }
      RunLoop.main.add(t, forMode: .common)
      retryTimer = t
    }
    if let next = pending {
      pending = nil
      run(next)
    }
  }

  func refreshNow() { run(.force) }

  /// Turned off in the config: no more collection runs.
  func stop() {
    configSub = nil
    pending = nil
    [refreshTimer, retryTimer, clockTimer].forEach { $0?.invalidate() }
    refreshTimer = nil
    retryTimer = nil
    clockTimer = nil
  }

  func popupOpened() {
    now = Date()
    openCount += 1
    run(.limitsOnly)
    clockTimer?.invalidate()
    let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.now = Date() }
    }
    RunLoop.main.add(t, forMode: .common)
    clockTimer = t
  }

  func popupClosed() {
    clockTimer?.invalidate()
    clockTimer = nil
  }
}
