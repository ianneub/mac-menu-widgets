import AppKit
import SwiftUI
import WidgetsCore

/// One menu-bar widget: the label drawn in the status item and the popup
/// shown under it. Each widget lives in its own folder (Time/, Weather/,
/// Agents/) and is listed in WidgetRegistry.
@MainActor
protocol MenuWidget: AnyObject {
  associatedtype Label: View
  associatedtype Content: View

  /// Stable id, used for the status item's autosave name (keeps the
  /// position the user drags it to with ⌘-drag).
  var id: String { get }

  /// The status item's content. Keep it to one line of menu-bar text and/or
  /// an SF Symbol. It is drawn into the status button's image (so the menu
  /// bar can dim it on an inactive screen) and redrawn when its state
  /// changes.
  @ViewBuilder func label() -> Label

  /// The popup panel's content. `host` lets it open or close a side pane,
  /// close the popup, or ask for a refresh.
  @ViewBuilder func panel(host: PanelHost) -> Content

  /// Called each time the popup opens (refresh stale data here).
  func popupWillOpen()
  /// Called when the popup closes.
  func popupDidClose()
  /// Esc in the popup: return true to keep it open (say, to leave a form).
  func handleEscape() -> Bool
  /// The widget was turned off in the config: stop timers, watchers and
  /// child processes. It is dropped afterwards.
  func shutdown()
}

extension MenuWidget {
  func popupWillOpen() {}
  func popupDidClose() {}
  func handleEscape() -> Bool { false }
  func shutdown() {}
}

/// Handed to a widget's panel so it can drive the popup chrome.
@MainActor
final class PanelHost: ObservableObject {
  weak var controller: StatusPanel?

  /// Show `view` in a side pane floating to the LEFT of the popup (the
  /// Omarchy "detail pane" pattern), its top edge level with `anchorY`
  /// (points from the top of the popup's content). Replaces any open pane.
  func showSidePane<V: View>(anchorY: CGFloat = 0, @ViewBuilder _ view: () -> V) {
    controller?.showSidePane(AnyView(view()), anchorY: anchorY)
  }

  /// Hide the side pane after a short grace period, so the pointer can
  /// cross the gap onto it. Cancelled if the pointer enters the pane or
  /// `showSidePane` is called again.
  func hideSidePane(after delay: TimeInterval = 0.25) {
    controller?.hideSidePane(after: delay)
  }

  /// True while the pointer is over the side pane.
  @Published var pointerInSidePane = false

  /// A hovered row hands over the switch to its pane here. With no pane
  /// open it runs now. With one open, it waits while the pointer is heading
  /// for the pane (see PaneAim), so moving diagonally onto the pane doesn't
  /// hand it to the rows crossed on the way. It runs later or never, so it
  /// should check its row is still the hovered one.
  func aim(_ commit: @escaping () -> Void) {
    guard controller?.sidePaneFrame != nil else {
      cancelAim()
      commit()
      return
    }
    aimCommit = commit
    guard aimTimer == nil else { return }
    aimFrom = NSEvent.mouseLocation
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkAim() }
    }
    RunLoop.main.add(timer, forMode: .common)
    aimTimer = timer
  }

  /// Drops a waiting switch (the popup closed, or a key moved the selection).
  func cancelAim() {
    aimTimer?.invalidate()
    aimTimer = nil
    aimCommit = nil
  }

  private var aimFrom = CGPoint.zero
  private var aimCommit: (() -> Void)?
  private var aimTimer: Timer?

  private func checkAim() {
    let now = NSEvent.mouseLocation
    let verdict = controller?.sidePaneFrame.map { PaneAim.judge(from: aimFrom, to: now, pane: $0) } ?? .settled
    switch verdict {
    case .heading:
      aimFrom = now
    case .arrived:
      cancelAim()
    case .settled:
      let commit = aimCommit
      cancelAim()
      commit?()
    }
  }

  func close() { controller?.close() }
}
