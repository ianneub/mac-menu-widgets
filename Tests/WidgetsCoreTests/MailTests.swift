import Foundation
import Testing
@testable import WidgetsCore

private func item(_ id: String, rev: String = "1", date: Date = Date(timeIntervalSince1970: 1_000_000)) -> MailItem {
  MailItem(id: id, account: "a", revision: rev, sender: "S", subject: "Hi", snippet: "", date: date,
           url: URL(string: "https://example.com")!)
}

// MARK: - diff

@Test func mailFirstLookIsBacklog() {
  #expect(MailDiff.news(previous: nil, since: nil, current: [item("x")]) == MailNews(fresh: [], gone: []))
}

@Test func mailNewThreadsAndRepliesAreFresh() {
  let t0 = Date(timeIntervalSince1970: 1_000_000)
  let prev = [item("a", rev: "1", date: t0), item("b", rev: "1", date: t0)]
  let cur = [item("a", rev: "1", date: t0), item("b", rev: "2", date: t0 + 60), item("c", date: t0 + 30)]
  let news = MailDiff.news(previous: prev, since: t0, current: cur)
  #expect(news.fresh.map(\.id) == ["b", "c"])
  #expect(news.gone.isEmpty)
}

@Test func mailReadElsewhereIsGone() {
  let news = MailDiff.news(previous: [item("a"), item("b")], since: nil, current: [item("b")])
  #expect(news.gone == ["a"])
  #expect(news.fresh.isEmpty)
}

@Test func mailOldMailMarkedUnreadIsNotNews() {
  let look = Date(timeIntervalSince1970: 2_000_000)
  let old = item("a", date: look - 86400)
  let recent = item("b", date: look - 60)
  #expect(MailDiff.news(previous: [], since: look, current: [old, recent]).fresh.map(\.id) == ["b"])
}

// MARK: - text

@Test func mailDisplayNames() {
  #expect(MailText.displayName(fromHeader: "\"Jane Doe\" <jane@example.com>") == "Jane Doe")
  #expect(MailText.displayName(fromHeader: "Jane Doe <jane@example.com>") == "Jane Doe")
  #expect(MailText.displayName(fromHeader: "<jane@example.com>") == "jane@example.com")
  #expect(MailText.displayName(fromHeader: "jane@example.com") == "jane@example.com")
}

@Test func mailSnippetsLoseEntities() {
  #expect(MailText.cleanSnippet("It&#39;s  here &amp; there&nbsp;\n now") == "It's here & there now")
  #expect(MailText.cleanSnippet("&#x2019;") == "\u{2019}")
}

@Test func mailAges() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "America/New_York")!
  let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
  #expect(MailText.age(now - 3600, now: now, calendar: cal) == "2:00 PM")
  #expect(MailText.age(now - 86400, now: now, calendar: cal) == "Yesterday")
  #expect(MailText.age(now - 3 * 86400, now: now, calendar: cal) == "Mon")
  #expect(MailText.age(now - 30 * 86400, now: now, calendar: cal) == "Sep 8")
}

// MARK: - HEY

@Test func heyUnseenPostings() throws {
  let json = """
  {"ok": true, "data": {"name": "Imbox", "postings": [
    {"id": 11, "topic_id": 101, "name": "Pantry", "summary": "Milk &amp; eggs", "active_at": "2026-10-08T19:05:41Z",
     "app_url": "https://app.hey.com/topics/101", "creator": {"name": "Becca"}},
    {"id": 12, "topic_id": 102, "name": "Plan", "alternative_sender_name": "Fidelity", "creator": {"name": "Ian"},
     "seen": false, "active_at": "2026-10-08T18:00:00.5Z", "app_url": "https://app.hey.com/topics/102"},
    {"id": 13, "topic_id": 103, "name": "Old", "seen": true, "active_at": "2026-10-01T00:00:00Z"}
  ]}}
  """
  let items = try HeyMail.unseen(boxJSON: Data(json.utf8))
  #expect(items.map(\.id) == ["hey:101", "hey:102"])
  #expect(items[0].sender == "Becca")
  #expect(items[0].snippet == "Milk & eggs")
  #expect(items[0].revision == "2026-10-08T19:05:41Z")
  #expect(items[1].sender == "Fidelity")
  #expect(items[1].date == Date(timeIntervalSince1970: 1_791_482_400.5))
  #expect(items[1].url.absoluteString == "https://app.hey.com/topics/102")
}

