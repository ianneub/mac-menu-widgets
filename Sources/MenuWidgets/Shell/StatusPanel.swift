import AppKit
import SwiftUI

/// Owns one status item and its popup: a borderless panel under the item
/// (closes on click-outside or Esc), plus an optional side pane floating to
/// the left of it for hover detail.
@MainActor
final class StatusPanel: NSObject {
  let statusItem: NSStatusItem
  let widgetID: String
  let host = PanelHost()
  private let popup: FloatingPanel
  private let popupHosting: NSHostingView<AnyView>
  private var sidePane: FloatingPanel?
  private var sidePaneHosting: NSHostingView<AnyView>?
  private var sidePaneAnchorY: CGFloat = 0
  private var hideWork: DispatchWorkItem?
  private var outsideClickMonitor: Any?
  private var keyMonitor: Any?
  private let willOpen: () -> Void
  private let didClose: () -> Void
  /// Keeps the widget alive: the registry creates it and hands it over.
  private let widget: AnyObject

  static let gap: CGFloat = 8
  static let corner: CGFloat = 12

  init<W: MenuWidget>(_ widget: W) {
    widgetID = widget.id
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.autosaveName = "com.ianneub.menu-widgets.\(widget.id)"
    self.widget = widget
    willOpen = { [weak widget] in widget?.popupWillOpen() }
    didClose = { [weak widget] in widget?.popupDidClose() }

    popup = FloatingPanel()
    popupHosting = NSHostingView(rootView: AnyView(EmptyView()))
    super.init()
    host.controller = self

    // Label: SwiftUI inside the status button; the item's length follows
    // the label's measured width. The menu bar already spaces items apart, so
    // only a point a side, which keeps the open highlight off the text.
    if let button = statusItem.button {
      let label = LabelContainer(content: AnyView(widget.label())) { [weak self] width in
        self?.statusItem.length = ceil(width) + 2
      }
      let labelHosting = NSHostingView(rootView: label)
      labelHosting.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(labelHosting)
      NSLayoutConstraint.activate([
        labelHosting.centerXAnchor.constraint(equalTo: button.centerXAnchor),
        labelHosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      ])
      button.target = self
      button.action = #selector(togglePopup)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    let root = PopupChrome(content: AnyView(widget.panel(host: host))) { [weak self] size in
      self?.resizePopup(to: size)
    }
    .environmentObject(host)
    popupHosting.rootView = AnyView(root)
    popup.setContent(popupHosting)
  }

  var isOpen: Bool { popup.isVisible }

  @objc func togglePopup() {
    isOpen ? close() : open()
  }

  func open() {
    willOpen()
    statusItem.button?.highlight(true)
    position()
    popup.orderFrontRegardless()
    popup.makeKey()
    installMonitors()
  }

  func close() {
    guard isOpen else { return }
    hideSidePaneNow()
    popup.orderOut(nil)
    statusItem.button?.highlight(false)
    removeMonitors()
    didClose()
  }

  // MARK: popup geometry

  private func position() {
    guard let button = statusItem.button, let window = button.window else { return }
    let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = window.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    let size = popup.frame.size
    // Right-align under the item (the popups grow leftward, so side panes
    // have room), clamped to the screen.
    var x = itemFrame.maxX - size.width
    x = min(max(x, visible.minX + Self.gap), visible.maxX - size.width - Self.gap)
    let y = itemFrame.minY - Self.gap / 2 - size.height
    popup.setFrameOrigin(NSPoint(x: x, y: y))
    repositionSidePane()
  }

  private func resizePopup(to size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let old = popup.frame
    guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
    // Keep the top edge fixed while the content grows or shrinks.
    let top = old.maxY
    popup.setContentSize(size)
    if isOpen {
      position()
    } else {
      popup.setFrameOrigin(NSPoint(x: old.minX, y: top - size.height))
    }
  }

  // MARK: side pane

  func showSidePane(_ view: AnyView, anchorY: CGFloat) {
    hideWork?.cancel()
    hideWork = nil
    sidePaneAnchorY = anchorY
    let pane: FloatingPanel
    let hosting: NSHostingView<AnyView>
    if let p = sidePane, let h = sidePaneHosting {
      pane = p
      hosting = h
    } else {
      pane = FloatingPanel()
      hosting = NSHostingView(rootView: AnyView(EmptyView()))
      pane.setContent(hosting)
      sidePane = pane
      sidePaneHosting = hosting
    }
    let chrome = PopupChrome(content: view) { [weak self] size in
      guard let self, let pane = self.sidePane else { return }
      pane.setContentSize(size)
      self.repositionSidePane()
    }
    .onHover { [weak self] inside in
      guard let self else { return }
      self.host.pointerInSidePane = inside
      if inside {
        self.hideWork?.cancel()
        self.hideWork = nil
      }
    }
    .environmentObject(host)
    hosting.rootView = AnyView(chrome)
    let fit = hosting.fittingSize
    if fit.width > 0, fit.height > 0 { pane.setContentSize(fit) }
    repositionSidePane()
    if !pane.isVisible { pane.orderFrontRegardless() }
  }

  func hideSidePane(after delay: TimeInterval) {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.host.pointerInSidePane else { return }
      self.hideSidePaneNow()
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func hideSidePaneNow() {
    hideWork?.cancel()
    hideWork = nil
    sidePane?.orderOut(nil)
    host.pointerInSidePane = false
  }

  private func repositionSidePane() {
    guard let pane = sidePane else { return }
    let main = popup.frame
    let size = pane.frame.size
    let visible = (popup.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    var x = main.minX - Self.gap - size.width
    x = max(x, visible.minX + Self.gap)
    var top = main.maxY - sidePaneAnchorY
    top = min(top, visible.maxY - Self.gap)
    var y = top - size.height
    y = max(y, visible.minY + Self.gap)
    pane.setFrameOrigin(NSPoint(x: x, y: y))
  }

  // MARK: dismissal

  private func installMonitors() {
    removeMonitors()
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      Task { @MainActor in self?.close() }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown, event.keyCode == 53 { // Esc
        self.close()
        return nil
      }
      if event.type == .leftMouseDown {
        // A click in another of our status items' buttons closes this one.
        let w = event.window
        if w !== self.popup, w !== self.sidePane, w !== self.statusItem.button?.window {
          self.close()
        }
      }
      return event
    }
  }

  private func removeMonitors() {
    if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
    if let m = keyMonitor { NSEvent.removeMonitor(m) }
    outsideClickMonitor = nil
    keyMonitor = nil
  }
}

/// Borderless, non-activating panel with a vibrant rounded background.
final class FloatingPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .popUpMenu
    hasShadow = true
    isOpaque = false
    backgroundColor = .clear
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    isMovable = false
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func setContent(_ view: NSView) {
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = StatusPanel.corner
    effect.layer?.masksToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      view.topAnchor.constraint(equalTo: effect.topAnchor),
      view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    contentView = effect
  }
}

/// Measures the popup content and reports its size so the panel can fit it.
private struct PopupChrome: View {
  let content: AnyView
  let onSize: (CGSize) -> Void

  var body: some View {
    content
      .fixedSize()
      .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
  }
}

private struct LabelContainer: View {
  let content: AnyView
  let onWidth: (CGFloat) -> Void

  var body: some View {
    content
      .fixedSize()
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onWidth($0) }
  }
}
