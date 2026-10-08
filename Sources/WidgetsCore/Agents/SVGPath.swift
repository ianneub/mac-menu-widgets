import CoreGraphics
import Foundation

/// A minimal SVG path-data parser (M L H V C S Q T Z, absolute and
/// relative; no arcs) — enough to draw the Claude mark from its SVG.
public enum SVGPath {
  public static func cgPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var tokens = tokenize(d)[...]
    var cmd: Character = "M"
    var cur = CGPoint.zero
    var start = CGPoint.zero
    var lastCtrl: CGPoint?
    var lastCmd: Character = " "

    func num() -> CGFloat? {
      guard case let .number(n)? = tokens.first else { return nil }
      tokens.removeFirst()
      return CGFloat(n)
    }

    while let t = tokens.first {
      if case let .command(c) = t {
        cmd = c
        tokens.removeFirst()
        if c == "Z" || c == "z" {
          path.closeSubpath()
          cur = start
          lastCmd = c
          continue
        }
      }
      let rel = cmd.isLowercase
      let base = rel ? cur : .zero
      switch cmd.uppercased().first! {
      case "M":
        guard let x = num(), let y = num() else { return path }
        cur = CGPoint(x: base.x + x, y: base.y + y)
        path.move(to: cur)
        start = cur
        // Subsequent pairs are implicit linetos.
        cmd = rel ? "l" : "L"
      case "L":
        guard let x = num(), let y = num() else { return path }
        cur = CGPoint(x: base.x + x, y: base.y + y)
        path.addLine(to: cur)
      case "H":
        guard let x = num() else { return path }
        cur.x = (rel ? cur.x : 0) + x
        path.addLine(to: cur)
      case "V":
        guard let y = num() else { return path }
        cur.y = (rel ? cur.y : 0) + y
        path.addLine(to: cur)
      case "C":
        guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num()
        else { return path }
        let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
        let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
        cur = CGPoint(x: base.x + x, y: base.y + y)
        path.addCurve(to: cur, control1: c1, control2: c2)
        lastCtrl = c2
      case "S":
        guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return path }
        let c1 = "CcSs".contains(lastCmd) ? reflect(lastCtrl, cur) : cur
        let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
        cur = CGPoint(x: base.x + x, y: base.y + y)
        path.addCurve(to: cur, control1: c1, control2: c2)
        lastCtrl = c2
      case "Q":
        guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { return path }
        let c = CGPoint(x: base.x + x1, y: base.y + y1)
        cur = CGPoint(x: base.x + x, y: base.y + y)
        path.addQuadCurve(to: cur, control: c)
        lastCtrl = c
      case "T":
        guard let x = num(), let y = num() else { return path }
        let c = "QqTt".contains(lastCmd) ? reflect(lastCtrl, cur) : cur
        cur = CGPoint(x: base.x + x, y: base.y + y)
        path.addQuadCurve(to: cur, control: c)
        lastCtrl = c
      default:
        // Unsupported command (arcs): skip its token run.
        tokens.removeFirst()
      }
      lastCmd = cmd
    }
    return path
  }

  private static func reflect(_ p: CGPoint?, _ about: CGPoint) -> CGPoint {
    guard let p else { return about }
    return CGPoint(x: 2 * about.x - p.x, y: 2 * about.y - p.y)
  }

  enum Token: Equatable { case command(Character), number(Double) }

  static func tokenize(_ d: String) -> [Token] {
    var out: [Token] = []
    let chars = Array(d)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c.isLetter, c != "e", c != "E" {
        out.append(.command(c))
        i += 1
      } else if c.isNumber || c == "-" || c == "+" || c == "." {
        var j = i
        var seenDot = false
        var seenExp = false
        if chars[j] == "-" || chars[j] == "+" { j += 1 }
        while j < chars.count {
          let d = chars[j]
          if d.isNumber { j += 1; continue }
          if d == ".", !seenDot, !seenExp { seenDot = true; j += 1; continue }
          if (d == "e" || d == "E"), !seenExp {
            seenExp = true
            j += 1
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            continue
          }
          break
        }
        if let n = Double(String(chars[i..<j])) { out.append(.number(n)) }
        i = max(j, i + 1)
      } else {
        i += 1
      }
    }
    return out
  }
}

/// The Claude mark (from Omarchy's agents/assets/claude.svg, 256×257).
public enum ClaudeMark {
  public static let viewBox = CGSize(width: 256, height: 257)
  public static let pathData = "m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z"

  public static let cgPath: CGPath = SVGPath.cgPath(pathData)
}
