import Foundation
import Security

/// Gmail refresh tokens, one login-keychain item per account. Items the app
/// creates trust the app's signature, so a stable signing identity (see
/// build-app.sh) keeps them readable without prompts across rebuilds.
enum Keychain {
  static let service = "com.ianneub.menu-widgets.gmail"

  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account.lowercased()]
  }

  static func read(_ account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  static func save(_ account: String, _ secret: String) -> Bool {
    let data = Data(secret.utf8)
    let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return true }
    var q = query(account)
    q[kSecValueData as String] = data
    q[kSecAttrLabel as String] = "MenuWidgets Gmail (\(account))"
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }

  static func delete(_ account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }
}
