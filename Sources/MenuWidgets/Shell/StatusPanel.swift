import AppKit
import Combine
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
  private var labelImage: LabelImage?
  private var outsideClickMonitor: Any?
  private var keyMonitor: Any?
  private let willOpen: () -> Void
  private let didClose: () -> Void
  private let escape: () -> Bool
  private let shutdown: () -> Void
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
    escape = { [weak widget] in widget?.handleEscape() ?? false }
    shutdown = { [weak widget] in widget?.shutdown() }

    popup = FloatingPanel()
    popupHosting = NSHostingView(rootView: AnyView(EmptyView()))
    super.init()
    host.controller = self

    // Label: SwiftUI drawn into the status button's image (see LabelImage).
    if let button = statusItem.button {
      labelImage = LabelImage(id: widget.id, content: AnyView(widget.label()), item: statusItem, button: button)
      if #available(macOS 27, *) {
        // The menu bar opens and closes the popup (see the delegate below).
        statusItem.expandedInterfaceDelegate = self
      } else {
        button.target = self
        button.action = #selector(togglePopup)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      }
    }

    let root = PopupChrome(content: AnyView(widget.panel(host: host))) { [weak self] size in
      self?.resizePopup(to: size)
    }
    .environmentObject(host)
    popupHosting.rootView = AnyView(root)
    popup.setContent(popupHosting)
  }

  var isOpen: Bool { popup.isVisible }

  /// Before macOS 27: the icon's click toggles the popup. (Clicks on our own
  /// icon reach us as our own events there, so the outside-click monitor
  /// never sees them.)
  @objc func togglePopup() {
    isOpen ? close() : open()
  }

  /// Shows the popup. On macOS 27 a click on the icon does this through
  /// the menu bar's session; calling it directly (the debug hooks) shows
  /// the popup without one.
  func open() {
    guard !isOpen else { return }
    willOpen()
    statusItem.button?.highlight(true)
    position()
    popup.orderFrontRegardless()
    popup.makeKey()
    installMonitors()
  }

  /// Closes the popup: Esc, a click elsewhere, or the widget asking. On
  /// macOS 27 that ends the menu bar's session, which then calls hide().
  func close() {
    if #available(macOS 27, *), let session = statusItem.expandedInterfaceSession {
      session.cancel()
    }
    hide()
  }

  private func hide() {
    guard isOpen else { return }
    host.cancelAim()
    hideSidePaneNow()
    popup.orderOut(nil)
    statusItem.button?.highlight(false)
    removeMonitors()
    didClose()
  }

  /// Takes the item out of the menu bar and stops the widget (it was turned
  /// off in the config).
  func remove() {
    close()
    if #available(macOS 27, *) { statusItem.expandedInterfaceDelegate = nil }
    NSStatusBar.system.removeStatusItem(statusItem)
    shutdown()
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

  /// The side pane's frame on screen while it's showing.
  var sidePaneFrame: NSRect? {
    guard let pane = sidePane, pane.isVisible else { return nil }
    return pane.frame
  }

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
    // Clicks anywhere outside the app close the popup, the menu bar
    // included: on macOS 27 the menu bar doesn't end the session when the
    // icon is clicked again (it just swallows the click), but this monitor
    // sees it. The session begins on mouse-down, so ending it here can't
    // race a reopen the way target/action on mouse-up did.
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isOpen else { return }
        self.close()
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown, event.keyCode == 53 { // Esc
        if !self.escape() { self.close() }
        return nil
      }
      if event.type == .leftMouseDown {
        // A click in another of our status items' buttons closes this one.
        // Only status-bar windows count: a click in one of our pop-up
        // menus (a Picker in the panel) must not close the panel.
        let w = event.window
        if w !== self.statusItem.button?.window, let w, w.className.contains("StatusBar") {
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

/// macOS 27: the menu bar opens the popup by beginning a session (a click on
/// the icon or the padding around it, or menu bar keyboard navigation) and
/// may end it. The app ends it through close(): Esc, a link opened from the
/// panel, or any click outside the app, including on the icon itself.
@available(macOS 27, *)
extension StatusPanel: NSStatusItemExpandedInterfaceDelegate {
  nonisolated func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
    MainActor.assumeIsolated { open() }
  }

  nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
    MainActor.assumeIsolated { hide() }
  }
}

/// Draws the label into the status button's image. On a screen other than
/// the active one the menu bar dims each button's own image and title, as
/// it does the system's icons, but not views added to the button, so a live
/// SwiftUI label stayed bright there. The image is redrawn whenever the
/// label's state changes, at 1x and 2x, in the menu bar's appearance (a
/// colored label can't be a template image, which would adapt by itself).
/// The item's length follows the image's width. The menu bar already spaces
/// items apart, so only a point a side, which keeps the open highlight off
/// the text.
///
/// Setting the image makes AppKit snapshot the button for the item's copies
/// on other screens, and it sets the button's appearance to do so, which
/// fires the appearance observer. Reacting to that by redrawing looped
/// forever (two thirds of a core, plus MenuBarAgent redrawing the copies).
/// So the appearance is read on the next pass, after the snapshot has put
/// it back, and an image with the same pixels as the last isn't set again.
/// A label that still changes more than a couple of times a second is
/// logged, in case another loop like that creeps in.
@MainActor
private final class LabelImage {
  private let id: String
  private weak var item: NSStatusItem?
  private let appearance = LabelAppearance()
  private let renderers: [ImageRenderer<AnyView>]
  private var changes: [AnyCancellable] = []
  private var appearanceObservation: NSKeyValueObservation?
  private var renderPending = false
  private var lastPixels: [Data] = []
  private var burstStart = Date.distantPast
  private var burstCount = 0
  private var lastWarning = Date.distantPast

  init(id: String, content: AnyView, item: NSStatusItem, button: NSStatusBarButton) {
    self.id = id
    self.item = item
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    let root = AnyView(LabelImageContent(content: content, appearance: appearance))
    renderers = [1, 2].map { scale in
      let renderer = ImageRenderer(content: root)
      renderer.scale = scale
      return renderer
    }
    for renderer in renderers {
      changes.append(renderer.objectWillChange.sink { [weak self] in self?.setNeedsRender() })
    }
    appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.setNeedsRender() }
    }
    render()
  }

  /// objectWillChange fires before the state changes, and both renderers
  /// fire it: render once, on the next pass of the run loop.
  private func setNeedsRender() {
    guard !renderPending else { return }
    renderPending = true
    DispatchQueue.main.async { [weak self] in self?.render() }
  }

  private func render() {
    guard let item, let button = item.button else {
      renderPending = false
      return
    }
    // Still pending, so the renderers' objectWillChange doesn't queue
    // another pass.
    let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let scheme: ColorScheme = dark ? .dark : .light
    if appearance.colorScheme != scheme { appearance.colorScheme = scheme }
    renderPending = false

    var image: NSImage?
    var pixels: [Data] = []
    for renderer in renderers {
      guard let cg = renderer.cgImage else { continue }
      let size = NSSize(width: CGFloat(cg.width) / renderer.scale, height: CGFloat(cg.height) / renderer.scale)
      let rep = NSBitmapImageRep(cgImage: cg)
      rep.size = size
      if image == nil { image = NSImage(size: size) }
      image?.addRepresentation(rep)
      pixels.append((cg.dataProvider?.data as Data?) ?? Data())
      pixels.append(withUnsafeBytes(of: (cg.width, cg.height)) { Data($0) })
    }
    guard pixels != lastPixels || button.image == nil else { return }
    lastPixels = pixels
    button.image = image
    if let image { item.length = ceil(image.size.width) + 2 }
    noteImageChange()
  }

  /// Logs (at most once a minute) when the image changed more than 20 times
  /// in 10 seconds. Each change redraws the item on every screen's menu bar.
  private func noteImageChange() {
    let now = Date()
    if now.timeIntervalSince(burstStart) > 10 {
      burstStart = now
      burstCount = 0
    }
    burstCount += 1
    guard burstCount > 20, now.timeIntervalSince(lastWarning) > 60 else { return }
    lastWarning = now
    NSLog("labels: \(id) changed its image \(burstCount) times in 10 seconds")
  }
}

@MainActor
private final class LabelAppearance: ObservableObject {
  @Published var colorScheme: ColorScheme = .dark
}

private struct LabelImageContent: View {
  let content: AnyView
  @ObservedObject var appearance: LabelAppearance

  var body: some View {
    content
      .fixedSize()
      .environment(\.colorScheme, appearance.colorScheme)
  }
}
