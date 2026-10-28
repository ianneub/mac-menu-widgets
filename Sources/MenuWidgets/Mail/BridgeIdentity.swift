import CryptoKit
import Darwin
import Foundation
import Security
import WidgetsCore

/// Whether the process at the other end of the socket is PIM Bridge, as
/// the bridge checks MenuWidgets. Without this, anything running as you
/// could listen at the socket while the bridge is down, show made-up mail
/// in the panel, and hand it a sign-in page to open.
enum BridgeIdentity {
  enum Verdict: Equatable {
    case genuine
    /// Something else, by its path when it has one.
    case impostor(String)
    /// MenuWidgets is signed ad hoc, so there's no signer to compare with.
    case unpinned
  }

  /// From MenuWidgets' own signature, once.
  static let requirement: SecRequirement? = {
    var me: SecCode?
    var staticMe: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
          SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
          SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let info = info as? [String: Any]
    else { return nil }
    let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
    let sha1 = leaf.map { Insecure.SHA1.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined() }
    guard let text = PIMBridge.requirement(teamID: info[kSecCodeInfoTeamIdentifier as String] as? String, leafSHA1: sha1)
    else { return nil }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
    return requirement
  }()

  /// Checks the peer of a connected socket. The audit token names the
  /// process that listens at the socket, so one check per connection does.
  static func check(_ fd: Int32) -> Verdict {
    guard let requirement else { return .unpinned }
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return .impostor(peerPath(fd)) }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    var info: CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
          let code,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
          // A SecCode works where a SecStaticCode is expected; dynamic information is its live status.
          SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                        SecCSFlags(rawValue: kSecCSDynamicInformation), &info) == errSecSuccess,
          let status = ((info as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value,
          PIMBridge.trustedStatus(status)
    else { return .impostor(peerPath(fd)) }
    return .genuine
  }

  private static func peerPath(_ fd: Int32) -> String {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return "an unknown process" }
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
    return String(cString: buf)
  }
}
