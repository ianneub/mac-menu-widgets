import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var widgets: [String: StatusPanel] = [:]
  private var configSub: AnyCancellable?
  private var termSource: DispatchSourceSignal?
  private var hotkeys: HotkeyCenter?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Status items are added right to left, so the last one created sits
    // furthest left. Order on screen: mail | Claude | weather | time | reminders
    // (like the Omarchy bar). macOS 27 may put a new item at the far left
    // instead; ⌘-drag moves it, and the spot is kept.
    // A widget turned off in the config ("enabled": false) is never created,
    // and turning one off or on while running removes or adds it.
    NSApp.mainMenu = Self.editMenu()

    let config = ConfigStore.shared
    configSub = config.$config
      .map(WidgetRegistry.enabledIDs)
      .removeDuplicates()
      .sink { [weak self] ids in self?.sync(enabled: Set(ids), config: config) }
    hotkeys = HotkeyCenter(config: config)

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

  /// ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z reach a text field through the main menu's key
  /// equivalents, and an accessory app has no main menu unless it makes
  /// one: without this, pasting into a popup's field did nothing. The menu
  /// itself is never shown.
  private static func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editItem.submenu = edit
    let main = NSMenu()
    // The first item is the application menu; it can stay empty.
    main.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    main.addItem(editItem)
    return main
  }

  func applicationWillTerminate(_ notification: Notification) {
    widgets.values.forEach { $0.remove() }
    hotkeys?.shutdown()
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
