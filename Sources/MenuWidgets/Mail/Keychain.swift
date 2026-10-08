import Foundation

/// Gmail refresh tokens, one login-keychain item per account, kept through
/// /usr/bin/security rather than SecItem: an item that tool writes trusts
/// the tool, so reading it back never prompts, however often the app is
/// rebuilt or re-signed (SecItem items trust the app's exact build, so each
/// rebuild asked for the Keychain password again). The token goes in on
/// stdin (`security -i`), never on a command line where `ps` could see it.
enum Keychain {
  static let service = "com.ianneub.menu-widgets.gmail-token"
  private static let tool = "/usr/bin/security"

  static func read(_ account: String) -> String? {
    let out = run(["find-generic-password", "-s", service, "-a", account.lowercased(), "-w"])
    guard out.status == 0 else { return nil }
    let s = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
  }

  @discardableResult
  static func save(_ account: String, _ secret: String) -> Bool {
    // Google's tokens are URL-safe; refuse anything the command parser
    // would need escaping for rather than mangle it.
    guard !secret.isEmpty, secret.allSatisfy({ !$0.isWhitespace && $0 != "\"" && $0 != "\\" }) else { return false }
    let label = "MenuWidgets Gmail (\(account.lowercased()))"
    let cmd = "add-generic-password -U -s \(service) -a \(account.lowercased()) -l \"\(label)\" -w \"\(secret)\"\n"
    return run(["-i"], stdin: Data(cmd.utf8)).status == 0
  }

  static func delete(_ account: String) {
    _ = run(["delete-generic-password", "-s", service, "-a", account.lowercased()])
  }

  private static func run(_ args: [String], stdin: Data? = nil) -> (status: Int32, stdout: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let input = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    do { try p.run() } catch { return (-1, Data()) }
    if let stdin {
      input.fileHandleForWriting.write(stdin)
      try? input.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
  }
}
