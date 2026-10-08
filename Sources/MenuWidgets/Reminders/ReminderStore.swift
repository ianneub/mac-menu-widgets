import AppKit
import EventKit
import WidgetsCore

/// Apple Reminders through EventKit, plus ReminderKit for the URL field.
/// Everything runs on one serial queue, so changes land in the order they
/// were made.
final class ReminderStore: @unchecked Sendable {
  struct ListInfo: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var isDefault: Bool
    var writable: Bool
    var rgb: [Double]
  }

  struct Snapshot: Sendable {
    var items: [ReminderItem]
    var lists: [ListInfo]
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  let store = EKEventStore()
  private let queue = DispatchQueue(label: "com.ianneub.menu-widgets.reminders")

  static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
  static var undecided: Bool { EKEventStore.authorizationStatus(for: .reminder) == .notDetermined }

  func requestAccess(_ done: @escaping @Sendable (Bool) -> Void) {
    store.requestFullAccessToReminders { granted, error in
      if let error { NSLog("Reminders access request failed: \(error)") }
      done(granted)
    }
  }

  /// Runs `work` on the store's queue and hands its result to the main queue.
  func run<T: Sendable>(_ work: @escaping @Sendable (ReminderStore) throws -> T,
                        then: @escaping @MainActor @Sendable (Result<T, Error>) -> Void) {
    queue.async {
      let result = Result { try work(self) }
      DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
    }
  }

  // MARK: reading

  /// Open reminders due before `end`, and every list.
  func snapshot(dueBefore end: Date) -> Snapshot {
    let done = DispatchSemaphore(value: 0)
    var found: [EKReminder] = []
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
    store.fetchReminders(matching: predicate) { reminders in
      found = reminders ?? []
      done.signal()
    }
    done.wait()
    let urls = ReminderKit.attachmentURLs(found.map(\.calendarItemIdentifier))
    let items = found.compactMap { r -> ReminderItem? in
      guard let c = r.dueDateComponents, let due = Self.dueDate(c) else { return nil }
      return ReminderItem(
        id: r.calendarItemIdentifier, title: r.title ?? "", list: r.calendar?.title ?? "", notes: r.notes ?? "",
        url: urls[r.calendarItemIdentifier] ?? r.url?.absoluteString ?? "", priority: Self.priorityName(r.priority),
        due: due, hasTime: c.hour != nil, rule: r.recurrenceRules?.first.map(Self.describe))
    }
    let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
    let lists = store.calendars(for: .reminder)
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
      .map { c -> ListInfo in
        let color = NSColor(cgColor: c.cgColor)?.usingColorSpace(.sRGB)
        return ListInfo(id: c.calendarIdentifier, name: c.title, isDefault: c.calendarIdentifier == defaultID,
                        writable: c.allowsContentModifications,
                        rgb: color.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } ?? [0.5, 0.5, 0.5])
      }
    return Snapshot(items: items, lists: lists)
  }

  /// The moment a due date refers to, in local time. Date-only reminders
  /// count as due at the start of that day.
  static func dueDate(_ components: DateComponents) -> Date? {
    var c = components
    guard c.year != nil, c.month != nil, c.day != nil else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = (c.hour != nil ? c.timeZone : nil) ?? .current
    c.calendar = nil
    c.timeZone = nil
    return calendar.date(from: c)
  }

  static func priorityName(_ value: Int) -> String {
    switch value {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    default: return "low"
    }
  }

  // MARK: repeat rules

  private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]  // EKWeekday raw value - 1
  private static let frequencies: [(String, EKRecurrenceFrequency)] =
    [("daily", .daily), ("weekly", .weekly), ("monthly", .monthly), ("yearly", .yearly)]

  static func describe(_ rule: EKRecurrenceRule) -> RepeatRule {
    var out = RepeatRule(frequency: frequencies.first { $0.1 == rule.frequency }?.0 ?? "unknown", interval: rule.interval)
    out.daysOfWeek = (rule.daysOfTheWeek ?? []).map {
      ($0.weekNumber != 0 ? String($0.weekNumber) : "") + weekdayNames[$0.dayOfTheWeek.rawValue - 1]
    }
    out.daysOfMonth = (rule.daysOfTheMonth ?? []).map(\.intValue)
    out.monthsOfYear = (rule.monthsOfTheYear ?? []).map(\.intValue)
    out.setPositions = (rule.setPositions ?? []).map(\.intValue)
    out.custom = rule.weeksOfTheYear?.isEmpty == false || rule.daysOfTheYear?.isEmpty == false
    if let end = rule.recurrenceEnd {
      if let date = end.endDate {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        out.until = f.string(from: date)
      } else if end.occurrenceCount > 0 {
        out.count = end.occurrenceCount
      }
    }
    return out
  }

  /// The editor's rule for EventKit. `until` may be anything WhenParser reads.
  static func ekRule(_ rule: RepeatRule) throws -> EKRecurrenceRule {
    guard let frequency = frequencies.first(where: { $0.0 == rule.frequency })?.1 else {
      throw Failure(description: "Can't repeat “\(rule.frequency)”")
    }
    let days: [EKRecurrenceDayOfWeek] = try rule.daysOfWeek.map { entry in
      let digits = entry.prefix { "-+0123456789".contains($0) }
      guard let index = weekdayNames.firstIndex(of: String(entry.dropFirst(digits.count).prefix(3))) else {
        throw Failure(description: "Can't read the day “\(entry)”")
      }
      return EKRecurrenceDayOfWeek(EKWeekday(rawValue: index + 1)!, weekNumber: Int(digits) ?? 0)
    }
    var end: EKRecurrenceEnd?
    if let until = rule.until, !until.isEmpty {
      let day: Date
      do { day = try WhenParser.parse(until).date } catch { throw Failure(description: "Can't read the end date “\(until)”") }
      // The whole last day counts, whatever time the reminder is due.
      end = EKRecurrenceEnd(end: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: day)!)
    } else if let count = rule.count, count > 0 {
      end = EKRecurrenceEnd(occurrenceCount: count)
    }
    func numbers(_ list: [Int]) -> [NSNumber]? { list.isEmpty ? nil : list.map { NSNumber(value: $0) } }
    return EKRecurrenceRule(
      recurrenceWith: frequency, interval: max(1, rule.interval), daysOfTheWeek: days.isEmpty ? nil : days,
      daysOfTheMonth: numbers(rule.daysOfMonth), monthsOfTheYear: numbers(rule.monthsOfYear), weeksOfTheYear: nil,
      daysOfTheYear: nil, setPositions: numbers(rule.setPositions), end: end)
  }

  // MARK: writing

  private func reminder(_ id: String) throws -> EKReminder {
    guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
      throw Failure(description: "That reminder is gone")
    }
    guard r.calendar.allowsContentModifications else {
      throw Failure(description: "The list “\(r.calendar.title)” is read-only")
    }
    return r
  }

  /// A due date from typed text, as DateComponents; date-only stays date-only.
  private static func dueComponents(_ text: String) throws -> DateComponents {
    let when: WhenParser.When
    do { when = try WhenParser.parse(text) } catch { throw Failure(description: "\(error)") }
    return Calendar.current.dateComponents(when.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day],
                                           from: when.date)
  }

  /// Sets or clears the due date. A due date with a time also gets an alert
  /// then, the way Reminders.app does it; without one nothing notifies.
  private static func applyDue(_ r: EKReminder, _ components: DateComponents?) {
    for alarm in r.alarms ?? [] where alarm.absoluteDate != nil { r.removeAlarm(alarm) }
    r.dueDateComponents = components
    if let c = components, c.hour != nil, let date = dueDate(c) { r.addAlarm(EKAlarm(absoluteDate: date)) }
  }

  /// "example.com" gets https://; empty clears.
  private static func url(_ text: String) throws -> URL? {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return nil }
    let full = Links.openable(t) ? t : "https://" + t
    guard let u = URL(string: full), u.scheme != nil else { throw Failure(description: "Can't read the URL “\(t)”") }
    return u
  }

  func setCompleted(_ id: String, _ completed: Bool) throws {
    let r = try reminder(id)
    r.isCompleted = completed
    try store.save(r, commit: true)
  }

  func add(title: String, listID: String?, when: String) throws {
    let r = EKReminder(eventStore: store)
    r.title = title
    if let listID, let list = store.calendar(withIdentifier: listID) {
      r.calendar = list
    } else if let list = store.defaultCalendarForNewReminders() {
      r.calendar = list
    } else {
      throw Failure(description: "No list to add it to")
    }
    if !when.isEmpty { Self.applyDue(r, try Self.dueComponents(when)) }
    try store.save(r, commit: true)
  }

  /// Applies an edit; everything is checked before anything changes.
  func apply(_ edit: Agenda.Edit, to id: String) throws {
    let r = try reminder(id)
    let due = try edit.due.map { $0.isEmpty ? nil : try Self.dueComponents($0) }
    let rule = try edit.rule.map { try $0.map(Self.ekRule) }
    let url = try edit.url.map(Self.url)
    let willHaveDue = due.map { $0 != nil } ?? (r.dueDateComponents != nil)
    if case .some(.some) = rule, !willHaveDue { throw Failure(description: "A repeating reminder needs a due date") }

    if let title = edit.title { r.title = title }
    if let notes = edit.notes { r.notes = notes.isEmpty ? nil : notes }
    if let due { Self.applyDue(r, due) }
    // Like Reminders.app, clearing the date stops the repeat.
    if rule != nil || due == .some(nil) {
      for old in r.recurrenceRules ?? [] { r.removeRecurrenceRule(old) }
      if case .some(.some(let new)) = rule { r.addRecurrenceRule(new) }
    }
    if url != nil, r.url != nil { r.url = nil }  // one URL, in the field the app shows
    try store.save(r, commit: true)
    if let url {
      do { try ReminderKit.setAttachmentURL(id, url) } catch {
        throw Failure(description: "Saved everything except the URL: \(error)")
      }
    }
  }
}

