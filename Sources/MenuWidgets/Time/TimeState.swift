import AppKit
import Combine
import SwiftUI
import WidgetsCore

/// A place the detail pane can show: here, or one of the configured zones.
struct TimePlace: Equatable {
  var name: String
  var offset: Int
  var abbr: String
  var coord: TimeModel.Coord?
}

/// One world clock row, ready to draw.
struct TimeZoneRow: Identifiable {
  let id: Int
  var name: String
  var detail: String
  var time: String
  var suffix: String
  var alt: String
}

/// Shared state for the time widget: the minute clock, the zones and which
/// row's detail pane is showing.
@MainActor
final class TimeState: ObservableObject {
  /// Detail selection: -2 none, -1 here, 0.. a zone row; -3 is the moon row,
  /// which pops out the phase list instead.
  static let none = -2, here = -1, moon = -3

  @Published private(set) var now = Date()
  @Published var shownIndex = TimeState.none
  /// Bumped each time the popup opens, so the panel can grab key focus.
  @Published var openCount = 0
  /// The moon row's top, in panel coordinates (for lining up its pop-out).
  var moonRowY: CGFloat = 0

  private(set) var hoverTarget = TimeState.none
  private var hideWork: DispatchWorkItem?
  private var tick: Timer?
  private var bag: Set<AnyCancellable> = []
  let config: ConfigStore
  weak var host: PanelHost?
  let zoneCoords = TimeModel.systemZoneCoords()

  init(config: ConfigStore) {
    self.config = config
    config.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.objectWillChange.send() }
    }.store(in: &bag)
    let nc = NotificationCenter.default
    nc.publisher(for: .NSSystemTimeZoneDidChange).sink { [weak self] _ in
      NSTimeZone.resetSystemTimeZone()
      self?.refresh()
    }.store(in: &bag)
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
      self?.refresh()
    }.store(in: &bag)
    scheduleTick()
  }

  /// Turned off in the config: no more ticks or notifications.
  func stop() {
    tick?.invalidate()
    tick = nil
    bag.removeAll()
    hideWork?.cancel()
  }

  /// Re-reads the clock and re-arms the minute timer (timers drift over sleep).
  func refresh() {
    now = Date()
    scheduleTick()
  }

  private func scheduleTick() {
    tick?.invalidate()
    let t = Date().timeIntervalSince1970
    let next = Date(timeIntervalSince1970: (floor(t / 60) + 1) * 60 + 0.05)
    let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    tick = timer
  }

  // MARK: Derived

  var use24h: Bool { config.config.time.timeFormat == "24h" }
  var zones: [WidgetsConfig.Zone] { TimeModel.normalizeZones(config.config.time.zones) }
  var nowMs: Double { now.timeIntervalSince1970 * 1000 }
  var local: TimeModel.ZoneOffset { TimeModel.zoneOffset(.current, at: now) }

  var barText: String {
    TimeModel.barLabel(now, use24h, showDate: config.config.time.showDate)
  }

  func zoneOffset(_ i: Int) -> TimeModel.ZoneOffset? {
    let z = zones
    guard i >= 0, i < z.count, let tz = TimeZone(identifier: z[i].tz) else { return nil }
    return TimeModel.zoneOffset(tz, at: now, id: z[i].tz)
  }

  var rows: [TimeZoneRow] {
    let localOffset = local.offset
    return zones.enumerated().map { i, z in
      guard let off = zoneOffset(i) else {
        return TimeZoneRow(id: i, name: z.name, detail: "Unknown zone \(z.tz)", time: "", suffix: "", alt: "")
      }
      let c = TimeModel.zoneClock(nowMs, off.offset, localOffset)
      let t = TimeModel.clockText(c.hours, c.minutes, use24h)
      let day = TimeModel.dayDeltaLabel(c.dayDelta)
      return TimeZoneRow(
        id: i, name: z.name,
        detail: TimeModel.relativeLabel(off.offset, localOffset) + " (" + TimeModel.offsetLabel(off.offset) + ")"
          + (day.isEmpty ? "" : " · " + day),
        time: t.time, suffix: t.suffix,
        alt: TimeModel.clockLabel(c.hours, c.minutes, !use24h))
    }
  }

  func place(_ index: Int) -> TimePlace? {
    if index == TimeState.here {
      let w = config.config.weather
      let l = local
      return TimePlace(
        name: w.name.isEmpty ? "Current Location" : w.name, offset: l.offset, abbr: l.abbr,
        coord: w.latitude.isFinite && w.longitude.isFinite ? .init(lat: w.latitude, lon: w.longitude) : nil)
    }
    let z = zones
    guard index >= 0, index < z.count, let off = zoneOffset(index) else { return nil }
    let coord = z[index].lat.flatMap { lat in z[index].lon.map { TimeModel.Coord(lat: lat, lon: $0) } }
      ?? zoneCoords[z[index].tz]
    return TimePlace(name: z[index].name, offset: off.offset, abbr: off.abbr, coord: coord)
  }

  /// Every place with coordinates, for the map's dots.
  var mapDots: [TimeModel.Coord] {
    (-1..<zones.count).compactMap { place($0)?.coord }
  }

  // MARK: Hover and keys

  func hoverEnter(_ index: Int) {
    hoverTarget = index
    hideWork?.cancel()
    hideWork = nil
    if shownIndex != index { shownIndex = index }
  }

  func hoverExit(_ index: Int) {
    if hoverTarget == index { hoverTarget = TimeState.none }
    scheduleHide()
  }

  /// The pane outlives the row by a moment so the pointer can cross the gap
  /// onto it; it stays while the pointer is over it.
  func scheduleHide() {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.hoverTarget == TimeState.none, self.host?.pointerInSidePane != true {
        self.shownIndex = TimeState.none
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  /// Up/Down walk the rows in screen order (here, the moon, then the
  /// zones); the pane follows. From no selection, Down starts at the top
  /// and Up at the bottom.
  func step(_ delta: Int) {
    let order = [TimeState.here, TimeState.moon] + Array(zones.indices)
    guard let current = order.firstIndex(of: shownIndex) else {
      shownIndex = delta > 0 ? order[0] : order[order.count - 1]
      return
    }
    shownIndex = order[max(0, min(order.count - 1, current + delta))]
  }

  func popupWillOpen() {
    refresh()
    openCount += 1
  }

  func popupDidClose() {
    hideWork?.cancel()
    hoverTarget = TimeState.none
    shownIndex = TimeState.none
  }
}
