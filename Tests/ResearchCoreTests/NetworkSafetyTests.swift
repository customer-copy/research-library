import Foundation
import Testing
@testable import ResearchCore

@Suite struct NetworkSafetyTests {
  @Test func privateAndObfuscatedHostsAreRejected() {
    for url in [
      "https://[::ffff:127.0.0.1]/", "https://[::1]/", "https://[::]/", "https://[fe80::1]/",
      "https://[fd12:3456::1]/", "https://[64:ff9b::a00:1]/", "https://0x7f.0.0.1/", "https://127.1/",
      "https://2130706433/", "https://017.0.0.1/", "https://100.64.0.1/", "https://172.20.1.1/",
      "https://169.254.169.254/latest", "https://224.0.0.1/", "https://[zz::1]/",
    ] {
      #expect(throws: (any Error).self, "\(url)") { try Identifiers.canonicalURL(url) }
    }
  }

  @Test func publicHostsStillWork() throws {
    for url in ["https://www.nature.com/articles/x", "https://8.8.8.8/", "https://[2606:4700::1111]/",
      "https://face.be/paper", "https://123.example.org/", "https://arxiv.org/abs/2610.03454"] {
      _ = try Identifiers.canonicalURL(url)
    }
  }

  @Test func resolutionCatchesNamesPointingAtThisMac() {
    #expect(NetworkSafety.resolvesToNonPublicAddress("localhost"))
    #expect(NetworkSafety.resolvesToNonPublicAddress("127.0.0.1"))
    #expect(!NetworkSafety.resolvesToNonPublicAddress("8.8.8.8"))
  }

  @Test func impossibleChromeCaptureIsSetAsideAfterRetries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChromeQuarantine-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try LibraryService(root: root, databaseURL: root.appendingPathComponent("index.sqlite"), providers: [])
    let id = UUID()
    let folder = root.appendingPathComponent("Inbox/BrowserCaptures")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let payload: [String: Any] = ["version": 2, "id": id.uuidString, "url": "https://10.1.2.3/paper",
      "phase": "pending", "metadata": ["title": "Intranet page"]]
    let envelope = folder.appendingPathComponent("\(id.uuidString.lowercased()).json")
    try JSONSerialization.data(withJSONObject: payload).write(to: envelope)
    for _ in 0..<LibraryService.chromeCaptureAttempts { await library.consumePendingChromeCaptures() }
    #expect(!FileManager.default.fileExists(atPath: envelope.path))
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Failed/\(id.uuidString.lowercased()).json").path))
  }
}

extension NetworkSafetyTests {
  @Test func symlinkedFolderCannotRedirectNewFilesOutsideLibrary() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("SafeURL-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Library"), outside = base.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Inbox"), withDestinationURL: outside)
    #expect(throws: LibraryError.self) { try Files.safeURL(root: root, relative: "Inbox/new.pdf") }
    #expect(throws: LibraryError.self) { try Files.safeURL(root: root, relative: "Inbox/Sub/new.pdf") }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
    let inside = try Files.safeURL(root: root, relative: "PDFs/Sub/new.pdf")
    #expect(inside.path.hasSuffix("/Library/PDFs/Sub/new.pdf"))
  }
}

extension NetworkSafetyTests {
  @Test func rateLimiterQueuesConcurrentCallersPerHost() {
    var limiter = HostRateLimiter()
    let now = Date(timeIntervalSince1970: 1_000)
    let a = limiter.reserve(host: "export.arxiv.org", now: now)
    let b = limiter.reserve(host: "export.arxiv.org", now: now)
    let c = limiter.reserve(host: "export.arxiv.org", now: now)
    #expect(a == now)
    #expect(b.timeIntervalSince(a) == 3 && c.timeIntervalSince(b) == 3)
    // Another host is not held up by arXiv's queue.
    #expect(limiter.reserve(host: "api.crossref.org", now: now) == now)
  }

  @Test func responseCacheIsBoundedAndKeysOmitCredentials() throws {
    var cache = ResponseCache(capacity: 2)
    let response = HTTPURLResponse(url: URL(string: "https://a.org")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    let keyed = ResponseCache.key(URL(string: "https://api.openalex.org/works?search=x&api_key=SECRET")!)
    #expect(!keyed.contains("SECRET"))
    cache.set("1", (Data(), response)); cache.set("2", (Data(), response))
    _ = cache.get("1")  // 1 is now most recent
    cache.set("3", (Data(), response))
    #expect(cache.count == 2 && cache.get("2") == nil && cache.get("1") != nil)
  }

  @Test func contactEmailGoesOnlyToPolitePoolAPIs() async {
    let transport = NativeHTTPTransport(contactEmail: "me@example.org")
    let crossref = await transport.withContact(URL(string: "https://api.crossref.org/works/10.1/x")!)
    #expect(crossref.absoluteString.contains("mailto=me@example.org"))
    let publisher = await transport.withContact(URL(string: "https://www.nature.com/articles/x")!)
    #expect(!publisher.absoluteString.contains("example.org"))
    let none = await NativeHTTPTransport(contactEmail: nil).withContact(URL(string: "https://api.openalex.org/works")!)
    #expect(!none.absoluteString.contains("mailto"))
  }
}
