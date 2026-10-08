import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var widgets: [StatusPanel] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Status items are added right to left, so the last one created sits
    // furthest left. Order on screen: Claude | weather | time (time nearest
    // the system clock, like the Omarchy bar).
    widgets = WidgetRegistry.makeAll()

    // Development aid: MENU_WIDGETS_OPEN=<widget id> opens that popup at
    // launch, for screenshots without clicking.
    if let id = ProcessInfo.processInfo.environment["MENU_WIDGETS_OPEN"],
       let panel = widgets.first(where: { $0.widgetID == id }) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { panel.open() }
    }
  }
}
