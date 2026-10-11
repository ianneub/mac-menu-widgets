import AppKit
import Carbon.HIToolbox
import Combine
import WidgetsCore

/// The config's `hotkeys`: global shortcuts that run a command. They go
/// through Carbon's RegisterEventHotKey, which needs no Accessibility or
/// Input Monitoring permission. A registered hotkey is taken from every app,
/// so one limited to some apps is only registered while one of them is
/// frontmost; anywhere else the key reaches the app as usual.
@MainActor
final class HotkeyCenter {
  private var hotkeys: [WidgetsConfig.Hotkey] = []
  /// Registered refs by index into `hotkeys`.
  private var registered: [Int: EventHotKeyRef] = [:]
  private var handler: EventHandlerRef?
  private var configSub: AnyCancellable?
  private var activationObserver: NSObjectProtocol?

  init(config: ConfigStore) {
    let spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let me = Unmanaged.passUnretained(self).toOpaque()
    withUnsafePointer(to: spec) { spec in
      _ = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard let userData else { return OSStatus(eventNotHandledErr) }
        // Carbon delivers hotkey events on the main thread.
        MainActor.assumeIsolated {
          Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().pressed(Int(id.id))
        }
        return noErr
      }, 1, spec, me, &handler)
    }

    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.sync() }
    }
    configSub = config.$config.map(\.hotkeys).removeDuplicates().sink { [weak self] hotkeys in
      self?.unregisterAll()
      self?.hotkeys = hotkeys
      for h in hotkeys where KeyCombo.parse(h.key) == nil || h.command.isEmpty {
        NSLog("hotkeys: ignoring \"\(h.key)\": unknown key or empty command")
      }
      self?.sync()
    }
  }

  func shutdown() {
    unregisterAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
    if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    configSub = nil
  }

  /// Registers the hotkeys that apply to the frontmost app and drops the rest.
  private func sync() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    for (i, h) in hotkeys.enumerated() {
      let wanted = h.apps.isEmpty || front.map(h.apps.contains) == true
      if wanted, registered[i] == nil, let combo = KeyCombo.parse(h.key), !h.command.isEmpty {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D57_486B), id: UInt32(i))  // 'MWHk'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
          registered[i] = ref
        } else {
          // Another app holds it, or macOS refuses it (Option or
          // Option+Shift alone, since macOS 15).
          NSLog("hotkeys: couldn't register \"\(h.key)\" (\(status))")
        }
      } else if !wanted, let ref = registered[i] {
        UnregisterEventHotKey(ref)
        registered[i] = nil
      }
    }
  }

  private func unregisterAll() {
    registered.values.forEach { UnregisterEventHotKey($0) }
    registered = [:]
  }

  private func pressed(_ index: Int) {
    guard hotkeys.indices.contains(index) else { return }
    let h = hotkeys[index]
    let p = Process()
    // env finds a bare program name on PATH; a path is run as is.
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = h.command
    p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.terminationHandler = { p in
      if p.terminationStatus != 0 {
        NSLog("hotkeys: \"\(h.key)\" command exited with \(p.terminationStatus)")
      }
    }
    do {
      try p.run()
    } catch {
      NSLog("hotkeys: \"\(h.key)\" command failed to start: \(error.localizedDescription)")
    }
  }
}
