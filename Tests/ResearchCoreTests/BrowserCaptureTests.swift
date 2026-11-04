import Foundation
import PDFKit
import Testing
@testable import ResearchCore

struct BrowserCaptureTests {
  func chromePayload(root: URL, id: UUID, phase: String = "pending", doi: String = "10.1038/s41586-026-11114-1") throws {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox/BrowserCaptures"), withIntermediateDirectories: true)
    let payload: [String: Any] = ["version": 2, "id": id.uuidString, "url": "https://www.nature.com/articles/s41586-026-11114-1",
      "pdfURL": "https://www.nature.com/articles/s41586-026-11114-1.pdf", "phase": phase,
      "metadata": ["title": "Human lung organoid modelling of tissue-resident antiviral T cell responses",
        "doi": doi, "journal": "Nature", "publicationDate": "2026/10/07", "abstract": "Captured abstract.",
        "authors": [["name": "Rathkey, Joseph K.", "orcid": "0009-0004-5981-7469"], ["name": "van Unen, Vincent"]]]]
    try Files.atomicWrite(JSONSerialization.data(withJSONObject: payload),
      to: root.appendingPathComponent("Inbox/BrowserCaptures/\(id.uuidString.lowercased()).json"))
  }
  func chromePDF(root: URL, id: UUID) throws {
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    let data = try #require(document.dataRepresentation())
    try Files.atomicWrite(data, to: root.appendingPathComponent("Inbox/Chrome-\(id.uuidString.lowercased()).pdf"))
  }
  @Test func chromePublishesMetadataBeforeDownloadAndPreservesItOnAttachment() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChromeFast-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let network = NoChromeNetwork()
    let library = try LibraryService(root: root, databaseURL: root.appendingPathComponent("index.sqlite"), providers: [], transport: network)
    let id = UUID()
    try chromePayload(root: root, id: id)
    let start = ContinuousClock.now
    let added = try await library.consumeChromeCapture(id)
    let elapsed = start.duration(to: .now)
    #expect(elapsed < timeBudget(1))
    #expect(added.doi == "10.1038/s41586-026-11114-1" && added.journal == "Nature")
    #expect(added.year == 2026 && added.publicationDate == "2026-10-07")
    #expect(added.abstract == "Captured abstract.")
    #expect(added.orderedAuthors[1].familyName == "van Unen")
    #expect(added.orderedAuthors[0].orcid == "0009-0004-5981-7469")
    #expect(!added.hasPDF && added.pdfLookup?.status == .pending)
    #expect(try await library.search("organoid").contains { $0.item.id == added.id })
    // Regular ingestion must not run metadata lookups or mark the incomplete download failed.
    await library.processPending()
    #expect(try await library.requests().first?.state == .waitingForResource)
    try chromePDF(root: root, id: id)
    try chromePayload(root: root, id: id, phase: "ready")
    let attachStart = ContinuousClock.now
    let attached = try await library.consumeChromeCapture(id)
    #expect(attachStart.duration(to: .now) < timeBudget(1))
    #expect(attached.id == added.id && attached.hasPDF && attached.pdfLookup?.status == .available)
    #expect(attached.orderedAuthors.count == 2 && attached.abstract == added.abstract)
    #expect(try await library.requests().first?.state == .complete)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox/Chrome-\(id.uuidString.lowercased()).pdf").path))
    #expect(await network.calls == 0)
    print("Chrome metadata registration: \(elapsed); attachment: \(attachStart.duration(to: .now))")
    let retried = try await library.consumeChromeCapture(id)
    #expect(retried.resources.filter { $0.relativePath != nil }.count == 1)
  }
  @Test func chromeDuplicateCapturesPreserveHumanEditsAndRecoverInterruptedCopy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChromeRecovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("index.sqlite")
    let library = try LibraryService(root: root, databaseURL: database, providers: [])
    var edited = LibraryItem(title: "A corrected title")
    edited.doi = "10.1038/s41586-026-11114-1"; edited.humanEdited = true; edited.notes = "Keep these notes"
    try await library.edit(edited)
    let id = UUID()
    try chromePayload(root: root, id: id)
    let added = try await library.consumeChromeCapture(id)
    #expect(added.id == edited.id && added.title == edited.title && added.notes == edited.notes)
    try chromePDF(root: root, id: id)
    try chromePayload(root: root, id: id, phase: "ready")
    await library.setImportFault { boundary in
      if case .copied = boundary { throw LibraryError.invalid("Simulated interruption") }
    }
    await #expect(throws: (any Error).self) { try await library.consumeChromeCapture(id) }
    let restarted = try LibraryService(root: root, databaseURL: database, providers: [])
    await restarted.consumePendingChromeCaptures()
    let recovered = try #require(try await restarted.item(edited.id))
    #expect(recovered.hasPDF && recovered.title == edited.title && recovered.notes == edited.notes)
    #expect(recovered.resources.filter { $0.relativePath != nil }.count == 1)
    #expect(try await restarted.requests().first?.state == .complete)
  }
  @Test func chromeSignalsAndDiskPayloadsRejectUnsafeInputs() throws {
    let id = UUID()
    #expect(try BrowserCapture.chromeID(from: URL(string: "researchlibrary://chrome-capture?id=\(id)")!) == id)
    for link in ["researchlibrary://chrome-capture?id=../escape", "researchlibrary://chrome-capture?id=\(id)&id=\(id)"] {
      #expect(throws: (any Error).self) { try BrowserCapture.chromeID(from: URL(string: link)!) }
    }
  }
  @Test func chromeLargePDFBecomesAvailableWithoutOCRorNetworkWaits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChromeLarge-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try LibraryService(root: root, databaseURL: root.appendingPathComponent("index.sqlite"), providers: [])
    let id = UUID()
    try chromePayload(root: root, id: id)
    _ = try await library.consumeChromeCapture(id)
    let document = PDFDocument(); document.insert(PDFPage(), at: 0)
    var data = try #require(document.dataRepresentation())
    data.append(Data("\n%".utf8)); data.append(Data(repeating: 32, count: 88 * 1024 * 1024))
    try Files.atomicWrite(data, to: root.appendingPathComponent("Inbox/Chrome-\(id.uuidString.lowercased()).pdf"))
    try chromePayload(root: root, id: id, phase: "ready")
    let start = ContinuousClock.now
    let item = try await library.consumeChromeCapture(id)
    let elapsed = start.duration(to: .now)
    #expect(item.hasPDF)
    #expect(elapsed < timeBudget(1))
    print("Chrome 88 MB local attachment: \(elapsed) (publisher transfer excluded)")
  }
  func link(id: UUID = UUID(), url: String = "https://example.org/paper", extra: [URLQueryItem] = []) throws -> URL {
    var components = URLComponents()
    components.scheme = "researchlibrary"; components.host = "capture"
    components.queryItems = [URLQueryItem(name: "version", value: "1"),
      URLQueryItem(name: "id", value: id.uuidString), URLQueryItem(name: "url", value: url)] + extra
    return try #require(components.url)
  }
  @Test func browserCitationAndPDFHintSurviveURLHandoff() throws {
    let id = UUID()
    let title = "Microscopy & biology: α / β?"
    let url = try link(id: id, extra: [URLQueryItem(name: "title", value: title),
      URLQueryItem(name: "doi", value: "10.1146/annurev-cellbio-111524-111428"),
      URLQueryItem(name: "pmid", value: "42823348"),
      URLQueryItem(name: "pdfURL", value: "https://example.org/paper.pdf?download=1&version=2")])
    let request = try BrowserCapture.request(from: url)
    #expect(request.id == id && request.source == "safariExtension")
    #expect(request.suggestedTitle == title)
    #expect(request.pmid == "42823348")
    #expect(request.doi == "10.1146/annurev-cellbio-111524-111428")
    #expect(request.inputText == "https://example.org/paper")
    #expect(request.inputURL == "https://example.org/paper.pdf?download=1&version=2")
  }
  @Test func malformedAndPrivateCapturesNeverEnterQueue() throws {
    for value in ["file:///etc/passwd", "javascript:alert(1)", "https://127.0.0.1/", "https://192.168.1.2/paper", "https://u:p@example.org/"] {
      let url = try link(url: value)
      #expect(throws: (any Error).self) { try BrowserCapture.request(from: url) }
    }
    let duplicate = try link(extra: [URLQueryItem(name: "url", value: "https://example.org/another")])
    #expect(throws: (any Error).self) { try BrowserCapture.request(from: duplicate) }
    let unsafePDF = try link(extra: [URLQueryItem(name: "pdfURL", value: "http://localhost/paper.pdf")])
    #expect(throws: (any Error).self) { try BrowserCapture.request(from: unsafePDF) }
    let wrongPMID = try link(extra: [URLQueryItem(name: "pmid", value: "42<script>")])
    #expect(throws: (any Error).self) { try BrowserCapture.request(from: wrongPMID) }
  }
  @Test func repeatedBrowserHandoffPreservesCompletedRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserCapture-" + UUID().uuidString)
    let library = try LibraryService(root: root, databaseURL: root.appendingPathComponent("index.sqlite"), providers: [])
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try link()
    let id = try await library.submitBrowserCapture(url)
    var request = try #require(try await library.requests().first)
    request.state = .complete; request.resultID = UUID(); request.note = "Existing capture state"
    try await library.submit(request)
    #expect(try await library.submitBrowserCapture(url) == id)
    let repeated = try await library.requests()
    #expect(repeated.count == 1)
    #expect(repeated.first?.state == .complete)
    #expect(repeated.first?.resultID == request.resultID)
    #expect(repeated.first?.note == "Existing capture state")
  }
  @Test func coldStartReconciliationPreservesCachedRecordsAndDetectsActualChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserStartup-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("index.sqlite")
    let library = try LibraryService(root: root, databaseURL: database, providers: [])
    let item = LibraryItem(title: "Existing article with cached metadata")
    try await library.edit(item)
    let restarted = try LibraryService(root: root, databaseURL: database, providers: [])
    try await restarted.synchronizeSidecars()
    #expect(await restarted.generation() == 0)
    var changed = item
    changed.title = "An actual metadata change with the same article timestamp"
    try SidecarService(root: root).save(changed)
    try await restarted.synchronizeSidecars()
    #expect(await restarted.generation() == 1)
    #expect(try await restarted.item(item.id)?.title == changed.title)
  }
}

private actor NoChromeNetwork: HTTPTransport {
  var calls = 0
  func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    calls += 1
    throw LibraryError.invalid("The fast browser path must not call metadata or PDF servers")
  }
}
