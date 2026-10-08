import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var widgets: [String: StatusPanel] = [:]
  private var configSub: AnyCancellable?
  private var termSource: DispatchSourceSignal?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Status items are added right to left, so the last one created sits
    // furthest left. Order on screen: mail | Claude | weather | time | reminders
    // (like the Omarchy bar). macOS 27 may put a new item at the far left
    // instead; ⌘-drag moves it, and the spot is kept.
    // A widget turned off in the config ("enabled": false) is never created,
    // and turning one off or on while running removes or adds it.
    let config = ConfigStore.shared
    configSub = config.$config
      .map(WidgetRegistry.enabledIDs)
      .removeDuplicates()
      .sink { [weak self] ids in self?.sync(enabled: Set(ids), config: config) }

    // launchd stops the app with SIGTERM, which skips the normal quit path:
    // route it through terminate so widgets stop their child processes
    // (`hey watch`) instead of leaving them running without a parent.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { NSApp.terminate(nil) }
    term.resume()
    termSource = term

    // Development aid: MENU_WIDGETS_OPEN=<widget id> opens that popup at
    // launch, for screenshots without clicking.
    if let id = ProcessInfo.processInfo.environment["MENU_WIDGETS_OPEN"], let panel = widgets[id] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { panel.open() }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    widgets.values.forEach { $0.remove() }
  }

  private func sync(enabled: Set<String>, config: ConfigStore) {
    for (id, panel) in widgets where !enabled.contains(id) {
      panel.remove()
      widgets[id] = nil
    }
    for entry in WidgetRegistry.all where enabled.contains(entry.id) && widgets[entry.id] == nil {
      widgets[entry.id] = entry.make(config)
    }
  }
}
