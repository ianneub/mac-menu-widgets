import AppKit
import SwiftUI
import WidgetsCore

/// The popup, after the Omarchy widget's Panel.qml: hero, quick add (title,
/// when, list), OVERDUE / TODAY / TOMORROW, and a footer. Click a row to edit
/// it, its circle to check it off (again within a moment to undo).
/// Keys: ↑/↓ move, space checks off, a adds, e edits, o opens a link,
/// r refreshes, Esc leaves a form or closes.
struct RemindersPanel: View {
  @ObservedObject var model: RemindersModel
  @FocusState private var focus: RemindersModel.Field?

  static let width: CGFloat = 380

  var body: some View {
    ScrollView(.vertical) {
      content
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.contentHeight = $0 }
    }
    .scrollIndicators(.automatic)
    .frame(width: Self.width, height: min(max(model.contentHeight, 1), Self.maxHeight))
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .panel)
    .onKeyPress(phases: .down) { press in handleKey(press) }
    .onChange(of: model.focusRequest) { _, field in
      guard let field else { return }
      focus = field
      model.focusRequest = nil
    }
    .onChange(of: focus) { _, field in model.focused = field }
    .onChange(of: model.openCount) { focus = .panel }
    .onAppear { focus = .panel }
    .environment(\.openURL, OpenURLAction { url in
      model.open(url.absoluteString)
      return .handled
    })
  }

  /// Tall enough for a full day, short of the screen.
  static var maxHeight: CGFloat {
    min(960, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      hero
      if model.access == .denied {
        accessCard
      } else {
        addForm
        let entries = model.entries
        let overdue = entries.filter { $0.bucket == .overdue }
        let today = entries.filter { $0.bucket == .today }
        let tomorrow = entries.filter { $0.bucket == .tomorrow }
        if !overdue.isEmpty { section("Overdue", overdue, offset: 0, color: .red) }
        section("Today", today, offset: overdue.count, empty: model.loaded ? "Nothing due today." : "")
        section("Tomorrow", tomorrow, offset: overdue.count + today.count, empty: model.loaded ? "Nothing due tomorrow." : "")
        footer
      }
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
  }

  // MARK: keys

  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    guard focus == .panel || focus == nil else { return .ignored }
    switch press.key {
    case .upArrow: model.moveCursor(-1); return .handled
    case .downArrow: model.moveCursor(1); return .handled
    case .space:
      if let e = model.cursorEntry { model.toggleDone(e) }
      return .handled
    case .return:
      if let e = model.cursorEntry { model.toggleDone(e) } else { focus = .addTitle }
      return .handled
    default: break
    }
    guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
    switch press.characters {
    case "a", "n", "/": focus = .addTitle
    case "e": if let e = model.cursorEntry { model.startEdit(e) }
    case "o": if let e = model.cursorEntry { model.open(Links.firstLink(e.item)) }
    case "r": model.refresh()
    default: return .ignored
    }
    return .handled
  }

  // MARK: hero

  private var hero: some View {
    let late = model.summary.late > 0
    return HStack(alignment: .center, spacing: 12) {
      Image(systemName: model.access == .denied ? "bell.slash" : late ? "bell.and.waves.left.and.right.fill" : "bell")
        .font(.system(size: 26))
        .foregroundStyle(late ? Color.red : Color.primary)
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 1) {
        Text("Reminders").font(.system(size: 15, weight: .semibold))
        Text(model.heroMeta)
          .font(.system(size: 12))
          .foregroundStyle(late ? Color.red : Color.secondary)
      }
      Spacer(minLength: 8)
      Button { model.openRemindersApp() } label: {
        Image(systemName: "arrow.up.forward.app").frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help("Open Reminders")
      Button { model.refresh() } label: {
        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
      }
      .buttonStyle(.borderless)
      .help("Refresh (r)")
    }
  }

  private var accessCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("MenuWidgets needs access to Reminders. Turn it on in System Settings → Privacy & Security → Reminders.")
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Privacy Settings") { model.openPrivacySettings() }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
  }

  // MARK: quick add

  private var addForm: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("New reminder", text: $model.addTitle)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .focused($focus, equals: .addTitle)
        .onSubmit { model.addReminder() }
      HStack(spacing: 6) {
        TextField("When: 5pm, 55m, sep 23 @ 3pm", text: $model.addWhen)
          .textFieldStyle(.roundedBorder)
          .focused($focus, equals: .addWhen)
          .onSubmit { model.addReminder() }
        Menu {
          ForEach(model.lists.filter(\.writable)) { list in
            Button {
              model.newListID = list.id
              focus = .addTitle
            } label: {
              if list.id == model.chosenList?.id {
                Label(list.name, systemImage: "checkmark")
              } else {
                Text(list.name)
              }
            }
          }
        } label: {
          Text(model.chosenList?.name ?? "Reminders").lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("List for new reminders")
        Button { model.addReminder() } label: {
          Image(systemName: "plus").frame(width: 14, height: 14)
        }
        .help("Add (Return)")
        .disabled(model.adding)
      }
      .controlSize(.large)
      if !model.statusMessage.isEmpty {
        Text(model.statusMessage)
          .font(.system(size: 11))
          .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func listColor(_ list: ReminderStore.ListInfo?) -> Color {
    guard let c = list?.rgb, c.count == 3 else { return .secondary }
    return Color(red: c[0], green: c[1], blue: c[2])
  }

  // MARK: sections

  @ViewBuilder
  private func section(_ title: String, _ entries: [AgendaEntry], offset: Int, color: Color = .secondary,
                       empty: String = "") -> some View {
    if !entries.isEmpty || !empty.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text(title.uppercased())
          .font(.system(size: 10, weight: .semibold))
          .tracking(0.8)
          .foregroundStyle(color)
          .padding(.bottom, 2)
        if entries.isEmpty {
          Text(empty)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
        }
        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
          ReminderRow(model: model, entry: e, index: offset + i,
                      color: listColor(model.lists.first { $0.name == e.item.list }), focus: $focus)
        }
      }
    }
  }

  private var footer: some View {
    Group {
      if let last = model.lastFetch {
        Text("Updated \(last.formatted(date: .omitted, time: .shortened))  ·  a add  ·  e edit  ·  o open link  ·  space check off")
      } else {
        Text(model.heroMeta)
      }
    }
    .font(.system(size: 10))
    .foregroundStyle(.tertiary)
    .lineLimit(1)
    .frame(maxWidth: .infinity)
    .padding(.top, 2)
  }
}

