import Foundation
import Testing
@testable import WidgetsCore

@Test func keyComboParsesModifiersInAnyOrder() {
  let e = KeyCombo(keyCode: 0x0E, modifiers: KeyCombo.command | KeyCombo.shift)
  #expect(KeyCombo.parse("cmd+shift+e") == e)
  #expect(KeyCombo.parse("Shift + Command + E") == e)
  #expect(KeyCombo.parse("ctrl+alt+f5") == KeyCombo(keyCode: 0x60, modifiers: KeyCombo.control | KeyCombo.option))
  #expect(KeyCombo.parse("opt+space")?.keyCode == 0x31)
  #expect(KeyCombo.parse("cmd+/")?.keyCode == 0x2C)
}

@Test func keyComboRejectsBadInput() {
  #expect(KeyCombo.parse("") == nil)
  #expect(KeyCombo.parse("cmd+") == nil)
  #expect(KeyCombo.parse("cmd+shift+nope") == nil)
  #expect(KeyCombo.parse("hyper+e") == nil)
  // A bare key would take it from every app; function keys are the exception.
  #expect(KeyCombo.parse("e") == nil)
  #expect(KeyCombo.parse("f13") == KeyCombo(keyCode: 0x69, modifiers: 0))
}

@Test func hotkeysDecodeAndSkipBadEntries() throws {
  let json = #"""
  {"hotkeys": [
    {"key": "cmd+shift+e", "command": ["/bin/echo", "hi"], "apps": ["com.mitchellh.ghostty"]},
    {"key": "f13", "command": ["say", "hello"]},
    {"key": "cmd+k"},
    "nonsense"
  ]}
  """#
  let h = try JSONDecoder().decode(WidgetsConfig.self, from: Data(json.utf8)).hotkeys
  #expect(h == [
    .init(key: "cmd+shift+e", command: ["/bin/echo", "hi"], apps: ["com.mitchellh.ghostty"]),
    .init(key: "f13", command: ["say", "hello"]),
  ])
  #expect(try JSONDecoder().decode(WidgetsConfig.self, from: Data("{}".utf8)).hotkeys.isEmpty)
}
