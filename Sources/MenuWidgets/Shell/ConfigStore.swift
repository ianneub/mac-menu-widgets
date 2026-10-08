import Foundation
import WidgetsCore

/// The live config, reloaded when ~/.config/menu-widgets/config.json changes.
/// Watches the folder (editors that save by replacing the file) and the file
/// itself (editors that write it in place).
@MainActor
final class ConfigStore: ObservableObject {
  static let shared = ConfigStore()
  @Published private(set) var config = WidgetsConfig.load()
  private var dirSource: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var pending: DispatchWorkItem?

  private init() {
    let dir = WidgetsConfig.directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    dirSource = Self.watch(dir.path, [.write, .rename, .delete]) { [weak self] in self?.scheduleReload() }
    watchFile()
  }

  func update(_ change: (inout WidgetsConfig) -> Void) {
    var c = config
    change(&c)
    config = c
    try? c.save()
  }

  /// Saves arrive as bursts (truncate, then write; or write, then rename):
  /// read the file once things have settled.
  private func scheduleReload() {
    pending?.cancel()
    let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
    pending = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
  }

  private func reload() {
    // A replaced file is a new inode: watch the new one.
    watchFile()
    // A half-written or mistyped file keeps the current settings rather
    // than flipping everything back to the defaults.
    guard let c = WidgetsConfig.loadIfValid() else { return }
    config = c
  }

  private func watchFile() {
    fileSource?.cancel()
    fileSource = Self.watch(WidgetsConfig.fileURL.path, [.write, .extend, .rename, .delete]) { [weak self] in
      self?.scheduleReload()
    }
  }

  private static func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                            _ handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
    src.setEventHandler { MainActor.assumeIsolated { handler() } }
    src.setCancelHandler { close(fd) }
    src.resume()
    return src
  }
}
