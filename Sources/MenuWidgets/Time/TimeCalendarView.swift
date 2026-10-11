import SwiftUI
import WidgetsCore

/// The top of the time popup: the month with a dot under each day for every
/// calendar with something on it, then the picked day's events (all-day
/// first, then timed ones by start).
struct TimeCalendarView: View {
  @ObservedObject var model: TimeCalendarModel
  let now: Date
  let use24h: Bool
  /// A click on an event: open it in Calendar.
  let onOpen: (CalendarEvent) -> Void

  /// The day list scrolls past this height rather than stretching the popup.
  static let listMaxHeight: CGFloat = 220

  var body: some View {
    let cal = Calendar.current
    let days = MonthCalendar.grid(model.month, calendar: cal)
    let today = cal.startOfDay(for: now)

    VStack(alignment: .leading, spacing: 10) {
      // ---- Month and paging.
      HStack(spacing: 2) {
        Text(MonthCalendar.monthTitle(model.month, calendar: cal))
          .font(.title3.weight(.semibold))
        Spacer(minLength: 8)
        PageButton(symbol: "chevron.left", help: "Previous month") { model.step(month: -1) }
        PageButton(symbol: "circle.fill", size: 6, help: "Today") { model.goToToday() }
        PageButton(symbol: "chevron.right", help: "Next month") { model.step(month: 1) }
      }
      .padding(.horizontal, 4)

      // ---- The grid: weekday letters, then six weeks.
      VStack(spacing: 1) {
        HStack(spacing: 0) {
          ForEach(Array(MonthCalendar.weekdaySymbols(calendar: cal).enumerated()), id: \.offset) { _, s in
            Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
          }
        }
        .padding(.bottom, 2)
        ForEach(0..<6, id: \.self) { week in
          HStack(spacing: 0) {
            ForEach(days[week * 7..<week * 7 + 7]) { day in
              DayCell(
                day: day, isToday: day.date == today, isSelected: day.date == model.selected,
                dots: MonthCalendar.dots(on: day.date, model.events, calendar: cal)
              ) { model.select(day.date) }
            }
          }
        }
      }

      Divider()

      // ---- The picked day.
      VStack(alignment: .leading, spacing: 6) {
        Text(MonthCalendar.dayHeading(model.selected, now: now, calendar: cal))
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
        dayList(cal)
      }
    }
  }

  @ViewBuilder
  private func dayList(_ cal: Calendar) -> some View {
    switch model.access {
    case .denied:
      note("No access to Calendars. Allow MenuWidgets in System Settings › Privacy & Security › Calendars.")
    case .unknown:
      note("Waiting for access to Calendars.")
    case .granted:
      let day = MonthCalendar.events(on: model.selected, model.events, calendar: cal)
      if day.isEmpty {
        note("No events")
      } else {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(day.allDay) { e in eventButton(e) { AllDayRow(event: e) } }
            ForEach(day.timed) { e in
              eventButton(e) {
                TimedRow(event: e, time: MonthCalendar.timeLabel(e, on: model.selected, use24h: use24h, calendar: cal),
                         past: e.end < now)
              }
            }
          }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.listHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(model.listHeight, 1), Self.listMaxHeight))
      }
    }
  }

  /// An event row that opens the event in Calendar, highlighted under the pointer.
  private func eventButton<Row: View>(_ e: CalendarEvent, @ViewBuilder _ row: () -> Row) -> some View {
    Button { onOpen(e) } label: {
      row()
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .timeRowHighlight(model.hoveredEvent == e.id)
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside { model.hoveredEvent = e.id } else if model.hoveredEvent == e.id { model.hoveredEvent = nil }
    }
    .help(e.calendarTitle.isEmpty ? "Open in Calendar" : "Open in Calendar (\(e.calendarTitle))")
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)
  }

  private struct PageButton: View {
    let symbol: String
    var size: CGFloat = 12
    let help: String
    let action: () -> Void

    var body: some View {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.system(size: size, weight: .semibold))
          .frame(width: 24, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(help)
    }
  }

  private struct DayCell: View {
    let day: MonthCalendar.Day
    let isToday: Bool
    let isSelected: Bool
    let dots: [[Double]]
    let action: () -> Void

    var body: some View {
      Button(action: action) {
        VStack(spacing: 1) {
          Text("\(day.number)")
            .font(.system(size: 13, weight: isToday ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(isToday ? Color.white : day.inMonth ? Color.primary : Color.secondary.opacity(0.6))
            .frame(width: 25, height: 25)
            .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: isSelected && !isToday ? 1.5 : 0))
            .overlay(Circle().inset(by: -2).strokeBorder(Color.accentColor.opacity(0.5),
                                                         lineWidth: isSelected && isToday ? 1.5 : 0))
          HStack(spacing: 2) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, c in
              Circle().fill(eventColor(c)).frame(width: 4.5, height: 4.5)
            }
          }
          .frame(height: 4.5)
          .opacity(day.inMonth ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private struct AllDayRow: View {
    let event: CalendarEvent

    var body: some View {
      HStack(spacing: 6) {
        Text(event.title).font(.callout).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 5).fill(eventColor(event.rgb).opacity(0.28)))
      .overlay(alignment: .leading) {
        UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5)
          .fill(eventColor(event.rgb)).frame(width: 3)
      }
    }
  }

  private struct TimedRow: View {
    let event: CalendarEvent
    let time: String
    let past: Bool

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(eventColor(event.rgb))
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 1) {
          Text(event.title).font(.callout).lineLimit(1)
          Text(event.location.isEmpty ? time : time + "  ·  " + event.location)
            .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 2)
      .opacity(past ? 0.5 : 1)
    }
  }
}

private func eventColor(_ rgb: [Double]) -> Color {
  rgb.count == 3 ? Color(red: rgb[0], green: rgb[1], blue: rgb[2]) : .secondary
}
