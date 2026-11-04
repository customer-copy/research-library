import AppIntents
import AppKit
import PDFKit
import Testing

@testable import ResearchCore

struct OfflineTransport: HTTPTransport {
  func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    throw LibraryError.invalid("HTTP 403")
  }
}
struct FixedProvider: MetadataProvider {
  let name = "Fixture"
  func resolve(_ item: ResearchCore.LibraryItem) async throws -> ResearchCore.LibraryItem? {
    guard item.doi != nil else { return nil }
    var item = item
    item.title = "Microglial lipid metabolism"
    item.year = 2025
    item.setAuthors([Author(givenName: "Jane", familyName: "Smith")])
    item.confidence = 0.99
    return item
  }
}
@Suite(.serialized) final class CoreTests {
  var temp: URL!
  init() throws {
    temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: temp) }
  func makeLibrary() throws -> LibraryService {
    try LibraryService(
      root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("index.sqlite"), providers: [FixedProvider()],
      transport: OfflineTransport())
  }
  func pdf(_ text: String, name: String = "fixture.pdf", scan: Bool = false) throws -> URL {
    let url = temp.appendingPathComponent(name)
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)
    else { throw LibraryError.invalid("Fixture context") }
    context.beginPDFPage(nil)
    let attributed = NSAttributedString(
      string: text,
      attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    if scan {
      let image = NSImage(size: NSSize(width: 612, height: 792))
      image.lockFocus()
      NSColor.white.setFill()
      bounds.fill()
      attributed.draw(in: CGRect(x: 40, y: 600, width: 530, height: 140))
      image.unlockFocus()
      image.draw(in: bounds)
    } else {
      attributed.draw(in: CGRect(x: 40, y: 600, width: 530, height: 140))
    }
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: url)
    return url
  }
  @Test func testPDFHighlightSaveRecoveryAndConflict() throws {
    let url = try pdf("Highlight persistence fixture")
    let original = try PDFEditing.read(url)
    let document = PDFDocument(data: original.data)!
    let page = document.page(at: 0)!
    let annotation = PDFAnnotation(
      bounds: CGRect(x: 40, y: 650, width: 150, height: 20),
      forType: .highlight, withProperties: nil)
    annotation.contents = "Persistent highlight"
    annotation.color = .systemYellow
    page.addAnnotation(annotation)
    let recovery = temp.appendingPathComponent("Recovery")
    let hash = try PDFEditing.save(
      document.dataRepresentation()!, to: url,
      expectedHash: original.sha256, recovery: recovery)
    expectNotEqual(hash, original.sha256)
    expectEqual(
      PDFDocument(url: url)!.page(at: 0)!.annotations.first?.contents, "Persistent highlight")
    expectEqual(
      try Data(contentsOf: recovery.appendingPathComponent(original.sha256 + ".pdf")), original.data
    )
    expectThrows(
      try PDFEditing.save(original.data, to: url, expectedHash: original.sha256, recovery: recovery)
    )
    expectEqual(try Files.hash(url), hash)
    expectThrows(
      try PDFEditing.save(Data("invalid".utf8), to: url, expectedHash: hash, recovery: recovery))
    expectEqual(try Files.hash(url), hash)
  }
  @Test func testPermanentDeletionPurgesManagedCopiesAndSurvivesRestart() async throws {
    let library = try makeLibrary()
    let source = try pdf("Permanent deletion scientific fixture", name: "outside.pdf")
    _ = try await library.captureFile(source)
    await library.processPending()
    var item = try await library.search("")[0].item
    let root = temp.appendingPathComponent("Archive")
    let sidecars = try SidecarService(root: root)
    let staleMetadata = try Data(contentsOf: sidecars.url(item.id))
    let originalPath = item.resources.first!.relativePath!
    item.title = "Renamed deletion fixture"
    item.notes = "Private note"
    try await library.edit(item)
    try await library.organizeFiles(item.id)
    item = try await library.item(item.id)!
    let resource = item.resources.first!
    let snapshot = try await library.readPDFForReader(itemID: item.id, resourceID: resource.id)
    let document = PDFDocument(data: snapshot.data)!
    document.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: CGRect(x: 40, y: 650, width: 80, height: 20), forType: .highlight, withProperties: nil))
    _ = try await library.savePDFAnnotations(itemID: item.id, resourceID: resource.id, data: document.dataRepresentation()!, expectedHash: snapshot.sha256)
    let pending = try await library.captureFile(source, attachTo: item.id)
    let pendingRequest = try await library.requests().first { $0.id == pending }!
    try await library.permanentlyRemove(item.id)
    expectEqual(try await library.search("").count, 0)
    for path in [originalPath, resource.relativePath!, "Metadata/\(item.id).json", "Recovery/Metadata/\(item.id)", "Recovery/PDFs/\(resource.id)", pendingRequest.inputFile!, "Inbox/Requests/\(pending).json"] {
      #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), Comment(rawValue: "Remaining deletion path: " + path))
    }
    expectTrue(FileManager.default.fileExists(atPath: source.path))
    let marker = try String(contentsOf: root.appendingPathComponent("Deletions/\(item.id).json"), encoding: .utf8)
    expectFalse(marker.contains("Private note"))
    expectFalse(marker.contains("Renamed"))
    try staleMetadata.write(to: sidecars.url(item.id))
    let restarted = try makeLibrary()
    try await restarted.synchronizeSidecars()
    expectFalse(FileManager.default.fileExists(atPath: sidecars.url(item.id).path))
    _ = try await restarted.rebuild()
    await restarted.processPending()
    expectEqual(try await restarted.search("").count, 0)
  }
  @Test func testPermanentDeletionPreservesSharedAttachments() async throws {
    let library = try makeLibrary()
    let source = try pdf("Shared attachment fixture")
    _ = try await library.captureFile(source)
    await library.processPending()
    let first = try await library.search("")[0].item
    var second = LibraryItem(title: "Other article")
    second.resources = first.resources.map { resource in
      var copy = resource
      copy.id = UUID()
      copy.itemID = second.id
      return copy
    }
    let sidecars = try SidecarService(root: temp.appendingPathComponent("Archive"))
    try sidecars.save(second)
    try await library.synchronizeSidecars()
    try await library.permanentlyRemove(first.id)
    let attachment = try Files.safeURL(root: sidecars.root, relative: second.resources.first!.relativePath!)
    expectTrue(FileManager.default.fileExists(atPath: attachment.path))
    expectEqual(try await library.search("").count, 1)
    expectEqual(try await library.item(second.id)?.title, "Other article")
  }
  @Test func testPermanentDeletionRejectsEscapingPathsBeforeRemovingAnything() async throws {
    let library = try makeLibrary()
    var item = LibraryItem(title: "Unsafe path")
    item.resources = [Resource(itemID: item.id, type: .pdf, path: "PDFs/../../outside.pdf", availability: .local)]
    let sidecars = try SidecarService(root: temp.appendingPathComponent("Archive"))
    try sidecars.save(item)
    try await library.synchronizeSidecars()
    do {
      try await library.permanentlyRemove(item.id)
      Issue.record("Unsafe deletion should fail")
    } catch {}
    expectTrue(FileManager.default.fileExists(atPath: sidecars.url(item.id).path))
    expectEqual(try await library.search("").count, 1)
  }
  @Test func testPermanentDeletionResumesInterruptedManifest() async throws {
    let library = try makeLibrary()
    let source = try pdf("Interrupted deletion fixture")
    _ = try await library.captureFile(source)
    await library.processPending()
    let item = try await library.search("")[0].item
    let root = temp.appendingPathComponent("Archive")
    let paths = [item.resources.first!.relativePath!, "Metadata/\(item.id).json"]
    try FileManager.default.removeItem(at: root.appendingPathComponent(paths[0]))
    let folder = root.appendingPathComponent("Deletions")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let marker = folder.appendingPathComponent("\(item.id).json")
    try JSONSerialization.data(withJSONObject: ["id": item.id.uuidString, "paths": paths, "requestIDs": []]).write(to: marker)
    let restarted = try makeLibrary()
    try await restarted.synchronizeSidecars()
    expectEqual(try await restarted.search("").count, 0)
    expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(paths[1]).path))
    let finished = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
    expectEqual((finished["paths"] as! [String]).count, 0)
    try await restarted.synchronizeSidecars()
    expectEqual(try await restarted.search("").count, 0)
  }
  @Test func testShortcutCapturesURLAndPDFIntoInbox() async throws {
    let library = try makeLibrary()
    let root = temp.appendingPathComponent("Archive")
    var link = AddToResearchLibraryIntent()
    link.rootOverride = root
    link.url = URL(string: "https://doi.org/10.1000/shortcut-link")!
    _ = try await link.perform()
    var file = AddToResearchLibraryIntent()
    file.rootOverride = root
    let source = try pdf("PDF shortcut fixture")
    file.file = IntentFile(data: try Data(contentsOf: source), filename: "paper.pdf")
    _ = try await file.perform()
    let requests = try await library.requests()
    expectEqual(requests.count, 2)
    expectTrue(requests.contains { $0.inputURL == link.url?.absoluteString })
    let captured = requests.first { $0.inputFile != nil }!
    expectEqual(try Data(contentsOf: root.appendingPathComponent(captured.inputFile!)), try Data(contentsOf: source))
    await library.processPending()
    expectEqual(try await library.search("").count, 2)
    expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(captured.inputFile!).path))
  }
  @Test func testAnnotatedPDFDuplicateIdentityAndExternalReload() async throws {
    let library = try makeLibrary()
    let fixture = try pdf("DOI: 10.1000/reader\nAnnotation fixture")
    let id = try await library.captureFile(fixture)
    await library.processPending()
    let item = try await library.item(id)!
    let resource = item.resources.first { $0.type == .pdf }!
    let snapshot = try await library.readPDFForReader(itemID: id, resourceID: resource.id)
    let document = PDFDocument(data: snapshot.data)!
    document.page(at: 0)!.addAnnotation(
      PDFAnnotation(
        bounds: CGRect(x: 50, y: 650, width: 100, height: 20), forType: .highlight,
        withProperties: nil))
    let hash = try await library.savePDFAnnotations(
      itemID: id, resourceID: resource.id,
      data: document.dataRepresentation()!, expectedHash: snapshot.sha256)
    let edited = try await library.item(id)!
    expectEqual(edited.resources.first { $0.id == resource.id }!.sha256, hash)
    expectEqual(edited.resources.first { $0.id == resource.id }!.originalSHA256, snapshot.sha256)
    let db = try LocalDatabase(url: temp.appendingPathComponent("index.sqlite"))
    expectEqual(try db.exactDuplicate(hash: snapshot.sha256), id)
    expectEqual(try db.exactDuplicate(hash: hash), id)
    let url = temp.appendingPathComponent("Archive/" + resource.relativePath!)
    try snapshot.data.write(to: url, options: .atomic)  // An external editor changed the file.
    do {
      _ = try await library.savePDFAnnotations(
        itemID: id, resourceID: resource.id,
        data: document.dataRepresentation()!, expectedHash: hash)
      Issue.record("Expected external-edit conflict")
    } catch {}
    let refreshed = try await library.readPDFForReader(itemID: id, resourceID: resource.id)
    expectEqual(refreshed.sha256, snapshot.sha256)
    expectEqual(
      try await library.item(id)!.resources.first { $0.id == resource.id }!.sha256, snapshot.sha256)
    _ = try await library.savePDFAnnotations(
      itemID: id, resourceID: resource.id,
      data: document.dataRepresentation()!, expectedHash: refreshed.sha256)
    // Re-importing the original must match the annotated item and safely clean its Inbox copy.
    let duplicate = try await library.captureFile(fixture)
    await library.processPending()
    let request = try await library.requests().first { $0.id == duplicate }!
    expectEqual(request.resultID, id)
    expectEqual(try await library.search("").count, 1)
    expectEqual(try await library.item(id)!.resources.filter { $0.type == .pdf }.count, 1)
    expectEqual(
      try await library.requests().first { $0.id == duplicate }!.inboxCleanupComplete, true)
  }
  @Test func testReaderMemoryPortableRoundTrip() throws {
    var position = ReaderPosition()
    position.page = 17
    position.scale = 1.75
    position.zoomMode = "manual"
    position.sidebar = "annotations"
    position.sidebarVisible = false
    expectEqual(
      try PortableJSON.decoder().decode(
        ReaderPosition.self,
        from: PortableJSON.encoder().encode(position)), position)
  }
  @Test func testICloudDownloadAvailability() {
    expectTrue(Files.isDownloadAvailable(.current))
    expectTrue(Files.isDownloadAvailable(.downloaded))
    expectFalse(Files.isDownloadAvailable(.notDownloaded))
    expectFalse(Files.isDownloadAvailable(nil))
    expectTrue(ResourceDownloadPending().localizedDescription.contains("iCloud"))
  }
  @Test func testMigrationsAndForeignKeys() throws {
    let url = temp.appendingPathComponent("db.sqlite")
    let db = try LocalDatabase(url: url)
    expectEqual(db.schemaVersion, 1)
    expectEqual(try db.rows("PRAGMA foreign_keys").first?["foreign_keys"], "1")
    expectEqual(try LocalDatabase(url: url).schemaVersion, 1)
    expectThrows(try db.rows("INSERT INTO resources VALUES('r','unknown','h','p','pdf')"))
  }
  @Test func testTransactionsRollback() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("db"))
    expectThrows(
      try db.transaction {
        try db.execute("INSERT INTO tags VALUES('x')")
        throw LibraryError.invalid("rollback")
      })
    expectTrue(try db.organization("tags").isEmpty)
  }
  @Test func testSidecarRoundTripAndUnknownFields() throws {
    let service = try SidecarService(root: temp)
    var item = ResearchCore.LibraryItem(title: "Portable")
    item.notes = "Decades of notes"
    item.setAuthors([Author(givenName: "Ada", familyName: "Lovelace")])
    item.tags = ["genetics"]
    try service.save(item)
    let url = service.url(item.id)
    var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var obj = root["item"] as! [String: Any]
    obj["futureProperty"] = ["keep": true]
    root["item"] = obj
    root["futureEnvelope"] = "keep"
    try JSONSerialization.data(withJSONObject: root).write(to: url)
    item.title = "Updated"
    try service.save(item)
    let result = try service.read(url)
    expectEqual(
      result,
      try PortableJSON.decoder().decode(
        ResearchCore.LibraryItem.self, from: PortableJSON.encoder().encode(item)))
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    expectEqual(saved["futureEnvelope"] as? String, "keep")
    expectNotNil((saved["item"] as? [String: Any])?["futureProperty"])
    expectNil((saved["item"] as? [String: Any])?["chunks"])
  }
  @Test func testAtomicWriteLeavesValidOriginalOnFailure() throws {
    let service = try SidecarService(root: temp)
    let item = ResearchCore.LibraryItem(title: "Original")
    try service.save(item)
    expectThrows(
      try Files.atomicWrite(Data("broken".utf8), to: temp.appendingPathComponent("absent/target")))
    expectEqual(try service.read(service.url(item.id)).title, "Original")
    for n in 0..<25 {
      var value = item
      value.notes = "revision \(n)"
      try service.save(value)
      expectEqual(try service.read(service.url(item.id)).notes, value.notes)
    }
  }
  @Test func testIdentifierExtraction() {
    expectEqual(Identifiers.doi("DOI: 10.1038/ABC.123."), "10.1038/abc.123")
    expectEqual(Identifiers.pmid("https://pubmed.ncbi.nlm.nih.gov/12345678/"), "12345678")
    expectEqual(Identifiers.pmid("PMID: 98765"), "98765")
    expectEqual(Identifiers.arxiv("arXiv: 2401.12345v2"), "2401.12345v2")
    expectNil(Identifiers.doi("No DOI"))
  }
  @Test func testURLCanonicalizationAndSecurity() throws {
    expectEqual(
      try Identifiers.canonicalURL("HTTPS://Example.COM/p?utm_source=x&a=1#frag").absoluteString,
      "https://example.com/p?a=1")
    for url in [
      "file:///etc/passwd", "http://localhost/a", "http://192.168.1.5",
      "https://user:secret@example.com", "http://172.16.1.1",
    ] { expectThrows(try Identifiers.canonicalURL(url)) }
  }
  @Test func testFilenameSafetyCollisionAndTraversal() throws {
    expectEqual(Files.sanitized("../bad:/name\n"), "bad name")
    let target = temp.appendingPathComponent("article.pdf")
    try Data().write(to: target)
    expectNotEqual(Files.uniqueURL(target), target)
    expectThrows(try Files.safeURL(root: temp, relative: "../secret"))
    expectThrows(try Files.safeURL(root: temp, relative: "/secret"))
    try FileManager.default.createSymbolicLink(
      at: temp.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    expectThrows(try Files.safeURL(root: temp, relative: "outside/passwd"))
  }
  @Test func testSHA256DuplicateDetection() throws {
    let file = temp.appendingPathComponent("file")
    try Data("abc".utf8).write(to: file)
    let hash = try Files.hash(file)
    expectEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let db = try LocalDatabase(url: temp.appendingPathComponent("db"))
    var item = ResearchCore.LibraryItem()
    var resource = Resource(itemID: item.id, type: .pdf, path: "PDFs/a.pdf", availability: .local)
    resource.sha256 = hash
    item.resources = [resource]
    try db.upsert(item)
    expectEqual(try db.exactDuplicate(hash: hash), item.id)
  }
  @Test func testCrossrefNormalization() throws {
    var item = ResearchCore.LibraryItem()
    item.doi = "10.1000/example"
    let json = Data(
      #"{"message":{"DOI":"10.1000/example","title":["Example science"],"container-title":["Journal"],"published":{"date-parts":[[2025,1,2]]},"author":[{"given":"Jane","family":"Smith"}],"abstract":"<jats:p>Cells</jats:p>"}}"#
        .utf8)
    let result = try CrossrefProvider.normalize(json, item: item)
    expectEqual(result.title, "Example science")
    expectEqual(result.year, 2025)
    expectEqual(result.authorText, "Jane Smith")
    expectEqual(result.abstract, "Cells")
    expectGreater(result.confidence, 0.9)
    expectEqual(result.publicationDate, "2025-01-02")
    expectTrue(result.sourceMetadata?.first?.payload.contains("date-parts") == true)
  }
  @Test func testMetadataCombinesProvidersWithoutErasingFields() async throws {
    struct First: MetadataProvider {
      let name = "First"
      func resolve(_ item: ResearchCore.LibraryItem) async throws -> ResearchCore.LibraryItem? {
        var result = item
        result.title = "Detailed scientific study of neural metabolism"
        result.journal = "First journal"
        result.abstract = "Short abstract."
        result.setAuthors([Author(givenName: "J", familyName: "Smith")])
        result.publisher = "Publisher"
        result.confidence = 0.99
        result.sourceMetadata = [
          MetadataSnapshot(source: name, format: "json", payload: "{\"funding\":true}")
        ]
        return result
      }
    }
    struct Second: MetadataProvider {
      let name = "Second"
      func resolve(_ item: ResearchCore.LibraryItem) async throws -> ResearchCore.LibraryItem? {
        var result = item
        result.title = ""
        result.journal = ""
        result.abstract =
          "A much more complete abstract describing neural metabolism and its mechanisms."
        result.volume = "12"
        result.pages = "10-20"
        result.keywords = ["Neurobiology"]
        var author = Author(givenName: "Jane", familyName: "Smith")
        author.orcid = "0000-0001-2345-6789"
        result.setAuthors([author])
        result.sourceMetadata = [
          MetadataSnapshot(source: name, format: "json", payload: "{\"references\":[]}")
        ]
        return result
      }
    }
    let initial = ResearchCore.LibraryItem()
    let result = await MetadataResolutionService(providers: [First(), Second()]).resolve(initial)
    expectEqual(result.id, initial.id)
    expectEqual(result.title, "Detailed scientific study of neural metabolism")
    expectEqual(result.journal, "First journal")
    expectTrue(result.abstract.contains("complete abstract"))
    expectEqual(result.authorText, "Jane Smith")
    expectNotNil(result.authors.first?.orcid)
    expectEqual(result.volume, "12")
    expectEqual(result.sourceMetadata?.count, 2)
    var edited = result
    edited.humanEdited = true
    edited.title = "My title"
    edited.abstract = "My abstract"
    edited.setAuthors([Author(givenName: "Me", familyName: "Editor")])
    edited.notes = "Personal note"
    edited.tags = ["Personal tag"]
    let refreshed = await MetadataResolutionService(providers: [First(), Second()]).resolve(edited)
    expectEqual(refreshed.title, "My title")
    expectEqual(refreshed.abstract, "My abstract")
    expectEqual(refreshed.authorText, "Me Editor")
    expectEqual(refreshed.notes, "Personal note")
    expectEqual(refreshed.tags, ["Personal tag"])
    expectEqual(refreshed.sourceMetadata?.count, 2)
  }
  @Test func testNewIdentifierTriggersEarlierMetadataProvider() async throws {
    struct DOIProvider: MetadataProvider {
      let name = "DOI"
      func resolve(_ item: ResearchCore.LibraryItem) async throws -> ResearchCore.LibraryItem? {
        guard item.doi != nil else { return nil }
        var result = item
        result.publisher = "Discovered publisher"
        return result
      }
    }
    struct Discover: MetadataProvider {
      let name = "Discover"
      func resolve(_ item: ResearchCore.LibraryItem) async throws -> ResearchCore.LibraryItem? {
        var result = item
        result.doi = "10.1000/discovered"
        return result
      }
    }
    let result = await MetadataResolutionService(providers: [DOIProvider(), Discover()]).resolve(
      ResearchCore.LibraryItem())
    expectEqual(result.publisher, "Discovered publisher")
  }
  @Test func testMetadataAuthorOrderAndConflictingIdentifiers() {
    var existing = ResearchCore.LibraryItem()
    existing.doi = "10.1000/order"
    existing.setAuthors([
      Author(givenName: "J", familyName: "Smith"), Author(givenName: "R", familyName: "Smith"),
    ])
    var incoming = existing
    incoming.setAuthors([
      Author(givenName: "Jane", familyName: "Smith"),
      Author(givenName: "Robert", familyName: "Smith"),
    ])
    let merged = MetadataResolutionService.merge(existing, incoming)
    expectEqual(merged.authorText, "Jane Smith; Robert Smith")
    expectEqual(merged.authors.map(\.id), existing.authors.map(\.id))
    incoming.doi = "10.1000/unrelated"
    incoming.abstract = "Wrong article"
    expectEqual(MetadataResolutionService.merge(existing, incoming), existing)
  }
  @Test func testMetadataProviderFailureStillUsesOtherSources() async {
    struct Unavailable: MetadataProvider {
      let name = "Unavailable"
      func resolve(_ item: ResearchCore.LibraryItem) async throws -> ResearchCore.LibraryItem? {
        throw LibraryError.invalid("HTTP 503")
      }
    }
    var item = ResearchCore.LibraryItem()
    item.doi = "10.1000/test"
    let result = await MetadataResolutionService(providers: [Unavailable(), FixedProvider()])
      .resolve(item)
    expectEqual(result.title, "Microglial lipid metabolism")
    expectTrue(result.provenance.contains { $0.source == "Unavailable" })
  }
  @Test func testTitleLookupIsExactUniqueAndChecksYear() async throws {
    struct Titles: HTTPTransport {
      let duplicates: Bool
      func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let work: [String: Any] = [
          "DOI": "10.1000/title", "title": ["A scientific investigation of neuronal metabolism"],
          "published": ["date-parts": [[2025]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
          "message": ["items": duplicates ? [work, work] : [work]]
        ])
        return (
          data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    }
    var item = ResearchCore.LibraryItem(title: "A scientific investigation of neuronal metabolism")
    let exact = try await CrossrefProvider(transport: Titles(duplicates: false)).resolve(item)
    expectEqual(exact?.doi, "10.1000/title")
    expectEqual(exact?.confidence, 0.9)
    expectNil(try await CrossrefProvider(transport: Titles(duplicates: true)).resolve(item))
    item.year = 2020
    expectNil(try await CrossrefProvider(transport: Titles(duplicates: false)).resolve(item))
    item.title = "A different scientific investigation of neuronal metabolism"
    expectNil(try await CrossrefProvider(transport: Titles(duplicates: false)).resolve(item))
  }
  @Test func testDataCiteAndPublisherStructuredMetadata() throws {
    var item = ResearchCore.LibraryItem()
    item.doi = "10.1000/full"
    let json = Data(
      #"{"data":{"attributes":{"doi":"10.1000/full","titles":[{"title":"Complete scientific metadata from public sources"}],"publicationYear":2025,"publisher":{"name":"Research Press"},"creators":[{"givenName":"Ada","familyName":"Smith"}],"descriptions":[{"descriptionType":"Abstract","description":"Dataset abstract"}],"subjects":[{"subject":"Biology"}],"fundingReferences":[{"funderName":"Grant agency"}]}}}"#
        .utf8)
    let result = try DataCiteProvider.normalize(json, item: item)
    expectEqual(result.publisher, "Research Press")
    expectEqual(result.abstract, "Dataset abstract")
    expectTrue(result.sourceMetadata!.first!.payload.contains("Grant agency"))
    let html =
      #"<script type="application/ld+json">{"@type":"ScholarlyArticle","identifier":{"value":"10.1000/full"},"headline":"Complete scientific metadata from public sources","abstract":"Full &amp; useful abstract","publisher":{"name":"Public Press"},"datePublished":"2025-02-03","author":[{"name":"Ada Smith","sameAs":"https://orcid.org/0000-0001-2345-6789"}],"keywords":["Neurons"],"license":"https://creativecommons.org/licenses/by/4.0/","funding":{"name":"Science Grant"}}</script>"#
    let publisher = try PublisherMetadataProvider.normalize(
      html, item: item, pageURL: URL(string: "https://example.org/paper")!)!
    expectEqual(publisher.abstract, "Full & useful abstract")
    expectEqual(publisher.publicationDate, "2025-02-03")
    expectEqual(publisher.authorText, "Ada Smith")
    expectEqual(publisher.keywords, ["Neurons"])
    expectTrue(publisher.sourceMetadata!.first!.payload.contains("Science Grant"))
    var other = item
    other.doi = "10.1000/wrong"
    expectNil(
      try PublisherMetadataProvider.normalize(
        html, item: other, pageURL: URL(string: "https://example.org/paper")!))
    expectEqual(
      WebMetadata.values(
        "citation_author",
        html:
          #"<meta name="citation_author" content="O'Neil, Jane"><meta content='Ada Smith' name='citation_author'>"#
      ), ["O'Neil, Jane", "Ada Smith"])
  }
  @Test func testPDFUploadFetchesAllMatchingSourcesAndRefreshPreservesEdits() async throws {
    struct Sources: HTTPTransport {
      func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if url.host == "api.crossref.org" {
          body =
            #"{"message":{"DOI":"10.1000/enriched","title":["Complete scientific study of neural metabolism"],"container-title":["Science Journal"],"author":[{"given":"J","family":"Smith","ORCID":"https://orcid.org/0000-0001-2345-6789"}],"publisher":"Science Press","ISSN":["1234-5678"],"published":{"date-parts":[[2025,3,4]]},"funder":[{"name":"Public Fund"}],"reference":[{"DOI":"10.1000/reference"}]}}"#
        } else if url.host == "www.ebi.ac.uk" {
          body =
            #"{"resultList":{"result":[{"source":"MED","id":"123","doi":"10.1000/enriched","pmcid":"PMC123","title":"Complete scientific study of neural metabolism","abstractText":"A comprehensive public abstract on neuronal metabolism and brain function.","keywordList":{"keyword":["Neurochemistry"]},"grantsList":{"grant":[{"agency":"Science Agency"}]}}]}}"#
        } else if url.host == "eutils.ncbi.nlm.nih.gov" {
          body =
            "<PubmedArticle><MedlineCitation><PMID>123</PMID><Article><ArticleTitle>Complete scientific study of neural metabolism</ArticleTitle><Journal><Title>Science Journal</Title></Journal><AuthorList><Author><LastName>Smith</LastName><ForeName>Jane</ForeName></Author></AuthorList></Article></MedlineCitation><ArticleIdList><ArticleId IdType=\"doi\">10.1000/enriched</ArticleId></ArticleIdList></PubmedArticle>"
        } else if url.host == "doi.org" {
          body =
            #"<meta name="citation_doi" content="10.1000/enriched"><meta name="citation_title" content="Complete scientific study of neural metabolism"><meta name="citation_volume" content="9"><meta name="citation_firstpage" content="10"><meta name="citation_lastpage" content="20"><meta name="citation_keywords" content="Neurons;Lipids">"#
        } else {
          throw LibraryError.invalid("Unexpected fixture URL")
        }
        return (
          Data(body.utf8),
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    }
    let library = try LibraryService(
      root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("index.sqlite"), transport: Sources())
    let file = try pdf(
      "DOI: 10.1000/enriched\nComplete scientific study of neural metabolism\nOriginal scientific body."
    )
    let id = try await library.captureFile(file)
    await library.processPending()
    var item = try await library.item(id)!
    expectEqual(item.title, "Complete scientific study of neural metabolism")
    expectEqual(item.authorText, "Jane Smith")
    expectEqual(item.pmid, "123")
    expectEqual(item.pmcid, "PMC123")
    expectEqual(item.publicationDate, "2025-03-04")
    expectEqual(item.volume, "9")
    expectEqual(item.pages, "10-20")
    expectTrue(item.abstract.contains("comprehensive"))
    expectEqual(
      Set(item.sourceMetadata!.map(\.source)),
      Set(["Crossref", "Europe PMC", "PubMed", "Publisher"]))
    expectTrue(item.sourceMetadata!.contains { $0.payload.contains("Science Agency") })
    expectEqual(try await library.search("Neurochemistry").count, 1)
    let restored = try SidecarService(root: temp.appendingPathComponent("Archive")).read(
      temp.appendingPathComponent("Archive/Metadata/\(id).json"))
    expectEqual(restored.sourceMetadata?.count, 4)
    item.title = "My corrected title"
    item.notes = "My personal interpretation"
    try await library.edit(item)
    try await library.refreshMetadata(id)
    let refreshed = try await library.item(id)!
    expectEqual(refreshed.title, "My corrected title")
    expectEqual(refreshed.notes, "My personal interpretation")
    expectEqual(refreshed.sourceMetadata?.count, 4)
  }
  @Test func testPDFEmbeddedTitleSeedsLookupWithoutIdentifier() async throws {
    let source = try pdf("Body text that is different from the publication title.")
    let document = PDFDocument(url: source)!
    document.documentAttributes = [
      PDFDocumentAttribute.titleAttribute: "A scientific investigation of neuronal metabolism"
    ]
    expectTrue(document.write(to: source))
    let seed = try PDFExtractionService().metadataSeed(url: source)
    expectEqual(seed?.title, "A scientific investigation of neuronal metabolism")
  }
  @Test func testPubMedNormalization() throws {
    var item = ResearchCore.LibraryItem()
    item.pmid = "123"
    let xml = Data(
      "<PubmedArticle><MedlineCitation><PMID>123</PMID><Article><ArticleTitle>A <i>complex</i> title</ArticleTitle><Journal><Title>Science</Title><PubDate><Year>2024</Year></PubDate></Journal><AuthorList><Author><LastName>Doe</LastName><ForeName>J</ForeName></Author></AuthorList><Abstract><AbstractText>Abstract body.</AbstractText></Abstract></Article></MedlineCitation><ArticleIdList><ArticleId IdType=\"doi\">10.1000/test</ArticleId></ArticleIdList></PubmedArticle>"
        .utf8)
    let r = try PubMedProvider.normalize(xml, item: item)
    expectTrue(r.title.contains("complex"))
    expectEqual(r.journal, "Science")
    expectEqual(r.year, 2024)
    expectEqual(r.authorText, "J Doe")
    expectEqual(r.doi, "10.1000/test")
    var expected = item
    expected.doi = "10.1000/test"
    let references = String(decoding: xml, as: UTF8.self).replacingOccurrences(
      of: "</PubmedArticle>",
      with:
        "<ReferenceList><Reference><ArticleIdList><ArticleId IdType=\"doi\">10.1000/cited-paper</ArticleId></ArticleIdList></Reference></ReferenceList></PubmedArticle>"
    )
    expectEqual(
      try PubMedProvider.normalize(Data(references.utf8), item: expected).doi, "10.1000/test")
  }
  @Test func testArxivNormalization() throws {
    var item = ResearchCore.LibraryItem()
    item.arxivID = "2401.12345"
    let xml = Data(
      "<feed><title>arXiv query</title><entry><id>http://arxiv.org/abs/2401.12345</id><title>Actual article</title><summary>Summary</summary><published>2024-01-01</published><author><name>Ada Smith</name></author></entry></feed>"
        .utf8)
    let r = try ArxivProvider.normalize(xml, item: item)
    expectEqual(r.title, "Actual article")
    expectEqual(r.type, .preprint)
    expectEqual(r.year, 2024)
    expectEqual(r.authorText, "Ada Smith")
  }
  @Test func testPDFLessAndPaywallRecordSurvives() async throws {
    let library = try makeLibrary()
    var r = IngestionRequest(text: "https://example.org/paywall")
    r.suggestedTitle = "Paywalled research"
    try await library.submit(r)
    await library.processPending()
    let item = try await library.item(r.id)
    expectNotNil(item)
    expectFalse(item!.hasPDF)
    expectEqual(item!.resources.first?.availability, .requiresAuthentication)
    let requests = try await library.requests()
    expectEqual(requests.first?.state, .complete)
  }
  @Test func testDOIOnlyItemAndIdempotency() async throws {
    let library = try makeLibrary()
    let r = IngestionRequest(text: "10.1000/test")
    try await library.submit(r)
    await library.processPending()
    await library.processPending()
    let results = try await library.search("")
    expectEqual(results.count, 1)
    expectFalse(results[0].item.hasPDF)
    expectEqual(results[0].item.title, "Microglial lipid metabolism")
    var replay = r
    replay.state = .indexing
    try await library.submit(replay)
    await library.processPending()
    let after = try await library.search("")
    expectEqual(after.count, 1)
  }
  @Test func testPDFImportLateAttachmentExactDuplicateAndSearch() async throws {
    let library = try makeLibrary()
    let r = IngestionRequest(text: "10.1000/test")
    try await library.submit(r)
    await library.processPending()
    let file = try pdf(
      "DOI: 10.1000/test\nIntroduction\nMicroglial cells metabolize cholesterol and sphingolipids.")
    _ = try await library.captureFile(file)
    await library.processPending()
    let items = try await library.search("")
    expectEqual(items.count, 1)
    expectTrue(items[0].item.hasPDF)
    expectEqual(items[0].item.id, r.id)
    _ = try await library.captureFile(file)
    await library.processPending()
    let duplicate = try await library.search("")
    expectEqual(duplicate.count, 1)
    expectEqual(duplicate[0].item.resources.filter { $0.type == .pdf }.count, 1)
    let body = try await library.search("sphingolipids")
    expectEqual(body.first?.pageStart, 1)
    expectNotNil(body.first?.resourceID)
    expectNotNil(body.first?.chunkID)
    let requests = try await library.requests()
    for request in requests where request.inputFile != nil {
      expectEqual(request.inboxCleanupComplete, true)
      expectFalse(
        FileManager.default.fileExists(
          atPath:
            temp.appendingPathComponent("Archive/" + request.inputFile!).path))
    }
    expectTrue(FileManager.default.fileExists(atPath: file.path))
  }
  @Test func testRestartRecoveryFromPersistedQueue() async throws {
    let library = try makeLibrary()
    var r = IngestionRequest(text: "10.1000/restart")
    r.state = .importing
    try await library.submit(r)
    let reopened = try makeLibrary()
    await reopened.processPending()
    let results = try await reopened.search("")
    expectEqual(results.count, 1)
    expectEqual(results.first?.item.id, r.id)
  }
  @Test func testHotFolderStableFiles() async throws {
    let library = try makeLibrary()
    let fixture = try pdf(
      "A hot folder scientific paper with enough readable text for native extraction.")
    let inbox = temp.appendingPathComponent("Archive/Inbox/hot.pdf")
    try FileManager.default.copyItem(at: fixture, to: inbox)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: inbox.path)
    try await library.pollInbox()
    let first = try await library.requests()
    expectTrue(first.isEmpty)
    try await library.pollInbox()
    try await library.pollInbox()
    let second = try await library.requests()
    expectEqual(second.count, 1)
    await library.processPending()
    let items = try await library.search("")
    expectEqual(items.count, 1)
    expectFalse(FileManager.default.fileExists(atPath: inbox.path))
    let organized = temp.appendingPathComponent(
      "Archive/" + items[0].item.resources[0].relativePath!)
    expectEqual(try Data(contentsOf: organized), try Data(contentsOf: fixture))
  }
  @Test func testCompletedInboxCleanupVerifiesCopyAndResumesAfterRestart() async throws {
    let library = try makeLibrary()
    let fixture = try pdf("DOI: 10.1000/cleanup\nA scientific paper to organize safely.")
    let id = try await library.captureFile(fixture)
    await library.processPending()
    let item = try await library.item(id)!
    let organized = temp.appendingPathComponent(
      "Archive/" + item.resources.first { $0.type == .pdf }!.relativePath!)
    var request = try await library.requests().first { $0.id == id }!
    let inbox = temp.appendingPathComponent("Archive/" + request.inputFile!)
    request.inboxCleanupComplete = nil  // Legacy request, or interrupted cleanup.
    try await library.submit(request)
    try Data("changed input".utf8).write(to: inbox)
    await library.processPending()
    expectTrue(FileManager.default.fileExists(atPath: inbox.path))
    try Data(contentsOf: fixture).write(to: inbox)
    try FileManager.default.removeItem(at: organized)
    await library.processPending()
    expectTrue(FileManager.default.fileExists(atPath: inbox.path))
    try Data("corrupt organized copy".utf8).write(to: organized)
    await library.processPending()
    expectTrue(FileManager.default.fileExists(atPath: inbox.path))
    try Data(contentsOf: fixture).write(to: organized)
    let reopened = try makeLibrary()
    await reopened.processPending()
    expectFalse(FileManager.default.fileExists(atPath: inbox.path))
    expectEqual(try Data(contentsOf: organized), try Data(contentsOf: fixture))
    // Restart after deletion but before the cleanup marker was persisted.
    try await reopened.submit(request)
    await reopened.processPending()
    let completed = try await reopened.requests().first { $0.id == id }!
    expectEqual(completed.inboxCleanupComplete, true)
  }
  @Test func testFailedExtractionKeepsInboxUntilSuccessfulRetry() async throws {
    struct Failing: PDFTextExtractor {
      func identifiers(url: URL) throws -> String { "DOI: 10.1000/failed-cleanup" }
      func extract(url: URL, itemID: UUID, resourceID: UUID) throws -> [DocumentPage] {
        throw LibraryError.invalid("Fixture extraction failed")
      }
    }
    let library = try LibraryService(
      root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("index.sqlite"),
      providers: [FixedProvider()], transport: OfflineTransport(), extraction: Failing())
    let fixture = try pdf("DOI: 10.1000/failed-cleanup\nScientific text for extraction.")
    let id = try await library.captureFile(fixture)
    await library.processPending()
    let request = try await library.requests().first { $0.id == id }!
    expectEqual(request.state, .failed)
    let inbox = temp.appendingPathComponent("Archive/" + request.inputFile!)
    expectTrue(FileManager.default.fileExists(atPath: inbox.path))
    let reopened = try makeLibrary()
    await reopened.processPending()
    expectFalse(FileManager.default.fileExists(atPath: inbox.path))
    expectEqual(try await reopened.requests().first { $0.id == id }?.state, .complete)
  }
  @Test func testDownloadedPDFAlsoLeavesOnlyOrganizedCopy() async throws {
    struct PDFTransport: HTTPTransport {
      let bytes: Data
      func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        (
          bytes,
          HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/pdf"])!
        )
      }
    }
    let fixture = try pdf("Scientific article downloaded through a public PDF URL.")
    let library = try LibraryService(
      root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("index.sqlite"),
      providers: [], transport: PDFTransport(bytes: try Data(contentsOf: fixture)))
    let request = IngestionRequest(text: "https://example.org/article.pdf")
    try await library.submit(request)
    await library.processPending()
    let completed = try await library.requests().first { $0.id == request.id }!
    expectEqual(completed.state, .complete)
    expectEqual(completed.inboxCleanupComplete, true)
    expectFalse(
      FileManager.default.fileExists(
        atPath:
          temp.appendingPathComponent("Archive/" + completed.inputFile!).path))
    let item = try await library.item(request.id)!
    expectEqual(
      try Data(
        contentsOf:
          temp.appendingPathComponent(
            "Archive/" + item.resources.first { $0.type == .pdf }!.relativePath!)),
      try Data(contentsOf: fixture))
  }
  @Test func testReviewAndCancelledCapturesKeepInboxOriginal() async throws {
    let library = try makeLibrary()
    var existing = IngestionRequest(text: "A scientific title requiring duplicate review")
    existing.suggestedTitle = "A scientific title requiring duplicate review"
    try await library.submit(existing)
    await library.processPending()
    let fixture = try pdf("A new PDF whose title needs duplicate review.")
    let id = try await library.captureFile(fixture)
    var request = try await library.requests().first { $0.id == id }!
    request.suggestedTitle = existing.suggestedTitle
    request.titleIsFilename = false
    try await library.submit(request)
    await library.processPending()
    let inbox = temp.appendingPathComponent("Archive/" + request.inputFile!)
    expectEqual(try await library.requests().first { $0.id == id }?.state, .awaitingReview)
    expectTrue(FileManager.default.fileExists(atPath: inbox.path))
    try await library.resolveReview(id, choice: .cancel)
    await library.processPending()
    expectTrue(FileManager.default.fileExists(atPath: inbox.path))
  }
  @Test func testChunksDeterminismOverlapAndPageProvenance() {
    let itemID = UUID()
    let resourceID = UUID()
    let pages = (1...3).map { n in
      DocumentPage(
        id: UUID(), itemID: itemID, resourceID: resourceID, pageNumber: n,
        text: (0..<700).map { "word\(n)_\($0)" }.joined(separator: " "), method: "PDFKit")
    }
    let chunks = TextDerivation.chunks(pages)
    expectEqual(chunks.map(\.id), TextDerivation.chunks(pages).map(\.id))
    expectEqual(chunks.first?.startPage, 1)
    expectEqual(chunks.last?.endPage, 3)
    expectTrue(chunks[1].text.hasPrefix("word1_570"))
    expectTrue(chunks.allSatisfy { $0.approximateTokens <= 900 })
  }
  @Test func testSectionDetection() {
    let p = DocumentPage(
      id: UUID(), itemID: UUID(), resourceID: UUID(), pageNumber: 1,
      text: "Abstract\nStudy of cells\n1. Introduction\nBackground\nMethods\nAn experiment",
      method: "PDFKit")
    expectEqual(TextDerivation.sections([p]).map(\.type), ["abstract", "introduction", "methods"])
  }
  @Test func testFTSRankingPhrasesAndFilters() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("db"))
    var a = ResearchCore.LibraryItem(title: "Lipid metabolism")
    a.year = 2025
    a.tags = ["brain"]
    a.collections = ["Neuroscience"]
    a.favorite = true
    a.setAuthors([Author(givenName: "Jane", familyName: "Smith")])
    try db.upsert(a)
    let b = ResearchCore.LibraryItem(title: "Unrelated study")
    try db.upsert(b)
    let r = UUID()
    let page = DocumentPage(
      id: UUID(), itemID: b.id, resourceID: r, pageNumber: 3,
      text: "Lipid metabolism occurs in cells.", method: "PDFKit")
    try db.index(pages: [page], sections: [], chunks: [], itemID: b.id, resourceID: r)
    let results = try db.search("\"lipid metabolism\"")
    expectEqual(results.count, 2)
    expectEqual(results.first?.item.id, a.id)
    expectEqual(results.last?.pageStart, 3)
    var f = SearchFilters()
    f.tag = "brain"
    f.collection = "Neuroscience"
    f.author = "Smith"
    f.yearMin = 2020
    f.yearMax = 2026
    f.favorite = true
    f.hasPDF = false
    expectEqual(try db.search("lipid", filters: f).count, 1)
    expectTrue(try db.search("nonexistent").isEmpty)
    expectNoThrow(try db.search("OR : ^ * \""))
  }
  @Test func testRebuildFromSidecarsAndOrphanDetection() async throws {
    let library = try makeLibrary()
    let r = IngestionRequest(text: "10.1000/rebuild")
    try await library.submit(r)
    await library.processPending()
    try Data("orphan".utf8).write(to: temp.appendingPathComponent("Archive/PDFs/orphan.pdf"))
    let issues = try await library.integrity()
    expectTrue(issues.contains { $0.message.contains("Orphan") })
    try Data("bad".utf8).write(to: temp.appendingPathComponent("Archive/Metadata/bad.json"))
    let rebuilt = try await library.rebuild()
    expectTrue(rebuilt.contains { $0.path == "bad.json" })
    let results = try await library.search("Microglial")
    expectEqual(results.count, 1)
    expectTrue(
      FileManager.default.fileExists(
        atPath: temp.appendingPathComponent("Archive/PDFs/orphan.pdf").path))
  }
  @Test func testManualMetadataPreservedDuringAttachment() async throws {
    let library = try makeLibrary()
    let r = IngestionRequest(text: "10.1000/manual")
    try await library.submit(r)
    await library.processPending()
    var item = try await library.item(r.id)!
    item.title = "My authoritative title"
    item.notes = "Important note"
    try await library.edit(item)
    let file = try pdf("DOI: 10.1000/manual\nThe body of this research describes cell membranes.")
    _ = try await library.captureFile(file)
    await library.processPending()
    let final = try await library.item(r.id)!
    expectEqual(final.title, "My authoritative title")
    expectEqual(final.notes, "Important note")
    expectTrue(final.hasPDF)
  }
  @Test func testAmbiguousDuplicateRequiresDecision() async throws {
    let library = try makeLibrary()
    var a = IngestionRequest(text: "A long scientific title without identifiers")
    a.suggestedTitle = "A long scientific title without identifiers"
    try await library.submit(a)
    await library.processPending()
    var b = a
    b.id = UUID()
    b.state = .discovered
    b.resultID = nil
    try await library.submit(b)
    await library.processPending()
    let queue = try await library.requests()
    expectEqual(queue.first { $0.id == b.id }?.state, .awaitingReview)
    try await library.resolveReview(b.id, choice: .keepBoth)
    await library.processPending()
    let values = try await library.search("")
    expectEqual(values.count, 2)
  }
  @Test func testPaperpileJSONAndBibtexParsingAndExport() throws {
    let json = Data(
      #"[{"title":"Portable science","year":2025,"doi":"10.1000/test","authors":[{"first":"Ada","last":"Smith"}],"labels":[{"name":"brain"}],"folders":[{"name":"Review"}],"notes":"User note","attachments":[{"url":"https://example.org/p.pdf"}]}]"#
        .utf8)
    let items = try ImportService.parse(json, format: "json")
    expectEqual(items[0].tags, ["brain"])
    expectEqual(items[0].collections, ["Review"])
    expectEqual(items[0].authorText, "Ada Smith")
    expectEqual(items[0].resources.count, 2)
    let bib = try ExportService.encode(items, format: .bib)
    let imported = try ImportService.parse(bib, format: "bib")
    expectEqual(imported[0].title, items[0].title)
    expectEqual(imported[0].notes, "User note")
    expectEqual(imported[0].doi, "10.1000/test")
    expectEqual(imported[0].collections, ["Review"])
    expectTrue(
      String(decoding: try ExportService.encode(items, format: .ris), as: UTF8.self).contains(
        "ER  -"))
    let nested = try ImportService.bibtex(
      "@article{x, title={Study of {DNA} and cells}, author={Smith, Ada and Doe, Jane}, year={2020}}"
    )
    expectEqual(nested[0].title, "Study of {DNA} and cells")
    expectEqual(nested[0].authors.count, 2)
  }
  @Test func testOCRFallbackOnRasterFixture() throws {
    let url = try pdf("SCIENTIFIC RESEARCH\nMicroglial lipid metabolism", scan: true)
    let pages = try PDFExtractionService().extract(url: url, itemID: UUID(), resourceID: UUID())
    expectEqual(pages.first?.method, "VisionOCR")
    expectTrue(pages.first?.text.lowercased().contains("research") == true)
  }
  @Test func testClearOptionalFieldsAndRecoverySnapshot() throws {
    let service = try SidecarService(root: temp)
    var item = ResearchCore.LibraryItem(title: "Optional values")
    item.doi = "10.1000/old"
    item.year = 2025
    try service.save(item)
    item.doi = nil
    item.year = nil
    try service.save(item)
    let read = try service.read(service.url(item.id))
    expectNil(read.doi)
    expectNil(read.year)
    let backups = try FileManager.default.contentsOfDirectory(
      at: temp.appendingPathComponent("Recovery/Metadata/" + item.id.uuidString),
      includingPropertiesForKeys: nil)
    expectEqual(backups.count, 1)
  }
  @Test func testMissingAttachmentAndInvalidMetadataIntegrity() async throws {
    let library = try makeLibrary()
    var item = ResearchCore.LibraryItem(title: "Missing paper")
    item.resources = [
      Resource(itemID: item.id, type: .pdf, path: "PDFs/missing.pdf", availability: .local)
    ]
    try await library.edit(item)
    try Data("{\"schemaVersion\":1,\"item\":{\"title\":\"Missing UUID\"}}".utf8).write(
      to: temp.appendingPathComponent("Archive/Metadata/broken.json"))
    let issues = try await library.integrity()
    expectTrue(issues.contains { $0.message.contains("Missing attachment") })
    expectTrue(issues.contains { $0.path == "broken.json" })
  }
  @Test func testPDFRebuildRestoresBodySearchAndExports() async throws {
    let library = try makeLibrary()
    let file = try pdf("Scientific paper on oligodendrocytes and axonal myelination.")
    let document = PDFDocument(url: file)!
    document.documentAttributes = [
      PDFDocumentAttribute.titleAttribute: "A study of myelin cell biology"
    ]
    expectTrue(document.write(to: file))
    _ = try await library.captureFile(file)
    await library.processPending()
    let before = try await library.search("oligodendrocytes")
    expectEqual(before.count, 1)
    _ = try await library.rebuild()
    let after = try await library.search("oligodendrocytes")
    expectEqual(after.count, 1)
    expectEqual(after.first?.pageStart, 1)
    for format in ExportFormat.allCases {
      let url = try await library.export(format: format)
      expectTrue(FileManager.default.fileExists(atPath: url.path))
      expectTrue(try Data(contentsOf: url).count > 0)
    }
  }
  @Test func testHTTPProvidersUseMockTransport() async throws {
    struct Mock: HTTPTransport {
      func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let data = Data(#"{"message":{"DOI":"10.1000/mock","title":["Mock metadata"]}}"#.utf8)
        return (
          data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    }
    var item = ResearchCore.LibraryItem()
    item.doi = "10.1000/mock"
    let result = try await CrossrefProvider(transport: Mock()).resolve(item)
    expectEqual(result?.title, "Mock metadata")
  }

  @Test func testAppIntentQueuesSamePortableRequest() async throws {
    let library = try makeLibrary()
    var intent = AddToResearchLibraryIntent()
    intent.rootOverride = temp.appendingPathComponent("Archive")
    intent.doi = "10.1000/shortcut"
    intent.collection = "Science"
    intent.tags = "brain, lipids"
    intent.note = "Captured with a Shortcut"
    _ = try await intent.perform()
    let requests = try await library.requests()
    expectEqual(requests.count, 1)
    expectEqual(requests[0].source, "appIntent")
    expectEqual(requests[0].suggestedTags, ["brain", "lipids"])
    await library.processPending()
    let items = try await library.search("")
    expectEqual(items.count, 1)
    expectEqual(items[0].item.collections, ["Science"])
    expectEqual(items[0].item.notes, "Captured with a Shortcut")
  }
  @Test func testAttachmentFilenameOrganizationPreservesOriginal() async throws {
    let library = try makeLibrary()
    let source = try pdf("Scientific methods for lipid metabolism and neural cells.")
    _ = try await library.captureFile(source)
    await library.processPending()
    var item = try await library.search("")[0].item
    let old = item.resources.first!.relativePath!
    item.title = "A better scientific title"
    try await library.edit(item)
    try await library.organizeFiles(item.id)
    let updated = try await library.item(item.id)!
    expectNotEqual(updated.resources.first!.relativePath, old)
    expectTrue(
      FileManager.default.fileExists(atPath: temp.appendingPathComponent("Archive/" + old).path))
    expectTrue(updated.resources.first!.relativePath!.contains("A better scientific title"))
  }

  @Test func testGeneralFileCaptureThroughIntent() async throws {
    let library = try makeLibrary()
    var intent = AddToResearchLibraryIntent()
    intent.rootOverride = temp.appendingPathComponent("Archive")
    intent.file = IntentFile(data: Data("Supplementary table".utf8), filename: "table.txt")
    _ = try await intent.perform()
    await library.processPending()
    let items = try await library.search("")
    expectEqual(items.count, 1)
    expectEqual(items[0].item.type, .genericDocument)
    expectFalse(items[0].item.hasPDF)
    expectEqual(items[0].item.resources.first?.type, .other)
    expectTrue(try await library.integrity().isEmpty)
  }
  @Test func testMalformedQueueDoesNotBlockOtherCaptures() async throws {
    let library = try makeLibrary()
    try Data("invalid".utf8).write(
      to: temp.appendingPathComponent("Archive/Inbox/Requests/bad.json"))
    try await library.submit(IngestionRequest(text: "10.1000/valid"))
    await library.processPending()
    expectEqual(try await library.search("").count, 1)
    expectTrue(try await library.integrity().contains { $0.message.contains("Malformed capture") })
  }
  @Test func testPaperpileMigrationAttachesExportedPDF() async throws {
    let library = try makeLibrary()
    _ = try pdf(
      "DOI: 10.1000/migration\nScientific study of mitochondrial transport in neurons.",
      name: "paper.pdf")
    let json = Data(
      #"[{"title":"Migrated paper","doi":"10.1000/migration","attachments":[{"path":"paper.pdf"}],"notes":"Migration note"}]"#
        .utf8)
    let url = temp.appendingPathComponent("paperpile.json")
    try json.write(to: url)
    expectEqual(try await library.importRecords(url), 1)
    let items = try await library.search("")
    expectEqual(items.count, 1)
    expectTrue(items[0].item.hasPDF)
    expectEqual(items[0].item.notes, "Migration note")
    expectEqual(try await library.search("mitochondrial").count, 1)
  }
  @Test func testAccessibleWebPDFIsAttachedWithoutScrapingReferences() async throws {
    struct WebFixture: HTTPTransport {
      let pdf: Data
      func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let isPDF = url.path.hasSuffix(".pdf")
        let html = Data(
          #"<html><meta content="10.1000/web" name="citation_doi"><meta name="citation_pdf_url" content="https://example.org/article.pdf"><title>Web paper</title>Reference DOI 10.1000/wrong</html>"#
            .utf8)
        return (
          isPDF ? pdf : html,
          HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": isPDF ? "application/pdf" : "text/html"])!
        )
      }
    }
    let source = try pdf("Scientific web paper on receptor trafficking and endocytosis.")
    let library = try LibraryService(
      root: temp.appendingPathComponent("Archive"), databaseURL: temp.appendingPathComponent("db"),
      providers: [FixedProvider()], transport: WebFixture(pdf: Data(contentsOf: source)))
    let request = IngestionRequest(text: "https://example.org/article")
    try await library.submit(request)
    await library.processPending()
    let item = try await library.item(request.id)!
    expectEqual(item.doi, "10.1000/web")
    expectTrue(item.hasPDF)
    expectEqual(try await library.search("endocytosis").first?.pageStart, 1)
  }
  @Test func testExactDuplicateCaptureRetainsNewUserNotes() async throws {
    let library = try makeLibrary()
    let file = try pdf("Scientific research on cortical circuits and inhibitory neurons.")
    _ = try await library.captureFile(file)
    await library.processPending()
    let id = try await library.captureFile(file)
    var request = try await library.requests().first { $0.id == id }!
    request.note = "A new observation"
    request.suggestedTags = ["cortex"]
    try await library.submit(request)
    await library.processPending()
    let items = try await library.search("")
    expectEqual(items.count, 1)
    expectEqual(items[0].item.notes, "A new observation")
    expectEqual(items[0].item.tags, ["cortex"])
  }

  @Test func testTwentyThousandItemSearchAndPagination() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("scale.sqlite"))
    for n in 0..<20000 {
      var item = ResearchCore.LibraryItem(title: String(format: "Paper %05d unique%d", n, n))
      item.year = 2000 + n % 26
      try db.upsert(item)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let hit = try db.search("unique15000", limit: 20)
    let duration = start.duration(to: clock.now)
    expectEqual(hit.count, 1)
    expectTrue(duration < timeBudget(2))
    print("20,000-item FTS search: \(duration)")
    var filters = SearchFilters()
    filters.sort = .title
    let page = try db.search("", filters: filters, limit: 100, offset: 19000)
    expectEqual(page.count, 100)
    expectTrue(page[0].item.title.hasPrefix("Paper 19000"))
    expectTrue(page[99].item.title.hasPrefix("Paper 19099"))
  }
  @Test func testSearchRemainsAvailableDuringExtraction() async throws {
    struct Blocking: PDFTextExtractor {
      let entered: DispatchSemaphore
      let release: DispatchSemaphore
      func identifiers(url: URL) throws -> String { "DOI: 10.1000/responsive" }
      func extract(url: URL, itemID: UUID, resourceID: UUID) throws -> [DocumentPage] {
        entered.signal()
        _ = release.wait(timeout: .now() + 4)
        return [
          DocumentPage(
            id: UUID(), itemID: itemID, resourceID: resourceID, pageNumber: 1,
            text: "A searchable scientific body", method: "fixture")
        ]
      }
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let library = try LibraryService(
      root: temp.appendingPathComponent("Archive"), databaseURL: temp.appendingPathComponent("db"),
      providers: [FixedProvider()], transport: OfflineTransport(),
      extraction: Blocking(entered: entered, release: release))
    let source = try pdf("Scientific research on neurons and their metabolism.")
    _ = try await library.captureFile(source)
    let processing = Task { await library.processPending() }
    let started = await Task.detached { waitForExtraction(entered) }.value
    expectTrue(started)
    let clock = ContinuousClock()
    let start = clock.now
    let results = try await library.search("Microglial")
    let elapsed = start.duration(to: clock.now)
    release.signal()
    await processing.value
    expectEqual(results.count, 1)
    expectTrue(elapsed < timeBudget(2))
    expectEqual(try await library.search("searchable").count, 1)
  }

}

private func expectEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a == b) }
private func expectNotEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a != b) }
private func expectTrue(_ value: Bool) { #expect(value) }
private func expectFalse(_ value: Bool) { #expect(!value) }
private func expectNotNil<T>(_ value: T?) { #expect(value != nil) }
private func expectNil<T>(_ value: T?) { #expect(value == nil) }
private func expectGreater<T: Comparable>(_ a: T, _ b: T) { #expect(a > b) }
private func expectThrows<T>(_ body: @autoclosure () throws -> T) {
  do {
    _ = try body()
    Issue.record("Expected error")
  } catch {}
}
private func expectNoThrow<T>(_ body: @autoclosure () throws -> T) {
  do { _ = try body() } catch { Issue.record("Unexpected error: \(error)") }
}

private func waitForExtraction(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now() + 5) == .success
}
