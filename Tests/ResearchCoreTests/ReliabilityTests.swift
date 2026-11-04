import Foundation
import Testing
@testable import ResearchCore

extension CoreTests {
  @Test func testPersistedSidecarRevisionsDetectReplacementsWithSameSizeAndDate() async throws {
    let library = try makeLibrary()
    let original = LibraryItem(title: "Original title")
    try await library.edit(original)
    try await library.synchronizeSidecars()
    let sidecars = try SidecarService(root: temp.appendingPathComponent("Archive"))
    let file = sidecars.url(original.id)
    let stamp = try #require(Files.localModificationDate(file))
    let bytes = try Data(contentsOf: file)
    let changed = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Original title", with: "Modified title").utf8)
    #expect(changed.count == bytes.count)
    try changed.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
    let reopened = try makeLibrary()
    try await reopened.synchronizeSidecars()
    #expect(try await reopened.item(original.id)?.title == "Modified title")
    #expect(await reopened.generation() == 1)
    let secondRestart = try makeLibrary()
    try await secondRestart.synchronizeSidecars()
    #expect(await secondRestart.generation() == 0)
    let index = try LocalDatabase(url: temp.appendingPathComponent("index.sqlite"))
    #expect(try index.rows("SELECT path FROM sidecar_revisions").count == 1)
    try index.reset()
    #expect(try index.rows("SELECT path FROM sidecar_revisions").isEmpty)
    let rebuilt = try makeLibrary()
    try await rebuilt.synchronizeSidecars()
    #expect(try await rebuilt.item(original.id)?.title == "Modified title")
  }

