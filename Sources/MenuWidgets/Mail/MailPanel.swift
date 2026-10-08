import AppKit
import SwiftUI
import WidgetsCore

/// The popup: a hero with the unread total, then one section per inbox
/// with its unread threads, newest first. Click a row (or Return on it) to
/// open the email; click an inbox's name to open the inbox.
/// Keys: ↑/↓ move, Return opens, r refreshes, Esc closes.
struct MailPanel: View {
  @ObservedObject var model: MailModel
  @FocusState private var focused: Bool

  static let width: CGFloat = 400

  var body: some View {
    ScrollView(.vertical) {
      content
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.contentHeight = $0 }
    }
    .scrollIndicators(.automatic)
    .frame(width: Self.width, height: min(max(model.contentHeight, 1), Self.maxHeight))
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(phases: .down) { press in handleKey(press) }
    .onAppear { focused = true }
  }

  static var maxHeight: CGFloat {
    min(900, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 14) {
      hero
      if model.sources.isEmpty {
        Text("Turn on HEY or add Gmail accounts under \"mail\" in ~/.config/menu-widgets/config.json.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(model.sources.enumerated()), id: \.element.id) { i, s in
        let offset = model.sources.prefix(i).reduce(0) { $0 + model.visible($1).count }
        MailSection(model: model, source: s, offset: offset)
      }
      footer
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
  }

  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    switch press.key {
    case .upArrow: model.moveCursor(-1); return .handled
    case .downArrow: model.moveCursor(1); return .handled
    case .return: model.openCursor(); return .handled
    default: break
    }
    guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
    if press.characters == "r" { model.refresh(); return .handled }
    return .ignored
  }

  private var hero: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: model.total > 0 ? "envelope.fill" : "envelope")
        .font(.system(size: 24))
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.total > 0 ? "\(model.total) unread" : "Mail").font(.system(size: 15, weight: .semibold))
        Text(model.heroMeta)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button { model.refresh() } label: {
        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help("Refresh (r)")
    }
  }

  private var footer: some View {
    let last = model.sources.compactMap(\.lastFetch).max()
    return Text(last.map { "Updated \($0.formatted(date: .omitted, time: .shortened))  ·  ↑↓ move  ·  return open  ·  r refresh" }
                ?? "↑↓ move  ·  return open  ·  r refresh")
      .font(.system(size: 10))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .frame(maxWidth: .infinity)
      .padding(.top, 2)
  }
}

/// One inbox: its name (opens the inbox), its state when it can't be read,
/// and its unread threads.
struct MailSection: View {
  @ObservedObject var model: MailModel
  @ObservedObject var source: MailSource
  let offset: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      header
      statusView
      let rows = model.visible(source)
      ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
        MailRow(model: model, item: item, index: offset + i)
      }
      let hidden = source.unread - rows.count
      if hidden > 0 {
        Button("\(hidden) more in \(source.name)…") { model.open(source.inboxURL) }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundStyle(Color.accentColor)
          .padding(.leading, 8)
      }
      if source.items?.isEmpty == true, source.status == .ok {
        Text("Nothing new.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .padding(.leading, 8)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Button { model.open(source.inboxURL) } label: {
        HStack(spacing: 5) {
          Text(source.name.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
          if source.unread > 0 {
            Text("\(source.unread)")
              .font(.system(size: 10, weight: .semibold).monospacedDigit())
          }
          Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Open \(source.name)")
      Spacer()
      if let gmail = source as? GmailSource, gmail.signedIn {
        Menu {
          Button("Sign out of \(gmail.email)") { gmail.signOut() }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .padding(.bottom, 2)
  }

  @ViewBuilder
  private var statusView: some View {
    switch source.status {
    case .needsSetup:
      notice("To read Gmail, save a Google OAuth client (Desktop app) as ~/.config/menu-widgets/google-oauth-client.json. The README has the steps.")
    case .needsSignIn:
      if let gmail = source as? GmailSource {
        HStack {
          Text(gmail.email).font(.system(size: 12)).foregroundStyle(.secondary)
          Spacer()
          Button("Sign in with Google") { gmail.startSignIn() }
        }
        .padding(.horizontal, 8)
      }
    case .signingIn:
      if let gmail = source as? GmailSource {
        HStack {
          ProgressView().controlSize(.small)
          Text("Finish signing in to \(gmail.email) in your browser.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          Spacer()
          Button("Cancel") { gmail.cancelSignIn() }
        }
        .padding(.horizontal, 8)
      }
    case .error(let msg):
      HStack(alignment: .top) {
        Text(msg)
          .font(.system(size: 11))
          .foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Retry") { source.refresh() }.controlSize(.small)
      }
      .padding(.horizontal, 8)
    case .loading where source.items == nil:
      Text("Checking…")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
    default:
      EmptyView()
    }
  }

  private func notice(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .fixedSize(horizontal: false, vertical: true)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
  }
}

struct MailRow: View {
  @ObservedObject var model: MailModel
  let item: MailItem
  let index: Int

  var body: some View {
    let hot = model.cursor == index
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(item.sender)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        if item.unread > 1 {
          Text("\(item.unread)")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Text(MailText.age(item.date, now: model.now))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(item.subject)
        .font(.system(size: 12))
        .lineLimit(1)
      if !item.snippet.isEmpty {
        Text(item.snippet)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hot ? 0.07 : 0)))
    .contentShape(Rectangle())
    .onHover { inside in if inside { model.cursor = index } }
    .onTapGesture { model.open(item.url) }
    .help(item.subject)
  }
}
