import AppKit
import SwiftUI

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
  /// an SF Symbol; it is rendered inside the status button.
  @ViewBuilder func label() -> Label

  /// The popup panel's content. `host` lets it open or close a side pane,
  /// close the popup, or ask for a refresh.
  @ViewBuilder func panel(host: PanelHost) -> Content

  /// Called each time the popup opens (refresh stale data here).
  func popupWillOpen()
  /// Called when the popup closes.
  func popupDidClose()
}

extension MenuWidget {
  func popupWillOpen() {}
  func popupDidClose() {}
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

  func close() { controller?.close() }
}
