import SwiftUI
import WidgetsCore

/// The popup, after Omarchy's agents Panel.qml: hero (mark, tool, plan),
/// an auth/endpoint status card, LIMITS with meters, TOKENS BY DAY and
/// TOKENS BY MODEL. `r` or Return refreshes; Esc closes (the shell).
struct AgentsPanel: View {
  @ObservedObject var model: AgentsModel
  @FocusState private var focused: Bool

  static let width: CGFloat = 340

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      hero
      if let r = model.record {
        if !r.usageStatusText.isEmpty { statusCard(r.authHelpText) }
        if !r.limits.isEmpty {
          Divider()
          section("Limits") {
            ForEach(Array(r.limits.enumerated()), id: \.offset) { _, limit in
              AgentsLimitRow(limit: limit, now: model.now)
            }
          }
        }
        if !r.stats.recentDays.isEmpty {
          Divider()
          daysSection(r.stats)
        }
        let models = UsageFormat.modelRows(r.stats.modelUsage)
        if !models.isEmpty {
          Divider()
          section("Tokens by model") {
            let peak = max(1, models[0].total)
            ForEach(models, id: \.id) { row in
              AgentsModelRow(row: row, share: Double(row.total) / Double(peak))
            }
          }
        }
        footer(r)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Reading Claude usage…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
      }
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress(keys: [.return]) { _ in
      model.refreshNow()
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in
      model.refreshNow()
      return .handled
    }
    .onAppear { focused = true }
    .onChange(of: model.openCount) { focused = true }
  }

  // MARK: hero

  private var hero: some View {
    HStack(alignment: .center, spacing: 12) {
      ClaudeMarkShape()
        .fill(Color.claude)
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.record?.name ?? "Claude Code")
          .font(.system(size: 15, weight: .semibold))
        Text(model.record?.heroMeta ?? "Subscription")
          .font(.system(size: 12))
          .foregroundStyle(model.record?.usageStatusText.isEmpty == false ? Color.red : Color.secondary)
      }
      Spacer(minLength: 8)
      Button {
        model.refreshNow()
      } label: {
        if model.refreshing {
          ProgressView().controlSize(.small).frame(width: 16, height: 16)
        } else {
          Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
        }
      }
      .buttonStyle(.borderless)
      .help("Refresh (r)")
    }
  }

  private func statusCard(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
  }

  // MARK: sections

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      AgentsSectionHeader(title: title)
      content()
    }
  }

  private func daysSection(_ stats: UsageStats) -> some View {
    let today = UsageFormat.dateString(model.now)
    let peak = max(1, stats.recentDays.map(\.tokens).max() ?? 1)
    return VStack(alignment: .leading, spacing: 6) {
      AgentsSectionHeader(title: "Tokens by day").padding(.bottom, 4)
      ForEach(stats.recentDays, id: \.date) { day in
        // By date, not position: the stats-cache fallback can end short of today.
        let isToday = day.date == today
        AgentsDayRow(day: day, ratio: Double(day.tokens) / Double(peak), today: isToday)
          .help(UsageFormat.dayTooltip(day, today: isToday, stats: stats))
      }
    }
  }

  @ViewBuilder private func footer(_ r: UsageRecord) -> some View {
    let s = r.stats
    VStack(spacing: 2) {
      if s.totalPrompts > 0 {
        Text("All time: \(UsageFormat.tokenCount(s.modelUsage.values.reduce(0) { $0 + $1.total })) tokens · \(s.totalSessions) sessions · \(s.activeDays) days")
      }
      Text("Updated \(r.updatedAt.formatted(date: .omitted, time: .shortened)) · r to refresh")
    }
    .font(.system(size: 10))
    .foregroundStyle(.tertiary)
    .frame(maxWidth: .infinity)
    .padding(.top, 2)
  }
}

struct AgentsSectionHeader: View {
  let title: String
  var body: some View {
    Text(title.uppercased())
      .font(.system(size: 10, weight: .semibold))
      .tracking(0.8)
      .foregroundStyle(.secondary)
  }
}

/// A rounded track with the used share filled, plus a pace tick (how far
/// through the window we are) when known.
struct AgentsMeter: View {
  let value: Double
  var pace: Double? = nil
  var alarming = false
  var height: CGFloat = 6

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.12))
        Capsule()
          .fill(alarming ? Color.red : Color.accentColor)
          .frame(width: max(value > 0 ? height : 0, g.size.width * min(1, max(0, value))))
        if let pace {
          Rectangle()
            .fill(Color.primary.opacity(0.55))
            .frame(width: 1.5, height: height + 6)
            .offset(x: g.size.width * pace - 0.75)
        }
      }
      .frame(height: g.size.height)
      .animation(.easeOut(duration: 0.16), value: value)
    }
    .frame(height: height)
  }
}

struct AgentsLimitRow: View {
  let limit: UsageLimit
  let now: Date

  var body: some View {
    let alarming = limit.percent >= 0.9
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(limit.displayTitle)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 6)
        Text("\(Int((limit.percent * 100).rounded()))%")
          .font(.system(size: 12, weight: .medium).monospacedDigit())
          .foregroundStyle(alarming ? Color.red : Color.primary)
      }
      AgentsMeter(value: limit.percent, pace: UsageFormat.paceFraction(limit, now: now), alarming: alarming)
      if let caption {
        Text(caption)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    }
    .help(paceHelp)
  }

  private var caption: String? {
    var parts: [String] = []
    if let reset = limit.resetsAt, reset > now {
      parts.append("Resets in " + UsageFormat.duration(reset.timeIntervalSince(now)))
    }
    if let pace = UsageFormat.paceText(limit, now: now) { parts.append(pace) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var paceHelp: String {
    guard let reset = limit.resetsAt else { return "" }
    let when = reset.formatted(date: .abbreviated, time: .shortened)
    return "Resets \(when). The tick marks how far through the window you are."
  }
}

struct AgentsDayRow: View {
  let day: DayTokens
  let ratio: Double
  let today: Bool

  var body: some View {
    HStack(spacing: 10) {
      Text(today ? "Today" : UsageFormat.dayName(day.date))
        .font(.system(size: 11, weight: today ? .bold : .regular))
        .foregroundStyle(today ? Color.primary : Color.secondary)
        .frame(width: 44, alignment: .leading)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.12))
          Capsule()
            .fill(Color.accentColor.opacity(today ? 1 : 0.55))
            .frame(width: g.size.width * min(1, max(0, ratio)))
        }
      }
      .frame(height: 6)
      Text(UsageFormat.tokenCount(day.tokens))
        .font(.system(size: 11, weight: .bold).monospacedDigit())
        .foregroundStyle(today ? Color.primary : Color.secondary)
        .frame(width: 48, alignment: .trailing)
    }
    .contentShape(Rectangle())
  }
}

/// Model rows read as a table: the share bar fills the row behind the name.
struct AgentsModelRow: View {
  let row: UsageFormat.ModelRow
  let share: Double

  var body: some View {
    HStack {
      Text(row.name)
        .font(.system(size: 12))
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(UsageFormat.tokenCount(row.total))
        .font(.system(size: 12, weight: .bold).monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(alignment: .leading) {
      GeometryReader { g in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.22))
            .frame(width: g.size.width * min(1, max(0, share)))
        }
      }
    }
    .contentShape(Rectangle())
    .help(UsageFormat.modelTooltip(row))
  }
}
