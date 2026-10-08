import Foundation
import WidgetsCore

/// The live config, reloaded when ~/.config/menu-widgets/config.json changes.
@MainActor
final class ConfigStore: ObservableObject {
  static let shared = ConfigStore()
  @Published private(set) var config = WidgetsConfig.load()
  private var source: DispatchSourceFileSystemObject?

  private init() { watch() }

  func update(_ change: (inout WidgetsConfig) -> Void) {
    var c = config
    change(&c)
    config = c
    try? c.save()
  }

  private func watch() {
    let dir = WidgetsConfig.directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    src.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.config = WidgetsConfig.load() }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    source = src
  }
}
