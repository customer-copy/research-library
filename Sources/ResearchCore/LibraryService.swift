import CoreSpotlight
import Foundation
import OSLog
import PDFKit
import UniformTypeIdentifiers

public struct IntegrityIssue: Identifiable, Sendable {
  public let id = UUID()
  public var path: String
  public var message: String
}
public struct InboxArchiveReport: Codable, Sendable {
  public var archives = 0
  public var PDFs = 0
  public var attached = 0
  public var alreadyPresent = 0
  public var needsReview = 0
  public var otherFiles = 0
  public var removedArchives: [String] = []
  /// Archives kept (moved to Needs Review) because some PDFs could not be attached or copied.
  public var keptArchives: [String] = []
}
public actor LibraryService: RetrievalService {
  public let root: URL
  private let sidecars: SidecarService
  private let database: LocalDatabase
  private let searchReader: LibrarySearchReader
  private let metadata: MetadataResolutionService
  private let transport: any HTTPTransport
  private let extraction: any PDFTextExtractor
  private let readerLoader: any PDFSnapshotLoader
  // Test seam for failures at durable import boundaries; no behavior in normal operation.
  enum ImportBoundary { case planned, copied, metadataSaved }
  private var importFault: ((ImportBoundary) throws -> Void)?
  func setImportFault(_ fault: ((ImportBoundary) throws -> Void)?) { importFault = fault }
  private var pdfLookups: [UUID: Task<LibraryItem, Error>] = [:]
  private var pdfCatalog: (date: Date, files: [URL])?
  private var verifiedPDFs: [UUID: (path: String, revision: Files.Revision, hash: String)] = [:]
  private var processing = false
  private var rebuilding = false
  private var deletedItems = Set<UUID>()
  private var cancelledRequests = Set<UUID>()
  private var permanentlyCancelledRequests = Set<UUID>()
  private var revision = 0
  public func generation() -> Int { revision }
  private var stableFiles: [String: (Int, Date)] = [:]
  private var chromeCaptureStamps: [UUID: Files.Revision] = [:]
  private var chromeCaptureFailures: [UUID: Int] = [:]
  private var lastSidecarStamp: [String: Files.Revision] = [:]
  private var loadedSidecarStamps = false
  private let logger = Logger(subsystem: "org.researchlibrary.app", category: "Library")
  private let signposter = OSSignposter(subsystem: "org.researchlibrary.app", category: "Performance")
  private var operationTimings: [String: [String: Double]] = [:]
  private func recordTiming(_ name: String, started: ContinuousClock.Instant) {
    let duration = started.duration(to: .now).components
    let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    var values = operationTimings[name] ?? ["count": 0, "totalMilliseconds": 0, "maxMilliseconds": 0]
    values["count", default: 0] += 1
    values["totalMilliseconds", default: 0] += milliseconds
    values["lastMilliseconds"] = milliseconds
    values["maxMilliseconds"] = max(values["maxMilliseconds", default: 0], milliseconds)
    operationTimings[name] = values
  }
  public init(
    root: URL, databaseURL: URL? = nil, providers: [any MetadataProvider]? = nil,
    transport: any HTTPTransport = NativeHTTPTransport(),
    extraction: any PDFTextExtractor = PDFExtractionService(),
    readerLoader: any PDFSnapshotLoader = NativePDFSnapshotLoader()
  ) throws {
    self.root = root
    sidecars = try SidecarService(root: root)
    self.transport = transport
    self.extraction = extraction
    self.readerLoader = readerLoader
    metadata =
      providers.map { MetadataResolutionService(providers: $0) } ?? .live(transport: transport)
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0
    ].appendingPathComponent(
      "ResearchLibrary/\(Files.stableID(root.standardizedFileURL.path))/index.sqlite")
    let indexURL = databaseURL ?? support
    database = try LocalDatabase(url: indexURL)
    searchReader = LibrarySearchReader(url: indexURL)
  }
  public nonisolated func search(
    _ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 100, offset: Int = 0
  ) async throws -> [RetrievalResult] {
    try await searchReader.search(query, filters: filters, limit: limit, offset: offset)
  }
  public nonisolated func searchMetadata(_ query: String, filters: SearchFilters = SearchFilters(),
    limit: Int = 100, offset: Int = 0) async throws -> [RetrievalResult] {
    try await searchReader.search(query, filters: filters, limit: limit, offset: offset, metadataOnly: true)
  }
  /// Returns the local records used by the homepage. This deliberately reads the indexed
  /// metadata only; PDF text is not loaded while the dashboard is opening.
  /// The search layer returns at most 500 rows per call, so this pages until `limit` items
  /// (or the whole library) have been read.
  public nonisolated func dashboardItems(limit: Int = 100_000) async throws -> [LibraryItem] {
    var filters = SearchFilters(); filters.sort = .dateAdded
    let page = 500
    var items: [LibraryItem] = []
    while items.count < limit {
      try Task.checkCancellation()
      let want = min(page, limit - items.count)
      let batch = try await searchReader.search("", filters: filters, limit: want, offset: items.count)
      items.append(contentsOf: batch.map(\.item))
      if batch.count < want { break }
    }
    return items
  }
  /// Merges an OpenAlex record using `OpenAlexMerge` rules. Returns false (and writes
  /// nothing) when the record adds nothing new, so repeated syncs do not churn sidecars,
  /// recovery copies or provenance.
  @discardableResult
  public func mergeOpenAlex(_ record: OpenAlexWorkRecord, into id: UUID) throws -> Bool {
    guard let item = try database.item(id) else { return false }
    guard var merged = OpenAlexMerge.apply(record, to: item) else { return false }
    merged.dateModified = Date()
    try save(merged)
    return true
  }
  public nonisolated func matchingPages(_ query: String, itemID: UUID, limit: Int = 5,
    offset: Int = 0) async throws -> [RetrievalResult] {
    try await searchReader.matchingPages(query, itemID: itemID, limit: limit, offset: offset)
  }
  public func item(_ id: UUID) throws -> LibraryItem? { try database.item(id) }
  /// Apply durable deletions before presenting cached results; cloud reconciliation follows separately.
  public func prepareCachedLibrary() throws { try reconcilePermanentDeletions() }
  /// A scoped support report: filenames, capture state, and match errors, never document text.
  public func pdfDiagnostic(_ id: UUID) throws -> Data {
    guard let item = try database.item(id) else { throw LibraryError.invalid("Reference not found") }
    var report: [String: Any] = ["root": root.path,
      "item": try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(item))]
    let terms = [item.doi ?? "", "pixels", "uhlmann"].filter { !$0.isEmpty }
    let allRequests = try sidecars.requests()
    report["captureCount"] = allRequests.count
    report["captureHistory"] = try allRequests.map { request -> [String: String] in
      var entry = ["state": request.state.rawValue, "inputFile": request.inputFile ?? "", "title": request.suggestedTitle ?? "", "error": request.error ?? ""]
      if let result = request.resultID, let linked = try database.item(result) { entry["resultTitle"] = linked.title; entry["resultDOI"] = linked.doi }
      return entry
    }
    report["rootEntries"] = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let reviewRoot = root.appendingPathComponent("Needs Review")
    if let files = try? PDFDiscovery.catalog(reviewRoot) {
      report["reviewFiles"] = files.map(\.path)
      let matches = PDFDiscovery.residentContentCandidates(files, item: item)
      report["reviewMatches"] = matches.map(\.path)
      report["reviewEvidence"] = matches.map { file -> [String: Any] in
        var value: [String: Any] = ["path": file.path]
        value["hash"] = try? Files.hash(file)
        if let pdf = PDFDocument(url: file) {
          value["pages"] = pdf.pageCount
          value["metadataTitle"] = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute]
          value["pageEvidence"] = (0..<min(3, pdf.pageCount)).map { index -> [String: Any] in
            let text = pdf.page(at: index)?.string ?? ""
            return ["page": index + 1, "firstDOI": Identifiers.doi(text) ?? "", "expectedDOI": item.doi.map { text.lowercased().contains($0.lowercased()) } ?? false, "titleMatches": PDFDiscovery.titleMatches(text, item: item)]
          }
        }
        do { try PDFDiscovery.validate(file, item: item, authoritative: false); value["validation"] = "valid" }
        catch { value["validation"] = error.localizedDescription }
        return value
      }
    }
    let requests = allRequests.filter { request in
      let value = [request.inputFile, request.suggestedTitle, request.doi, request.inputText].compactMap { $0 }.joined(separator: " ").lowercased()
      return request.resultID == id || terms.contains { value.contains($0.lowercased()) }
    }
    report["captures"] = try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(requests))
    report["captureResults"] = try requests.compactMap { request -> Any? in
      guard let result = request.resultID, let linked = try database.item(result) else { return nil }
      return try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(linked))
    }
    do {
      let files = try PDFDiscovery.catalog(root)
      report["catalogCount"] = files.count
      let matches = PDFDiscovery.localCandidates(files, item: item)
      report["filenameMatches"] = matches.map(\.path)
      report["residentMatches"] = PDFDiscovery.residentContentCandidates(files, item: item).map(\.path)
      report["validation"] = matches.map { file -> [String: String] in
        do { try PDFDiscovery.validate(file, item: item, authoritative: false); return ["path": file.path, "status": "valid"] }
        catch { return ["path": file.path, "error": error.localizedDescription] }
      }
    } catch { report["catalogError"] = error.localizedDescription }
    return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  }
  public func organization() throws -> (tags: [String], collections: [String]) {
    (try database.organization("tags"), try database.organization("collections"))
  }
  public func requests() throws -> [IngestionRequest] {
    try sidecars.requests().sorted { $0.createdAt > $1.createdAt }
  }
  public func submit(_ request: IngestionRequest) throws { try sidecars.saveRequest(request) }
  /// Publish the page metadata without waiting for networking, OCR or Inbox stability polling.
  @discardableResult public func consumeChromeCapture(_ id: UUID) async throws -> LibraryItem {
    let payload = try ChromeCaptureEnvelope.read(id: id, root: root)
    let page = try Identifiers.canonicalURL(payload.url)
    let pdf = try payload.pdfURL.map(Identifiers.canonicalURL)
    let journal = root.appendingPathComponent("Inbox/Requests/\(id.uuidString).json")
    var request: IngestionRequest
    if FileManager.default.fileExists(atPath: journal.path) {
      request = try Files.coordinatedRead(journal) { try PortableJSON.decoder().decode(IngestionRequest.self, from: Data(contentsOf: $0)) }
      guard request.source == "chromeExtensionV2" else { throw LibraryError.conflict("Capture identifier already exists") }
      if request.duplicateChoice == .cancel || request.state == .complete {
        guard let item = try request.resultID.flatMap({ try database.item($0) }) else { throw CancellationError() }
        return item
      }
      if request.importCommit != nil {
        try await finishImportCommit(&request, indexNow: false)
        cleanupInbox(request)
        return try database.item(request.resultID!)!
      }
      if payload.phase == "pending", let existing = try request.resultID.flatMap({ try database.item($0) }) {
        return existing
      }
    } else {
      request = IngestionRequest(source: "chromeExtensionV2", text: page.absoluteString)
      request.id = id
      request.inputURL = pdf?.absoluteString ?? page.absoluteString
      // Reserve the atomically installed filename before the browser starts downloading.
      request.inputFile = "Inbox/Chrome-\(id.uuidString.lowercased()).pdf"
      request.state = .waitingForResource
    }
    let seed = payload.metadata.item(id: id, page: page, pdf: pdf)
    var target = try request.resultID ?? database.identifierDuplicate(seed) ?? database.item(id)?.id
    if target == nil, seed.doi == nil, seed.pmid == nil {
      target = try database.rows("SELECT id FROM items WHERE json_extract(json,'$.canonicalURL')=? LIMIT 1", [page.absoluteString])
        .first?["id"].flatMap(UUID.init(uuidString:))
    }
    var item = try target.flatMap { try database.item($0) }.map { MetadataResolutionService.merge($0, seed) } ?? seed
    guard !deletedItems.contains(item.id), !permanentlyCancelledRequests.contains(id) else { throw CancellationError() }
    request.resultID = item.id
    request.suggestedTitle = item.title
    request.doi = item.doi; request.pmid = item.pmid
    if !item.hasPDF {
      item.pdfLookup = PDFLookup(payload.phase == "failed" ? .retry : .pending,
        detail: payload.phase == "failed" ? String((payload.error ?? "PDF download failed; retry from Chrome.").prefix(1000)) : "Downloading PDF from Chrome…")
    }
    item.dateModified = Date()
    try sidecars.saveRequest(request)
    try save(item)
    guard payload.phase == "ready" else {
      if payload.phase == "failed" { request.state = .failed; request.error = item.pdfLookup?.detail; try sidecars.saveRequest(request) }
      return item
    }
    let file = try Files.safeURL(root: root, relative: request.inputFile!)
    // The host has already validated the PDF. Recheck independently before committing.
    let data = try Files.coordinatedRead(file) { try Data(contentsOf: $0, options: .mappedIfSafe) }
    guard data.count <= 512 * 1024 * 1024, data.starts(with: Data("%PDF-".utf8)),
      let document = PDFDocument(data: data), document.pageCount > 0 else { throw LibraryError.invalid("Invalid browser PDF") }
    let hash = Files.digest(data)
    if let duplicate = try database.exactDuplicate(hash: hash), duplicate != item.id,
      item.id == id, !item.humanEdited, item.notes.isEmpty, !item.hasPDF,
      let original = try database.item(duplicate) {
      let merged = MetadataResolutionService.merge(original, item)
      try save(merged)
      request.resultID = duplicate; request.state = .complete; request.error = nil
      try sidecars.saveRequest(request)
      // The provisional record has no user edits; retain its metadata in Recovery.
      try remove(item.id)
      cleanupInbox(request)
      return merged
    }
    if item.resources.contains(where: { $0.sha256 == hash || $0.originalSHA256 == hash }) {
      request.state = .complete; request.error = nil
      try sidecars.saveRequest(request); cleanupInbox(request)
      return item
    }
    let base = Files.digest(try PortableJSON.encoder().encode(item))
    item.pdfLookup = PDFLookup(.available, detail: "PDF saved from Chrome.", checkedAt: Date())
    let destination = Files.uniqueURL(root.appendingPathComponent("PDFs/" + Files.filename(item,
      pattern: UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}")))
    var resource = Resource(itemID: item.id, type: .pdf, url: pdf?.absoluteString,
      path: "PDFs/" + destination.lastPathComponent, availability: .local)
    resource.sha256 = hash; resource.mimeType = "application/pdf"; resource.primary = !item.hasPDF
    resource.source = "Chrome page"
    request.importCommit = ImportCommitCheckpoint(item: item, resource: resource, baseRecordHash: base)
    request.error = nil
    try stage(.importing, &request)
    try await finishImportCommit(&request, indexNow: false)
    cleanupInbox(request)
    return try database.item(item.id)!
  }
  public func consumePendingChromeCaptures() async {
    sweepAbandonedChromeTransfers()
    let folder = root.appendingPathComponent("Inbox/BrowserCaptures")
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
    for file in files where file.pathExtension == "json" {
      guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
      if let stamp = Files.revision(file), chromeCaptureStamps[id] == stamp { continue }
      do {
        _ = try await consumeChromeCapture(id)
        chromeCaptureStamps[id] = Files.revision(file)
        chromeCaptureFailures[id] = nil
      }
      catch {
        logger.error("Chrome capture requires retry: \(error.localizedDescription,privacy:.public)")
        // Validation/decoding errors will never succeed on retry. After a few attempts,
        // set the envelope aside so it stops being retried every poll. A PDF that arrived
        // with it stays in the Inbox and is imported as an ordinary file.
        let permanent = error is DecodingError || {
          if case LibraryError.invalid = error { return true } else { return false }
        }()
        guard permanent else { continue }
        chromeCaptureFailures[id, default: 0] += 1
        if chromeCaptureFailures[id, default: 0] >= Self.chromeCaptureAttempts {
          quarantineChromeCapture(file, reason: error.localizedDescription)
          chromeCaptureFailures[id] = nil
        }
      }
    }
  }
  static let chromeCaptureAttempts = 3
  private func quarantineChromeCapture(_ file: URL, reason: String) {
    let failed = root.appendingPathComponent("Inbox/BrowserCaptures/Failed", isDirectory: true)
    try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
    let target = Files.uniqueURL(failed.appendingPathComponent(file.lastPathComponent))
    try? FileManager.default.moveItem(at: file, to: target)
    try? Data("\(Date()): \(reason)\n".utf8).write(
      to: target.deletingPathExtension().appendingPathExtension("reason.txt"))
  }
  /// The Chrome helper stages PDFs as Inbox/.Chrome-<uuid>.part. If Chrome kills the helper
  /// mid-transfer, the stage file is never cleaned up; remove ones older than an hour.
  private func sweepAbandonedChromeTransfers() {
    let inbox = root.appendingPathComponent("Inbox")
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for file in files where file.lastPathComponent.hasPrefix(".Chrome-") && file.pathExtension == "part" {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
      if Date().timeIntervalSince(modified) > 3600 { try? FileManager.default.removeItem(at: file) }
    }
  }
  @discardableResult public func submitBrowserCapture(_ url: URL) throws -> UUID {
    let request = try BrowserCapture.request(from: url)
    let path = root.appendingPathComponent("Inbox/Requests/\(request.id.uuidString).json")
    // Retrying a browser handoff cannot reset a completed capture or duplicate its notes.
    if FileManager.default.fileExists(atPath: path.path) {
      try Files.materialize(path)
      let existing = try Files.coordinatedRead(path) {
        try PortableJSON.decoder().decode(IngestionRequest.self, from: Data(contentsOf: $0))
      }
      guard existing.source == "safariExtension" else { throw LibraryError.conflict("Capture identifier already exists") }
      return existing.id
    }
    try sidecars.saveRequest(request)
    return request.id
  }
  public func edit(_ item: LibraryItem) throws {
    if FileManager.default.fileExists(atPath: sidecars.url(item.id).path) {
      let current = try sidecars.read(sidecars.url(item.id))
      if current.dateModified.timeIntervalSince(item.dateModified) > 1 {
        throw LibraryError.conflict(
          "This item changed since the editor opened. Reopen the editor and retry.")
      }
    }
    var item = item
    item.humanEdited = true
    item.dateModified = Date()
    item.confidence = 1
    item.provenance.append(Provenance("user", "Manual authoritative correction"))
    try save(item)
  }
  public func refreshMetadata(_ id: UUID) async throws {
    guard let existing = try database.item(id) else { return }
    var seed = existing
    if seed.doi == nil && seed.pmid == nil && seed.arxivID == nil,
      let path = seed.resources.first(where: { $0.type == .pdf })?.relativePath
    {
      do {
        let url = try Files.safeURL(root: root, relative: path)
        let text = try extraction.identifiers(url: url)
        seed.doi = Identifiers.doi(text)
        seed.pmid = Identifiers.pmid(text)
        seed.pmcid = Identifiers.pmcid(text) ?? seed.pmcid
        seed.arxivID = Identifiers.arxiv(text)
        if !seed.humanEdited, let embedded = try extraction.metadataSeed(url: url) {
          seed = MetadataResolutionService.merge(seed, embedded)
        }
      } catch {
        seed.provenance.append(
          Provenance("PDF", "Metadata seed unavailable: \(error.localizedDescription)"))
      }
    }
    let enriched = await metadata.resolve(seed)
    guard !deletedItems.contains(id) else { return }
    // Merge into the latest record so edits made during a web request stay authoritative.
    let current = try sidecars.read(sidecars.url(id))
    var refreshed = MetadataResolutionService.merge(current, enriched)
    refreshed.dateModified = Date()
    try save(refreshed)
  }
  private func save(_ item: LibraryItem) throws {
    guard !deletedItems.contains(item.id) else {
      throw LibraryError.invalid("This library item was deleted")
    }
    try sidecars.save(item)
    try database.upsert(item)
    revision += 1
    spotlight(item)
  }
  private func saveCoordinatedInBackground(_ item: LibraryItem) async throws {
    let sidecars = self.sidecars
    try await Task.detached(priority: .utility) { try sidecars.save(item) }.value
    try database.upsert(item)
    revision += 1
    spotlight(item)
  }
  public func savePDFAnnotations(itemID: UUID, resourceID: UUID, data: Data, expectedHash: String)
    throws -> String
  {
    guard !deletedItems.contains(itemID) else {
      throw LibraryError.invalid("This library item was deleted")
    }
    var item = try sidecars.read(sidecars.url(itemID))
    guard let index = item.resources.firstIndex(where: { $0.id == resourceID }),
      let path = item.resources[index].relativePath, item.resources[index].type == .pdf
    else {
      throw LibraryError.invalid("PDF attachment is no longer available")
    }
    if let recorded = item.resources[index].sha256, recorded != expectedHash {
      throw LibraryError.conflict(
        "This PDF changed on another device. Reload the reader before saving.")
    }
    let url = try Files.safeURL(root: root, relative: path)
    let hash = try PDFEditing.save(
      data, to: url, expectedHash: expectedHash,
      recovery: root.appendingPathComponent("Recovery/PDFs/\(resourceID)"))
    item.resources[index].originalSHA256 = item.resources[index].originalSHA256 ?? expectedHash
    item.resources[index].sha256 = hash
    item.dateModified = Date()
    try save(item)
    return hash
  }
  public func readPDFForReader(itemID: UUID, resourceID: UUID) async throws -> PDFReadSnapshot {
    let started = ContinuousClock.now
    let interval = signposter.beginInterval("PDF read", id: signposter.makeSignpostID())
    defer { signposter.endInterval("PDF read", interval); recordTiming("pdfRead", started: started) }
    guard !deletedItems.contains(itemID) else {
      throw LibraryError.invalid("This library item was deleted")
    }
    let original = try sidecars.read(sidecars.url(itemID))
    guard let resource = original.resources.first(where: { $0.id == resourceID }),
      let path = resource.relativePath, resource.type == .pdf
    else { throw LibraryError.invalid("PDF attachment is no longer available") }
    let url = try Files.safeURL(root: root, relative: path)
    let loader = readerLoader
    let task = Task.detached(priority: .userInitiated) { try loader.read(url) }
    let snapshot = try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
    try Task.checkCancellation()
    guard !deletedItems.contains(itemID) else { throw CancellationError() }
    // Re-read after suspension: edits and deletion can happen while the file is loading.
    var item = try sidecars.read(sidecars.url(itemID))
    guard let index = item.resources.firstIndex(where: { $0.id == resourceID }),
      item.resources[index].relativePath == path else {
      throw LibraryError.conflict("The PDF attachment changed while loading. Open it again.")
    }
    guard item.resources[index].sha256 == resource.sha256 else {
      throw LibraryError.conflict("This PDF changed while loading. Open it again.")
    }
    if item.resources[index].sha256 != snapshot.sha256 {
      item.resources[index].originalSHA256 =
        item.resources[index].originalSHA256 ?? item.resources[index].sha256
      item.resources[index].sha256 = snapshot.sha256
      item.dateModified = Date()
      try save(item)
    }
    return snapshot
  }
  private func spotlight(_ item: LibraryItem) {
    let attrs = CSSearchableItemAttributeSet(contentType: .content)
    attrs.title = item.title
    attrs.authorNames = item.orderedAuthors.map(\.displayName)
    attrs.contentDescription = String(item.abstract.prefix(4000))
    attrs.keywords =
      item.tags + [item.journal, item.year.map(String.init) ?? "", item.doi ?? "", item.pmid ?? ""]
    attrs.relatedUniqueIdentifier = item.id.uuidString
    let entry = CSSearchableItem(
      uniqueIdentifier: item.id.uuidString, domainIdentifier: Files.stableID(root.path).uuidString,
      attributeSet: attrs)
    if #available(macOS 15.0, iOS 18.0, *) {
      entry.associateAppEntity(LibraryItemEntity(id: item.id, title: item.title))
    }
    CSSearchableIndex.default().indexSearchableItems([entry]) { error in
      if let error {
        Logger(subsystem: "org.researchlibrary.app", category: "Spotlight").error(
          "Spotlight indexing failed: \(error.localizedDescription,privacy:.public)")
      }
    }
  }
  public func remove(_ id: UUID) throws {
    deletedItems.insert(id)
    pdfLookups[id]?.cancel()
    for var request in try sidecars.requests()
    where request.resultID == id || request.candidateID == id {
      cancelledRequests.insert(request.id)
      request.duplicateChoice = .cancel
      request.state = .complete
      try sidecars.saveRequest(request)
    }
    let source = sidecars.url(id)
    let target = root.appendingPathComponent(
      "Recovery/\(id)-\(Int(Date().timeIntervalSince1970)).json")
    try Files.coordinatedRead(source) { try Files.atomicWrite(Data(contentsOf: $0), to: target) }
    var error: NSError?
    var deletion: Error?
    NSFileCoordinator().coordinate(writingItemAt: source, options: .forDeleting, error: &error) {
      url in do { try FileManager.default.removeItem(at: url) } catch { deletion = error }
    }
    if let error { throw error }
    if let deletion { throw deletion }
    try database.remove(id)
    revision += 1
    CSSearchableIndex.default().deleteSearchableItems(
      withIdentifiers: [id.uuidString], completionHandler: nil)
  }
  private struct PermanentDeletion: Codable {
    var id: UUID
    var paths: [String]
    var requestIDs: [UUID]
  }
  /// A small UUID-only tombstone remains after completion to prevent stale cloud metadata revival.
  public func permanentlyRemove(_ id: UUID) throws {
    let marker = root.appendingPathComponent("Deletions/\(id.uuidString).json")
    if FileManager.default.fileExists(atPath: marker.path) {
      try reconcilePermanentDeletions()
      return
    }
    let current = try sidecars.read(sidecars.url(id))
    var versions = [current]
    var paths = Set<String>()
    let recovery = root.appendingPathComponent("Recovery")
    let metadataRecovery = recovery.appendingPathComponent("Metadata/\(id.uuidString)")
    if FileManager.default.fileExists(atPath: metadataRecovery.path) {
      for file in try FileManager.default.contentsOfDirectory(
        at: metadataRecovery, includingPropertiesForKeys: nil) where file.pathExtension == "json"
      {
        versions.append(try recoveryItem(file))
      }
      paths.insert("Recovery/Metadata/\(id.uuidString)")
    }
    for file in try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasPrefix(id.uuidString + "-") && file.pathExtension == "json" {
      versions.append(try recoveryItem(file))
      paths.insert("Recovery/" + file.lastPathComponent)
    }
    // Refuse to guess about unavailable metadata: another article may share an attachment.
    let others = try sidecars.metadataFiles().map { try sidecars.read($0) }.filter { $0.id != id }
    guard versions.allSatisfy({ $0.id == id }) else {
      throw LibraryError.invalid("Recovery metadata does not match this article")
    }
    let sharedPaths = Set(try others.flatMap(\.resources).compactMap(\.relativePath).map {
      try Files.safeURL(root: root, relative: $0).path
    })
    let sharedIDs = Set(others.flatMap(\.resources).map(\.id))
    for resource in versions.flatMap(\.resources) {
      if let path = resource.relativePath {
        guard path.hasPrefix("PDFs/") else {
          throw LibraryError.invalid("Permanent deletion only removes managed attachments inside PDFs.")
        }
        if !sharedPaths.contains(try Files.safeURL(root: root, relative: path).path) { paths.insert(path) }
      }
      if !sharedIDs.contains(resource.id) { paths.insert("Recovery/PDFs/\(resource.id.uuidString)") }
    }
    let requestFolder = root.appendingPathComponent("Inbox/Requests")
    var requestIDs: [UUID] = []
    for file in try FileManager.default.contentsOfDirectory(at: requestFolder, includingPropertiesForKeys: nil)
    where file.pathExtension == "json" {
      try Files.materialize(file)
      let request = try Files.coordinatedRead(file) {
        try PortableJSON.decoder().decode(IngestionRequest.self, from: Data(contentsOf: $0))
      }
      guard request.resultID == id || request.candidateID == id else { continue }
      // An ambiguous review linking to a different article is retained, rather than deleting its input.
      if let other = request.resultID, other != id { continue }
      requestIDs.append(request.id)
      paths.insert("Inbox/Requests/" + file.lastPathComponent)
      if let path = request.inputFile, path.hasPrefix("Inbox/"), path.split(separator: "/").count == 2 {
        paths.insert(path)
      }
    }
    // Metadata is removed last; a durable path manifest allows retry after a partial failure.
    let plan = PermanentDeletion(id: id, paths: paths.sorted() + ["Metadata/\(id.uuidString).json"], requestIDs: requestIDs)
    for path in plan.paths { _ = try Files.safeURL(root: root, relative: path) }
    try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A merged bibliography may use a pre-existing native ID. Tombstone its stable import
    // identities as well, so reimporting the source cannot recreate a permanently deleted paper.
    for externalID in Set(versions.flatMap { $0.importedIDs ?? [] }) where externalID.hasPrefix("paperpile:") {
      let alias = Files.stableID(externalID)
      if alias != id {
        let tombstone = PermanentDeletion(id: alias, paths: [], requestIDs: [])
        try Files.atomicWrite(PortableJSON.encoder().encode(tombstone),
          to: root.appendingPathComponent("Deletions/\(alias.uuidString).json"))
      }
    }
    try Files.atomicWrite(PortableJSON.encoder().encode(plan), to: marker)
    try reconcilePermanentDeletions()
  }
  private func recoveryItem(_ url: URL) throws -> LibraryItem {
    try Files.materialize(url)
    return try Files.coordinatedRead(url) {
      let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any]
      guard let item = envelope?["item"] else { throw LibraryError.invalid("Invalid metadata recovery copy") }
      return try PortableJSON.decoder().decode(LibraryItem.self, from: JSONSerialization.data(withJSONObject: item))
    }
  }
  private func reconcilePermanentDeletions() throws {
    let folder = root.appendingPathComponent("Deletions")
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    for marker in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    where marker.pathExtension == "json" {
      try Files.materialize(marker)
      var plan = try Files.coordinatedRead(marker) {
        try PortableJSON.decoder().decode(PermanentDeletion.self, from: Data(contentsOf: $0))
      }
      guard marker.deletingPathExtension().lastPathComponent == plan.id.uuidString else {
        throw LibraryError.invalid("Invalid permanent deletion marker")
      }
      deletedItems.insert(plan.id)
      pdfLookups[plan.id]?.cancel()
      permanentlyCancelledRequests.formUnion(plan.requestIDs)
      cancelledRequests.formUnion(plan.requestIDs)
      if plan.paths.isEmpty {
        // Completed deletion. This runs every poll, so only act if something reappeared
        // (for example a stale copy of the metadata synced back from another device).
        let sidecar = sidecars.url(plan.id)
        if FileManager.default.fileExists(atPath: sidecar.path) { try Files.permanentlyRemove(sidecar) }
        if try database.item(plan.id) != nil { try database.remove(plan.id) }
        continue
      }
      let others = try sidecars.metadataFiles().map { try sidecars.read($0) }.filter { $0.id != plan.id }
      let sharedPaths = Set(try others.flatMap(\.resources).compactMap(\.relativePath).map {
        try Files.safeURL(root: root, relative: $0).path
      })
      let sharedIDs = Set(others.flatMap(\.resources).map(\.id))
      for path in plan.paths {
        let parts = path.split(separator: "/").map(String.init)
        let attachment = parts.count == 2 && parts[0] == "PDFs"
        let inboxFile = parts.count == 2 && parts[0] == "Inbox"
        let requestFile = parts.count == 3 && parts[0] == "Inbox" && parts[1] == "Requests"
          && plan.requestIDs.contains(where: { parts[2] == $0.uuidString + ".json" })
        let pdfRecovery = parts.count == 3 && parts[0] == "Recovery" && parts[1] == "PDFs" && UUID(uuidString: parts[2]) != nil
        let metadataRecovery = path == "Recovery/Metadata/\(plan.id.uuidString)"
        let oldMetadata = parts.count == 2 && parts[0] == "Recovery"
          && parts[1].hasPrefix(plan.id.uuidString + "-") && parts[1].hasSuffix(".json")
        guard attachment || inboxFile || requestFile || pdfRecovery || metadataRecovery || oldMetadata
          || path == "Metadata/\(plan.id.uuidString).json"
        else { throw LibraryError.invalid("Invalid deletion path") }
        let url = try Files.safeURL(root: root, relative: path)
        if attachment && sharedPaths.contains(url.path) { continue }
        if pdfRecovery, let resourceID = UUID(uuidString: parts[2]), sharedIDs.contains(resourceID) { continue }
        if attachment || inboxFile, FileManager.default.fileExists(atPath: url.path),
          try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
          throw LibraryError.invalid("Refusing to delete an attachment directory")
        }
        try Files.permanentlyRemove(url)
      }
      try database.remove(plan.id)
      if !plan.paths.isEmpty {
        plan.paths = []
        plan.requestIDs = []
        try Files.atomicWrite(PortableJSON.encoder().encode(plan), to: marker)
        revision += 1
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [plan.id.uuidString], completionHandler: nil)
      }
    }
  }
  public func resolveReview(_ id: UUID, choice: DuplicateChoice) throws {
    guard var r = try sidecars.requests().first(where: { $0.id == id }) else { return }
    r.duplicateChoice = choice
    if choice == .cancel { cancelledRequests.insert(id) }
    if choice == .cancel { r.state = .complete } else { r.state = .discovered }
    r.error = nil
    try sidecars.saveRequest(r)
  }
  public func retry(_ id: UUID) throws {
    guard var r = try sidecars.requests().first(where: { $0.id == id }) else { return }
    r.state = .discovered
    r.error = nil
    r.retryCount += 1
    try sidecars.saveRequest(r)
  }
  public func pollInbox() throws {
    let files = try Files.coordinatedRead(root.appendingPathComponent("Inbox")) {
      try FileManager.default.contentsOfDirectory(
        at: $0,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
    }
    let existing = try sidecars.requests()
    let capturedPaths = Set(existing.compactMap(\.inputFile))
    let now = Date()
    for file in files where file.pathExtension.lowercased() == "pdf" {
      let relative = "Inbox/" + file.lastPathComponent
      if capturedPaths.contains(relative) { continue }
      let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      let size = values.fileSize ?? 0
      let modified = values.contentModificationDate ?? now
      guard size > 0 else { continue }
      if let previous = stableFiles[relative], previous.0 == size, previous.1 == modified,
        now.timeIntervalSince(modified) > 2
      {
        let id = Files.stableID("\(relative):\(size):\(modified.timeIntervalSince1970)")
        if !existing.contains(where: { $0.id == id }) {
          var r = IngestionRequest(source: "hotFolder", file: relative)
          r.id = id
          try sidecars.saveRequest(r)
        }
      }
      stableFiles[relative] = (size, modified)
    }
  }
  private var synchronizingSidecars = false
  public func synchronizeSidecars() async throws {
    guard !synchronizingSidecars else { return }
    let started = ContinuousClock.now
    let interval = signposter.beginInterval("Metadata reconciliation", id: signposter.makeSignpostID())
    defer { signposter.endInterval("Metadata reconciliation", interval); recordTiming("metadataReconciliation", started: started) }
    synchronizingSidecars = true
    defer { synchronizingSidecars = false }
    try reconcilePermanentDeletions()
    if !loadedSidecarStamps {
      for (index, row) in try database.rows("SELECT path,revision FROM sidecar_revisions").enumerated() {
        if index % 100 == 0 { try Task.checkCancellation(); await Task.yield() }
        if let path = row["path"], let encoded = row["revision"],
          let stamp = try? PortableJSON.decoder().decode(Files.Revision.self, from: Data(encoded.utf8)) {
          lastSidecarStamp[path] = stamp
        }
      }
      loadedSidecarStamps = true
    }
    let files = try sidecars.metadataFiles()
    var seen = Set<String>()
    for (index, file) in files.enumerated() {
      if index % 20 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      seen.insert(file.lastPathComponent)
      let stamp = Files.revision(file)
      if stamp == nil || lastSidecarStamp[file.path] != stamp {
        do {
          // A cloud-only sidecar must not block urgent browser captures on this actor.
          let sidecars = self.sidecars
          let item = try await Task.detached(priority: .utility) { try sidecars.read(file) }.value
          // A browser capture or editor may have saved a newer version during that read.
          if let stamp, stamp != Files.revision(file) { continue }
          guard !deletedItems.contains(item.id) else { continue }
          // A cold launch still verifies sidecars, but should not rebuild every unchanged
          // article's author relations and FTS rows before accepting browser captures.
          if try !database.containsSameRecord(item) {
            try database.upsert(item)
            revision += 1
            spotlight(item)
          }
          // Mark only the revision actually read; a concurrent replacement must be read next pass.
          if let stamp, stamp == Files.revision(file) {
            let encoded = String(decoding: try PortableJSON.encoder().encode(stamp), as: UTF8.self)
            _ = try database.rows("INSERT OR REPLACE INTO sidecar_revisions(path,item_id,revision) VALUES(?,?,?)",
              [file.path, item.id.uuidString, encoded])
            lastSidecarStamp[file.path] = stamp
          }
        } catch {
          logger.error(
            "Metadata reconciliation failed: \(error.localizedDescription,privacy:.public)")
        }
      }
    }
    // Removal is never inferred from an incomplete iCloud directory listing. Rebuild reconciles deletions explicitly.
  }
  public func isProcessing() -> Bool { processing }
  public func indexPendingAttachments(limit: Int = 3) async {
    guard !processing && !rebuilding else { return }
    do {
      let rows = try database.rows(
        """
        SELECT DISTINCT r.item_id FROM resources r
        WHERE r.type='pdf' AND r.path IS NOT NULL
          AND NOT EXISTS(SELECT 1 FROM pages p WHERE p.resource_id=r.id)
        LIMIT \(max(1, min(limit, 20)))
        """)
      for row in rows {
        try Task.checkCancellation()
        guard let value = row["item_id"], let id = UUID(uuidString: value),
          let item = try database.item(id) else { continue }
        do { try await indexAttachments(item) }
        catch is CancellationError { return }
        catch {
          logger.error(
            "Deferred PDF indexing failed: \(id.uuidString,privacy:.public) \(error.localizedDescription,privacy:.public)")
        }
      }
    } catch {
      logger.error("Deferred PDF indexing query failed: \(error.localizedDescription,privacy:.public)")
    }
  }
  public func processPending() async {
    guard !processing && !rebuilding else { return }
    processing = true
    defer { processing = false }
    do {
      let requests = try sidecars.requests()
      for request in requests where request.state == .complete {
        cleanupInbox(request)
      }
      for request in requests
      where request.state != .complete && request.state != .awaitingReview
        && (request.state != .failed || request.retryCount < 3)
      {
        // These use their page metadata and ready notification, rather than the network/OCR queue.
        if request.source == "chromeExtensionV2" { continue }
        if permanentlyCancelledRequests.contains(request.id) { continue }
        if Task.isCancelled { return }
        var r = request
        do {
          try await process(&r)
          if r.state == .complete { r.error = nil }
        } catch {
          if error is CancellationError {
            if !permanentlyCancelledRequests.contains(r.id) { try? sidecars.saveRequest(r) }
            return
          }
          r.error = error.localizedDescription
          r.retryCount += 1
          r.state = r.error?.contains("iCloud") == true ? .waitingForResource : .failed
          logger.error(
            "Capture failed: \(r.id.uuidString,privacy:.public) \(error.localizedDescription,privacy:.public)"
          )
        }
        if permanentlyCancelledRequests.contains(r.id) { continue }
        try sidecars.saveRequest(r)
        if r.state == .complete { cleanupInbox(r) }
      }
    } catch {
      logger.error("Queue processing failed: \(error.localizedDescription,privacy:.public)")
    }
  }
  private func stage(_ state: IngestionState, _ request: inout IngestionRequest) throws {
    guard !permanentlyCancelledRequests.contains(request.id) else { throw CancellationError() }
    if let id = request.resultID, deletedItems.contains(id) { throw CancellationError() }
    request.state = state
    try sidecars.saveRequest(request)
  }
  private func cleanupInbox(_ request: IngestionRequest) {
    guard request.inboxCleanupComplete != true, request.duplicateChoice != .cancel,
      let path = request.inputFile, path.split(separator: "/").count == 2,
      path.hasPrefix("Inbox/"), let resultID = request.resultID
    else { return }
    do {
      let source = try Files.safeURL(root: root, relative: path)
      let inbox = root.appendingPathComponent("Inbox").resolvingSymlinksInPath()
      guard source.deletingLastPathComponent().path == inbox.path else { return }
      var completed = request
      if !FileManager.default.fileExists(atPath: source.path) {
        completed.inboxCleanupComplete = true
        try sidecars.saveRequest(completed)
        return
      }
      // Verify the organized attachment; annotated copies also require a verified original backup.
      guard FileManager.default.fileExists(atPath: sidecars.url(resultID).path) else { return }
      let item = try sidecars.read(sidecars.url(resultID))
      let hash = try Files.coordinatedRead(source) { try Files.hash($0) }
      for resource in item.resources
      where resource.sha256 == hash || resource.originalSHA256 == hash {
        guard let organizedPath = resource.relativePath, organizedPath.hasPrefix("PDFs/")
        else { continue }
        let organized = try Files.safeURL(root: root, relative: organizedPath)
        guard organized != source, !organized.path.hasPrefix(inbox.path + "/"),
          FileManager.default.fileExists(atPath: organized.path)
        else { continue }
        try Files.materialize(organized)
        let organizedHash = resource.sha256 ?? hash
        if organizedHash != hash {
          let backup = root.appendingPathComponent("Recovery/PDFs/\(resource.id)/\(hash).pdf")
          guard FileManager.default.fileExists(atPath: backup.path) else { continue }
          try Files.materialize(backup)
          guard try Files.coordinatedRead(backup, { try Files.hash($0) }) == hash else { continue }
        }
        var coordinationError: NSError?
        var deletion: Result<Bool, Error>?
        NSFileCoordinator().coordinate(
          readingItemAt: organized, options: [], writingItemAt: source, options: .forDeleting,
          error: &coordinationError
        ) { copy, original in
          deletion = Result {
            guard try Files.hash(copy) == organizedHash, try Files.hash(original) == hash else {
              return false
            }
            try FileManager.default.removeItem(at: original)
            return true
          }
        }
        if let coordinationError { throw coordinationError }
        if try deletion?.get() == true {
          completed.inboxCleanupComplete = true
          try sidecars.saveRequest(completed)
          return
        }
      }
    } catch {
      // Cleanup can retry after restart without turning a successful import into a failed one.
      logger.error(
        "Inbox cleanup deferred: \(request.id.uuidString,privacy:.public) \(error.localizedDescription,privacy:.public)"
      )
    }
  }
  /// A sidecar is the commit point; the queue journal makes a copied-but-uncommitted PDF recoverable.
  private func finishImportCommit(_ request: inout IngestionRequest, indexNow: Bool = true) async throws {
    let started = ContinuousClock.now
    let interval = signposter.beginInterval("Import commit", id: signposter.makeSignpostID())
    defer { signposter.endInterval("Import commit", interval); recordTiming("importCommit", started: started) }
    guard let checkpoint = request.importCommit,
      let path = checkpoint.resource.relativePath, let expected = checkpoint.resource.sha256,
      let input = request.inputFile else { throw LibraryError.invalid("Incomplete import checkpoint") }
    try stage(.importing, &request)
    let destination = try Files.safeURL(root: root, relative: path)
    let source = try Files.safeURL(root: root, relative: input)
    let committed = FileManager.default.fileExists(atPath: sidecars.url(checkpoint.item.id).path)
      ? try sidecars.read(sidecars.url(checkpoint.item.id)) : nil
    let annotated = committed?.resources.first {
      $0.id == checkpoint.resource.id && $0.relativePath == path && $0.originalSHA256 == expected
    }?.sha256
    let recovery = root.appendingPathComponent("Recovery/PDFs/\(checkpoint.resource.id)/\(expected).pdf")
    let copy = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: destination.path) {
        try Files.materialize(destination)
        let currentHash = try Files.coordinatedRead(destination, { try Files.hash($0) })
        if currentHash != expected {
          guard currentHash == annotated, FileManager.default.fileExists(atPath: recovery.path) else {
            throw LibraryError.conflict("The organized copy changed during import. Original retained for review.")
          }
          try Files.materialize(recovery)
          guard try Files.coordinatedRead(recovery, { try Files.hash($0) }) == expected else {
            throw LibraryError.conflict("The pre-edit recovery copy could not be verified. Original retained.")
          }
        }
      } else {
        try Files.materialize(source)
        try Files.installVerifiedCopy(source, to: destination, expectedHash: expected)
      }
    }
    try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
    try Task.checkCancellation()
    try importFault?(.copied)
    guard !deletedItems.contains(checkpoint.item.id), !permanentlyCancelledRequests.contains(request.id)
    else { throw CancellationError() }
    // Existing sidecars win: never replay stale notes or metadata over edits made after the crash.
    var item = FileManager.default.fileExists(atPath: sidecars.url(checkpoint.item.id).path)
      ? try sidecars.read(sidecars.url(checkpoint.item.id)) : checkpoint.item
    if let base = checkpoint.baseRecordHash,
      Files.digest(try PortableJSON.encoder().encode(item)) == base {
      item = checkpoint.item
    }
    if !item.resources.contains(where: {
      $0.id == checkpoint.resource.id || $0.sha256 == expected || $0.originalSHA256 == expected
    }) { item.resources.append(checkpoint.resource) }
    item.dateModified = Date()
    try save(item)
    try importFault?(.metadataSaved)
    request.resultID = item.id
    if indexNow {
      try stage(.extractingText, &request)
      try await indexAttachments(item)
    }
    if cancelledRequests.contains(request.id) || deletedItems.contains(item.id) {
      request.duplicateChoice = .cancel
    }
    request.importCommit = nil
    try stage(.complete, &request)
  }
  private func process(_ request: inout IngestionRequest) async throws {
    if request.duplicateChoice == .cancel {
      request.state = .complete
      return
    }
    if request.importCommit != nil {
      try await finishImportCommit(&request)
      return
    }
    try stage(.extractingIdentifiers, &request)
    var candidate = LibraryItem(id: request.id, title: request.suggestedTitle ?? "Untitled")
    candidate.tags = request.suggestedTags
    candidate.collections = request.suggestedCollection.map { [$0] } ?? []
    candidate.notes = request.note
    var input = request.inputText ?? request.inputURL ?? ""
    var file: URL?
    var hash: String?
    if let path = request.inputFile {
      file = try Files.safeURL(root: root, relative: path)
      try Files.materialize(file!)
      try stage(.hashing, &request)
      hash = try Files.coordinatedRead(file!) { try Files.hash($0) }
      if let duplicate = try database.exactDuplicate(hash: hash!),
        request.duplicateChoice != .keepBoth
      {
        request.resultID = duplicate
        try stage(.extractingText, &request)
        if var existing = try database.item(duplicate) {
          existing = await metadata.resolve(existing)
          existing.tags = Array(Set(existing.tags + request.suggestedTags)).sorted()
          if let collection = request.suggestedCollection {
            existing.collections = Array(Set(existing.collections + [collection])).sorted()
          }
          if !request.note.isEmpty, !existing.notes.contains(request.note) {
            existing.notes += (existing.notes.isEmpty ? "" : "\n") + request.note
          }
          existing.dateModified = Date()
          try save(existing)
          try await indexAttachments(existing)
        }
        try stage(.complete, &request)
        return
      }
      candidate.title = request.suggestedTitle ?? file!.deletingPathExtension().lastPathComponent
      if file!.pathExtension.lowercased() == "pdf" {
        let extracted = try extraction.identifiers(url: file!)
        input += "\n" + extracted
        if request.suggestedTitle == nil || request.titleIsFilename == true {
          if let seed = try extraction.metadataSeed(url: file!) {
            candidate = MetadataResolutionService.merge(candidate, seed)
          } else if let title = extracted.components(separatedBy: .newlines).first(where: {
            MetadataResolutionService.searchableTitle($0) && Identifiers.doi($0) == nil
              && !$0.lowercased().hasPrefix("abstract")
          }) {
            candidate.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
      } else {
        candidate.type = .genericDocument
      }
    }
    candidate.pmcid = Identifiers.pmcid(input)
    candidate.doi = request.doi.flatMap(Identifiers.doi) ?? Identifiers.doi(input)
    candidate.pmid = request.pmid ?? Identifiers.pmid(input)
    candidate.arxivID = Identifiers.arxiv(input)
    if candidate.doi == nil && candidate.pmid == nil
      && input.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy(\.isNumber)
      && !input.isEmpty
    {
      candidate.pmid = input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var remote: URL?
    if let supplied = request.inputURL ?? (input.hasPrefix("http") && file == nil ? input : nil) {
      remote = try Identifiers.canonicalURL(supplied)
      candidate.canonicalURL = remote!.absoluteString
      if candidate.title == "Untitled" { candidate.title = remote!.host ?? supplied }
      candidate.resources.append(
        Resource(itemID: candidate.id, type: .publisherPage, url: remote!.absoluteString))
    }
    if remote == nil, let doi = candidate.doi {
      candidate.canonicalURL = "https://doi.org/\(doi)"
      candidate.resources.append(
        Resource(itemID: candidate.id, type: .doi, url: candidate.canonicalURL))
    }
    if remote == nil, let pmid = candidate.pmid {
      candidate.canonicalURL = "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/"
      candidate.resources.append(
        Resource(itemID: candidate.id, type: .pubmed, url: candidate.canonicalURL))
    }
    if let arxiv = candidate.arxivID {
      candidate.canonicalURL = candidate.canonicalURL ?? "https://arxiv.org/abs/\(arxiv)"
    }
    if candidate.title == "Untitled", !input.isEmpty { candidate.title = String(input.prefix(200)) }
    try stage(.resolvingMetadata, &request)
    candidate = await metadata.resolve(candidate)
    if let remote, file == nil {
      do {
        let (data, response) = try await transport.data(remote)
        let mime = response.mimeType?.lowercased() ?? ""
        if mime == "application/pdf" || data.starts(with: Data("%PDF-".utf8)) {
          let downloaded = root.appendingPathComponent("Inbox/\(request.id).pdf")
          try Files.atomicWrite(data, to: downloaded)
          let identifiers = try extraction.identifiers(url: downloaded)
          file = downloaded
          request.inputFile = "Inbox/\(downloaded.lastPathComponent)"
          try sidecars.saveRequest(request)
          hash = try Files.hash(downloaded)
          if candidate.doi == nil {
            candidate.doi = Identifiers.doi(identifiers)
            candidate = await metadata.resolve(candidate)
          }
        } else if let html = String(data: data, encoding: .utf8) {
          if candidate.doi == nil,
            let doi = WebMetadata.meta("citation_doi", html: html)
              ?? WebMetadata.meta("dc.identifier", html: html)
          {
            candidate.doi = Identifiers.doi(doi)
            candidate = await metadata.resolve(candidate)
          }
          if let pdfLink = WebMetadata.meta("citation_pdf_url", html: html),
            let linked = URL(string: pdfLink, relativeTo: remote)?.absoluteURL,
            let safe = try? Identifiers.canonicalURL(linked.absoluteString)
          {
            do {
              let (pdfData, pdfResponse) = try await transport.data(safe)
              if pdfResponse.mimeType == "application/pdf"
                || pdfData.starts(with: Data("%PDF-".utf8))
              {
                let target = root.appendingPathComponent("Inbox/\(request.id).pdf")
                try Files.atomicWrite(pdfData, to: target)
                _ = try extraction.identifiers(url: target)
                file = target
                request.inputFile = "Inbox/\(target.lastPathComponent)"
                try sidecars.saveRequest(request)
                hash = try Files.hash(target)
              }
            } catch {
              candidate.provenance.append(
                Provenance("PDF link", "Accessible PDF unavailable; URL retained"))
            }
          }
          if candidate.title == remote.host,
            let title = Identifiers.capture("<title[^>]*>(.*?)</title>", html, group: 1)
          {
            candidate.title = title
          }
        }
      } catch {
        candidate.resources = candidate.resources.map {
          var r = $0
          r.availability =
            error.localizedDescription.contains("401") || error.localizedDescription.contains("403")
            ? .requiresAuthentication : .unavailable
          return r
        }
        candidate.provenance.append(
          Provenance("URL", "Page unavailable; bibliographic record retained"))
      }
    }
    try Task.checkCancellation()
    if cancelledRequests.contains(request.id) {
      request.state = .complete
      request.duplicateChoice = .cancel
      return
    }
    try stage(.checkingDuplicates, &request)
    var target = try request.resultID ?? database.item(request.id)?.id
    if target == nil, request.duplicateChoice != .keepBoth {
      target = try database.identifierDuplicate(candidate)
    }
    if target == nil, let hash, request.duplicateChoice != .keepBoth {
      target = try database.exactDuplicate(hash: hash)
    }
    if request.duplicateChoice == .attach { target = request.candidateID ?? target }
    if target == nil, request.duplicateChoice == .automatic,
      let possible = try database.titleDuplicate(candidate)
    {
      request.candidateID = possible
      request.error =
        "Possible title/year duplicate. Choose Attach to Existing, Keep Both, or Cancel."
      try stage(.awaitingReview, &request)
      return
    }
    var item =
      try target.flatMap { id in
        let url = sidecars.url(id)
        return FileManager.default.fileExists(atPath: url.path)
          ? try sidecars.read(url) : try database.item(id)
      } ?? candidate
    guard !deletedItems.contains(item.id) else { throw CancellationError() }
    let baseRecordHash = target == nil ? nil : Files.digest(try PortableJSON.encoder().encode(item))
    if item.id != candidate.id {
      item = MetadataResolutionService.merge(item, candidate)
    }
    item.tags = Array(Set(item.tags + request.suggestedTags)).sorted()
    item.collections = Array(Set(item.collections + candidate.collections)).sorted()
    if item.id != candidate.id, !request.note.isEmpty, !item.notes.contains(request.note) {
      item.notes += (item.notes.isEmpty ? "" : "\n") + request.note
    }
    for r in candidate.resources
    where !item.resources.contains(where: { $0.remoteURL == r.remoteURL }) {
      var value = r
      value.itemID = item.id
      item.resources.append(value)
    }
    if let file, let hash, !item.resources.contains(where: { $0.sha256 == hash || $0.originalSHA256 == hash }) {
      let pattern = UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}"
      let isPDF = file.pathExtension.lowercased() == "pdf"
      let filename = isPDF ? Files.filename(item, pattern: pattern) : Files.sanitized(file.lastPathComponent)
      // A unique suffix belongs to the durable plan, not to each retry.
      let base = root.appendingPathComponent("PDFs").appendingPathComponent(filename)
      let previous = FileManager.default.fileExists(atPath: base.path) && (try? Files.hash(base)) == hash
      let destination = previous ? base : Files.uniqueURL(base)
      var resource = Resource(itemID: item.id, type: isPDF ? .pdf : .other,
        path: "PDFs/" + destination.lastPathComponent, availability: .local)
      resource.sha256 = hash
      resource.mimeType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
      resource.primary = !item.hasPDF
      resource.source = request.source
      request.importCommit = ImportCommitCheckpoint(item: item, resource: resource, baseRecordHash: baseRecordHash)
      request.resultID = item.id
      try stage(.importing, &request)
      try importFault?(.planned)
      try await finishImportCommit(&request)
      return
    }
    item.dateModified = Date()
    try save(item)
    request.resultID = item.id
    try sidecars.saveRequest(request)
    try stage(.extractingText, &request)
    try await indexAttachments(item)
    if cancelledRequests.contains(request.id) || deletedItems.contains(item.id) {
      request.state = .complete
      request.duplicateChoice = .cancel
      return
    }
    try stage(.indexing, &request)
    spotlight(item)
    try stage(.complete, &request)
  }
  private func indexAttachments(_ item: LibraryItem) async throws {
    for resource in item.resources where resource.type == .pdf {
      guard let path = resource.relativePath else { continue }
      let url = try Files.safeURL(root: root, relative: path)
      let extraction = self.extraction
      let task = Task.detached(priority: .utility) {
        let pages = try extraction.extract(url: url, itemID: item.id, resourceID: resource.id)
        let sections = TextDerivation.sections(pages)
        let chunks = TextDerivation.chunks(pages, sections: sections)
        return (pages, sections, chunks)
      }
      let (pages, sections, chunks) = try await withTaskCancellationHandler(
        operation: { try await task.value }, onCancel: { task.cancel() })
      guard !deletedItems.contains(item.id) else { return }
      try database.index(
        pages: pages, sections: sections, chunks: chunks, itemID: item.id, resourceID: resource.id)
      revision += 1
    }
  }
  public func captureFile(_ url: URL, attachTo: UUID? = nil) throws -> UUID {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw LibraryError.invalid("Select a regular file")
    }
    var request = IngestionRequest(source: "filePicker")
    request.suggestedTitle = url.deletingPathExtension().lastPathComponent
    request.titleIsFilename = true
    let destination = root.appendingPathComponent(
      "Inbox/\(request.id)-" + Files.sanitized(url.lastPathComponent))
    try Files.coordinatedRead(url) { try Files.atomicWrite(Data(contentsOf: $0), to: destination) }
    request.inputFile = "Inbox/" + destination.lastPathComponent
    if let attachTo {
      request.resultID = attachTo
      request.duplicateChoice = .attach
    }
    try submit(request)
    return request.id
  }
  private func resetSpotlight() {
    // Spotlight is an optional derived service and must never gate local recovery.
    CSSearchableIndex.default().deleteSearchableItems(
      withDomainIdentifiers: [Files.stableID(root.path).uuidString]) { error in
        if let error {
          Logger(subsystem: "org.researchlibrary.app", category: "Spotlight").error(
            "Spotlight reset failed: \(error.localizedDescription,privacy:.public)")
        }
      }
  }
  public func rebuild() async throws -> [IntegrityIssue] {
    guard !processing && !rebuilding else {
      throw LibraryError.invalid("Wait for processing to finish before rebuilding")
    }
    rebuilding = true
    defer { rebuilding = false }
    try reconcilePermanentDeletions()
    var issues: [IntegrityIssue] = []
    let files = try sidecars.metadataFiles()
    var items: [LibraryItem] = []
    for file in files {
      do {
        let item = try sidecars.read(file)
        if !deletedItems.contains(item.id) { items.append(item) }
      } catch {
        issues.append(
          IntegrityIssue(path: file.lastPathComponent, message: error.localizedDescription))
      }
    }
    try database.reset()
    lastSidecarStamp.removeAll()
    revision += 1
    resetSpotlight()
    // Pass 1: restore every item's metadata so the library is fully browsable and
    // searchable by metadata quickly. One bad item is recorded and skipped, never fatal.
    var restored: [LibraryItem] = []
    for var item in items {
      do {
        for index in item.resources.indices {
          if let path = item.resources[index].relativePath,
            !FileManager.default.fileExists(
              atPath: (try Files.safeURL(root: root, relative: path)).path)
          {
            item.resources[index].availability = .missing
          }
        }
        try database.upsert(item)
        restored.append(item)
        spotlight(item)
      } catch {
        issues.append(IntegrityIssue(path: item.id.uuidString, message: error.localizedDescription))
      }
    }
    revision += 1
    // Pass 2: PDF text (slow; OCR for scans).
    for (position, item) in restored.enumerated() {
      if position % 10 == 0 { try Task.checkCancellation(); await Task.yield() }
      do { try await indexAttachments(item) } catch is CancellationError { throw CancellationError() }
      catch {
        issues.append(IntegrityIssue(path: item.id.uuidString, message: error.localizedDescription))
      }
    }
    return issues
  }
  public func integrity() throws -> [IntegrityIssue] {
    var issues: [IntegrityIssue] = []
    var referenced = Set<String>()
    var hashes: [String: String] = [:]
    for file in try sidecars.metadataFiles() {
      do {
        let item = try sidecars.read(file)
        for r in item.resources {
          guard let path = r.relativePath else { continue }
          referenced.insert(path)
          do {
            let url = try Files.safeURL(root: root, relative: path)
            if !FileManager.default.fileExists(atPath: url.path) {
              issues.append(IntegrityIssue(path: path, message: "Missing attachment"))
              continue
            }
            if let hash = r.sha256 {
              if let other = hashes[hash] {
                issues.append(IntegrityIssue(path: path, message: "Duplicate hash with \(other)"))
              }
              hashes[hash] = path
              if try Files.hash(url) != hash {
                issues.append(IntegrityIssue(path: path, message: "Attachment hash mismatch"))
              }
            }
          } catch { issues.append(IntegrityIssue(path: path, message: error.localizedDescription)) }
        }
        if item.resources.isEmpty { /* PDF-less items are valid. */  }
      } catch {
        issues.append(
          IntegrityIssue(path: file.lastPathComponent, message: error.localizedDescription))
      }
    }
    for url in try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("Inbox/Requests"), includingPropertiesForKeys: nil)
    where url.pathExtension == "json" {
      do {
        _ = try PortableJSON.decoder().decode(IngestionRequest.self, from: Data(contentsOf: url))
      } catch {
        issues.append(
          IntegrityIssue(
            path: "Inbox/Requests/" + url.lastPathComponent,
            message: "Malformed capture request: \(error.localizedDescription)"))
      }
    }
    for url in try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("PDFs"), includingPropertiesForKeys: nil)
    {
      if !referenced.contains("PDFs/" + url.lastPathComponent) {
        issues.append(
          IntegrityIssue(
            path: "PDFs/" + url.lastPathComponent,
            message: "Orphan attachment; retained for recovery"))
      }
    }
    return issues
  }
  public func attachSupplement(_ url: URL, to id: UUID) throws {
    guard var item = try database.item(id) else {
      throw LibraryError.invalid("Item no longer exists")
    }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let name = Files.sanitized(url.lastPathComponent)
    let target = Files.uniqueURL(root.appendingPathComponent("PDFs").appendingPathComponent(name))
    try Files.coordinatedRead(url) { source in
      try Files.atomicWrite(Data(contentsOf: source), to: target)
    }
    var resource = Resource(
      itemID: id, type: .supplement, path: "PDFs/" + target.lastPathComponent, availability: .local)
    resource.sha256 = try Files.hash(target)
    resource.mimeType = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType
    item.resources.append(resource)
    item.dateModified = Date()
    try save(item)
  }
  public func organizeFiles(_ id: UUID) throws {
    guard var item = try database.item(id) else { return }
    let pattern =
      UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}"
    for i in item.resources.indices where item.resources[i].type == .pdf {
      guard let path = item.resources[i].relativePath else { continue }
      let old = try Files.safeURL(root: root, relative: path)
      let base = root.appendingPathComponent("PDFs").appendingPathComponent(
        Files.filename(item, pattern: pattern))
      if old == base { continue }
      let target = Files.uniqueURL(base)
      try Files.coordinatedRead(old) { try Files.atomicWrite(Data(contentsOf: $0), to: target) }
      item.resources[i].relativePath = "PDFs/" + target.lastPathComponent
      item.dateModified = Date()
      try save(item)
      // Retain prior attachments in Recovery; other records may still refer to the original path.
    }
  }
  public func export(format: ExportFormat) throws -> URL {
    let items = try sidecars.metadataFiles().map { try sidecars.read($0) }
    let data = try ExportService.encode(items, format: format)
    let url = root.appendingPathComponent(
      "Exports/Research Library-\(Int(Date().timeIntervalSince1970)).\(format.rawValue)")
    try Files.atomicWrite(data, to: url)
    return url
  }
  /// Recovery snapshot of the last synchronized local index, without hydrating cloud sidecars.
  public func exportCachedSnapshot(to url: URL) throws {
    try reconcilePermanentDeletions()
    let items = try database.rows("SELECT json FROM items ORDER BY id").compactMap { row in
      try row["json"].map {
        try PortableJSON.decoder().decode(LibraryItem.self, from: Data($0.utf8))
      }
    }
    try Files.atomicWrite(ExportService.encode(items, format: .json), to: url)
  }
  public func diagnostics() throws -> URL {
    let counts =
      try database.rows(
        "SELECT (SELECT count(*) FROM items) AS items,(SELECT count(*) FROM resources) AS resources,(SELECT count(*) FROM chunks) AS chunks"
      ).first ?? [:]
    let requestStates = Dictionary(grouping: try sidecars.requests(), by: { $0.state.rawValue })
      .mapValues { $0.count }
    let report: [String: Any] = [
      "applicationVersion": "1.0", "system": ProcessInfo.processInfo.operatingSystemVersionString,
      "schemaVersion": database.schemaVersion, "counts": counts, "captureStates": requestStates,
      "sessionOperationTimings": operationTimings,
      "integrityIssues": try integrity().map { ["path": $0.path, "message": $0.message] },
    ]
    let url = root.appendingPathComponent(
      "Exports/Diagnostics-\(Int(Date().timeIntervalSince1970)).json")
    try Files.atomicWrite(
      JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
      to: url)
    return url
  }
  public func resolvePDF(_ id: UUID, retry: Bool = false) async throws -> LibraryItem {
    let started = ContinuousClock.now
    let interval = signposter.beginInterval("PDF lookup", id: signposter.makeSignpostID())
    defer { signposter.endInterval("PDF lookup", interval); recordTiming("pdfLookup", started: started) }
    if let task = pdfLookups[id] { return try await task.value }
    let task = Task { try await self.locatePDF(id, retry: retry) }
    pdfLookups[id] = task
    defer { pdfLookups[id] = nil }
    return try await task.value
  }
  private func recordPDFLookup(_ id: UUID, _ status: PDFLookupStatus, _ detail: String) throws -> LibraryItem {
    guard !deletedItems.contains(id), var current = try database.item(id) else { throw CancellationError() }
    for index in current.resources.indices where current.resources[index].type == .pdf {
      if let path = current.resources[index].relativePath, let file = try? Files.safeURL(root: root, relative: path),
        !FileManager.default.fileExists(atPath: file.path) { current.resources[index].availability = .missing }
    }
    current.pdfLookup = PDFLookup(status, detail: detail, checkedAt: Date())
    current.dateModified = Date()
    try save(current)
    return current
  }
  private func attachLocatedPDF(
    _ data: Data?, file: URL?, remote: URL?, id: UUID, index: Bool = true
  ) async throws -> LibraryItem {
    guard !deletedItems.contains(id), var current = try database.item(id) else { throw CancellationError() }
    let managed = root.appendingPathComponent("PDFs").resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let target: URL
    if let file, file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(managed) {
      target = file
    } else if let data {
      target = Files.uniqueURL(root.appendingPathComponent("PDFs/" + Files.filename(current,
        pattern: UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}")))
      try Files.atomicWrite(data, to: target)
    } else if let file {
      target = Files.uniqueURL(root.appendingPathComponent("PDFs/" + Files.filename(current,
        pattern: UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}")))
      try Files.atomicCopy(file, to: target)
    } else {
      throw LibraryError.invalid("PDF data is unavailable")
    }
    let path = String(target.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
    if !current.resources.contains(where: { $0.relativePath == path }) {
      var resource = Resource(itemID: id, type: .pdf, url: remote?.absoluteString, path: path, availability: .local)
      resource.mimeType = "application/pdf"; resource.primary = true
      resource.sha256 = try Files.hash(target)
      resource.source = remote == nil ? "iCloud/library match" : "Online PDF lookup"
      current.resources.append(resource)
    }
    current.pdfLookup = PDFLookup(.available, detail: remote == nil ? "PDF found in your library folder." : "PDF retrieved online and saved to your library.", checkedAt: Date())
    current.dateModified = Date()
    try await saveCoordinatedInBackground(current)
    if index { Task { try? await self.indexAttachments(current) } }
    return current
  }

  #if os(macOS)
  private struct ArchiveAttachment: Sendable {
    var file: URL
    var review: URL
    var itemID: UUID
  }
  private nonisolated static func archiveFiles(_ extracted: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: extracted, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]) else { throw LibraryError.invalid("Could not inspect extracted ZIP") }
    var files: [URL] = []
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
      if values.isRegularFile == true { files.append(file) }
    }
    return files
  }
  public func processInboxArchives() async throws -> InboxArchiveReport {
    try reconcilePermanentDeletions()
    let inbox = root.appendingPathComponent("Inbox")
    let archives = try Files.coordinatedRead(inbox) {
      try FileManager.default.contentsOfDirectory(
        at: $0, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
      ).filter { $0.pathExtension.lowercased() == "zip" }
    }
    var report = InboxArchiveReport()
    let items = try database.rows("SELECT json FROM items").compactMap { row in
      try row["json"].map { try PortableJSON.decoder().decode(LibraryItem.self, from: Data($0.utf8)) }
    }
    var paths: [String: Set<UUID>] = [:]
    var names: [String: Set<UUID>] = [:]
    for item in items {
      for hint in item.pdfFilenameHints ?? [] {
        let key = hint.replacingOccurrences(of: "\\", with: "/").lowercased()
        paths[key, default: []].insert(item.id)
        names[URL(fileURLWithPath: hint).lastPathComponent.lowercased(), default: []].insert(item.id)
      }
    }
    for archive in archives.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      try Task.checkCancellation()
      let work = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ResearchLibraryArchive-" + UUID().uuidString, isDirectory: true)
      let localArchive = work.appendingPathComponent("upload.zip")
      let extracted = work.appendingPathComponent("contents", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: work) }
      try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
      let deadline = Date().addingTimeInterval(600)
      while true {
        do { try Files.materialize(archive); break }
        catch is ResourceDownloadPending {
          guard Date() < deadline else {
            throw LibraryError.invalid("An Inbox ZIP is still downloading from iCloud; retry after it finishes.")
          }
          try await Task.sleep(for: .seconds(1))
        }
      }
      try Files.atomicCopy(archive, to: localArchive)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-x", "-k", localArchive.path, extracted.path]
      let errors = Pipe(); process.standardError = errors
      try process.run(); process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw LibraryError.invalid("Could not extract \(archive.lastPathComponent): \(message)")
      }
      let files = try Self.archiveFiles(extracted)
      let reviewRoot = root.appendingPathComponent("Needs Review/Paperpile ZIPs/")
        .appendingPathComponent(Files.sanitized(archive.deletingPathExtension().lastPathComponent))
      var attachments: [ArchiveAttachment] = []
      var lost = 0
      for (position, file) in files.enumerated() {
        if position % 20 == 0 { try Task.checkCancellation(); await Task.yield() }
        let relative = String(file.path.dropFirst(extracted.path.count + 1))
        let review = relative.split(separator: "/").reduce(reviewRoot) {
          $0.appendingPathComponent(Files.sanitized(String($1)))
        }
        guard file.pathExtension.lowercased() == "pdf" else {
          try Files.atomicCopy(file, to: Files.uniqueURL(review))
          report.otherFiles += 1
          continue
        }
        report.PDFs += 1
        let normalized = relative.replacingOccurrences(of: "\\", with: "/").lowercased()
        let components = normalized.split(separator: "/")
        var candidates = Set<UUID>()
        for index in components.indices {
          candidates.formUnion(paths[components[index...].joined(separator: "/")] ?? [])
        }
        if candidates.isEmpty {
          candidates = names[file.lastPathComponent.lowercased()] ?? []
        }
        if candidates.count > 1 {
          candidates = Set(candidates.filter { id in
            guard let item = try? database.item(id) else { return false }
            return (try? PDFDiscovery.validate(file, item: item, authoritative: false)) != nil
          })
        }
        if candidates.isEmpty, let doi = PDFDiscovery.doi(file) {
          var probe = LibraryItem(title: file.deletingPathExtension().lastPathComponent)
          probe.doi = doi
          if let id = try database.identifierDuplicate(probe) { candidates.insert(id) }
        }
        guard candidates.count == 1, let id = candidates.first, let item = try database.item(id) else {
          try Files.atomicCopy(file, to: Files.uniqueURL(review))
          report.needsReview += 1
          continue
        }
        do {
          try PDFDiscovery.validate(file, item: item, authoritative: true)
          let hash = try Files.hash(file)
          if let duplicate = try database.exactDuplicate(hash: hash),
            let existing = try database.item(duplicate),
            let resource = existing.resources.first(where: { $0.sha256 == hash }),
            let path = resource.relativePath {
            if duplicate != id {
              attachments.append(ArchiveAttachment(
                file: try Files.safeURL(root: root, relative: path), review: review, itemID: id))
            } else { report.alreadyPresent += 1 }
          } else {
            attachments.append(ArchiveAttachment(file: file, review: review, itemID: id))
          }
        } catch {
          try Files.atomicCopy(file, to: Files.uniqueURL(review))
          report.needsReview += 1
        }
      }
      let grouped = Dictionary(grouping: attachments, by: \.itemID).map(\.value)
      for start in stride(from: 0, to: grouped.count, by: 8) {
        let end = min(start + 8, grouped.count)
        let batch = Array(grouped[start..<end])
        await withTaskGroup(of: (Int, Int, Int).self) { group in
          for records in batch {
            group.addTask {
              var attached = 0
              var review = 0
              var unplaced = 0
              for record in records {
                do {
                  _ = try await self.attachLocatedPDF(
                    nil, file: record.file, remote: nil, id: record.itemID, index: false)
                  attached += 1
                } catch {
                  do {
                    try Files.atomicCopy(record.file, to: Files.uniqueURL(record.review))
                    review += 1
                  } catch { unplaced += 1 }  // e.g. disk full: neither attached nor set aside
                }
              }
              return (attached, review, unplaced)
            }
          }
          for await outcome in group {
            report.attached += outcome.0
            report.needsReview += outcome.1
            lost += outcome.2
          }
        }
      }
      report.archives += 1
      if lost == 0 {
        try Files.permanentlyRemove(archive)
        report.removedArchives.append(archive.lastPathComponent)
      } else {
        // Some PDFs exist only inside the archive now. Keep it, out of the Inbox so it isn't
        // reprocessed; if even that fails, it stays in the Inbox untouched.
        let kept = Files.uniqueURL(reviewRoot.appendingPathComponent(archive.lastPathComponent))
        try Files.atomicCopy(archive, to: kept)
        try Files.permanentlyRemove(archive)
        report.keptArchives.append(archive.lastPathComponent)
      }
    }
    pdfCatalog = nil
    return report
  }
  #endif
  @discardableResult private func updateAttachmentAvailability(
    _ id: UUID, resourceID: UUID, availability: Availability, lookup: PDFLookup? = nil
  ) throws -> LibraryItem {
    guard !deletedItems.contains(id), var current = try database.item(id),
      let index = current.resources.firstIndex(where: { $0.id == resourceID }) else { throw CancellationError() }
    guard current.resources[index].availability != availability || (lookup != nil && current.pdfLookup != lookup)
    else { return current }
    current.resources[index].availability = availability
    if let lookup { current.pdfLookup = lookup }
    current.dateModified = Date()
    try save(current)
    return current
  }
  private func locatePDF(_ id: UUID, retry: Bool) async throws -> LibraryItem {
    guard !deletedItems.contains(id), let item = try database.item(id) else { throw CancellationError() }
    var invalidAttachment: String?
    for resource in item.resources where resource.type == .pdf {
      guard let path = resource.relativePath,
        let file = try? Files.safeURL(root: root, relative: path) else { continue }
      guard FileManager.default.fileExists(atPath: file.path) else {
        _ = try updateAttachmentAvailability(id, resourceID: resource.id, availability: .missing)
        continue
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(300))
      while true {
        do {
          let stamp = Files.revision(file)
          let hash: String
          if let cached = verifiedPDFs[resource.id], cached.path == path,
            cached.revision == stamp, Files.hasResidentData(file) {
            hash = cached.hash
          } else {
            let verification = Task.detached(priority: .userInitiated) {
              try Task.checkCancellation()
              try Files.materialize(file)
              return try Files.coordinatedRead(file) { url in
                let before = Files.revision(url)
                try PDFDiscovery.validate(url, item: item, authoritative: true)
                let hash = try Files.hash(url)
                guard let before, before == Files.revision(url) else {
                  throw LibraryError.conflict("The PDF changed during verification. Open it again.")
                }
                return (hash, before)
              }
            }
            let result = try await withTaskCancellationHandler(
              operation: { try await verification.value }, onCancel: { verification.cancel() })
            hash = result.0
            try Task.checkCancellation()
            if result.1 == Files.revision(file) {
              if verifiedPDFs.count >= 64 { verifiedPDFs.removeAll(keepingCapacity: true) }
              verifiedPDFs[resource.id] = (path, result.1, hash)
            }
          }
          guard !deletedItems.contains(id), var current = try database.item(id),
            let index = current.resources.firstIndex(where: { $0.id == resource.id }),
            current.resources[index].relativePath == path else { throw CancellationError() }
          // A reader save or attachment replacement can complete during validation.
          guard current.resources[index].sha256 == resource.sha256 else {
            verifiedPDFs[resource.id] = nil
            throw LibraryError.conflict("The PDF changed while being checked. Open it again.")
          }
          if current.resources[index].sha256 != hash {
            current.resources[index].originalSHA256 = current.resources[index].originalSHA256 ?? resource.sha256
            current.resources[index].sha256 = hash
          }
          if current.resources[index].availability != .local || current.pdfLookup?.status != .available
            || current.resources[index].sha256 != resource.sha256 {
            current.resources[index].availability = .local
            current.pdfLookup = PDFLookup(.available, detail: "PDF verified in your library folder.", checkedAt: Date())
            current.dateModified = Date()
            try save(current)
          }
          return current
        } catch is ResourceDownloadPending {
          _ = try updateAttachmentAvailability(id, resourceID: resource.id, availability: .remote,
            lookup: PDFLookup(.pending, detail: "Downloading this PDF from iCloud…"))
          guard ContinuousClock.now < deadline else {
            return try recordPDFLookup(id, .retry, "iCloud download has not finished. Check your connection and try again.")
          }
          try await Task.sleep(for: .seconds(1))
        } catch is CancellationError { throw CancellationError() }
        catch {
          verifiedPDFs[resource.id] = nil
          invalidAttachment = error.localizedDescription
          _ = try updateAttachmentAvailability(id, resourceID: resource.id, availability: .unavailable)
          break
        }
      }
    }
    if let invalidAttachment {
      return try recordPDFLookup(id, .needsReview,
        "The attached PDF could not be verified: " + invalidAttachment + ". Original retained; use Attach PDF to replace it.")
    }
    // Always check local storage, even if a previous web lookup is still in its cooldown.
    if retry || pdfCatalog == nil || Date().timeIntervalSince(pdfCatalog!.date) > 60 {
      let root = self.root
      let files = try await Task.detached(priority: .userInitiated) { try PDFDiscovery.catalog(root) }.value
      pdfCatalog = (Date(), files)
    }
    var candidates = PDFDiscovery.localCandidates(pdfCatalog?.files ?? [], item: item)
    // Filenames are not always descriptive (notably exported Paperpile libraries). Reuse the
    // text index we already maintain for managed PDFs before doing any web lookup.
    if let doi = item.doi {
      for path in try database.indexedPDFPaths(containingDOI: doi) {
        guard let file = try? Files.safeURL(root: root, relative: path),
          FileManager.default.fileExists(atPath: file.path), !candidates.contains(file)
        else { continue }
        candidates.insert(file, at: 0)
      }
    }
    if candidates.isEmpty {
      let files = pdfCatalog?.files ?? []
      candidates = await Task.detached(priority: .userInitiated) {
        PDFDiscovery.residentContentCandidates(files, item: item)
      }.value
    }
    var verified: [(URL, Data?)] = []
    var verifiedHashes = Set<String>()
    var uncertain = false
    for file in candidates.prefix(10) {
      try Task.checkCancellation()
      do {
        let deadline = Date().addingTimeInterval(300)
        while true {
          do { try Files.materialize(file); break }
          catch is ResourceDownloadPending {
            guard Date() < deadline else { throw LibraryError.invalid("iCloud download has not finished; retry later.") }
            try await Task.sleep(for: .seconds(1))
          }
        }
        let data = try Files.coordinatedRead(file) { try Data(contentsOf: $0) }
        try PDFDiscovery.validate(data, item: item, authoritative: false)
        // ZIP retries can leave byte-identical review copies. They represent one PDF,
        // rather than an ambiguous choice between different versions.
        let hash = try Files.coordinatedRead(file) { try Files.hash($0) }
        if verifiedHashes.insert(hash).inserted { verified.append((file, data)) }
      } catch is CancellationError { throw CancellationError() }
      catch { uncertain = true }
    }
    if verified.count == 1 {
      return try await attachLocatedPDF(verified[0].1, file: verified[0].0, remote: nil, id: id)
    }
    if verified.count > 1 {
      return try recordPDFLookup(id, .needsReview, "Multiple PDFs match this paper in the library folder. Choose the correct copy with Attach PDF.")
    }
    if !retry, let lookup = item.pdfLookup, let date = lookup.checkedAt,
      lookup.status != .pending, lookup.status != .available, Date().timeIntervalSince(date) < 3600 { return item }
    let online = OnlinePDFDiscovery(transport: transport)
    var webCandidates = item.resources.filter { $0.type == .pdf }.compactMap { resource -> PDFCandidate? in
      guard let value = resource.remoteURL, let url = try? Identifiers.canonicalURL(value) else { return nil }
      return PDFCandidate(url: url, authoritative: true)
    }
    var pmcid = item.pmcid
    var retryNeeded = false
    var authentication = false
    var publisherBlocked = false
    func noteFailure(_ error: Error, repository: Bool = false) {
      let message = error.localizedDescription
      if message.contains("401") {
        if !repository { authentication = true }
      } else if message.contains("403") {
        if !repository { publisherBlocked = true }
      } else if !message.contains("404") { retryNeeded = true }
    }
    do { webCandidates += try await online.openAlex(item) }
    catch is CancellationError { throw CancellationError() }
    catch { noteFailure(error, repository: true) }
    do {
      let result = try await online.europePMC(item)
      pmcid = pmcid ?? result.pmcid; webCandidates += result.candidates
    } catch is CancellationError { throw CancellationError() }
    catch { noteFailure(error, repository: true) }
    if let pmcid {
      do { webCandidates = try await online.pmc(pmcid, item: item) + webCandidates }
      catch is CancellationError { throw CancellationError() }
      catch { noteFailure(error, repository: true) }
    }
    if let arxiv = item.arxivID, let url = try? Identifiers.canonicalURL("https://arxiv.org/pdf/" + arxiv) {
      webCandidates.append(PDFCandidate(url: url, authoritative: true))
    }
    let pages = [item.canonicalURL, item.doi.map { "https://doi.org/" + $0 }].compactMap { $0 }
      + item.resources.filter { $0.type != .pdf }.compactMap(\.remoteURL)
    var visited = Set<String>()
    // Try trusted repository PDFs before fetching publisher landing pages.
    for candidate in webCandidates {
      guard visited.insert(candidate.url.absoluteString).inserted else { continue }
      do {
        let (data, _) = try await transport.data(candidate.url)
        try PDFDiscovery.validate(data, item: item, authoritative: candidate.authoritative)
        return try await attachLocatedPDF(data, file: nil, remote: candidate.url, id: id)
      } catch is CancellationError { throw CancellationError() }
      catch LibraryError.conflict { uncertain = true }
      catch { noteFailure(error) }
    }
    for value in pages {
      guard let url = try? Identifiers.canonicalURL(value), !OnlinePDFDiscovery.isPMCWebPage(url),
        url.host != "pubmed.ncbi.nlm.nih.gov", visited.insert(url.absoluteString).inserted else { continue }
      do {
        let (data, response) = try await transport.data(url)
        if data.starts(with: Data("%PDF-".utf8)) {
          try PDFDiscovery.validate(data, item: item, authoritative: false)
          return try await attachLocatedPDF(data, file: nil, remote: url, id: id)
        }
        let html = String(decoding: data, as: UTF8.self)
        let pageDOI = WebMetadata.meta("citation_doi", html: html).flatMap(Identifiers.doi)
        if let expected = item.doi, let pageDOI, expected.lowercased() != pageDOI.lowercased() {
          uncertain = true; continue
        }
        let trusted = (item.doi != nil && pageDOI == item.doi)
          || PDFDiscovery.titleMatches(WebMetadata.meta("citation_title", html: html) ?? "", item: item)
        for pdf in WebMetadata.pdfLinks(html, relativeTo: response.url ?? url)
          where !OnlinePDFDiscovery.isPMCWebPage(pdf) && visited.insert(pdf.absoluteString).inserted
        {
          do {
            let (pdfData, _) = try await transport.data(pdf)
            try PDFDiscovery.validate(pdfData, item: item, authoritative: trusted)
            return try await attachLocatedPDF(pdfData, file: nil, remote: pdf, id: id)
          } catch is CancellationError { throw CancellationError() }
          catch LibraryError.conflict { uncertain = true }
          catch { noteFailure(error) }
        }
      } catch is CancellationError { throw CancellationError() }
      catch LibraryError.conflict { uncertain = true }
      catch { noteFailure(error) }
    }
    if uncertain { return try recordPDFLookup(id, .needsReview, "A possible PDF could not be confidently matched. Attach the correct PDF or review the article website.") }
    if publisherBlocked { return try recordPDFLookup(id, .requiresAuthentication, "The publisher blocked the automatic PDF request. The article may still be openly available; open Website or attach a PDF.") }
    if authentication { return try recordPDFLookup(id, .requiresAuthentication, "The publisher requires access or sign-in. Open Website, then attach a PDF you can access.") }
    if retryNeeded { return try recordPDFLookup(id, .retry, "Online lookup could not finish. Check your connection and try Find PDF Again.") }
    return try recordPDFLookup(id, .notFound, "No accessible PDF was found in your library folder or online. Attach a PDF or open Website.")
  }
  public func libraryCounts() throws -> [String: Int] {
    let rows = try database.rows("SELECT count(*) AS total, sum(has_pdf) AS withPDF FROM items").first ?? [:]
    let origins = try database.rows("SELECT count(*) AS count FROM import_origins WHERE external_id LIKE 'paperpile:%'").first?["count"] ?? "0"
    return ["total": Int(rows["total"] ?? "0") ?? 0, "withPDF": Int(rows["withPDF"] ?? "0") ?? 0,
      "paperpileReferences": Int(origins) ?? 0]
  }

  public func importRecords(_ url: URL, resume: Bool = false) async throws -> Int {
    try reconcilePermanentDeletions()
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let data = try Files.coordinatedRead(url) { try Data(contentsOf: $0) }
    let items = try ImportService.parse(data, format: url.pathExtension)
    let attachments = ImportService.attachmentPaths(data)
    for (index, var item) in items.enumerated() {
      if deletedItems.contains(item.id) { continue }
      var target = item.id
      let importedID = try database.item(item.id)?.id ?? database.importedDuplicate(item)
      // Resume only skips sources already committed with the identical original payload.
      // This preserves edits and avoids rewriting evicted metadata from a partial cloud import.
      if resume, let id = importedID, let prior = try database.item(id),
        let snapshots = item.sourceMetadata, !snapshots.isEmpty,
        snapshots.allSatisfy({ incoming in
          prior.sourceMetadata?.contains(where: {
            $0.source == incoming.source && $0.format == incoming.format && $0.payload == incoming.payload
          }) == true
        }), index >= attachments.count || attachments[index].isEmpty {
        continue
      }
      var existingID = try importedID ?? database.identifierDuplicate(item)
      if importedID == nil, let id = existingID, let existing = try database.item(id),
        (existing.pmid != nil && item.pmid != nil && existing.pmid != item.pmid)
          || (existing.doi != nil && item.doi != nil && existing.doi?.lowercased() != item.doi?.lowercased()) {
        existingID = nil
        item.pdfLookup = PDFLookup(.needsReview, detail: "This import conflicts with another reference's identifiers. Review the metadata before finding a PDF.", checkedAt: Date())
        item.provenance.append(Provenance("Paperpile", "Conflicting identifiers retained as a separate reference for review"))
      }
      if let existing = existingID,
        var value = try database.item(existing)
      {
        target = existing
        let prior = value
        value = MetadataResolutionService.merge(value, item)
        value.tags = Array(Set(value.tags + item.tags)).sorted()
        value.collections = Array(Set(value.collections + item.collections)).sorted()
        if !item.notes.isEmpty, !value.notes.contains(item.notes) {
          value.notes += (value.notes.isEmpty ? "" : "\n") + item.notes
        }
        if value != prior {
          value.dateModified = Date()
          try save(value)
        }
      } else {
        item.provenance.append(Provenance("migration", "Imported portable bibliography"))
        try save(item)
      }
      if index < attachments.count {
        for path in attachments[index] {
          do {
            let file = try Files.safeURL(root: url.deletingLastPathComponent(), relative: path)
            if FileManager.default.fileExists(atPath: file.path),
              file.pathExtension.lowercased() == "pdf"
            {
              _ = try captureFile(file, attachTo: target)
            }
          } catch {
            logger.error(
              "Migration attachment requires manual selection: \(error.localizedDescription,privacy:.public)"
            )
          }
        }
      }
    }
    await processPending()
    return items.count
  }
}
