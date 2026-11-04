import Foundation
import AppKit
import PDFKit
import Testing
@testable import ResearchCore

actor LookupFixtureTransport: HTTPTransport {
  var requests: [URL] = []
  let responses: [String: Data]
  let denied: Set<String>
  init(_ responses: [String: Data] = [:], denied: Set<String> = []) { self.responses = responses; self.denied = denied }
  func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    requests.append(url)
    if denied.contains(url.absoluteString) { throw LibraryError.invalid("HTTP 403") }
    let key = responses[url.absoluteString] != nil ? url.absoluteString : url.host == "www.ebi.ac.uk" ? "europePMC" : url.query != nil && url.host == "pmc-oa-opendata.s3.amazonaws.com" ? "pmcVersions" : url.absoluteString
    guard let data = responses[key] else { throw LibraryError.invalid("HTTP 404") }
    return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  func count() -> Int { requests.count }
}

@Suite(.serialized) struct PaperpileTests {
  private func record(_ id: String = "paperpile-id") throws -> Data {
    try JSONSerialization.data(withJSONObject: [[
      "_id": id, "title": "Visualizing dynamic microvillar search and stabilization during ligand detection by T cells",
      "doi": "10.1126/science.aal3118", "pmid": "28495700", "pmc": "PMC6364556",
      "published": ["year": "2017", "month": "5", "day": "12"],
      "author": [["first": "En", "last": "Cai", "orcid": "0000-0002-8212-8387"]],
      "url": ["https://doi.org/10.1126/science.aal3118", "https://example.org/article"],
      "citekey": "Cai2017", "volume": "356", "issue": "6338", "pages": "eaal3118", "created": 1500000000,
      "folders": ["678838fa-5735-4d6b-8059-d708f35f74c8"], "labels": [["name": "T cells"]],
      "attachments": [["filename": "All Papers/C/Cai et al. 2017 - Visualizing dynamic microvillar search and stabilization during ligand detection by T cells.pdf", "source_filename": "nihms-948276.pdf", "article_pdf": 1, "mimeType": "application/pdf"]]
    ]])
  }
  private func pdfData(title: String? = nil) -> Data {
    let document = PDFDocument()
    if let title { document.documentAttributes = [PDFDocumentAttribute.titleAttribute: title] }
    document.insert(PDFPage(), at: 0)
    return document.dataRepresentation()!
  }
  private func textPDF(_ text: String) throws -> Data {
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
      .draw(in: CGRect(x: 40, y: 400, width: 530, height: 350))
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage(); context.closePDF()
    return data as Data
  }
  @Test func wrappedPublisherDOIIsNotAConflictingIdentifier() throws {
    let doi = "10.1146/annurev-cellbio-111524-111428"
    let text = "DOI: 10.1146/annurev-cellbio-111524-\n111428"
    #expect(Identifiers.doi(text) == doi)
    #expect(Identifiers.doi("10.1146/\nannurev-cellbio-111524-111428") == doi)
    #expect(Identifiers.doi("10.1146/annurev-cellbio-111524-111428\nAbstract") == doi)
    var item = LibraryItem(title: "From Pixels to Discovery")
    item.doi = doi
    let data = try textPDF(text)
    try PDFDiscovery.validate(data, item: item, authoritative: false)
    item.doi = "10.1146/annurev-cellbio-111524-999999"
    #expect(throws: (any Error).self) { try PDFDiscovery.validate(data, item: item, authoritative: true) }
  }
  private func withLibrary(_ transport: any HTTPTransport) throws -> (URL, LibraryService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LookupFixture-" + UUID().uuidString)
    let library = try LibraryService(root: root, databaseURL: root.appendingPathComponent("index.sqlite"), providers: [], transport: transport)
    return (root, library)
  }
  @Test func realPaperpileShapePreservesBibliographyAndStableIdentity() throws {
    let data = try record()
    let item = try ImportService.parse(data, format: "json")[0]
    #expect(item.id == (try ImportService.parse(data, format: "json")[0].id))
    #expect(item.year == 2017)
    #expect(item.publicationDate == "2017-05-12")
    #expect(item.pmcid == "PMC6364556")
    #expect(item.citationKey == "Cai2017")
    #expect(item.authors.first?.orcid == "0000-0002-8212-8387")
    #expect(item.volume == "356" && item.issue == "6338")
    #expect(item.resources.count == 2)
    #expect(item.pdfFilenameHints?.count == 2)
    #expect(item.collections.isEmpty)
    #expect(item.sourceMetadata?.first?.payload.contains("678838fa") == true)
    #expect(item.dateAdded == Date(timeIntervalSince1970: 1500000000))
    let longName = URL(fileURLWithPath: "/tmp/" + Files.filename(item))
    #expect(PDFDiscovery.localCandidates([longName], item: item) == [longName])
  }
  @Test func importIsLazyAndRepeatedImportPreservesEdits() async throws {
    let transport = LookupFixtureTransport()
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    #expect(try await library.importRecords(file) == 1)
    var item = try await library.search("")[0].item
    item.notes = "My important note"; item.title = "My corrected title"; item.tags = ["My tag"]
    try await library.edit(item)
    #expect(try await library.importRecords(file) == 1)
    let result = try await library.search("")
    #expect(result.count == 1)
    #expect(result[0].item.notes == "My important note")
    #expect(result[0].item.title == "My corrected title")
    #expect(result[0].item.tags.contains("My tag"))
    #expect(await transport.count() == 0)
    let modified = result[0].item.dateModified
    _ = try await library.importRecords(file)
    #expect(try await library.item(item.id)?.dateModified == modified)
  }
  @Test func importedItemDoesNotReturnAfterPermanentDeletion() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let item = try await library.search("")[0].item
    try await library.permanentlyRemove(item.id)
    _ = try await library.importRecords(file)
    #expect(try await library.search("").isEmpty)
  }
  @Test func recoverySnapshotDoesNotRequireHydratingSidecars() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let item = try await library.search("")[0].item
    // The cached recovery backup remains usable if cloud metadata is unavailable.
    try FileManager.default.removeItem(at: root.appendingPathComponent("Metadata/\(item.id.uuidString).json"))
    let backup = root.appendingPathComponent("cached-backup.json")
    try await library.exportCachedSnapshot(to: backup)
    let restored = try ImportService.parse(Data(contentsOf: backup), format: "json")
    #expect(restored.count == 1)
    #expect(restored.first?.importedIDs == item.importedIDs)
    #expect(restored.first?.title == item.title)
    #expect(try await library.importRecords(file, resume: true) == 1)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/\(item.id.uuidString).json").path))
    #expect(try await library.libraryCounts()["paperpileReferences"] == 1)
  }
  @Test func paperpileZipAttachesExactFilenameAndTriagesUnknownPDF() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    let bibliography = root.appendingPathComponent("paperpile.json")
    try record().write(to: bibliography)
    _ = try await library.importRecords(bibliography)
    let staging = root.appendingPathComponent("zip-source")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try pdfData().write(to: staging.appendingPathComponent("nihms-948276.pdf"))
    try pdfData().write(to: staging.appendingPathComponent("unknown.pdf"))
    let archive = root.appendingPathComponent("Inbox/paperpile-pdfs.zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    zip.arguments = ["-c", "-k", staging.path, archive.path]
    try zip.run(); zip.waitUntilExit()
    #expect(zip.terminationStatus == 0)
    let report = try await library.processInboxArchives()
    #expect(report.archives == 1 && report.PDFs == 2)
    #expect(report.attached == 1 && report.needsReview == 1)
    #expect(!FileManager.default.fileExists(atPath: archive.path))
    let item = try await library.search("")[0].item
    #expect(item.resources.contains { $0.type == .pdf && $0.availability == .local })
    let review = root.appendingPathComponent("Needs Review/Paperpile ZIPs/paperpile-pdfs")
    let reviewFiles = FileManager.default.enumerator(at: review, includingPropertiesForKeys: nil)?
      .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
    #expect(reviewFiles.contains("unknown.pdf"))
  }
  @Test func localTitleMatchWinsWithoutNetworkAndUsesExistingManagedCopy() async throws {
    let transport = LookupFixtureTransport()
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let item = try await library.search("")[0].item
    let pdf = root.appendingPathComponent("PDFs/" + item.title + ".pdf")
    try pdfData(title: item.title).write(to: pdf)
    let result = try await library.resolvePDF(item.id)
    #expect(result.hasPDF)
    #expect(result.resources.first(where: { $0.type == .pdf })?.relativePath == "PDFs/" + item.title + ".pdf")
    #expect(await transport.count() == 0)
  }
  @Test func unindexedInboxPDFIsFoundBeforeNetworkLookup() async throws {
    let transport = LookupFixtureTransport()
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let title = "From Pixels to Discovery: Microscopy Image Analysis in the Age of Artificial Intelligence"
    var item = LibraryItem(title: title)
    item.doi = "10.1146/annurev-cellbio-111524-111428"
    try await library.edit(item)
    let file = root.appendingPathComponent("Inbox/annurev-cellbio-111524-111428.pdf")
    try pdfData(title: title).write(to: file)
    let result = try await library.resolvePDF(item.id)
    #expect(result.hasPDF)
    #expect(result.resources.contains { $0.relativePath?.hasPrefix("PDFs/") == true })
    #expect(await transport.count() == 0)
  }
  @Test func shortenedCloudFilenameIsACandidate() {
    let item = LibraryItem(title: "From Pixels to Discovery: Microscopy Image Analysis in the Age of Artificial Intelligence")
    let file = URL(fileURLWithPath: "/tmp/2026 - Uhlmann - From Pixels to Discovery Microscopy Image Analysis in the Age of Artificial.pdf")
    #expect(PDFDiscovery.localCandidates([file], item: item) == [file])
  }
  @Test func identicalReviewCopiesRecoverAsOnePDFBeforeNetworkLookup() async throws {
    let transport = LookupFixtureTransport()
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let title = "From Pixels to Discovery: Microscopy Image Analysis in the Age of Artificial Intelligence"
    var item = LibraryItem(title: title)
    item.doi = "10.1146/annurev-cellbio-111524-111428"
    item.pdfLookup = PDFLookup(.notFound, detail: "Old failed lookup", checkedAt: Date())
    try await library.edit(item)
    let review = root.appendingPathComponent("Needs Review/Paperpile ZIPs/archive/All Papers/U")
    try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
    let data = try textPDF(title + "\nDOI: 10.1146/annurev-cellbio-111524-\n111428")
    try data.write(to: review.appendingPathComponent(title + ".pdf"))
    try data.write(to: review.appendingPathComponent(title + ".2.pdf"))
    let result = try await library.resolvePDF(item.id)
    #expect(result.hasPDF)
    #expect(result.pdfLookup?.status == .available)
    #expect(result.resources.filter { $0.type == .pdf }.count == 1)
    let path = try #require(result.resources.first { $0.type == .pdf }?.relativePath)
    #expect(path.hasPrefix("PDFs/"))
    #expect(try Data(contentsOf: root.appendingPathComponent(path)) == data)
    #expect(await transport.count() == 0)
  }
  @Test func indexedDOIReconnectsAnOpaqueManagedPDF() async throws {
    let transport = LookupFixtureTransport()
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let doi = "10.1146/annurev-cellbio-111524-111428"
    let title = "From Pixels to Discovery: Microscopy Image Analysis in the Age of Artificial Intelligence"
    let file = root.appendingPathComponent("PDFs/opaque-export-name.pdf")
    try pdfData(title: title).write(to: file)
    var source = LibraryItem(title: "Imported under a different title")
    let resource = Resource(itemID: source.id, type: .pdf, path: "PDFs/opaque-export-name.pdf", availability: .local)
    source.resources = [resource]
    try await library.edit(source)
    let database = try LocalDatabase(url: root.appendingPathComponent("index.sqlite"))
    try database.index(
      pages: [DocumentPage(id: UUID(), itemID: source.id, resourceID: resource.id, pageNumber: 1,
                           text: "DOI: \(doi)", method: "fixture")],
      sections: [], chunks: [], itemID: source.id, resourceID: resource.id)
    var target = LibraryItem(title: title)
    target.doi = doi
    try await library.edit(target)
    let resolved = try await library.resolvePDF(target.id)
    #expect(resolved.hasPDF)
    #expect(resolved.resources.contains { $0.type == .pdf && $0.relativePath == "PDFs/opaque-export-name.pdf" })
    #expect(await transport.count() == 0)
  }
  @Test func ambiguousLocalCopiesRequireReview() async throws {
    let transport = LookupFixtureTransport()
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let item = try await library.search("")[0].item
    for prefix in ["2017 - ", "2018 - "] {
      try pdfData(title: item.title).write(to: root.appendingPathComponent("PDFs/" + prefix + item.title + ".pdf"))
    }
    let result = try await library.resolvePDF(item.id)
    #expect(result.pdfLookup?.status == .needsReview)
    #expect(!result.hasPDF)
    var filters = SearchFilters(); filters.needsReview = true
    #expect(try await library.search("", filters: filters).count == 1)
    #expect(await transport.count() == 0)
  }
  @Test func currentPMCVersionMetadataProvidesPDFAndOnlyOrganizedCopyRemains() async throws {
    let fixturePDF = pdfData()
    let pdfURL = "https://pmc-oa-opendata.s3.amazonaws.com/PMC6364556.2/paper.pdf"
    let transport = LookupFixtureTransport([
      "pmcVersions": Data("<ListBucketResult><CommonPrefixes><Prefix>PMC6364556.2/</Prefix></CommonPrefixes></ListBucketResult>".utf8),
      "https://pmc-oa-opendata.s3.amazonaws.com/metadata/PMC6364556.2.json": try JSONSerialization.data(withJSONObject: ["pmcid": "PMC6364556", "doi": "10.1126/science.aal3118", "pdf_url": "s3://pmc-oa-opendata/PMC6364556.2/paper.pdf", "pmid": 28495700]),
      pdfURL: fixturePDF
    ])
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let item = try await library.search("")[0].item
    let result = try await library.resolvePDF(item.id)
    #expect(result.hasPDF && result.pdfLookup?.status == .available)
    let resource = try #require(result.resources.first { $0.type == .pdf })
    #expect(resource.remoteURL == pdfURL)
    #expect(try Data(contentsOf: root.appendingPathComponent(resource.relativePath!)) == fixturePDF)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Inbox").path) == ["Requests"])
  }
  @Test func noPDFAndPublisherAccessRestrictionAreDistinctAndCanRetry() async throws {
    let transport = LookupFixtureTransport(denied: ["https://doi.org/10.1126/science.aal3118"])
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let item = try await library.search("")[0].item
    let result = try await library.resolvePDF(item.id)
    #expect(result.pdfLookup?.status == .requiresAuthentication)
    let count = await transport.count()
    _ = try await library.resolvePDF(item.id)
    #expect(await transport.count() == count)
    _ = try await library.resolvePDF(item.id, retry: true)
    #expect(await transport.count() > count)
    let (otherRoot, other) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    let otherFile = otherRoot.appendingPathComponent("export.json")
    try record().write(to: otherFile)
    _ = try await other.importRecords(otherFile)
    #expect(try await other.resolvePDF(item.id).pdfLookup?.status == .notFound)
  }
  @Test func europePMCFreeLinkIsUsedWhenPMCVersionHasNoPDF() async throws {
    let fixture = pdfData()
    let pdfURL = "https://example.org/open-access.pdf"
    let transport = LookupFixtureTransport([
      "europePMC": try JSONSerialization.data(withJSONObject: ["resultList": ["result": [["id": "28495700", "source": "MED", "doi": "10.1126/science.aal3118", "pmcid": "PMC6364556", "fullTextUrlList": ["fullTextUrl": [["documentStyle": "pdf", "availability": "Free", "url": pdfURL]]]]]]]),
      "pmcVersions": Data("<ListBucketResult/>".utf8), pdfURL: fixture
    ])
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    let id = try await library.search("")[0].item.id
    let resolved = try await library.resolvePDF(id)
    #expect(resolved.hasPDF)
    #expect(resolved.resources.contains { $0.type == .pdf && $0.remoteURL == pdfURL })
  }
  @Test func openAccessResolverFindsPDFWhenPublisherBlocksLandingPage() async throws {
    let fixture = pdfData()
    let doi = "10.1146/annurev-cellbio-111524-111428"
    let articleURL = "https://doi.org/\(doi)"
    let pdfURL = "https://repository.example.org/uhlmann.pdf"
    let openAlexURL = "https://api.openalex.org/works/https://doi.org/\(doi)"
    let transport = LookupFixtureTransport([
      openAlexURL: try JSONSerialization.data(withJSONObject: [
        "doi": articleURL, "open_access": ["is_oa": true],
        "best_oa_location": ["pdf_url": pdfURL], "locations": []
      ]),
      "europePMC": Data("{\"resultList\":{\"result\":[]}}".utf8), pdfURL: fixture
    ], denied: [articleURL])
    let (root, library) = try withLibrary(transport)
    defer { try? FileManager.default.removeItem(at: root) }
    var item = LibraryItem(title: "From Pixels to Discovery: Microscopy Image Analysis in the Age of Artificial Intelligence")
    item.doi = doi
    item.canonicalURL = articleURL
    try await library.edit(item)
    let resolved = try await library.resolvePDF(item.id)
    #expect(resolved.hasPDF)
    #expect(resolved.resources.contains { $0.type == .pdf && $0.remoteURL == pdfURL })
  }
  @Test func publisherPageAcceptsStandardPDFLinkMarkup() throws {
    let html = #"<link rel="alternate" type="application/pdf" href="/files/article.pdf"><a href="https://example.org/download?format=pdf">PDF</a>"#
    let links = WebMetadata.pdfLinks(html, relativeTo: URL(string: "https://example.org/article")!)
    #expect(links.map(\.absoluteString) == [
      "https://example.org/files/article.pdf", "https://example.org/download?format=pdf"
    ])
  }
  @Test func conflictingIdentifiersAreRetainedForReviewAndNotMerged() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("export.json")
    var records = try JSONSerialization.jsonObject(with: record()) as! [[String: Any]]
    var second = records[0]; second["_id"] = "conflicting-record"; second["pmid"] = "99999999"
    records.append(second)
    try JSONSerialization.data(withJSONObject: records).write(to: file)
    _ = try await library.importRecords(file)
    let results = try await library.search("")
    #expect(results.count == 2)
    #expect(results.contains { $0.item.pdfLookup?.status == .needsReview })
    _ = try await library.importRecords(file)
    #expect(try await library.search("").count == 2)
  }
  @Test func editedIdentifiersStillRecognizeOriginalPaperpileIdentity() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    var existing = LibraryItem(title: "Existing record")
    existing.doi = "10.1126/science.aal3118"
    try await library.edit(existing)
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    var corrected = try #require(try await library.item(existing.id))
    corrected.doi = "10.1000/corrected"; corrected.pmid = "12345678"
    try await library.edit(corrected)
    _ = try await library.importRecords(file)
    let results = try await library.search("")
    #expect(results.count == 1)
    #expect(results[0].item.doi == "10.1000/corrected")
  }
  @Test func permanentDeletionOfMergedNativeRecordSurvivesReimportAfterRestart() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    var existing = LibraryItem(title: "Previously captured paper")
    existing.doi = "10.1126/science.aal3118"
    try await library.edit(existing)
    let file = root.appendingPathComponent("export.json")
    try record().write(to: file)
    _ = try await library.importRecords(file)
    try await library.permanentlyRemove(existing.id)
    let restarted = try LibraryService(root: root, databaseURL: root.appendingPathComponent("restarted.sqlite"), providers: [], transport: LookupFixtureTransport())
    _ = try await restarted.importRecords(file)
    #expect(try await restarted.search("").isEmpty)
  }
  @Test func missingManagedFileIsTriagedAsUnavailable() async throws {
    let (root, library) = try withLibrary(LookupFixtureTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    var item = LibraryItem(title: "A paper whose attachment was removed")
    item.resources = [Resource(itemID: item.id, type: .pdf, path: "PDFs/removed.pdf", availability: .local)]
    try await library.edit(item)
    let result = try await library.resolvePDF(item.id)
    #expect(result.pdfLookup?.status == .notFound)
    #expect(!result.hasPDF)
    #expect(result.resources[0].availability == .missing)
    try pdfData().write(to: root.appendingPathComponent("PDFs/removed.pdf"))
    let restored = try await library.resolvePDF(item.id, retry: true)
    #expect(restored.hasPDF && restored.resources[0].availability == .local)
  }
  @Test func searchIndexUpdatesUseExistingRowIDAndMigrationBackfillsLookup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("index.sqlite")
    var item = LibraryItem(title: "Original searchable title")
    let database = try LocalDatabase(url: url)
    try database.upsert(item)
    #expect(try database.rows("SELECT count(*) AS count FROM item_fts_lookup")[0]["count"] == "1")
    try database.execute("DROP TABLE item_fts_lookup")
    let migrated = try LocalDatabase(url: url)
    #expect(try migrated.rows("SELECT count(*) AS count FROM item_fts_lookup")[0]["count"] == "1")
    item.title = "Replacement searchable title"
    try migrated.upsert(item)
    #expect(try migrated.search("Original", filters: SearchFilters(), limit: 100, offset: 0).isEmpty)
    #expect(try migrated.search("Replacement", filters: SearchFilters(), limit: 100, offset: 0).count == 1)
    try migrated.remove(item.id)
    #expect(try migrated.rows("SELECT count(*) AS count FROM item_fts")[0]["count"] == "0")
    #expect(try migrated.rows("SELECT count(*) AS count FROM item_fts_lookup")[0]["count"] == "0")
  }
  @Test func residentLocalBytesAreRecognizedWithoutCloudDownloadStatus() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(!Files.hasResidentData(file))
    try Data().write(to: file)
    #expect(!Files.hasResidentData(file))
    try Data("{\"item\":true}".utf8).write(to: file)
    #expect(Files.hasResidentData(file))
  }
  @Test func downloadedHTMLIsNeverAttachedAsPDF() async throws {
    #expect(throws: (any Error).self) { try PDFDiscovery.validate(Data("<html>Sign in</html>".utf8), item: LibraryItem(), authoritative: true) }
    let item = try ImportService.parse(record(), format: "json")[0]
    #expect(throws: (any Error).self) { try PDFDiscovery.validate(pdfData(), item: item, authoritative: false) }
  }
  @Test func bioRxivMetadataNormalizationUsesCollectionResponse() async throws {
    var item = LibraryItem(title: "Old title")
    item.doi = "10.1101/2025.01.01.123456"
    let response: [String: Any] = [
      "collection": [[
        "doi": "10.1101/2025.01.01.123456", "title": "A preprint title",
        "authors": "Doe, Jane; John Smith", "date": "2025-01-02",
        "abstract": "<p>An abstract.</p>", "category": "cell biology",
        "license": "https://creativecommons.org/licenses/by/4.0/"
      ]]
    ]
    let data = try JSONSerialization.data(withJSONObject: response)
    let transport = LookupFixtureTransport([
      "https://api.biorxiv.org/details/biorxiv/10.1101/2025.01.01.123456/na/json": data
    ])
    let result = try await BioRxivProvider(transport: transport).resolve(item)
    #expect(result?.title == "A preprint title")
    #expect(result?.abstract == "An abstract.")
    #expect(result?.publicationDate == "2025-01-02")
    #expect(result?.year == 2025)
    #expect(result?.authorText == "Jane Doe; John Smith")
    #expect(result?.keywords == ["cell biology"])
    #expect(result?.provenance.contains { $0.source == "bioRxiv" } == true)
  }
}
