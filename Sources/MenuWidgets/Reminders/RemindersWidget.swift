import AppKit
import SwiftUI
import WidgetsCore

/// Apple Reminders due today and tomorrow: the Mac port of the Omarchy
/// widget ianneub.reminders. The menu bar shows a bell and the count left
/// today (only the past-due ones, in red, while any are); the popup lists
/// overdue, today and tomorrow, with quick add, check-off and in-place edits.
/// Alerts are left to Reminders' own notifications.
@MainActor
final class RemindersWidget: MenuWidget {
  let id = "reminders"
  let model = RemindersModel()

  func label() -> some View { RemindersLabel(model: model) }
  func panel(host: PanelHost) -> some View {
    model.onClose = { [weak host] in host?.close() }
    openFromEnvironment(host)
    return RemindersPanel(model: model)
  }

  /// MENU_WIDGETS_REMINDERS_EDIT=<row>[,<repeat preset>] opens the popup a
  /// few seconds after launch with row n's edit form open, optionally with a
  /// Repeat menu item picked ("custom" opens Custom). Nothing is saved. For
  /// screenshots and testing.
  private func openFromEnvironment(_ host: PanelHost) {
    guard let raw = ProcessInfo.processInfo.environment["MENU_WIDGETS_REMINDERS_EDIT"] else { return }
    let parts = raw.split(separator: ",").map(String.init)
    guard let n = Int(parts[0]) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak host] in
      host?.controller?.open()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard let self, n < self.model.entries.count else { return }
        self.model.startEdit(self.model.entries[n])
        guard parts.count > 1, let d = self.model.draft else { return }
        d.customOpen = parts[1] == "custom"
        d.rep = d.rep.applying(preset: parts[1] == "custom" ? "day" : parts[1])
        if parts.count > 2 { d.rep = d.rep.withFrequency(parts[2]) }
      }
    }
  }

  func popupWillOpen() { model.popupOpened() }
  func popupDidClose() { model.popupClosed() }
  func handleEscape() -> Bool { model.escape() }
  func shutdown() { model.stop() }
}

struct RemindersLabel: View {
  @ObservedObject var model: RemindersModel

  var body: some View {
    let s = model.summary
    let late = s.late > 0
    let count = Agenda.barCount(s)
    HStack(spacing: 3) {
      Image(systemName: model.access == .denied ? "bell.slash" : late ? "bell.and.waves.left.and.right.fill" : "bell")
        .font(.system(size: 13))
        .foregroundStyle(late ? Color.red : model.access == .denied ? Color.secondary : Color.primary)
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 13).monospacedDigit())
          .foregroundStyle(late ? Color.red : Color.primary)
      }
    }
    .help(model.access == .denied ? "Reminders: no access" : model.loaded ? Agenda.tooltip(s) : "Reminders")
  }
}
