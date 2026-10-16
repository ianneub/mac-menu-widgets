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
    {"id": 13, "topic_id": 103, "name": "Old", "seen": true, "active_at": "2026-10-01T00:00:00Z"},
    {"id": 14, "topic_id": 104, "kind": "bundle", "name": "Receipts", "active_at": "2026-10-08T17:00:00Z"}
  ]}}
  """
  let items = try HeyMail.unseen(boxJSON: Data(json.utf8))
  #expect(items.map(\.id) == ["hey:101", "hey:102", "hey:104"])
  // `hey trash` takes the box item id; a bundle can't be trashed.
  #expect(items.map(\.trashID) == ["11", "12", nil])
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

// MARK: - Gmail (through PIM Bridge)

@Test func gmailQuery() {
  #expect(GmailMail.unreadQuery(primaryOnly: true) == "is:unread in:inbox category:primary")
  #expect(GmailMail.unreadQuery(primaryOnly: false) == "is:unread in:inbox")
}

@Test func gmailWebURLs() {
  #expect(GmailMail.webURL(email: "me@Example.com").absoluteString == "https://mail.google.com/a/example.com/#inbox")
  #expect(GmailMail.webURL(email: "someone@gmail.com").absoluteString
    == "https://mail.google.com/mail/?authuser=someone@gmail.com#inbox")
}

@Test func gmailAccounts() throws {
  let a = try GmailMail.accounts(json: Data("""
  {"accounts":[{"name":"Work","email":"me@example.com","status":"signed_in"},
               {"name":"Side","email":"x@example.org","status":"needs_sign_in","problem":"Sign-in expired"},
               {"email":"y@example.org","status":"something_new"}]}
  """.utf8))
  #expect(a.accounts == [
    .init(name: "Work", email: "me@example.com", status: .signedIn),
    .init(name: "Side", email: "x@example.org", status: .needsSignIn, problem: "Sign-in expired"),
    .init(name: "y@example.org", email: "y@example.org", status: .needsSignIn),
  ])
  #expect(a.problem == nil)
  #expect(try GmailMail.accounts(json: Data(#"{"accounts":[],"problem":"No OAuth client"}"#.utf8)).problem == "No OAuth client")
}

@Test func gmailThreadsFromSearch() throws {
  let msgs = try GmailMail.messages(searchJSON: Data("""
  {"account":"me@example.com","query":"is:unread in:inbox","estimated_total":2,"messages":[
    {"id":"m1","thread_id":"t1","from":"Bob <bob@x.com>","to":"me@example.com","subject":"Lunch",
     "snippet":"Hi &amp; bye","labels":["UNREAD","INBOX"],"unread":true,
     "url":"https://mail.google.com/mail/u/me@example.com/#all/t1","date":"2026-10-16T08:01:09-04:00"},
    {"id":"m2","thread_id":"t1","from":"\\"Ann\\" <ann@x.com>","to":"me@example.com","subject":"Re: Lunch",
     "snippet":"Sure","labels":["UNREAD","INBOX"],"unread":true,
     "url":"https://mail.google.com/mail/u/me@example.com/#all/t1","date":"2026-10-16T09:00:00-04:00"}]}
  """.utf8))
  #expect(msgs.count == 2)
  #expect(msgs[0].date == ISO8601DateFormatter().date(from: "2026-10-16T12:01:09Z"))
  let items = GmailMail.items(email: "Me@example.com", messages: msgs)
  #expect(items.count == 1)
  #expect(items[0].id == "gmail:me@example.com:t1")
  #expect(items[0].revision == "m2")
  #expect(items[0].sender == "Ann")
  #expect(items[0].subject == "Re: Lunch")
  #expect(items[0].unread == 2)
  #expect(items[0].url.absoluteString == "https://mail.google.com/mail/u/me@example.com/#all/t1")
  #expect(items[0].trashID == "t1")
  #expect(try GmailMail.messages(searchJSON: Data(#"{"messages":[]}"#.utf8)).isEmpty)
}

// MARK: - PIM Bridge socket

@Test func bridgeRequestIsOneLine() throws {
  let d = PIMBridge.request(id: 7, tool: "search", arguments: ["account": "Work", "max": 100])
  #expect(d.last == 0x0A)
  #expect(d.dropLast().contains(0x0A) == false)
  let obj = try JSONSerialization.jsonObject(with: d) as! [String: Any]
  #expect(obj["jsonrpc"] as? String == "2.0")
  #expect(obj["id"] as? Int == 7)
  #expect(obj["method"] as? String == "tools/call")
  let params = obj["params"] as! [String: Any]
  #expect(params["name"] as? String == "search")
  #expect((params["arguments"] as! [String: Any])["max"] as? Int == 100)
}

@Test func bridgeReplies() {
  let ok = PIMBridge.reply(Data(#"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"accounts\":[]}"}],"isError":false}}"#.utf8))
  #expect(ok.id == 3)
  #expect(ok.result == .success(Data(#"{"accounts":[]}"#.utf8)))
  let toolError = PIMBridge.reply(Data(#"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"No account Foo"}],"isError":true}}"#.utf8))
  #expect(toolError.result == .failure(.tool("No account Foo")))
  let rpc = PIMBridge.reply(Data(#"{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"Unknown tool"}}"#.utf8))
  #expect(rpc.result == .failure(.rpc("Unknown tool")))
  #expect(PIMBridge.reply(Data("nope".utf8)).result == .failure(.malformed))
}

@Test func bridgeThreadMoves() throws {
  let t = try PIMBridge.threadMove(json: Data("""
  {"trashed":[{"thread_id":"t1","from":"Bob","subject":"Lunch","messages":2}],"failed":[{"thread_id":"t2","error":"Not found"}]}
  """.utf8))
  #expect(t.moved == ["t1"])
  #expect(t.failed.map(\.id) == ["t2"] && t.failed.map(\.error) == ["Not found"])
  let u = try PIMBridge.threadMove(json: Data(#"{"untrashed":[{"thread_id":"t1","inbox":true}],"failed":[]}"#.utf8))
  #expect(u.moved == ["t1"] && u.failed.isEmpty)
}

// MARK: - config

@Test func mailConfigDefaultsAndOverrides() throws {
  let c = try JSONDecoder().decode(WidgetsConfig.self, from: Data("""
  {"mail": {"gmail": true, "pollIntervalSec": 2}}
  """.utf8))
  #expect(c.mail.gmail)
  #expect(c.mail.pollIntervalSec == 10)
  #expect(c.mail.hey && c.mail.primaryOnly && c.mail.notify)
  #expect(c.mail.sound == "default")
  let quiet = try JSONDecoder().decode(WidgetsConfig.self, from: Data(#"{"mail": {"sound": "Bottle"}}"#.utf8))
  #expect(quiet.mail.sound == "Bottle")
  #expect(!WidgetsConfig().mail.gmail)
}

/// Before PIM Bridge, `gmail` listed the accounts: a list with accounts
/// turns Gmail on, an empty one leaves it off, and the rest still loads.
@Test func mailConfigOldGmailList() throws {
  func gmail(_ json: String) throws -> WidgetsConfig.MailSettings {
    try JSONDecoder().decode(WidgetsConfig.self, from: Data(json.utf8)).mail
  }
  let old = try gmail(#"{"mail": {"gmail": [{"name": "Work", "email": "me@example.com"}], "primaryOnly": false}}"#)
  #expect(old.gmail && !old.primaryOnly)
  #expect(try !gmail(#"{"mail": {"gmail": []}}"#).gmail)
  #expect(try !gmail(#"{"mail": {"gmail": "yes"}}"#).gmail)
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

// MARK: - processes

@Test func processExitIsSignaledOffTheMainThread() async {
  let status: Int32? = await withCheckedContinuation { cont in
    DispatchQueue.global().async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/sh")
      p.arguments = ["-c", "exit 3"]
      guard let exited = try? p.runSignalingExit(), exited.wait(timeout: .now() + 10) == .success else {
        cont.resume(returning: nil)
        return
      }
      cont.resume(returning: p.terminationStatus)
    }
  }
  #expect(status == 3)
}