@Test func heyWatchLines() {
  #expect(HeyMail.watchSignal(line: #"{"change":"ready","at":"x"}"#) == .ready)
  #expect(HeyMail.watchSignal(line: #"{"change":"added","new":true}"#) == .changed)
  #expect(HeyMail.watchSignal(line: #"{"change":"resync"}"#) == .changed)
  #expect(HeyMail.watchSignal(line: #"{"change":"disconnected"}"#) == .disconnected)
  #expect(HeyMail.watchSignal(line: "garbage") == .other)
}

// MARK: - Gmail

@Test func gmailListURL() {
  let u = GmailMail.listURL(primaryOnly: true).absoluteString
  #expect(u.contains("labelIds=INBOX&labelIds=UNREAD&labelIds=CATEGORY_PERSONAL"))
  #expect(!GmailMail.listURL(primaryOnly: false).absoluteString.contains("CATEGORY_PERSONAL"))
}

@Test func gmailWebURLs() {
  #expect(GmailMail.webURL(email: "me@Example.com", threadID: "18f").absoluteString
    == "https://mail.google.com/a/example.com/#inbox/18f")
  #expect(GmailMail.webURL(email: "someone@gmail.com").absoluteString
    == "https://mail.google.com/mail/?authuser=someone@gmail.com#inbox")
}

