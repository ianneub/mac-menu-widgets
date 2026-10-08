import AppKit
import SwiftUI
import WidgetsCore

/// Weather in the menu bar: the condition symbol and current temperature;
/// the popup has current conditions and the forecast strip, and hovering a
/// day (or ↑/↓) opens its hourly detail in a side pane.
@MainActor
final class WeatherWidget: MenuWidget {
  let id = "weather"
  let service: WeatherService
  let state = WeatherPanelState()

  init(config: ConfigStore) {
    service = WeatherService(config: config)
  }

  func label() -> some View { WeatherLabel(service: service) }
  func shutdown() { service.stop() }

  func panel(host: PanelHost) -> some View {
    state.host = host
    state.service = service
    openFromEnvironment(host)
    return WeatherPanel(service: service, state: state)
  }

  /// MENU_WIDGETS_WEATHER_DETAIL=n opens the popup a few seconds after
  /// launch with the detail pane on row n (-1 = none), like the Omarchy
  /// plugin's "detail <n>" IPC. For screenshots and testing.
  private func openFromEnvironment(_ host: PanelHost) {
    guard let raw = ProcessInfo.processInfo.environment["MENU_WIDGETS_WEATHER_DETAIL"], let n = Int(raw) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak host] in
      host?.controller?.open()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.state.shownIndex = n }
    }
  }

  func popupWillOpen() {
    service.refreshIfStale()
    state.opened()
  }

  func popupDidClose() { state.closed() }
}

// MARK: - Label

struct WeatherLabel: View {
  @ObservedObject var service: WeatherService

  var body: some View {
    let current = service.current
    let icon = Weather.currentIcon(current)
    HStack(spacing: 4) {
      Image(systemName: icon.isEmpty ? "cloud" : icon)
        .opacity(current == nil ? 0.5 : 1)
      if let current {
        Text(verbatim: "\(service.useImperial ? current.tempF : current.tempC)°\(service.useImperial ? "F" : "C")")
          .monospacedDigit()
      }
    }
    .font(Font(NSFont.menuBarFont(ofSize: 0)))
  }
}

// MARK: - Panel state

/// Which day the detail pane shows, hover bookkeeping, and the location
/// editor. hoverTarget is the row under the pointer; the pane outlives it
/// by a moment so the pointer can cross the gap onto the pane.
@MainActor
final class WeatherPanelState: ObservableObject {
  weak var host: PanelHost?
  weak var service: WeatherService?

  @Published var shownIndex = -1 {
    didSet {
      guard shownIndex != oldValue else { return }
      hoverHour = -1
      hoverOwner = ""
      syncPane()
    }
  }
  /// The detail pane's hovered hour (-1 none) and which chart owns it.
  @Published var hoverHour = -1
  var hoverOwner = ""
  @Published var openToken = 0
  private var hoverTarget = -1
  private var hideWork: DispatchWorkItem?

  // Location editor.
  @Published var editing = false
  @Published var query = ""
  @Published var suggestions: [Weather.Place] = []
  @Published var suggestionIndex = 0
  private var geocodeTask: Task<Void, Never>?

  func opened() { openToken += 1 }

  func closed() {
    hideWork?.cancel()
    hoverTarget = -1
    shownIndex = -1
    cancelEditing()
  }

  func hoverEnter(_ i: Int) {
    hoverTarget = i
    hideWork?.cancel()
    shownIndex = i
  }

  func hoverExit(_ i: Int) {
    if hoverTarget == i { hoverTarget = -1 }
    scheduleHideCheck()
  }

