import Foundation
import Testing
@testable import ResearchCore

extension CoreTests {
  @Test func testRecoveryCopiesAreCappedPerItem() throws {
    let root = temp.appendingPathComponent("RecoveryCap")
    let sidecars = try SidecarService(root: root)
    var item = LibraryItem(title: "Versioned")
    for n in 0..<(Files.recoveryVersionsPerItem + 8) {
      item.notes = "revision \(n)"
      try sidecars.save(item)
    }
    let folder = root.appendingPathComponent("Recovery/Metadata/\(item.id.uuidString)")
    let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
    #expect(kept.count == Files.recoveryVersionsPerItem)
    #expect(try sidecars.read(sidecars.url(item.id)).notes == "revision \(Files.recoveryVersionsPerItem + 7)")
  }

  @Test func testRebuildSkipsABadItemInsteadOfEmptyingTheIndex() async throws {
    let library = try makeLibrary()
    let sidecars = try SidecarService(root: temp.appendingPathComponent("Archive"))
    let good = LibraryItem(title: "Healthy record about myelin")
    var bad = LibraryItem(title: "Record with an unsafe attachment path")
    bad.resources = [Resource(itemID: bad.id, type: .pdf, path: "../outside.pdf", availability: .local)]
    try sidecars.save(good)
    try sidecars.save(bad)
    let issues = try await library.rebuild()
    #expect(issues.contains { $0.path == bad.id.uuidString })
    let ids = try await library.search("").map(\.item.id)
    #expect(ids.contains(good.id))
  }

  @Test func testReindexingAndRemovalReplacePageTextExactly() throws {
    let db = try LocalDatabase(url: temp.appendingPathComponent("pages.sqlite"))
    let item = LibraryItem(title: "Paper")
    try db.upsert(item)
    let resource = UUID()
    func page(_ text: String) -> DocumentPage {
      DocumentPage(id: UUID(), itemID: item.id, resourceID: resource, pageNumber: 1, text: text, method: "fixture")
    }
    try db.index(pages: [page("first draft zebrafish")], sections: [], chunks: [], itemID: item.id, resourceID: resource)
    try db.index(pages: [page("final version axolotl")], sections: [], chunks: [], itemID: item.id, resourceID: resource)
    #expect(try db.search("zebrafish").isEmpty)
    #expect(try db.search("axolotl").count == 1)
    let rows = try db.rows("SELECT count(*) AS n FROM page_fts")
    #expect(rows.first?["n"] == "1")
    try db.remove(item.id)
    #expect(try db.rows("SELECT count(*) AS n FROM page_fts").first?["n"] == "0")
    #expect(try db.rows("SELECT count(*) AS n FROM page_fts_lookup").first?["n"] == "0")
  }
}
