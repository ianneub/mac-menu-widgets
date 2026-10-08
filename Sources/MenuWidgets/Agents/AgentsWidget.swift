import AppKit
import SwiftUI
import WidgetsCore

/// Claude subscription usage: the Mac port of Omarchy's built-in agents
/// widget (Claude only). The menu bar shows the Claude mark and the fullest
/// limit window's percentage; the popup shows plan, limits with pace and
/// reset countdowns, tokens by day and tokens by model.
@MainActor
final class AgentsWidget: MenuWidget {
  let id = "agents"
  let model: AgentsModel

  init(config: ConfigStore) {
    model = AgentsModel(config: config)
  }

  func label() -> some View { AgentsLabel(model: model) }
  func panel(host: PanelHost) -> some View { AgentsPanel(model: model) }
  func popupWillOpen() { model.popupOpened() }
  func popupDidClose() { model.popupClosed() }
  func shutdown() { model.stop() }
}

/// The Claude mark, scaled to fit its frame.
struct ClaudeMarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    let box = ClaudeMark.viewBox
    let scale = min(rect.width / box.width, rect.height / box.height)
    let dx = rect.minX + (rect.width - box.width * scale) / 2
    let dy = rect.minY + (rect.height - box.height * scale) / 2
    let t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    return Path(ClaudeMark.cgPath).applying(t)
  }
}

extension Color {
  /// Claude's brand orange, from the SVG.
  static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

struct AgentsLabel: View {
  @ObservedObject var model: AgentsModel

  var body: some View {
    let headline = model.record?.bindingLimit
    let alarming = (headline?.percent ?? 0) >= 0.9
    let warning = (headline?.percent ?? 0) >= 0.75
    HStack(spacing: 4) {
      ClaudeMarkShape()
        .fill(alarming ? Color.red : Color.primary)
        .frame(width: 14, height: 14)
      if let headline {
        Text("\(Int((headline.percent * 100).rounded()))%")
          .font(.system(size: 13).monospacedDigit())
          .foregroundStyle(alarming ? Color.red : warning ? Color.orange : Color.primary)
      }
    }
    .help(labelHelp)
  }

  private var labelHelp: String {
    guard let r = model.record else { return "Claude Code usage" }
    let parts = r.limits.map { "\($0.displayTitle) \(Int(($0.percent * 100).rounded()))%" }
    return parts.isEmpty ? (r.usageStatusText.isEmpty ? "Claude Code usage" : r.usageStatusText) : parts.joined(separator: " · ")
  }
}

#if DEBUG
/// Development aid: MENU_WIDGETS_SNAPSHOT=<dir> writes the panel and label
/// as PNGs after each refresh lands.
@MainActor
enum AgentsSnapshot {
  static func writeIfRequested(_ model: AgentsModel) {
    guard let dir = ProcessInfo.processInfo.environment["MENU_WIDGETS_SNAPSHOT"] else { return }
    let views: [(String, AnyView)] = [
      ("agents-panel", AnyView(AgentsPanel(model: model).background(Color(nsColor: .windowBackgroundColor)))),
      ("agents-label", AnyView(AgentsLabel(model: model).padding(4).background(Color(nsColor: .windowBackgroundColor)))),
    ]
    for (name, view) in views {
      let r = ImageRenderer(content: view)
      r.scale = 2
      if let img = r.nsImage, let tiff = img.tiffRepresentation,
         let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
      }
    }
  }
}
#endif
