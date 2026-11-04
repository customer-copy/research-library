import Foundation
import Testing
@testable import ResearchCore

extension CoreTests {
  @Test func testLegacyDuplicateMetadataHitsRemainOnePaper() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("duplicates.sqlite"))
    let first = LibraryItem(title: "Microglia study")
    let second = LibraryItem(title: "Microglia other study")
    try db.upsert(first); try db.upsert(second)
    for _ in 0..<8 {
      _ = try db.rows("INSERT INTO item_fts VALUES(?,?,?,?,?,?,?,?,?)",
        [first.id.uuidString, "Microglia microglia microglia", "", "", "", "", "", "", ""])
    }
    let results = try db.search("microglia", limit: 2, metadataOnly: true)
    #expect(results.count == 2)
    #expect(Set(results.map { $0.item.id }) == Set([first.id, second.id]))
  }

  @Test func testLargeBodyResultPageBatchesCitationQueries() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("large-page.sqlite"))
    for number in 0..<520 {
      let item = LibraryItem(title: "Unrelated paper \(number)")
      try db.upsert(item)
      let resource = UUID()
      try db.index(pages: [DocumentPage(id: UUID(), itemID: item.id, resourceID: resource,
        pageNumber: 1, text: "Needle evidence", method: "fixture")], sections: [], chunks: [],
        itemID: item.id, resourceID: resource)
    }
    let values = try db.search("needle", limit: 500)
    #expect(values.count == 500)
    #expect(Set(values.map { $0.item.id }).count == 500)
    #expect(values.allSatisfy { $0.pageStart == 1 && $0.snippet.contains("Needle") })
  }

  @Test func testSearchGroupsPapersAndKeepsMatchingPageCitations() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("search.sqlite"))
    var metadata = LibraryItem(title: "Microglia metabolism")
    metadata.year = 2025
    try db.upsert(metadata)
    let body = LibraryItem(title: "Another scientific paper")
    try db.upsert(body)
    let resource = UUID()
    let pages = (1...12).map { page in
      DocumentPage(id: UUID(), itemID: body.id, resourceID: resource, pageNumber: page,
        text: "Microglia metabolism occurs in cells. Page \(page)", method: "fixture")
    }
    let sections = TextDerivation.sections(pages)
    let chunks = TextDerivation.chunks(pages, sections: sections)
    try db.index(pages: pages, sections: sections, chunks: chunks, itemID: body.id, resourceID: resource)
    let ownResource = UUID()
    try db.index(pages: [DocumentPage(id: UUID(), itemID: metadata.id, resourceID: ownResource,
      pageNumber: 1, text: "Microglia metabolism also matches this paper's title.", method: "fixture")],
      sections: [], chunks: [], itemID: metadata.id, resourceID: ownResource)
    let results = try db.search("microglia")
    #expect(results.count == 2)
    #expect(Set(results.map { $0.item.id }).count == 2)
    #expect(results.first?.item.id == metadata.id)
    #expect(results.last?.item.id == body.id)
    #expect(results.last?.resourceID == resource)
    #expect(results.last?.pageStart != nil)
    #expect(results.last?.chunkID != nil)
    #expect(results.last?.snippet.lowercased().contains("microglia") == true)
    let preview = try db.search("microglia", metadataOnly: true)
    #expect(preview.count == 1)
    #expect(preview.first?.id == results.first?.id)
    let matches = try db.matchingPages("microglia", itemID: body.id)
    #expect(matches.count == 5)
    #expect(Set(matches.map { $0.pageMatchID }).count == 5)
    #expect(matches.allSatisfy { $0.item.id == body.id && $0.resourceID == resource && $0.chunkID != nil })
    let next = try db.matchingPages("microglia", itemID: body.id, offset: 5)
    #expect(Set(matches.map { $0.pageMatchID }).isDisjoint(with: next.map { $0.pageMatchID }))
  }

  @Test func testGroupedSearchPaginationAndGlobalSortsDoNotRepeatPapers() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("search.sqlite"))
    var ids = Set<UUID>()
    for number in 0..<35 {
      var item = LibraryItem(title: String(format: "Paper %02d", number))
      item.year = 2020 + number % 6
      item.publicationDate = String(format: "202%1d-%02d-01", number % 6, (number % 12) + 1)
      item.dateAdded = Date(timeIntervalSince1970: Double(number))
      item.tags = number % 2 == 0 ? ["selected"] : []
      try db.upsert(item)
      let rid = UUID()
      try db.index(pages: (1...8).map {
        DocumentPage(id: UUID(), itemID: item.id, resourceID: rid, pageNumber: $0,
          text: "Microglia evidence \(number)", method: "fixture")
      }, sections: [], chunks: [], itemID: item.id, resourceID: rid)
      ids.insert(item.id)
    }
    for sort in [LibrarySort.relevance, .title, .year, .publicationDate, .dateAdded] {
      var filters = SearchFilters(); filters.sort = sort
      let first = try db.search("microglia", filters: filters, limit: 10)
      let second = try db.search("microglia", filters: filters, limit: 10, offset: 10)
      let third = try db.search("microglia", filters: filters, limit: 20, offset: 20)
      let combined = first + second + third
      #expect(combined.count == 35)
      #expect(Set(combined.map { $0.item.id }) == ids)
      #expect(try db.search("microglia", filters: filters, limit: 10).map { $0.id } == first.map { $0.id })
      if sort == .title { #expect(combined.map { $0.item.title } == combined.map { $0.item.title }.sorted()) }
      if sort == .year { #expect(combined.map { $0.item.year! } == combined.map { $0.item.year! }.sorted(by: >)) }
      if sort == .publicationDate {
        #expect(combined.compactMap { $0.item.publicationDate } == combined.compactMap { $0.item.publicationDate }.sorted(by: >))
      }
      if sort == .dateAdded { #expect(combined.map { $0.item.dateAdded } == combined.map { $0.item.dateAdded }.sorted(by: >)) }
    }
    var filtered = SearchFilters(); filtered.tag = "selected"; filtered.sort = .title
    #expect(try db.search("microglia", filters: filtered, limit: 100).count == 18)
  }

  @Test func testCancelledSQLiteQueryStopsAndConnectionRemainsUsable() async throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("cancel.sqlite"))
    try db.upsert(LibraryItem(title: "Usable after cancellation"))
    let token = SearchCancellation()
    let entered = DispatchSemaphore(value: 0)
    let work = Task.detached {
      try db.withSearchCancellation(token) {
        entered.signal()
        _ = try db.rows("WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n")
      }
    }
    let started = await Task.detached { waitForSearchFixture(entered) }.value
    #expect(started)
    let start = ContinuousClock.now
    token.cancel()
    do { try await work.value; Issue.record("Expected cancellation of running SQLite query") }
    catch is CancellationError {} catch { Issue.record("Expected CancellationError, got \(error)") }
    #expect(start.duration(to: .now) < timeBudget(1))
    #expect(try db.search("usable").count == 1)
  }

  @Test func testSearchRunsWhileImportActorIsBlocked() async throws {
    struct BlockedIdentifierExtraction: PDFTextExtractor {
      let entered: DispatchSemaphore
      let release: DispatchSemaphore
      func identifiers(url: URL) throws -> String {
        entered.signal(); waitForImportFixture(release)
        return "DOI: 10.1000/search-independent"
      }
      func extract(url: URL, itemID: UUID, resourceID: UUID) throws -> [DocumentPage] { [] }
    }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let library = try LibraryService(root: temp.appendingPathComponent("Archive"),
      databaseURL: temp.appendingPathComponent("search.sqlite"), providers: [FixedProvider()],
      transport: OfflineTransport(), extraction: BlockedIdentifierExtraction(entered: entered, release: release))
    try await library.edit(LibraryItem(title: "Search stays responsive"))
    _ = try await library.captureFile(pdf("Scientific import fixture"))
    let importing = Task { await library.processPending() }
    defer { release.signal() }
    #expect(await Task.detached { waitForSearchFixture(entered) }.value)
    let start = ContinuousClock.now
    let values = try await library.search("responsive")
    #expect(values.count == 1)
    #expect(start.duration(to: .now) < timeBudget(1))
    release.signal()
    await importing.value
  }

  @Test func testPageLookupMigrationAndReindexingPreserveSearch() throws {
    let file = temp.appendingPathComponent("migration.sqlite")
    let db = try LocalDatabase(url: file)
    let item = LibraryItem(title: "Legacy PDF index")
    try db.upsert(item)
    let resource = UUID()
    let page = DocumentPage(id: UUID(), itemID: item.id, resourceID: resource, pageNumber: 1,
      text: "Microglia evidence", method: "fixture")
    try db.index(pages: [page], sections: [], chunks: [], itemID: item.id, resourceID: resource)
    try db.execute("DROP TABLE page_fts_lookup")
    try db.execute("PRAGMA user_version=1")  // simulate an index from before the lookup table
    let migrated = try LocalDatabase(url: file)
    #expect(try migrated.rows("SELECT * FROM page_fts_lookup").count == 1)
    #expect(try migrated.search("microglia").first?.item.id == item.id)
    #expect(try migrated.matchingPages("microglia", itemID: item.id).first?.pageStart == 1)
    var replacement = page; replacement.text = "Oligodendrocyte evidence"
    try migrated.index(pages: [replacement], sections: [], chunks: [], itemID: item.id, resourceID: resource)
    #expect(try migrated.rows("SELECT * FROM page_fts_lookup").count == 1)
    #expect(try migrated.search("microglia").isEmpty)
    #expect(try migrated.search("oligodendrocyte").count == 1)
    try migrated.remove(item.id)
    #expect(try migrated.rows("SELECT * FROM page_fts_lookup").isEmpty)
    #expect(try migrated.search("oligodendrocyte").isEmpty)
  }
}

private func waitForSearchFixture(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now() + 2) == .success
}
private func waitForImportFixture(_ semaphore: DispatchSemaphore) {
  _ = semaphore.wait(timeout: .now() + 5)
}
