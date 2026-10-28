import AppKit
import Combine
import SwiftUI
import UserNotifications
import WidgetsCore

/// The mail widget's state: one source per inbox (HEY first, then the Gmail
/// accounts in PIM Bridge's order), rebuilt when the mail config changes. Each
/// read is diffed against the last to post banners for new mail and
/// withdraw them once it's read elsewhere.
@MainActor
final class MailModel: ObservableObject {
  @Published private(set) var sources: [MailSource] = []
  /// Gmail through PIM Bridge, when `mail.gmail` is on.
  @Published private(set) var gmail: GmailHub?
  /// The thread just trashed from the panel, for Undo.
  @Published private(set) var trashed: Trashed?
  /// The row whose trash button is asking "Trash?" (an inbox with no Undo).
  @Published private(set) var confirmingTrash: String?
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
  private var hey: HeySource?
  private var trashedTimer: Timer?
  private var confirmTimer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(config: ConfigStore) {
    settings = config.config.mail
    // MENU_WIDGETS_MAIL_TEST=1 posts a sample banner (with the configured
    // sound) a few seconds after launch, to hear and see the notification.
    if ProcessInfo.processInfo.environment["MENU_WIDGETS_MAIL_TEST"] != nil {
      let sample = MailItem(id: "test:\(UUID().uuidString)", account: "test", revision: "1", sender: "MenuWidgets",
                            subject: "A sample new email", snippet: "This is what a new email's banner looks like.",
                            date: Date(), url: URL(string: "https://mail.google.com/")!)
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self else { return }
        self.notifier.post([sample], account: "Test", inbox: sample.url, sound: self.settings.sound)
      }
    }
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

  /// MENU_WIDGETS_MAIL_DEMO=1: made-up inboxes in place of HEY and Gmail,
  /// for screenshots that don't show your own mail. =empty has nothing
  /// unread, and =attention has the second inbox waiting for a sign-in.
  private static let demoMode = ProcessInfo.processInfo.environment["MENU_WIDGETS_MAIL_DEMO"]
  private static var demo: Bool { demoMode != nil }

  private func rebuild() {
    if Self.demo { sources = Self.demoSources(now: Date()); return }
    hey?.stop()
    gmail?.stop()
    hey = settings.hey ? HeySource(command: settings.heyCommand) : nil
    gmail = settings.gmail ? GmailHub(primaryOnly: settings.primaryOnly, interval: TimeInterval(settings.pollIntervalSec)) : nil
    gmail?.onSourcesChanged = { [weak self] in self?.wire() }
    wire()
    if settings.notify { notifier.requestAuthorization() }
    hey?.start()
    gmail?.start()
  }

  private static func demoSources(now: Date) -> [MailSource] {
    func inbox(_ id: String, _ name: String, _ mail: [(sender: String, subject: String, snippet: String, minutesAgo: Double)]) -> MailSource {
      let url = URL(string: "https://example.com/\(id)")!
      let source = MailSource(id: id, name: name, inboxURL: url)
      source.publish(demoMode == "empty" ? [] : mail.enumerated().map { i, m in
        MailItem(id: "\(id):\(i)", account: id, revision: "1", sender: m.sender, subject: m.subject, snippet: m.snippet,
                 date: now.addingTimeInterval(-m.minutesAgo * 60), url: url)
      })
      return source
    }
    let sources = [
      inbox("hey", "HEY", [
        ("Maya Chen", "Dinner on Saturday?", "We were thinking 7 at the new place on Main. Let me know if that works.", 12),
        ("City Library", "Your holds are ready", "2 items are waiting for you at the front desk until Friday.", 95),
      ]),
      inbox("gmail:work", "Work", [
        ("Sam Ortiz", "Re: Launch checklist", "Looks good to me. I added two items about the docs.", 4),
        ("GitHub", "[menu-widgets] New issue: Dark mode label", "The label is hard to read on a tinted menu bar.", 48),
        ("Priya Natarajan", "Notes from today's sync", "Here's a quick summary of what we covered and who owns what.", 180),
      ]),
    ]
    if demoMode == "attention" { sources[1].status = .needsSignIn }
    return sources
  }

