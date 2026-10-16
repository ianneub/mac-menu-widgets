import CoreGraphics
import Foundation

/// Menu aim for the side panes, the way macOS handles submenus: while the
/// pointer is moving toward the open pane, the rows it crosses on the way
/// don't take the pane over. Each check compares the pointer with where it
/// was at the last check: still moving, and inside the triangle from there
/// to the pane's near edge, means it's heading for the pane.
public enum PaneAim {
  public enum Verdict: Equatable {
    /// Over the pane: it keeps what it shows.
    case arrived
    /// Moving toward the pane: look again in a moment.
    case heading
    /// Stopped, or moving somewhere else: the row under the pointer wins.
    case settled
  }

  /// Moving less than this between checks counts as stopped.
  public static let minStep: CGFloat = 2

  public static func judge(from last: CGPoint, to now: CGPoint, pane: CGRect) -> Verdict {
    if pane.contains(now) { return .arrived }
    if hypot(now.x - last.x, now.y - last.y) < minStep { return .settled }
    let edgeX = last.x >= pane.midX ? pane.maxX : pane.minX
    let top = CGPoint(x: edgeX, y: pane.maxY)
    let bottom = CGPoint(x: edgeX, y: pane.minY)
    return contains(triangle: (last, top, bottom), now) ? .heading : .settled
  }

  /// True when `p` is inside the triangle or on its edge.
  static func contains(triangle t: (CGPoint, CGPoint, CGPoint), _ p: CGPoint) -> Bool {
    func side(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
      (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
    let s = [side(t.0, t.1), side(t.1, t.2), side(t.2, t.0)]
    return !(s.contains { $0 < 0 } && s.contains { $0 > 0 })
  }
}
