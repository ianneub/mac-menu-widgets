import AppKit
import SwiftUI
import WidgetsCore

/// The popup: a hero with the unread total, then one section per inbox
/// with its unread threads, newest first. Click a row (or Return on it) to
/// open the email, or its trash can to move the thread to the Trash: at
/// once with Undo for Gmail, on a second click for HEY, which has no Undo);
/// click an inbox's name to open the inbox.
/// Keys: ↑/↓ move, Return opens, ⌫ trashes, r refreshes, Esc closes.
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
      if model.sources.isEmpty && model.gmail == nil {
        Text("Turn on HEY or Gmail under \"mail\" in ~/.config/menu-widgets/config.json.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      let firstGmail = model.sources.firstIndex { $0 is GmailSource } ?? model.sources.count
      ForEach(Array(model.sources.enumerated()), id: \.element.id) { i, s in
        let offset = model.sources.prefix(i).reduce(0) { $0 + model.visible($1).count }
        if i == firstGmail, let hub = model.gmail { BridgeNotice(hub: hub) }
        MailSection(model: model, source: s, offset: offset)
      }
      if firstGmail == model.sources.count, let hub = model.gmail { BridgeNotice(hub: hub) }
      if let t = model.trashed { undoBar(t) }
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
    case .delete, .deleteForward: model.trashCursor(); return .handled
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

  private func undoBar(_ t: MailModel.Trashed) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "trash").foregroundStyle(.secondary)
      Text(t.undoable ? "Moved \u{201C}\(t.item.subject)\u{201D} to the Trash"
                      : "Moved \u{201C}\(t.item.subject)\u{201D} to \(t.source.name)\u{2019}s Trash")
        .font(.system(size: 12))
        .lineLimit(1)
      Spacer(minLength: 4)
      if t.undoable {
        Button("Undo") { model.undoTrash() }.controlSize(.small)
      } else {
        // HEY can't move it back from here; its page in HEY can.
        Button("Open in \(t.source.name)") { model.open(t.item.url) }
          .controlSize(.small)
          .help("Move it back to the Imbox from there")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
  }

  private var footer: some View {
    let last = model.sources.compactMap(\.lastFetch).max()
    let keys = model.trashable ? "↑↓ move  ·  return open  ·  ⌫ trash  ·  r refresh" : "↑↓ move  ·  return open  ·  r refresh"
    return Text(last.map { "Updated \($0.formatted(date: .omitted, time: .shortened))  ·  \(keys)" } ?? keys)
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
          // The bridge holds one sign-in for every app that uses it.
          Button("Sign out of \(gmail.email) in PIM Bridge") { gmail.signOut() }
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
    case .needsSignIn:
      if let gmail = source as? GmailSource {
        GmailSignIn(source: gmail)
      }
    case .signingIn:
      if let gmail = source as? GmailSource {
        GmailSigningIn(source: gmail)
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

/// An account the bridge needs to sign in again (Google's test-mode
/// sign-ins expire after a week): one click opens Google's page.
struct GmailSignIn: View {
  @ObservedObject var source: GmailSource

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 1) {
        Text(source.email).font(.system(size: 12)).foregroundStyle(.secondary)
        if let p = source.problem {
          Text(p)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
      Button("Sign in…") { source.signIn() }
    }
    .padding(.horizontal, 8)
  }
}

struct GmailSigningIn: View {
  @ObservedObject var source: GmailSource

  var body: some View {
    HStack {
      ProgressView().controlSize(.small)
      Text("Finish signing in to \(source.email) in your browser.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      if let url = source.signInURL {
        Button("Open Page") { NSWorkspace.shared.open(url) }
          .help("Open Google's sign-in page again")
      }
    }
    .padding(.horizontal, 8)
  }
}

/// What's wrong with PIM Bridge as a whole, shown above the Gmail accounts:
/// not running, refusing MenuWidgets, or Gmail not set up there.
struct BridgeNotice: View {
  @ObservedObject var hub: GmailHub

  var body: some View {
    switch hub.state {
    case .failed(let f):
      HStack(alignment: .top) {
        Text(f.message)
          .font(.system(size: 12))
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Retry") { hub.refresh() }.controlSize(.small)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    case .connecting where hub.sources.isEmpty:
      Text("Asking PIM Bridge for your Gmail accounts…")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    case .ok where hub.problem != nil || hub.sources.isEmpty:
      Text(hub.problem ?? "No Gmail accounts in PIM Bridge yet. Add one with its `gmail` command.")
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    default:
      EmptyView()
    }
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
        if model.confirmingTrash == item.id {
          Button { model.trash(item) } label: {
            Label("Trash?", systemImage: "trash.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.red)
          }
          .buttonStyle(.borderless)
          .help("Click again (or ⌫) to move it to the Trash. It can't be undone from here.")
        } else if hot && model.canTrash(item) {
          Button { model.trash(item) } label: {
            Image(systemName: "trash").font(.system(size: 11))
          }
          .buttonStyle(.borderless)
          .help("Move this conversation to the Trash (⌫)")
        }
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
    // The address too: the name alone is whatever the sender typed.
    .help(item.from + "\n" + item.subject)
  }
}
