import AppKit
import EventKit
import SwiftUI
import WidgetsCore

/// The reminders widget's state: open reminders due through tomorrow, read
/// from EventKit when the store changes (and every minute), plus the panel's
/// forms. After Panel.qml in the Omarchy widget.
@MainActor
final class RemindersModel: ObservableObject {
  enum Access { case unknown, granted, denied }

  /// Where keyboard focus should be; the panel mirrors it into @FocusState.
  enum Field: Hashable { case panel, addTitle, addWhen, editTitle, editWhen, editURL, editNotes, until }

  let store = ReminderStore()

  @Published private(set) var items: [ReminderItem] = []
  @Published private(set) var lists: [ReminderStore.ListInfo] = []
  @Published private(set) var access: Access = ReminderStore.hasAccess ? .granted : .unknown
  @Published private(set) var loaded = false
  @Published private(set) var failed = false
  @Published private(set) var lastFetch: Date?
  @Published private(set) var now = Date()
  @Published private(set) var statusMessage = ""
  @Published private(set) var statusIsError = false

  /// Optimistic check-offs, by id, until the next fetch settles them.
  @Published private(set) var done: Set<String> = []
  /// Rows whose notes are shown in full.
  @Published var expanded: Set<String> = []
  /// Each row's notes as shown and in full, to offer "more" when cut short.
  @Published var noteHeights: [String: [CGFloat]] = [:]
  /// The panel content's height, which sizes its scroll view.
  @Published var contentHeight: CGFloat = 0

  @Published var addTitle = ""
  @Published var addWhen = ""
  /// The list chosen for new reminders (an id); "" means the default list.
  @Published var newListID = ""
  @Published private(set) var adding = false

  @Published var cursorActive = false
  @Published var rowIndex = 0
  /// The reminder being edited in place, and its form.
  @Published private(set) var draft: EditDraft?

  /// Set to move keyboard focus; `focused` is where it actually is.
  @Published var focusRequest: Field?
  var focused: Field?
  /// Bumped each time the popup opens.
  @Published private(set) var openCount = 0
  var isOpen = false
  var onClose: () -> Void = {}

  private var pendingJobs = 0
  private var fetching = false
  private var refreshAgain = false
  private var settle: DispatchWorkItem?
  private var ticker: Timer?
  private var observers: [NSObjectProtocol] = []

  var entries: [AgendaEntry] { Agenda.entries(items, now: now) }
  var summary: Agenda.Summary { Agenda.summary(entries, done: done, now: now) }
  var chosenList: ReminderStore.ListInfo? {
    lists.first { $0.id == newListID } ?? lists.first { $0.isDefault } ?? lists.first
  }

  var heroMeta: String {
    switch access {
    case .denied: return "No access to Reminders"
    case .unknown where !loaded: return "Loading"
    default: break
    }
    if !loaded { return failed ? "Couldn't read Reminders" : "Loading" }
    let s = summary
    return s.due == 0 ? "All done today" : Agenda.dueParts(s).joined(separator: " · ")
  }

