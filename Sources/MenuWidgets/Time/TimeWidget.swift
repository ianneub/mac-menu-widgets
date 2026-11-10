import SwiftUI
import WidgetsCore

/// World clock, after ianneub.time on the Omarchy desktop (itself after the
/// iStat Menus time dropdown): the time in the menu bar; the popup has the
/// local time, the moon and the configured zones, with a detail pane beside
/// it for whichever row is hovered or picked with ↑/↓, and a slider that
/// moves the clocks to another time of day.
@MainActor
final class TimeWidget: MenuWidget {
  let id = "time"
  let state: TimeState

  init(config: ConfigStore) {
    state = TimeState(config: config)
  }

  func label() -> some View { TimeBarLabel(state: state) }
  func shutdown() { state.stop() }

  func panel(host: PanelHost) -> some View {
    state.host = host
    openForDebugging(host)
    return TimePanel(state: state, host: host)
  }

  /// MENU_WIDGETS_TIME_DETAIL=<n> opens the popup at launch with the pane on
  /// row n (-1 here, -3 the moon phases, 0.. the zones), for checking layout
  /// without a pointer. The desktop's `omarchy-shell ianneub.time detail <n>`.
  /// MENU_WIDGETS_TIME_SHIFT=<steps> opens it with the time slider moved that
  /// many quarter hours (negative for earlier), alone or with a pane.
  private func openForDebugging(_ host: PanelHost) {
    if let dir = ProcessInfo.processInfo.environment["MENU_WIDGETS_TIME_SNAPSHOT"] {
      DispatchQueue.main.async { [state] in Self.snapshot(state: state, host: host, to: dir) }
      return
    }
    let detail = ProcessInfo.processInfo.environment["MENU_WIDGETS_TIME_DETAIL"].flatMap { Int($0) }
    let shift = ProcessInfo.processInfo.environment["MENU_WIDGETS_TIME_SHIFT"].flatMap { Int($0) }
    guard detail != nil || shift != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [state] in
      host.controller?.open()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        if let shift { state.setShift(shift) }
        if let detail { state.shownIndex = detail }
      }
    }
  }

  /// MENU_WIDGETS_TIME_SNAPSHOT=<dir> renders the panel and panes to PNGs
  /// (light and dark) and quits: a layout check where screen capture isn't
  /// allowed.
  private static func snapshot(state: TimeState, host: PanelHost, to dir: String) {
    func render<V: View>(_ view: V, _ name: String) {
      for scheme in [ColorScheme.light, .dark] {
        let bg = scheme == .light ? Color(white: 0.93) : Color(white: 0.16)
        let r = ImageRenderer(content: view.fixedSize().background(bg).environment(\.colorScheme, scheme))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
      }
    }
    if state.showsCalendar { state.calendar.popupWillOpen() }
    state.shownIndex = 1
    render(TimePanel(state: state, host: host), "panel")
    for (i, n) in [(-1, "here"), (0, "london"), (1, "utc"), (5, "anchorage")] {
      render(TimeDetailPane(state: state, index: i), "detail-\(n)")
    }
    render(TimeMoonPane(state: state), "moon")
    state.setShift(38)
    render(TimePanel(state: state, host: host), "panel-shifted")
    render(TimeDetailPane(state: state, index: 0), "detail-london-shifted")
    NSApp.terminate(nil)
  }

  func popupWillOpen() { state.popupWillOpen() }
  func popupDidClose() { state.popupDidClose() }
  func handleEscape() -> Bool { state.escape() }
}

private struct TimeBarLabel: View {
  @ObservedObject var state: TimeState

  var body: some View {
    Text(state.barText)
      .font(Font(NSFont.menuBarFont(ofSize: 0)))
      .monospacedDigit()
  }
}
