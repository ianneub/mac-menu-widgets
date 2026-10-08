import AppKit
import Combine
import SwiftUI
import UserNotifications
import WidgetsCore

/// The mail widget's state: one source per inbox (HEY first, then the Gmail
/// accounts in config order), rebuilt when the mail config changes. Each
/// read is diffed against the last to post banners for new mail and
/// withdraw them once it's read elsewhere.
@MainActor
final class MailModel: ObservableObject {
  @Published private(set) var sources: [MailSource] = []
  @Published private(set) var settings: WidgetsConfig.MailSettings
  @Published private(set) var now = Date()
  /// The panel content's height, which sizes its scroll view.
  @Published var contentHeight: CGFloat = 0
  @Published var cursor: Int?
  var onClose: () -> Void = {}

  private let notifier = MailNotifier()
  private var sourceWatch: [AnyCancellable] = []
  private var cancellables: Set<AnyCancellable> = []
  private var ticker: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(config: ConfigStore) {
    settings = config.config.mail
    config.$config
      .map(\.mail)
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] s in
        self?.settings = s
        self?.rebuild()
      }
      .store(in: &cancellables)
    let ws = NSWorkspace.shared.notificationCenter
    observers.append((ws, ws.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // The network is often not back the instant the lid opens.
      MainActor.assumeIsolated {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
      }
    }))
    let nc = NotificationCenter.default
    observers.append((nc, nc.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.sources.forEach { $0.stop() } }
    }))
    let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.now = Date() }
    }
    RunLoop.main.add(t, forMode: .common)
    ticker = t
    rebuild()
  }

  private func rebuild() {
    sources.forEach { $0.stop() }
    var list: [MailSource] = []
    if settings.hey { list.append(HeySource(command: settings.heyCommand)) }
    for a in settings.gmail {
      list.append(GmailSource(account: a, primaryOnly: settings.primaryOnly, interval: TimeInterval(settings.pollIntervalSec)))
    }
    // Re-publish when any source changes, so the label and panel follow.
    sourceWatch = list.map { s in
      s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    for s in list {
      s.onUpdate = { [weak self] src, previous, previousFetch in
        self?.sourceUpdated(src, previous: previous, previousFetch: previousFetch)
      }
    }
    sources = list
    if settings.notify { notifier.requestAuthorization() }
    list.forEach { $0.start() }
  }

  private func sourceUpdated(_ src: MailSource, previous: [MailItem]?, previousFetch: Date?) {
    let news = MailDiff.news(previous: previous, since: previousFetch, current: src.items ?? [])
    notifier.withdraw(news.gone)
    guard settings.notify, !news.fresh.isEmpty else { return }
    notifier.post(news.fresh, account: src.name, inbox: src.inboxURL)
  }

  /// Turned off in the config: stop polling and the `hey watch` process.
  func stop() {
    cancellables.removeAll()
    sources.forEach { $0.stop() }
    sourceWatch = []
    sources = []
    ticker?.invalidate()
    ticker = nil
    for (center, o) in observers { center.removeObserver(o) }
    observers = []
  }

  // MARK: summary

  var total: Int { sources.reduce(0) { $0 + $1.unread } }
  var needsAttention: Bool { sources.contains { $0.status.needsAttention } }
  var loaded: Bool { sources.contains { $0.items != nil } }

  var heroMeta: String {
    if sources.isEmpty { return "No inboxes set up" }
    if !loaded { return needsAttention ? "Needs attention" : "Checking" }
    if total == 0 { return "All caught up" }
    return sources.filter { $0.unread > 0 }.map { "\($0.name) \($0.unread)" }.joined(separator: " · ")
  }

  var tooltip: String {
    let parts = sources.map { s -> String in
      switch s.status {
      case .needsSetup, .needsSignIn: return "\(s.name): sign in"
      case .error where s.items == nil: return "\(s.name): error"
      default: return "\(s.name) \(s.unread)"
      }
    }
    return parts.isEmpty ? "Mail" : parts.joined(separator: " · ")
  }

  /// Every row in panel order, for the keyboard cursor.
  var rows: [MailItem] { sources.flatMap { visible($0) } }

  static let rowsPerInbox = 8

  func visible(_ s: MailSource) -> [MailItem] {
    Array((s.items ?? []).sorted { $0.date > $1.date }.prefix(Self.rowsPerInbox))
  }

  // MARK: actions

  func refresh() { sources.forEach { $0.refresh() } }

  func open(_ url: URL) {
    NSWorkspace.shared.open(url)
    onClose()
  }

  func moveCursor(_ by: Int) {
    let n = rows.count
    guard n > 0 else { cursor = nil; return }
    cursor = cursor.map { ($0 + by + n) % n } ?? (by > 0 ? 0 : n - 1)
  }

  func openCursor() {
    guard let c = cursor, c < rows.count else { return }
    open(rows[c].url)
  }

  func popupOpened() {
    now = Date()
    cursor = nil
    // Gmail is polled; catch up now if the last look is more than a few seconds old.
    for s in sources where s is GmailSource && (s.lastFetch.map { Date().timeIntervalSince($0) > 10 } ?? true) {
      s.refresh()
    }
  }
}

/// Banners for new mail. Each thread's banner has the thread's id, so a
/// reply replaces the earlier one and reading the thread elsewhere
/// withdraws it. Clicking a banner opens the thread in the browser.
@MainActor
final class MailNotifier: NSObject, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private var asked = false

  override init() {
    super.init()
    center.delegate = self
  }

  func requestAuthorization() {
    guard !asked else { return }
    asked = true
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      if let error { NSLog("mail: notification permission: \(error.localizedDescription)") }
      else if !granted { NSLog("mail: notifications are turned off for MenuWidgets") }
    }
  }

  func post(_ items: [MailItem], account: String, inbox: URL) {
    if items.count > MailDiff.bannerLimit {
      let c = UNMutableNotificationContent()
      c.title = "\(items.count) new emails"
      c.subtitle = account
      c.body = items.prefix(4).map(\.sender).joined(separator: ", ")
      c.threadIdentifier = account
      c.sound = .default
      c.userInfo = ["url": inbox.absoluteString]
      center.add(UNNotificationRequest(identifier: "summary:\(account):\(UUID().uuidString)", content: c, trigger: nil))
      return
    }
    for (i, item) in items.enumerated() {
      let c = UNMutableNotificationContent()
      c.title = item.sender
      c.subtitle = item.subject
      c.body = item.snippet.isEmpty ? account : "\(account) · \(item.snippet)"
      c.threadIdentifier = account
      // One sound per batch.
      c.sound = i == 0 ? .default : nil
      c.userInfo = ["url": item.url.absoluteString]
      center.add(UNNotificationRequest(identifier: item.id, content: c, trigger: nil))
    }
  }

  func withdraw(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .list, .sound])
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                          withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
       let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
      DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }
    completionHandler()
  }
}