// MARK: - a row

struct ReminderRow: View {
  @ObservedObject var model: RemindersModel
  let entry: AgendaEntry
  let index: Int
  let color: Color
  var focus: FocusState<RemindersModel.Field?>.Binding

  var body: some View {
    let checked = model.done.contains(entry.id)
    let late = !checked && Agenda.isLate(entry, now: model.now)
    let hasCursor = model.cursorActive && model.rowIndex == index
    let draft = model.draft?.entry.id == entry.id ? model.draft : nil
    HStack(alignment: .top, spacing: 10) {
      Button { model.toggleDone(entry) } label: {
        Image(systemName: checked ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 17, weight: .light))
          .foregroundStyle(checked ? color : Color.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(checked ? "Undo" : "Complete")
      .padding(.top, 1)

      if let draft {
        EditForm(model: model, draft: draft, focus: focus)
      } else {
        details(checked: checked, late: late)
        Spacer(minLength: 0)
        if hasCursor {
          Image(systemName: "pencil")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.primary.opacity(hasCursor && draft == nil ? 0.07 : draft != nil ? 0.04 : 0)))
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { model.cursorActive = true; model.rowIndex = index }
    }
    .onTapGesture { if draft == nil { model.startEdit(entry) } }
  }

  @ViewBuilder
  private func details(checked: Bool, late: Bool) -> some View {
    let item = entry.item
    VStack(alignment: .leading, spacing: 2) {
      Text(Agenda.priorityMark(item.priority) + item.title)
        .font(.system(size: 13))
        .strikethrough(checked)
        .foregroundStyle(checked ? Color.secondary : Color.primary)
        .lineLimit(2)
      if let line = detailLine {
        line
          .font(.system(size: 11))
          .foregroundStyle(late ? Color.red : Color.secondary)
          .lineLimit(1)
      }
      if !item.notes.isEmpty { NotesText(model: model, id: item.id, notes: item.notes) }
      if !item.url.isEmpty, Links.openable(item.url) || !item.url.contains(" ") {
        Text(linkText(item.url))
          .font(.system(size: 11))
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  /// "5:00 PM · Home · ↻ weekly on Mon"
  private var detailLine: Text? {
    var parts: [Text] = []
    if !entry.label.isEmpty { parts.append(Text(entry.label)) }
    parts.append(Text(entry.item.list))
    if let rule = entry.item.rule { parts.append(Text(Image(systemName: "repeat")) + Text(" " + rule.phrase)) }
    guard var line = parts.first else { return nil }
    for p in parts.dropFirst() { line = line + Text(" · ") + p }
    return line
  }

  private func linkText(_ url: String) -> AttributedString {
    var a = AttributedString(Links.label(url))
    a.link = URL(string: Links.openable(url) ? url : "https://" + url)
    return a
  }
}

/// Notes, three lines until expanded; web addresses in them are links.
struct NotesText: View {
  @ObservedObject var model: RemindersModel
  let id: String
  let notes: String

  var body: some View {
    let full = model.expanded.contains(id)
    let text = Links.attributed(notes)
    VStack(alignment: .leading, spacing: 1) {
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(full ? nil : 3)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.noteHeights[id, default: [0, 0]][0] = $0 }
        .background(alignment: .topLeading) {
          // The whole note, laid out unseen, to tell whether three lines cut it short.
          Text(text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.noteHeights[id, default: [0, 0]][1] = $0 }
        }
      if full || model.notesCut(id) {
        Button(full ? "less" : "more") { model.toggleExpanded(id) }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundStyle(Color.accentColor)
      }
    }
    .padding(.top, 2)
  }
}