  /// Watches the current sources (Gmail's accounts come and go with the
  /// bridge's list).
  private func wire() {
    let list: [MailSource] = (hey.map { [$0] } ?? []) + (gmail?.sources ?? [])
    // Re-publish when any source changes, so the label and panel follow.
    sourceWatch = list.map { s in
      s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    if let gmail {
      sourceWatch.append(gmail.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }
    for s in list {
      s.onUpdate = { [weak self] src, previous, previousFetch in
        self?.sourceUpdated(src, previous: previous, previousFetch: previousFetch)
      }
    }
    sources = list
  }

  private func sourceUpdated(_ src: MailSource, previous: [MailItem]?, previousFetch: Date?) {
    let news = MailDiff.news(previous: previous, since: previousFetch, current: src.items ?? [])
    notifier.withdraw(news.gone)
    guard settings.notify, !news.fresh.isEmpty else { return }
    notifier.post(news.fresh, account: src.name, inbox: src.inboxURL, sound: settings.sound)
  }

  /// Turned off in the config: stop polling and the `hey watch` process.
  func stop() {
    cancellables.removeAll()
    hey?.stop()
    gmail?.stop()
    hey = nil
    gmail = nil
    sourceWatch = []
    sources = []
    trashedTimer?.invalidate()
    confirmTimer?.invalidate()
    ticker?.invalidate()
    ticker = nil
    for (center, o) in observers { center.removeObserver(o) }
    observers = []
  }

  // MARK: summary

  var total: Int { sources.reduce(0) { $0 + $1.unread } }
  var needsAttention: Bool { sources.contains { $0.status.needsAttention } || gmail?.needsAttention == true }
  var loaded: Bool { sources.contains { $0.items != nil } }

  var heroMeta: String {
    if sources.isEmpty { return gmail == nil ? "No inboxes set up" : (needsAttention ? "Needs attention" : "Checking") }
    if !loaded { return needsAttention ? "Needs attention" : "Checking" }
    if total == 0 { return "All caught up" }
    return sources.filter { $0.unread > 0 }.map { "\($0.name) \($0.unread)" }.joined(separator: " · ")
  }

  /// Every row in panel order, for the keyboard cursor.
  var rows: [MailItem] { sources.flatMap { visible($0) } }

  static let rowsPerInbox = 8

  func visible(_ s: MailSource) -> [MailItem] {
    Array((s.items ?? []).sorted { $0.date > $1.date }.prefix(Self.rowsPerInbox))
  }

  // MARK: actions

  func refresh() {
    hey?.refresh()
    gmail?.refresh()
  }

  struct Trashed {
    let item: MailItem
    let source: MailSource
    /// Gmail can take it back out; HEY can't, so the bar links to it.
    let undoable: Bool
  }

  private func source(of item: MailItem) -> MailSource? { sources.first { $0.id == item.account } }

  func canTrash(_ item: MailItem) -> Bool {
    item.trashID != nil && source(of: item)?.canTrash == true
  }

  /// Trashes the row's thread. Where the trash can be undone (Gmail) it
  /// goes at once, with Undo for a while after; where it can't (HEY) the
  /// first press asks, and a second within a few seconds trashes.
  func trash(_ item: MailItem) {
    guard canTrash(item), let s = source(of: item) else { return }
    if !s.canUndoTrash && confirmingTrash != item.id {
      confirmingTrash = item.id
      confirmTimer?.invalidate()
      let t = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.confirmingTrash = nil }
      }
      RunLoop.main.add(t, forMode: .common)
      confirmTimer = t
      return
    }
    confirmingTrash = nil
    confirmTimer?.invalidate()
    if let c = cursor, c >= rows.count - 1 { cursor = rows.count > 1 ? rows.count - 2 : nil }
    Task { [weak self] in
      guard await s.trash(item), let self else { return }
      trashed = Trashed(item: item, source: s, undoable: s.canUndoTrash)
      trashedTimer?.invalidate()
      let t = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.trashed = nil }
      }
      RunLoop.main.add(t, forMode: .common)
      trashedTimer = t
    }
  }

  func undoTrash() {
    guard let t = trashed, t.undoable else { return }
    trashed = nil
    trashedTimer?.invalidate()
    Task { await t.source.untrash(t.item) }
  }

  func trashCursor() {
    guard let c = cursor, c < rows.count else { return }
    trash(rows[c])
  }

  /// Any inbox here can trash (for the footer's key hint).
  var trashable: Bool { sources.contains { $0.canTrash } }

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
    confirmingTrash = nil
    // Gmail is polled; catch up now if the last look is more than a few seconds old.
    if let gmail, gmail.lastFetch.map({ Date().timeIntervalSince($0) > 10 }) ?? true { gmail.refresh() }
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

  /// The configured sound: "default", "none", or a sound file's name, found
  /// in the system's or the user's Sounds folder (or the app bundle).
  static func sound(_ name: String) -> UNNotificationSound? {
    let n = name.trimmingCharacters(in: .whitespaces)
    switch n.lowercased() {
    case "", "none": return nil
    case "default": return .default
    default:
      // A bare name ("Bottle") gets the extension of the file that has it.
      if (n as NSString).pathExtension.isEmpty {
        let dirs = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds").path,
                    "/Library/Sounds", "/System/Library/Sounds"]
        for dir in dirs {
          for ext in ["aiff", "aif", "caf", "wav"] where FileManager.default.fileExists(atPath: "\(dir)/\(n).\(ext)") {
            return UNNotificationSound(named: UNNotificationSoundName("\(n).\(ext)"))
          }
        }
      }
      return UNNotificationSound(named: UNNotificationSoundName(n))
    }
  }

  func post(_ items: [MailItem], account: String, inbox: URL, sound: String) {
    let tone = Self.sound(sound)
    if items.count > MailDiff.bannerLimit {
      let c = UNMutableNotificationContent()
      c.title = "\(items.count) new emails"
      c.subtitle = account
      c.body = items.prefix(4).map(\.sender).joined(separator: ", ")
      c.threadIdentifier = account
      c.sound = tone
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
      c.sound = i == 0 ? tone : nil
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
