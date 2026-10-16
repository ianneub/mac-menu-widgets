import CoreGraphics
import Testing
@testable import WidgetsCore

// A pane like the weather's: to the left of the popup, its top level with
// the popup's (screen coordinates, y up).
private let pane = CGRect(x: 100, y: 300, width: 460, height: 500)

@Test func aimOverThePaneHasArrived() {
  #expect(PaneAim.judge(from: CGPoint(x: 600, y: 760), to: CGPoint(x: 500, y: 600), pane: pane) == .arrived)
}

@Test func aimDownAndLeftIsHeading() {
  // From the top row toward the temperature chart, partway down the pane.
  #expect(PaneAim.judge(from: CGPoint(x: 640, y: 780), to: CGPoint(x: 630, y: 770), pane: pane) == .heading)
  // Straight left counts too.
  #expect(PaneAim.judge(from: CGPoint(x: 640, y: 780), to: CGPoint(x: 630, y: 780), pane: pane) == .heading)
}

@Test func aimStraightDownSettles() {
  // Walking down the list switches rows as before.
  #expect(PaneAim.judge(from: CGPoint(x: 640, y: 780), to: CGPoint(x: 640, y: 770), pane: pane) == .settled)
  #expect(PaneAim.judge(from: CGPoint(x: 640, y: 780), to: CGPoint(x: 650, y: 770), pane: pane) == .settled)
}

@Test func aimAboveThePaneSettles() {
  // Up and left, past the pane's top corner.
  #expect(PaneAim.judge(from: CGPoint(x: 640, y: 780), to: CGPoint(x: 635, y: 790), pane: pane) == .settled)
}

@Test func aimStoppedSettles() {
  #expect(PaneAim.judge(from: CGPoint(x: 640, y: 780), to: CGPoint(x: 639, y: 779), pane: pane) == .settled)
}

@Test func triangleContainment() {
  let t = (CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10))
  #expect(PaneAim.contains(triangle: t, CGPoint(x: 2, y: 2)))
  #expect(PaneAim.contains(triangle: t, CGPoint(x: 5, y: 0)))
  #expect(!PaneAim.contains(triangle: t, CGPoint(x: 6, y: 6)))
  #expect(!PaneAim.contains(triangle: t, CGPoint(x: -1, y: 2)))
}