  func scheduleHideCheck() {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.hoverTarget == -1, self.host?.pointerInSidePane != true else { return }
      self.shownIndex = -1
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  /// Up/Down walk the forecast rows; the pane follows.
  func step(_ delta: Int, count n: Int) {
    guard n > 0 else { return }
    let next = shownIndex < 0 ? (delta > 0 ? 0 : n - 1) : shownIndex + delta
    shownIndex = next < 0 || next >= n ? -1 : next
  }

  private func syncPane() {
    guard let host, let service else { return }
    if shownIndex >= 0 {
      host.showSidePane(anchorY: 0) { DayDetailPane(service: service, state: self) }
    } else {
      host.hideSidePane(after: 0)
    }
  }

  // MARK: location editing

  func startEditing() {
    editing = true
    query = service?.settings.name ?? ""
    suggestions = []
    suggestionIndex = 0
  }

  func cancelEditing() {
    editing = false
    suggestions = []
    geocodeTask?.cancel()
  }

  /// Debounced Open-Meteo geocoding; the latest query wins.
  func queryChanged() {
    geocodeTask?.cancel()
    let q = query.trimmingCharacters(in: .whitespaces)
    guard q.count >= 2 else {
      suggestions = []
      return
    }
    geocodeTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self, let service = self.service else { return }
      let results = await service.geocode(q)
      guard !Task.isCancelled, self.editing else { return }
      self.suggestions = results
      self.suggestionIndex = 0
    }
  }

  func commit() {
    guard !suggestions.isEmpty else { return }
    pick(suggestions[max(0, min(suggestionIndex, suggestions.count - 1))])
  }

  func pick(_ place: Weather.Place) {
    ConfigStore.shared.update {
      $0.weather.name = place.name
      $0.weather.latitude = place.latitude
      $0.weather.longitude = place.longitude
    }
    cancelEditing()
  }
}

// MARK: - Panel

enum WeatherStyle {
  static let caption: CGFloat = 11
  static let bodySmall: CGFloat = 12
  static let body: CGFloat = 13
  static let subtitle: CGFloat = 15
  static let title: CGFloat = 17
  static let display: CGFloat = 24
}

struct WeatherPanel: View {
  @ObservedObject var service: WeatherService
  @ObservedObject var state: WeatherPanelState
  @EnvironmentObject var host: PanelHost
  @FocusState private var focus: Field?

  enum Field { case panel, location }

  static let width: CGFloat = 480

