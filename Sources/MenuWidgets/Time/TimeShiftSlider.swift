import SwiftUI
import WidgetsCore

/// The slider under the local time: drag it to move the popup's clocks up to
/// a day back or ahead, a quarter hour at a time. Now is the mark in the
/// middle. Drawn here rather than with Slider, which puts a tick at every one
/// of its 193 stops when stepped and has no mark for the middle when not (and
/// MENU_WIDGETS_TIME_SNAPSHOT can't render one).
struct TimeShiftSlider: View {
  @ObservedObject var state: TimeState
  @Environment(\.colorScheme) private var scheme

  static let thumb: CGFloat = 16

  var body: some View {
    let hours = TimeModel.shiftMaxSteps * TimeModel.shiftStepMinutes / 60
    let label = TimeModel.shiftLabel(state.shownMs, state.nowMs)

    VStack(spacing: 1) {
      GeometryReader { geo in
        // The thumb's center travels half its width short of each end.
        let mid = geo.size.width / 2
        let reach = max(1, mid - Self.thumb / 2)
        let maxSteps = CGFloat(TimeModel.shiftMaxSteps)
        let x = mid + CGFloat(state.shiftSteps) / maxSteps * reach
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.18)).frame(height: 4)
          Capsule().fill(Color.accentColor)
            .frame(width: abs(x - mid), height: 4)
            .offset(x: min(x, mid))
          Capsule().fill(Color.primary.opacity(0.45))
            .frame(width: 2, height: 10)
            .offset(x: mid - 1)
          Circle().fill(scheme == .dark ? Color(white: 0.85) : Color.white)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .frame(width: Self.thumb, height: Self.thumb)
            .offset(x: x - Self.thumb / 2)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
          state.setShift(Int(((drag.location.x - mid) / reach * maxSteps).rounded()))
        })
      }
      .frame(height: 20)
      .accessibilityElement()
      .accessibilityLabel("Time")
      .accessibilityValue(label)
      .accessibilityAdjustableAction { direction in
        state.setShift(state.shiftSteps + (direction == .increment ? 1 : -1))
      }

      // ---- The ends, and between them how far from now the clocks are.
      HStack {
        Text("\u{2212}\(hours)h")
        Spacer()
        Text("+\(hours)h")
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
      .overlay {
        HStack(spacing: 4) {
          Text(label)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(state.isShifted ? .primary : .secondary)
          if state.isShifted {
            Button { state.setShift(0) } label: {
              Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to now (Esc)")
            .accessibilityLabel("Back to now")
          }
        }
      }
    }
  }
}
