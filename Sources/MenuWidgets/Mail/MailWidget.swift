import AppKit
import SwiftUI
import WidgetsCore

/// New mail across HEY and Gmail. The menu bar shows an envelope and the
/// unread count; the popup lists each inbox's unread threads (click one to
/// open it in the browser), and each new email gets a banner.
@MainActor
final class MailWidget: MenuWidget {
  let id = "mail"
  let model: MailModel

  init(config: ConfigStore) {
    model = MailModel(config: config)
  }

  func label() -> some View { MailLabel(model: model) }
  func panel(host: PanelHost) -> some View {
    model.onClose = { [weak host] in host?.close() }
    return MailPanel(model: model)
  }
  func popupWillOpen() { model.popupOpened() }
  func shutdown() { model.stop() }
}

struct MailLabel: View {
  @ObservedObject var model: MailModel

  var body: some View {
    let count = model.total
    HStack(spacing: 3) {
      Image(systemName: count > 0 ? "envelope.fill" : "envelope")
        .font(.system(size: 13))
      if count > 0 {
        Text("\(count)").font(.system(size: 13).monospacedDigit())
      }
      if model.needsAttention {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 9))
          .foregroundStyle(Color.orange)
      }
    }
    .help(model.tooltip)
  }
}
