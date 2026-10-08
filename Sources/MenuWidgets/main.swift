import AppKit

// A menu-bar-only app: no Dock icon, no main window. Each widget owns one
// status item and one popup panel (see Shell/StatusPanel.swift).
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.accessory)
  withExtendedLifetime(delegate) { app.run() }
}