  @Test func testReconciliationAndReaderPerformanceBaseline() async throws {
    let root = temp.appendingPathComponent("Archive")
    let sidecars = try SidecarService(root: root)
    for number in 0..<5000 {
      var item = LibraryItem(title: "Benchmark article \(number)")
      item.year = 2020 + number % 7
      try sidecars.save(item)
    }
    let first = try makeLibrary()
    let start = ContinuousClock.now
    try await first.synchronizeSidecars()
    let firstDuration = start.duration(to: .now)
    let reopened = try makeLibrary()
    let reopenedStart = ContinuousClock.now
    try await reopened.synchronizeSidecars()
    let reopenedDuration = reopenedStart.duration(to: .now)
    #expect(try await reopened.search("", limit: 100).count == 100)
    let searchStart = ContinuousClock.now
    #expect(try await reopened.search("\"Benchmark article 4321\"").count == 1)
    let searchDuration = searchStart.duration(to: .now)
    let source = try pdf("DOI: 10.1000/reader-benchmark\nScientific research content")
    let id = try await reopened.captureFile(source)
    await reopened.processPending()
    let item = try #require(try await reopened.item(id))
    let resource = try #require(item.resources.first { $0.type == .pdf })
    let readerStart = ContinuousClock.now
    _ = try await reopened.readPDFForReader(itemID: id, resourceID: resource.id)
    let readerDuration = readerStart.duration(to: .now)
    func milliseconds(_ duration: Duration) -> Double {
      let values = duration.components
      return Double(values.seconds) * 1000 + Double(values.attoseconds) / 1e15
    }
    let report: [String: Any] = ["fixtureRecords": 5000, "fixturePDFPages": 1,
      "firstIndexMilliseconds": milliseconds(firstDuration),
      "existingIndexReconciliationMilliseconds": milliseconds(reopenedDuration),
      "searchMilliseconds": milliseconds(searchDuration), "pdfReadMilliseconds": milliseconds(readerDuration),
      "limitations": "Disposable local fixtures. Excludes app launch/UI rendering, large PDFs, OCR, and iCloud latency."]
    print("Local performance baseline: \(report)")
    if let path = ProcessInfo.processInfo.environment["RESEARCH_LIBRARY_BENCHMARK_REPORT"] {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
  }

  @Test func testAnnotationSaveRecoversAfterBytesCommitBeforeMetadata() async throws {
    let library = try makeLibrary()
    let id = try await library.captureFile(pdf("DOI: 10.1000/annotation-commit\nResearch content"))
    await library.processPending()
    let item = try #require(try await library.item(id))
    let resource = try #require(item.resources.first { $0.type == .pdf })
    let originalHash = try #require(resource.sha256)
    let file = temp.appendingPathComponent("Archive/" + resource.relativePath!)
    let changed = try Data(contentsOf: pdf("DOI: 10.1000/annotation-commit\nUpdated PDF content", name: "updated.pdf"))
    let recovery = temp.appendingPathComponent("Archive/Recovery/PDFs/\(resource.id)")
    let newHash = try PDFEditing.save(changed, to: file, expectedHash: originalHash, recovery: recovery)
    // The PDF write has committed, while the sidecar still records its original hash.
    #expect(try await library.item(id)?.resources.first { $0.id == resource.id }?.sha256 == originalHash)
    let resumedHash = try await library.savePDFAnnotations(itemID: id, resourceID: resource.id,
      data: changed, expectedHash: originalHash)
    #expect(resumedHash == newHash)
    #expect(try await library.item(id)?.resources.first { $0.id == resource.id }?.sha256 == newHash)
    #expect(try Files.hash(recovery.appendingPathComponent(originalHash + ".pdf")) == originalHash)
  }

  @Test(arguments: [LibraryService.ImportBoundary.planned, .copied, .metadataSaved])
  func testImportRestartsAtEveryCommitBoundary(_ boundary: LibraryService.ImportBoundary) async throws {
    let library = try makeLibrary()
    let source = try pdf("DOI: 10.1000/commit-recovery\nScientific text to index.")
    // Force a suffixed filename: old recovery only looked for the unsuffixed name.
    let occupied = temp.appendingPathComponent("Archive/PDFs/2025 - Smith - Microglial lipid metabolism.pdf")
    let unrelated = try pdf("An unrelated existing paper", name: "other.pdf")
    try FileManager.default.copyItem(at: unrelated, to: occupied)
    await library.setImportFault { reached in
      if reached == boundary { throw LibraryError.invalid("Simulated process interruption") }
    }
    let id = try await library.captureFile(source)
    await library.processPending()
    let interrupted = try #require(try await library.requests().first { $0.id == id })
    let checkpoint = try #require(interrupted.importCommit)
    let planned = try #require(checkpoint.resource.relativePath)
    #expect(planned != "PDFs/" + occupied.lastPathComponent)
    let inbox = temp.appendingPathComponent("Archive/" + interrupted.inputFile!)
    #expect(FileManager.default.fileExists(atPath: inbox.path))
    // Drop the derived index too: recovery must work from the durable queue and sidecars.
    let reopened = try LibraryService(root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("recovered.sqlite"), providers: [FixedProvider()],
      transport: OfflineTransport())
    try await reopened.synchronizeSidecars()
    await reopened.processPending()
    let completed = try #require(try await reopened.requests().first { $0.id == id })
    #expect(completed.state == .complete)
    #expect(completed.importCommit == nil)
    #expect(completed.inboxCleanupComplete == true)
    let item = try #require(try await reopened.item(id))
    let resource = try #require(item.resources.first { $0.type == .pdf })
    #expect(resource.id == checkpoint.resource.id)
    #expect(resource.relativePath == planned)
    #expect(try Files.hash(temp.appendingPathComponent("Archive/" + planned)) == Files.hash(source))
    #expect(try Files.hash(occupied) == Files.hash(unrelated))
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.appendingPathComponent("Archive/PDFs").path).count == 2)
    #expect(try await reopened.search("Scientific").count == 1)
    await reopened.processPending()
    #expect(try await reopened.search("").count == 1)
  }

  @Test func testImportRecoveryPreservesEditsAfterInterruptedCommit() async throws {
    let library = try makeLibrary()
    await library.setImportFault { reached in
      if reached == .metadataSaved { throw LibraryError.invalid("Simulated stop after sidecar commit") }
    }
    let id = try await library.captureFile(pdf("DOI: 10.1000/commit-edits\nResearch content"))
    await library.processPending()
    var item = try #require(try await library.item(id))
    item.title = "My corrected title"
    item.notes = "Notes written after interruption"
    item.tags = ["my-tag"]
    try await library.edit(item)
    let reopened = try makeLibrary()
    await reopened.processPending()
    let recovered = try #require(try await reopened.item(id))
    #expect(recovered.title == "My corrected title")
    #expect(recovered.notes == "Notes written after interruption")
    #expect(recovered.tags == ["my-tag"])
    #expect(recovered.humanEdited)
    #expect(try await reopened.requests().first { $0.id == id }?.state == .complete)
  }

  @Test func testImportRecoveryPreservesPDFEditsMadeBeforeRetry() async throws {
    let library = try makeLibrary()
    await library.setImportFault { reached in
      if reached == .metadataSaved { throw LibraryError.invalid("Simulated interruption") }
    }
    let id = try await library.captureFile(pdf("DOI: 10.1000/commit-annotations\nResearch content"))
    await library.processPending()
    let item = try #require(try await library.item(id))
    let resource = try #require(item.resources.first { $0.type == .pdf })
    let changed = try Data(contentsOf: pdf("DOI: 10.1000/commit-annotations\nUpdated research content", name: "changed.pdf"))
    let changedHash = try await library.savePDFAnnotations(itemID: id, resourceID: resource.id,
      data: changed, expectedHash: resource.sha256!)
    let reopened = try makeLibrary()
    await reopened.processPending()
    #expect(try await reopened.requests().first { $0.id == id }?.state == .complete)
    #expect(try await reopened.requests().first { $0.id == id }?.inboxCleanupComplete == true)
    #expect(try Files.hash(temp.appendingPathComponent("Archive/" + resource.relativePath!)) == changedHash)
  }

  @Test(arguments: [LibraryService.ImportBoundary.planned, .copied])
  func testChangedFileDuringImportNeverClobbersOrCleansOriginal(_ boundary: LibraryService.ImportBoundary) async throws {
    let library = try makeLibrary()
    await library.setImportFault { reached in
      if reached == boundary { throw LibraryError.invalid("Simulated stop") }
    }
    let id = try await library.captureFile(pdf("DOI: 10.1000/commit-changed\nResearch content"))
    await library.processPending()
    let request = try #require(try await library.requests().first { $0.id == id })
    let inbox = temp.appendingPathComponent("Archive/" + request.inputFile!)
    let destination = temp.appendingPathComponent("Archive/" + request.importCommit!.resource.relativePath!)
    let changed = Data("Do not replace these changed bytes".utf8)
    try changed.write(to: boundary == .planned ? inbox : destination, options: .atomic)
    let reopened = try makeLibrary()
    await reopened.processPending()
    #expect(FileManager.default.fileExists(atPath: inbox.path))
    #expect(try Data(contentsOf: boundary == .planned ? inbox : destination) == changed)
    let failed = try #require(try await reopened.requests().first { $0.id == id })
    #expect(failed.state == .failed)
    #expect(failed.importCommit != nil)
    #expect(failed.inboxCleanupComplete != true)
  }

  @Test func testPDFReadRejectsInvalidBytesBeforeUpdatingRecordedHash() async throws {
    let library = try makeLibrary()
    let id = try await library.captureFile(pdf("DOI: 10.1000/invalid-read\nResearch content"))
    await library.processPending()
    let item = try #require(try await library.item(id))
    let resource = try #require(item.resources.first { $0.type == .pdf })
    let file = temp.appendingPathComponent("Archive/" + resource.relativePath!)
    try Data("%PDF-1.7\nthis is corrupt".utf8).write(to: file, options: .atomic)
    do {
      _ = try await library.readPDFForReader(itemID: id, resourceID: resource.id)
      Issue.record("Corrupt attachment must not open")
    } catch {}
    #expect(try await library.item(id)?.resources.first { $0.id == resource.id }?.sha256 == resource.sha256)
    let resolved = try await library.resolvePDF(id)
    #expect(resolved.pdfLookup?.status == .needsReview)
    #expect(!resolved.hasPDF)
    #expect(FileManager.default.fileExists(atPath: file.path))
    // Repair the file; verification must not get stuck behind an earlier lookup cooldown.
    let repaired = try pdf("DOI: 10.1000/invalid-read\nRepaired research content", name: "repaired.pdf")
    try Data(contentsOf: repaired).write(to: file, options: .atomic)
    let available = try await library.resolvePDF(id)
    #expect(available.hasPDF)
    #expect(available.pdfLookup?.status == .available)
  }

  @Test func testPDFVerificationCacheDetectsAtomicReplacement() async throws {
    let library = try makeLibrary()
    let id = try await library.captureFile(pdf("DOI: 10.1000/cache-validation\nResearch content"))
    await library.processPending()
    let valid = try await library.resolvePDF(id)
    #expect(valid.hasPDF)
    let resource = try #require(valid.resources.first { $0.type == .pdf })
    let file = temp.appendingPathComponent("Archive/" + resource.relativePath!)
    let previousDate = Files.localModificationDate(file)!
    let previousBytes = try Data(contentsOf: file)
    try Data(repeating: 65, count: previousBytes.count).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: previousDate], ofItemAtPath: file.path)
    let resolved = try await library.resolvePDF(id)
    #expect(resolved.pdfLookup?.status == .needsReview)
    #expect(!resolved.hasPDF)
  }

  @Test func testSearchAndEditsRemainResponsiveDuringPDFRead() async throws {
    struct BlockedReader: PDFSnapshotLoader {
      let entered: DispatchSemaphore
      let release: DispatchSemaphore
      func read(_ url: URL) throws -> PDFReadSnapshot {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return try PDFEditing.read(url)
      }
    }
    let normal = try makeLibrary()
    let id = try await normal.captureFile(pdf("DOI: 10.1000/slow-reader\nResearch content"))
    await normal.processPending()
    let item = try #require(try await normal.item(id))
    let resource = try #require(item.resources.first { $0.type == .pdf })
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let library = try LibraryService(root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("index.sqlite"), providers: [FixedProvider()],
      transport: OfflineTransport(), readerLoader: BlockedReader(entered: entered, release: release))
    let reading = Task { try await library.readPDFForReader(itemID: id, resourceID: resource.id) }
    defer { release.signal() }
    let started = await Task.detached { waitForReaderFixture(entered) }.value
    #expect(started)
    let start = ContinuousClock.now
    let results = try await library.search("Microglial")
    #expect(results.count == 1)
    var changed = item
    changed.notes = "Edited while disk read was blocked"
    try await library.edit(changed)
    let elapsed = start.duration(to: .now)
    #expect(elapsed < timeBudget(1))
    print("Search and metadata edit during blocked PDF read: \(elapsed)")
    release.signal()
    _ = try await reading.value
    #expect(try await library.item(id)?.notes == changed.notes)
  }
}

private func waitForReaderFixture(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now() + 2) == .success
}
