import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var widgets: [StatusPanel] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Status items are added right to left, so the last one created sits
    // furthest left. Order on screen: mail | Claude | weather | time | reminders
    // (like the Omarchy bar). macOS 27 may put a new item at the far left
    // instead; ⌘-drag moves it, and the spot is kept.
    widgets = WidgetRegistry.makeAll()

    // Development aid: MENU_WIDGETS_OPEN=<widget id> opens that popup at
    // launch, for screenshots without clicking.
    if let id = ProcessInfo.processInfo.environment["MENU_WIDGETS_OPEN"],
       let panel = widgets.first(where: { $0.widgetID == id }) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { panel.open() }
    }
  }
}
