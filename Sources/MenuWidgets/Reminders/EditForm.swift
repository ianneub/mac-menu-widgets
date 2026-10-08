import SwiftUI
import WidgetsCore

/// A row opened for editing: title, when, repeat, URL and notes. Return
/// saves (⌘Return in notes), Esc cancels, Tab moves between fields.
struct EditForm: View {
  @ObservedObject var model: RemindersModel
  @ObservedObject var draft: EditDraft
  var focus: FocusState<RemindersModel.Field?>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Title", text: $draft.title)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .focused(focus, equals: .editTitle)
        .onSubmit { model.saveEdit() }
      HStack(spacing: 6) {
        TextField("No due date", text: $draft.when)
          .textFieldStyle(.roundedBorder)
          .focused(focus, equals: .editWhen)
          .onSubmit { model.saveEdit() }
        Button { model.saveEdit() } label: { Image(systemName: "checkmark").frame(width: 14, height: 14) }
          .help("Save (Return)")
        Button { model.cancelEdit() } label: { Image(systemName: "xmark").frame(width: 14, height: 14) }
          .help("Cancel (Esc)")
      }
      .controlSize(.large)
      if draft.when.trimmingCharacters(in: .whitespaces).isEmpty {
        Text("Add a date to repeat it.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      } else {
        RepeatEditor(draft: draft, focus: focus)
          .padding(.vertical, 2)
      }
      TextField("URL", text: $draft.url)
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .focused(focus, equals: .editURL)
        .onSubmit { model.saveEdit() }
      TextEditor(text: $draft.notes)
        .font(.system(size: 13))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(minHeight: 72)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
        .overlay(alignment: .topLeading) {
          if draft.notes.isEmpty {
            Text("Notes  (⌘Return saves)")
              .font(.system(size: 13))
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .allowsHitTesting(false)
          }
        }
        .focused(focus, equals: .editNotes)
        .onKeyPress(.return, phases: .down) { press in
          guard press.modifiers.contains(.command) else { return .ignored }
          model.saveEdit()
          return .handled
        }
    }
  }
}

/// Reminders.app's repeat controls, laid out as on the Mac: the Repeat menu,
/// End Repeat, and Custom's frequency, interval, days, months and "on the".
struct RepeatEditor: View {
  @ObservedObject var draft: EditDraft
  var focus: FocusState<RemindersModel.Field?>.Binding

  private var rep: RepeatState { draft.rep }
  private var repeating: Bool { rep.freq != "never" }
  private var showCustom: Bool { repeating && (draft.customOpen || rep.presetKey == "custom") }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
        GridRow {
          label("Repeat")
          Picker("Repeat", selection: Binding(
            get: { showCustom ? "custom" : rep.presetKey },
            set: { key in
              draft.customOpen = key == "custom"
              if key != "custom" { draft.rep = rep.applying(preset: key) }
              else if !repeating { draft.rep = rep.applying(preset: "day") }
            })) {
            ForEach(Array(RepeatState.presets.enumerated()), id: \.offset) { _, p in
              if p.option.separator { Divider() } else { Text(p.option.label).tag(p.option.key) }
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        if repeating {
          GridRow {
            label("End Repeat")
            HStack(spacing: 6) {
              Picker("End Repeat", selection: Binding(
                get: { rep.end },
                set: { key in
                  draft.rep.end = key
                  if key == "until" { focus.wrappedValue = .until }
                })) {
                ForEach(rep.endOptions, id: \.key) { Text($0.label).tag($0.key) }
              }
              .labelsHidden()
              .fixedSize()
              if rep.end == "until" {
                TextField("dec 31, 2026-12-31", text: $draft.rep.until)
                  .textFieldStyle(.roundedBorder)
                  .focused(focus, equals: .until)
              } else if rep.end == "count" {
                Stepper(value: $draft.rep.count, in: 1...999) {
                  Text("\(rep.count) \(rep.count == 1 ? "time" : "times")").font(.system(size: 12))
                }
              }
            }
          }
        }
      }
      if showCustom { custom }
    }
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .frame(width: 70, alignment: .trailing)
      .gridColumnAlignment(.trailing)
  }