@Test func gmailThreadsFromMessages() throws {
  let refs = try GmailMail.refs(listJSON: Data(#"{"messages":[{"id":"m2","threadId":"t1"},{"id":"m1","threadId":"t1"}],"resultSizeEstimate":2}"#.utf8))
  #expect(refs == [.init(id: "m2", threadId: "t1"), .init(id: "m1", threadId: "t1")])
  #expect(try GmailMail.refs(listJSON: Data(#"{"resultSizeEstimate":0}"#.utf8)).isEmpty)

  func msg(_ id: String, _ ms: Int, from: String) throws -> GmailMail.Message {
    try GmailMail.message(json: Data("""
    {"id":"\(id)","threadId":"t1","snippet":"Hi &amp; bye","internalDate":"\(ms)",
     "payload":{"headers":[{"name":"From","value":"\(from)"},{"name":"Subject","value":"Lunch"}]}}
    """.utf8))
  }
  let a = try msg("m1", 1_000_000, from: "Bob <bob@x.com>")
  let b = try msg("m2", 2_000_000, from: #"\"Ann\" <ann@x.com>"#)
  #expect(a.date == Date(timeIntervalSince1970: 1000))
  let items = GmailMail.items(email: "me@example.com", messages: [a, b])
  #expect(items.count == 1)
  #expect(items[0].id == "gmail:me@example.com:t1")
  #expect(items[0].revision == "m2")
  #expect(items[0].sender == "Ann")
  #expect(items[0].snippet == "Hi & bye")
  #expect(items[0].unread == 2)
}

@Test func gmailErrors() {
  #expect(GmailMail.errorMessage(json: Data(#"{"error":{"code":403,"message":"Gmail API has not been used"}}"#.utf8))
    == "Gmail API has not been used")
}

// MARK: - OAuth

@Test func oauthClientFile() {
  let installed = #"{"installed":{"client_id":"abc.apps.googleusercontent.com","client_secret":"s3","redirect_uris":["http://localhost"]}}"#
  #expect(GoogleOAuth.client(json: Data(installed.utf8)) == .init(id: "abc.apps.googleusercontent.com", secret: "s3"))
  #expect(GoogleOAuth.client(json: Data(#"{"client_id":"x"}"#.utf8)) == .init(id: "x", secret: ""))
  #expect(GoogleOAuth.client(json: Data("{}".utf8)) == nil)
}

@Test func oauthPKCE() {
  // RFC 7636 appendix B.
  #expect(GoogleOAuth.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  let v = GoogleOAuth.makeVerifier()
  #expect(v.count == 64)
}

@Test func oauthAuthURL() {
  let u = GoogleOAuth.authURL(client: .init(id: "cid", secret: ""), redirect: "http://127.0.0.1:5000",
                              verifier: "v", state: "st", loginHint: "me@example.org")
  let q = Dictionary(uniqueKeysWithValues: URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
  #expect(q["redirect_uri"] == "http://127.0.0.1:5000")
  #expect(q["scope"] == "https://www.googleapis.com/auth/gmail.metadata")
  #expect(q["access_type"] == "offline")
  #expect(q["login_hint"] == "me@example.org")
  #expect(q["code_challenge_method"] == "S256")
}

@Test func oauthCallback() {
  #expect(GoogleOAuth.callback(requestLine: "GET /?state=st&code=4/0Ab&scope=x HTTP/1.1") == .code("4/0Ab", state: "st"))
  #expect(GoogleOAuth.callback(requestLine: "GET /?error=access_denied&state=st HTTP/1.1") == .error("access_denied"))
  #expect(GoogleOAuth.callback(requestLine: "GET /favicon.ico HTTP/1.1") == .unrelated)
}

@Test func oauthFormBody() {
  let body = String(decoding: GoogleOAuth.formBody([("code", "4/0A b+c"), ("x", "y")]), as: UTF8.self)
  #expect(body == "code=4%2F0A%20b%2Bc&x=y")
}

@Test func oauthTokens() {
  let now = Date(timeIntervalSince1970: 0)
  let ok = GoogleOAuth.token(json: Data(#"{"access_token":"at","expires_in":3599,"refresh_token":"rt"}"#.utf8), now: now)
  #expect(ok == .success(.init(access: "at", refresh: "rt", expires: Date(timeIntervalSince1970: 3539))))
  let bad = GoogleOAuth.token(json: Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))
  #expect(bad == .failure(.invalidGrant("Token has been expired or revoked.")))
}

// MARK: - config

@Test func mailConfigDefaultsAndOverrides() throws {
  let c = try JSONDecoder().decode(WidgetsConfig.self, from: Data("""
  {"mail": {"gmail": [{"name": "Work", "email": "me@example.com"}], "pollIntervalSec": 2}}
  """.utf8))
  #expect(c.mail.gmail == [.init(name: "Work", email: "me@example.com")])
  #expect(c.mail.pollIntervalSec == 10)
  #expect(c.mail.hey && c.mail.primaryOnly && c.mail.notify)
  #expect(c.mail.sound == "default")
  let quiet = try JSONDecoder().decode(WidgetsConfig.self, from: Data(#"{"mail": {"sound": "Bottle"}}"#.utf8))
  #expect(quiet.mail.sound == "Bottle")
  #expect(WidgetsConfig().mail.gmail.isEmpty)
}

@Test func widgetsCanBeTurnedOff() throws {
  let c = try JSONDecoder().decode(WidgetsConfig.self, from: Data("""
  {"agents": {"enabled": false}, "reminders": {"enabled": false}, "weather": {"name": "X"}}
  """.utf8))
  #expect(!c.agents.enabled && !c.reminders.enabled)
  #expect(c.time.enabled && c.weather.enabled && c.mail.enabled)
  #expect(c.agents.refreshIntervalSec == 900)
  let all = WidgetsConfig()
  #expect(all.time.enabled && all.weather.enabled && all.agents.enabled && all.reminders.enabled && all.mail.enabled)
}