  init() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store.store, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    })
    // Every minute: the clock moves reminders into "past due", and a fetch
    // catches anything the change notification missed.
    let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.now = Date()
        self?.refresh()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    ticker = t
    requestAccessIfNeeded()
  }

  private func requestAccessIfNeeded() {
    if ReminderStore.hasAccess { access = .granted; refresh(); return }
    guard ReminderStore.undecided else { access = .denied; return }
    store.requestAccess { granted in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.access = granted ? .granted : .denied
          if granted { self.refresh() }
        }
      }
    }
  }

  // MARK: fetching

  func refresh() {
    now = Date()
    if access != .granted {
      guard ReminderStore.hasAccess else { return }
      access = .granted
    }
    // Held back while changes are in flight or settling (so checked rows stay
    // to undo), and while a form is open (new rows would wipe the typing).
    if fetching || pendingJobs > 0 || settle != nil || draft != nil { refreshAgain = true; return }
    fetching = true
    let cal = Calendar.current
    let end = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: Date()))!
    store.run({ $0.snapshot(dueBefore: end) }) { [weak self] result in
      guard let self else { return }
      self.fetching = false
      switch result {
      case .success(let snap):
        if self.pendingJobs > 0 || self.settle != nil || self.draft != nil {
          self.refreshAgain = true
        } else {
          self.items = snap.items
          self.lists = snap.lists
          self.done = []
          self.loaded = true
          self.failed = false
          self.lastFetch = Date()
          if self.statusIsError { self.statusMessage = "" }
          self.rowIndex = min(self.rowIndex, max(0, self.entries.count - 1))
        }
      case .failure(let error):
        self.failed = true
        self.setStatus("Couldn't read Reminders: \(error)", error: true)
      }
      self.flushRefresh()
    }
  }

  /// Runs a refresh that was held back, once nothing holds it any more.
  private func flushRefresh() {
    guard refreshAgain, !fetching, pendingJobs == 0, settle == nil, draft == nil else { return }
    refreshAgain = false
    refresh()
  }

  private func setStatus(_ text: String, error: Bool) {
    statusMessage = text
    statusIsError = error
  }

  // MARK: changes

  /// Runs one change on the store's queue, in order. `ok` is the status line
  /// on success; `what` finishes "Couldn't …" on failure.
  private func job(_ what: String, ok: String? = nil, refreshNow: Bool = false,
                   _ work: @escaping @Sendable (ReminderStore) throws -> Void,
                   succeeded: (() -> Void)? = nil, failed: (() -> Void)? = nil) {
    pendingJobs += 1
    settle?.cancel()
    settle = nil
    store.run(work) { [weak self] result in
      guard let self else { return }
      self.pendingJobs -= 1
      switch result {
      case .success:
        if let ok { self.setStatus(ok, error: false) }
        succeeded?()
      case .failure(let error):
        self.setStatus("Couldn't \(what): \(error)", error: true)
        failed?()
      }
      guard self.pendingJobs == 0 else { return }
      if refreshNow {
        self.refreshAgain = true
        self.flushRefresh()
      } else {
        // Waits a moment after the last change so a few quick check-offs
        // settle into one refresh, and the checked rows stay up to undo.
        let work = DispatchWorkItem { [weak self] in
          guard let self else { return }
          self.settle = nil
          self.refreshAgain = true
          self.flushRefresh()
        }
        self.settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
      }
    }
  }

  func toggleDone(_ e: AgendaEntry) {
    let id = e.id
    if done.contains(id) {
      done.remove(id)
      job("reopen “\(e.item.title)”") { try $0.setCompleted(id, false) }
    } else {
      done.insert(id)
      job("complete “\(e.item.title)”") { try $0.setCompleted(id, true) }
    }
  }

  func addReminder() {
    let title = addTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { focusRequest = .addTitle; return }
    guard !adding else { return }
    let when = addWhen.trimmingCharacters(in: .whitespacesAndNewlines)
    let list = chosenList
    let listID = list?.id
    let listName = list?.name ?? "Reminders"
    adding = true
    job("add “\(title)”", ok: "Added “\(title)” to \(listName)" + (when.isEmpty ? ", no due date" : ", \(when)"),
        refreshNow: true, { try $0.add(title: title, listID: listID, when: when) },
        succeeded: { [weak self] in
          guard let self else { return }
          self.adding = false
          // Clear only once it's in, and only if the form still holds what was sent.
          if self.addTitle.trimmingCharacters(in: .whitespacesAndNewlines) == title
              && self.addWhen.trimmingCharacters(in: .whitespacesAndNewlines) == when {
            self.addTitle = ""
            self.addWhen = ""
          }
        },
        failed: { [weak self] in
          // The text stays; a bad "when" is the usual cause.
          guard let self else { return }
          self.adding = false
          if self.isOpen && self.draft == nil { self.focusRequest = when.isEmpty ? .addTitle : .addWhen }
        })
  }

  // MARK: editing

  func startEdit(_ e: AgendaEntry, from typed: EditDraft? = nil) {
    cursorActive = true
    rowIndex = max(0, entries.firstIndex { $0.id == e.id } ?? 0)
    draft = typed ?? EditDraft(e)
    focusRequest = .editTitle
  }

  func cancelEdit() {
    guard draft != nil else { return }
    draft = nil
    focusRequest = .panel
    refreshAgain = true
    flushRefresh()  // fetches were held back while the form was open
  }

  func saveEdit() {
    guard let d = draft else { return }
    let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if title.isEmpty { focusRequest = .editTitle; return }
    let e = d.entry
    let change = Agenda.edit(for: e, title: d.title, when: d.when, notes: d.notes, url: d.url, repeat: d.rep)
    if change.isEmpty { cancelEdit(); return }
    var ok = "Saved “\(title)”"
    if let due = change.due { ok += ", " + (due.isEmpty ? "no due date" : due) }
    if let rule = change.rule {
      let preset = d.rep.presetKey
      ok += rule == nil ? ", no repeat"
        : ", repeats " + (preset == "custom" ? "on a custom schedule" : RepeatState.presetLabel(preset).lowercased())
    }
    let id = e.id
    draft = nil
    focusRequest = .panel
    job("save “\(title)”", ok: ok, refreshNow: true, { try $0.apply(change, to: id) },
        failed: { [weak self] in
          // A failed save reopens the form with the typing intact.
          guard let self, self.isOpen, self.draft == nil else { return }
          self.startEdit(e, from: d)
        })
    // Show the new text right away; the new time and repeat come with the refresh.
    items = items.map { i in
      guard i.id == id else { return i }
      var n = i
      if let t = change.title { n.title = t }
      if let notes = change.notes { n.notes = notes }
      if let url = change.url { n.url = url }
      return n
    }
  }

  // MARK: panel

  func popupOpened() {
    isOpen = true
    openCount += 1
    cursorActive = false
    rowIndex = 0
    focusRequest = .panel
    if access != .granted { requestAccessIfNeeded() }
    refresh()
  }

  func popupClosed() {
    isOpen = false
    if draft != nil { cancelEdit() }
  }

  /// Esc: leaves a form first; returns false when the popup should close.
  func escape() -> Bool {
    if draft != nil { cancelEdit(); return true }
    if focused == .addTitle || focused == .addWhen { focusRequest = .panel; return true }
    return false
  }

  func moveCursor(_ dy: Int) {
    let n = entries.count
    guard n > 0 else { return }
    if !cursorActive { cursorActive = true; rowIndex = dy > 0 ? 0 : n - 1; return }
    rowIndex = max(0, min(n - 1, rowIndex + dy))
  }

  var cursorEntry: AgendaEntry? {
    let e = entries
    return cursorActive && rowIndex < e.count ? e[rowIndex] : nil
  }

  func notesCut(_ id: String) -> Bool {
    guard let h = noteHeights[id], h.count == 2 else { return false }
    return h[1] > h[0] + 1
  }

  func toggleExpanded(_ id: String) {
    if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
  }

  func open(_ link: String) {
    guard Links.openable(link), let url = URL(string: link) else { return }
    NSWorkspace.shared.open(url)
    onClose()
  }

  func openRemindersApp() {
    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
      NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
    onClose()
  }

  func openPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
      NSWorkspace.shared.open(url)
    }
    onClose()
  }
}

/// The edit form's fields, kept apart from the model so typing redraws only
/// the form.
@MainActor
final class EditDraft: ObservableObject {
  let entry: AgendaEntry
  @Published var title: String
  @Published var when: String
  @Published var url: String
  @Published var notes: String
  @Published var rep: RepeatState
  /// Custom… was picked, so the custom controls stay up even if a preset matches.
  @Published var customOpen = false

  init(_ e: AgendaEntry) {
    entry = e
    title = e.item.title
    when = Agenda.whenText(e)
    url = e.item.url
    notes = e.item.notes
    rep = Agenda.repeatState(e)
  }
}