  var body: some View {
    let rows = service.rows
    VStack(alignment: .leading, spacing: 14) {
      hero
      if state.editing && !state.suggestions.isEmpty { suggestionList }
      if service.current == nil {
        Text("Fetching forecast…")
          .font(.system(size: WeatherStyle.bodySmall).italic())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
      }
      if !rows.isEmpty {
        Divider().opacity(0.6)
        ForecastList(service: service, state: state, rows: rows)
      }
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 4)
    .frame(width: Self.width, alignment: .leading)
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .panel)
    .onKeyPress(.upArrow) {
      state.step(-1, count: rows.count)
      return .handled
    }
    .onKeyPress(.downArrow) {
      state.step(1, count: rows.count)
      return .handled
    }
    .onKeyPress(.return) {
      state.startEditing()
      return .handled
    }
    .onKeyPress("r") {
      service.refresh()
      return .handled
    }
    .onChange(of: state.openToken) { focus = .panel }
    .onChange(of: state.editing) { _, editing in focus = editing ? .location : .panel }
    // Leaving the pane hides it (after the grace period) unless the pointer
    // went back onto a row. Only transitions count: the publisher's initial
    // value and repeated writes would hide a pane opened with ↑/↓.
    .onReceive(host.$pointerInSidePane.removeDuplicates().dropFirst()) { inside in
      if !inside { state.scheduleHideCheck() }
    }
  }

  private var unit: String { service.useImperial ? "°F" : "°C" }

  @ViewBuilder private var hero: some View {
    let current = service.current
    let imperial = service.useImperial
    let tempText = current.map { String(imperial ? $0.tempF : $0.tempC) } ?? ""
    // Triple-digit or negative readings step the hero down a size so it
    // never runs into the stats column.
    let wide = tempText.count > 2
    let today = service.todayForecast
    let high = Weather.bareTemp(today, .max, imperial: imperial)
    let low = Weather.bareTemp(today, .min, imperial: imperial)

    HStack(alignment: .center) {
      HStack(spacing: 16) {
        let icon = Weather.currentIcon(current)
        Image(systemName: icon.isEmpty ? "cloud" : icon)
          .symbolRenderingMode(.multicolor)
          .font(.system(size: wide ? 48 : 54))
          .frame(minWidth: 64)
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(tempText.isEmpty ? "—" : tempText)
              .font(.system(size: wide ? 44 : 56, weight: .bold))
              .monospacedDigit()
            if current != nil {
              Text(unit)
                .font(.system(size: WeatherStyle.display))
                .alignmentGuide(.firstTextBaseline) { d in d[.top] + (wide ? 30 : 40) }
            }
          }
          if service.settings.showTodayRange && (!high.isEmpty || !low.isEmpty) {
            HStack(spacing: 10) {
              if !high.isEmpty { Text("H \(high)") }
              if !low.isEmpty { Text("L \(low)").foregroundStyle(.secondary) }
            }
            .font(.system(size: wide ? WeatherStyle.bodySmall : WeatherStyle.subtitle))
          }
        }
      }
      .padding(.leading, 12)

      Spacer(minLength: 12)

      VStack(alignment: .leading, spacing: 12) {
        if state.editing {
          locationField
        } else if !service.settings.name.isEmpty {
          Button {
            state.startEditing()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "mappin.and.ellipse")
              Text(service.settings.name.uppercased()).tracking(1)
            }
            .font(.system(size: WeatherStyle.body))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
          .help("Change location")
        }
        if let current {
          HStack(alignment: .top, spacing: 28) {
            stat("FEELS", (imperial ? current.feelsLikeF : current.feelsLikeC).map { "\($0)\(unit)" } ?? "")
            stat("WIND", (imperial ? current.windMph : current.windKmh).map { "\($0) \(imperial ? "mph" : "km/h")" } ?? "")
            stat("HUMID", current.humidity.map { "\($0)%" } ?? "")
          }
        }
      }
      .padding(.trailing, 16)
    }
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: WeatherStyle.bodySmall))
        .tracking(1)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: WeatherStyle.title))
        .monospacedDigit()
    }
  }

  private var locationField: some View {
    HStack(spacing: 6) {
      TextField("Search city", text: $state.query)
        .textFieldStyle(.roundedBorder)
        .frame(width: 190)
        .focused($focus, equals: .location)
        .onChange(of: state.query) { state.queryChanged() }
        .onSubmit { state.commit() }
        .onKeyPress(.downArrow) {
          if state.suggestionIndex < state.suggestions.count - 1 { state.suggestionIndex += 1 }
          return .handled
        }
        .onKeyPress(.upArrow) {
          if state.suggestionIndex > 0 { state.suggestionIndex -= 1 }
          return .handled
        }
      Button {
        state.cancelEditing()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: WeatherStyle.bodySmall))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Cancel")
    }
  }

  private var suggestionList: some View {
    VStack(spacing: 0) {
      ForEach(Array(state.suggestions.enumerated()), id: \.offset) { i, place in
        let selected = i == state.suggestionIndex
        HStack(spacing: 8) {
          Text(place.name)
            .font(.system(size: WeatherStyle.body))
            .foregroundStyle(selected ? Color.white : Color.primary)
          if !place.description.isEmpty {
            Text(place.description)
              .font(.system(size: WeatherStyle.bodySmall))
              .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
          }
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onHover { if $0 { state.suggestionIndex = i } }
        .onTapGesture { state.pick(place) }
      }
    }
    .padding(.horizontal, 4)
  }
}

// MARK: - Forecast strip

/// One row per day, today first: day, icon, rain %, low, a range bar, high.
/// Every bar is drawn against the strip's shared min/max, so the rows read
/// as one scale; a vertical line marks the current temperature on it.
struct ForecastList: View {
  @ObservedObject var service: WeatherService
  @ObservedObject var state: WeatherPanelState
  let rows: [Weather.Day]

  static let rowHeight: CGFloat = 24
  static let spacing: CGFloat = 4
  static let edge: CGFloat = 12
  static let tempW: CGFloat = 32
  static let iconW: CGFloat = 24
  static let rainW: CGFloat = 32