  // MARK: Custom, like the Mac's sheet

  private var custom: some View {
    VStack(alignment: .leading, spacing: 8) {
      if rep.custom, let phrase = draft.entry.item.rule?.phrase {
        Text("Set up elsewhere as “\(phrase)”. Changing it here replaces it.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
        GridRow {
          label("Frequency")
          Picker("Frequency", selection: Binding(get: { rep.freq }, set: { draft.rep = rep.withFrequency($0) })) {
            ForEach(RepeatState.frequencies, id: \.key) { Text($0.label).tag($0.key) }
          }
          .labelsHidden()
          .fixedSize()
        }
        GridRow {
          label("Every")
          Stepper(value: Binding(get: { rep.interval }, set: { draft.rep.interval = $0 }), in: 1...999) {
            Text("\(rep.interval) \(RepeatState.unitLabel(rep.freq, rep.interval))").font(.system(size: 12))
          }
        }
        switch rep.freq {
        case "weekly":
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            ToggleGrid(columns: 7, options: RepeatState.week.map { ($0, String($0.prefix(1)).uppercased(), RepeatState.dayNames[$0]!) },
                       chosen: rep.shownDays) { draft.rep.days = RepeatState.toggled(rep.shownDays, $0) }
          }
        case "monthly":
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            VStack(alignment: .leading, spacing: 6) {
              Picker("", selection: $draft.rep.monthMode) {
                Text("Each").tag("each")
                Text("On the…").tag("onthe")
              }
              .pickerStyle(.radioGroup)
              .horizontalRadioGroupLayout()
              .labelsHidden()
              if rep.monthMode == "each" {
                ToggleGrid(columns: 7,
                           options: (1...31).map { ($0, String($0), nil) } + [(-1, "Last", "The last day of the month")],
                           chosen: rep.shownMonthDays) { draft.rep.monthDays = RepeatState.toggled(rep.shownMonthDays, $0) }
              } else {
                onThe
              }
            }
          }
        case "yearly":
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            VStack(alignment: .leading, spacing: 6) {
              ToggleGrid(columns: 4,
                         options: (1...12).map { ($0, String(RepeatState.monthNames[$0 - 1].prefix(3)), nil) },
                         chosen: rep.shownMonths) { draft.rep.months = RepeatState.toggled(rep.shownMonths, $0) }
              Toggle("On the…", isOn: $draft.rep.yearOnThe)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
              if rep.yearOnThe { onThe }
            }
          }
        default:
          EmptyView()
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
  }

  /// On the [first ▾] [Monday ▾]
  private var onThe: some View {
    HStack(spacing: 6) {
      Picker("", selection: $draft.rep.ordinal) {
        ForEach(RepeatState.ordinals, id: \.key) { Text($0.label).tag($0.key) }
      }
      .labelsHidden()
      .fixedSize()
      Picker("", selection: $draft.rep.ordDay) {
        ForEach(Array(RepeatState.onTheDays.enumerated()), id: \.offset) { _, o in
          if o.separator { Divider() } else { Text(o.label).tag(o.key) }
        }
      }
      .labelsHidden()
      .fixedSize()
    }
  }
}

/// A grid of toggles: the Mac's weekday, day-of-month and month pickers.
struct ToggleGrid<Key: Hashable>: View {
  let columns: Int
  let options: [(key: Key, label: String, tip: String?)]
  let chosen: [Key]
  let toggle: (Key) -> Void

  var body: some View {
    let rows = stride(from: 0, to: options.count, by: columns).map { Array(options[$0..<min($0 + columns, options.count)]) }
    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          ForEach(Array(row.enumerated()), id: \.offset) { _, o in
            let on = chosen.contains(o.key)
            Button { toggle(o.key) } label: {
              Text(o.label)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(o.tip ?? "")
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}