// MARK: - ReminderKit (the URL field)

// The URL field Reminders.app shows is a URL *attachment*, which EventKit
// never exposes; EKReminder.url is the old iCal URL property, which the app
// doesn't show. ReminderKit is the private framework EventKit sits on, and
// remindd gives an app the access its Reminders permission allows. Selectors
// are checked before every call, so an OS update that renames one costs only
// the URL field.

@objc private protocol RKStore {
  @objc(fetchRemindersWithDACalendarItemUniqueIdentifiers:inList:error:)
  func fetchReminders(_ ids: NSArray, inList list: AnyObject?) throws -> NSDictionary
}

@objc private protocol RKSaveRequest {
  @objc(initWithStore:) init(store: AnyObject)
  @objc(updateReminder:) func update(_ reminder: AnyObject) -> AnyObject
  @objc(saveSynchronouslyWithError:) func saveSynchronously() throws
}

@objc private protocol RKAttachmentChanges {
  @objc(setURLAttachmentWithURL:) func setURL(_ url: NSURL)
  @objc(removeURLAttachments) func removeURLs()
}

enum ReminderKit {
  nonisolated(unsafe) private static let store: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW) != nil,
          let type = NSClassFromString("REMStore") as? NSObject.Type else {
      NSLog("ReminderKit unavailable; the URL field falls back to EventKit's url")
      return nil
    }
    return type.init()
  }()

  private static func responds(_ object: AnyObject?, _ selectors: String...) -> Bool {
    guard let object else { return false }
    return selectors.allSatisfy { object.responds(to: NSSelectorFromString($0)) }
  }

  /// ReminderKit reminders by EventKit id (the same UUID in both).
  private static func reminders(_ ids: [String]) throws -> [String: NSObject] {
    guard !ids.isEmpty else { return [:] }
    guard let store, responds(store, "fetchRemindersWithDACalendarItemUniqueIdentifiers:inList:error:") else {
      throw ReminderStore.Failure(description: "ReminderKit can't fetch reminders on this macOS")
    }
    let found = try unsafeBitCast(store, to: RKStore.self).fetchReminders(ids as NSArray, inList: nil)
    var out: [String: NSObject] = [:]
    for (key, value) in found {
      guard let reminder = value as? NSObject else { continue }
      if let id = key as? String {
        out[id] = reminder
      } else if let uuid = (reminder.value(forKey: "remObjectID") as? NSObject)?.value(forKey: "uuid") as? UUID {
        out[uuid.uuidString] = reminder
      }
    }
    return out
  }

  /// The URL field of each reminder that has one, by EventKit id; empty if
  /// ReminderKit fails, so reads fall back to EventKit's url.
  static func attachmentURLs(_ ids: [String]) -> [String: String] {
    do {
      var out: [String: String] = [:]
      for (id, reminder) in try reminders(ids) {
        guard responds(reminder, "attachmentContext"),
              let context = reminder.value(forKey: "attachmentContext") as? NSObject,
              responds(context, "urlAttachments"),
              let first = (context.value(forKey: "urlAttachments") as? [NSObject])?.first,
              responds(first, "url"), let url = first.value(forKey: "url") as? URL else { continue }
        out[id] = url.absoluteString
      }
      return out
    } catch {
      NSLog("reading reminder URLs failed: \(error)")
      return [:]
    }
  }

  /// Sets (or, with nil, removes) the URL field the way Reminders.app does.
  static func setAttachmentURL(_ id: String, _ url: URL?) throws {
    guard let store, let reminder = try reminders([id])[id] else {
      throw ReminderStore.Failure(description: "ReminderKit can't find the reminder")
    }
    guard let requestType = NSClassFromString("REMSaveRequest"),
          requestType.instancesRespond(to: NSSelectorFromString("initWithStore:")) else {
      throw ReminderStore.Failure(description: "ReminderKit has no save request on this macOS")
    }
    let request = unsafeBitCast(requestType, to: RKSaveRequest.Type.self).init(store: store)
    guard responds(request, "updateReminder:", "saveSynchronouslyWithError:") else {
      throw ReminderStore.Failure(description: "ReminderKit's save request changed on this macOS")
    }
    let change = request.update(reminder)
    guard responds(change, "attachmentContext"),
          let context = (change as? NSObject)?.value(forKey: "attachmentContext") as? NSObject,
          responds(context, "setURLAttachmentWithURL:", "removeURLAttachments") else {
      throw ReminderStore.Failure(description: "ReminderKit's attachment API changed on this macOS")
    }
    let attachments = unsafeBitCast(context, to: RKAttachmentChanges.self)
    if let url { attachments.setURL(url as NSURL) } else { attachments.removeURLs() }
    try request.saveSynchronously()
  }
}
