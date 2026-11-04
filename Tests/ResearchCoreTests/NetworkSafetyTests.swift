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
