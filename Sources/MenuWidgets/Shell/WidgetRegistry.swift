import AppKit
import WidgetsCore

@MainActor
enum WidgetRegistry {
  struct Entry {
    let id: String
    let enabled: (WidgetsConfig) -> Bool
    let make: (ConfigStore) -> StatusPanel
  }

  /// Every widget, in creation order. Status items are placed right to left
  /// in creation order, so the first one sits nearest the system clock.
  static let all: [Entry] = [
    // Right of the clock, as on the Omarchy bar.
    Entry(id: "reminders", enabled: { $0.reminders.enabled }, make: { _ in StatusPanel(RemindersWidget()) }),
    Entry(id: "time", enabled: { $0.time.enabled }, make: { StatusPanel(TimeWidget(config: $0)) }),
    Entry(id: "weather", enabled: { $0.weather.enabled }, make: { StatusPanel(WeatherWidget(config: $0)) }),
    Entry(id: "agents", enabled: { $0.agents.enabled }, make: { StatusPanel(AgentsWidget(config: $0)) }),
    Entry(id: "mail", enabled: { $0.mail.enabled }, make: { StatusPanel(MailWidget(config: $0)) }),
  ]

  /// The ids of the widgets the config turns on, in registry order.
  static func enabledIDs(_ config: WidgetsConfig) -> [String] {
    all.filter { $0.enabled(config) }.map(\.id)
  }
}
