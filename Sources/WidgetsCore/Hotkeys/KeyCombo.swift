import Foundation

/// A global keyboard shortcut written the way terminal and editor configs
/// write them ("cmd+shift+e", "ctrl+alt+f5"), turned into the virtual key
/// code and Carbon modifier mask that RegisterEventHotKey takes.
public struct KeyCombo: Equatable, Sendable {
  public var keyCode: UInt32
  /// Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
  public var modifiers: UInt32

  public init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  // Carbon's modifier bits (Events.h), kept here so the core target needs
  // no Carbon import.
  public static let command: UInt32 = 0x0100
  public static let shift: UInt32 = 0x0200
  public static let option: UInt32 = 0x0800
  public static let control: UInt32 = 0x1000

  /// Parses "cmd+shift+e". Modifiers: cmd/command, shift, alt/opt/option,
  /// ctrl/control, in any order and case. Nil for an unknown key, a
  /// missing key, or no modifier at all (a bare letter would take that
  /// letter away from every app).
  public static func parse(_ text: String) -> KeyCombo? {
    let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let keyName = parts.last, !keyName.isEmpty, let code = keyCodes[keyName] else { return nil }
    var mods: UInt32 = 0
    for part in parts.dropLast() {
      switch part {
      case "cmd", "command": mods |= command
      case "shift": mods |= shift
      case "alt", "opt", "option": mods |= option
      case "ctrl", "control": mods |= control
      default: return nil
      }
    }
    // Function keys may stand alone; anything else needs a modifier.
    guard mods != 0 || functionKeys.contains(keyName) else { return nil }
    return KeyCombo(keyCode: code, modifiers: mods)
  }

  private static let functionKeys: Set<String> = Set((1...20).map { "f\($0)" })

  /// Virtual key codes (kVK_* in Events.h). Letters, digits and punctuation
  /// are key positions on a US (ANSI) keyboard, as with any macOS hotkey.
  static let keyCodes: [String: UInt32] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
    "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "delete": 0x75,
    "escape": 0x35, "esc": 0x35, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
    "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
    "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
  ]
}
