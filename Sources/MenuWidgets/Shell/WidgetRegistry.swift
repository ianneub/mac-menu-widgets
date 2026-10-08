import AppKit

@MainActor
enum WidgetRegistry {
  /// Status items are placed right to left in creation order, so the first
  /// one sits nearest the system clock.
  static func makeAll() -> [StatusPanel] {
    let config = ConfigStore.shared
    return [
      StatusPanel(TimeWidget(config: config)),
      StatusPanel(WeatherWidget(config: config)),
      StatusPanel(AgentsWidget(config: config)),
    ]
  }
}