  var compact: Bool { rows.count > 3 }
  var dayW: CGFloat { compact ? 48 : 88 }
  var width: CGFloat { WeatherPanel.width - 8 }
  var trackX: CGFloat { Self.edge + dayW + 8 + Self.iconW + 4 + Self.rainW + 4 + Self.tempW + 10 }
  var trackW: CGFloat { width - trackX - (Self.edge + Self.tempW + 10) }

  var body: some View {
    let imperial = service.useImperial
    let range = Weather.forecastTempRange(rows, imperial: imperial)
    let currentTemp = service.current.map { Double(imperial ? $0.tempF : $0.tempC) }
    VStack(spacing: Self.spacing) {
      ForEach(Array(rows.enumerated()), id: \.element.date) { i, day in
        row(i, day, range: range, imperial: imperial)
      }
    }
    .frame(width: width)
    .overlay(alignment: .topLeading) {
      // The current-temperature line, one unbroken stroke down the strip.
      if let range, let currentTemp {
        Rectangle()
          .fill(Color.primary.opacity(0.6))
          .frame(width: 2)
          .offset(x: trackX + trackW * Weather.rangeFraction(currentTemp, range) - 1)
          .allowsHitTesting(false)
      }
    }
  }

  private func row(_ i: Int, _ day: Weather.Day, range: Weather.ValueRange?, imperial: Bool) -> some View {
    let lo = Weather.tempValue(day, .min, imperial: imperial)
    let hi = Weather.tempValue(day, .max, imperial: imperial)
    let selected = state.shownIndex == i
    return HStack(spacing: 0) {
      Text(dayLabel(day.date))
        .font(.system(size: WeatherStyle.caption))
        .tracking(1)
        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
        .lineLimit(1)
        .frame(width: dayW, alignment: .leading)
      Spacer().frame(width: 8)
      let icon = Weather.dayIcon(day)
      Image(systemName: icon.isEmpty ? "cloud" : icon)
        .symbolRenderingMode(selected ? .monochrome : .multicolor)
        .font(.system(size: WeatherStyle.subtitle))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(width: Self.iconW)
      Spacer().frame(width: 4)
      // Chance of rain in the accent color; blank on dry days so the wet
      // ones stand out down the column.
      Text(Weather.precipChanceLabel(day))
        .font(.system(size: WeatherStyle.caption).monospacedDigit())
        .foregroundStyle(selected ? Color.white : Color.accentColor)
        .frame(width: Self.rainW, alignment: .leading)
      Spacer().frame(width: 4)
      Text(Weather.bareTemp(day, .min, imperial: imperial))
        .font(.system(size: WeatherStyle.body).monospacedDigit())
        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
        .frame(width: Self.tempW, alignment: .trailing)
      Spacer().frame(width: 10)
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.14))
        if let range, let lo, let hi {
          let a = Weather.rangeFraction(Double(lo), range)
          let b = Weather.rangeFraction(Double(hi), range)
          Capsule()
            .fill(selected ? Color.white : Color.accentColor)
            .frame(width: max(5, trackW * (b - a)))
            .offset(x: trackW * a)
        }
      }
      .frame(width: trackW, height: 5)
      Spacer().frame(width: 10)
      Text(Weather.bareTemp(day, .max, imperial: imperial))
        .font(.system(size: WeatherStyle.body).monospacedDigit())
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(width: Self.tempW, alignment: .leading)
    }
    .padding(.horizontal, Self.edge)
    .frame(width: width, height: Self.rowHeight)
    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
    .contentShape(Rectangle())
    .onHover { inside in inside ? state.hoverEnter(i) : state.hoverExit(i) }
  }

  private func dayLabel(_ date: String) -> String {
    if date == service.today { return "TODAY" }
    guard let d = Weather.noon(of: date) else { return "" }
    let f = DateFormatter()
    f.dateFormat = compact ? "EEE" : "EEEE"
    return f.string(from: d).uppercased()
  }
}
