import Foundation
import Testing
@testable import ResearchCore

@Suite struct FormatSafetyTests {
  @Test func minimalLegacyItemDecodesWithDefaults() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","title":"Old record","authors":[{"familyName":"Lovelace"}],"#
      + #""resources":[{"itemID":"\#(id.uuidString)","type":"pdf","availability":"local","relativePath":"PDFs/a.pdf"}]}"#
    let item = try PortableJSON.decoder().decode(LibraryItem.self, from: Data(json.utf8))
    #expect(item.id == id)
    #expect(item.title == "Old record")
    #expect(item.tags.isEmpty && !item.humanEdited && item.confidence == 0.2)
    #expect(item.authors.first?.familyName == "Lovelace")
    #expect(item.resources.first?.source == "user")
    #expect(item.dateModified == .distantPast)  // unknown age never looks "newer" in conflict checks
  }

  @Test func unknownEnumValuesFromNewerVersionsFallBack() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","type":"dataset","pdfLookup":{"status":"queuedRemotely","detail":""},"#
      + #""resources":[{"itemID":"\#(id.uuidString)","type":"hologram","availability":"teleported"}]}"#
    let item = try PortableJSON.decoder().decode(LibraryItem.self, from: Data(json.utf8))
    #expect(item.type == .genericDocument)
    #expect(item.resources.first?.type == .other)
    #expect(item.resources.first?.availability == .unavailable)
    #expect(item.pdfLookup?.status == .needsReview)
    let request = try PortableJSON.decoder().decode(IngestionRequest.self,
      from: Data(#"{"id":"\#(UUID().uuidString)","state":"futureState"}"#.utf8))
    #expect(request.state == .awaitingReview)
    #expect(request.source == "manual" && request.suggestedTags.isEmpty)
  }

  @Test func itemsStillRequireAnIdentity() {
    #expect(throws: (any Error).self) {
      _ = try PortableJSON.decoder().decode(LibraryItem.self, from: Data(#"{"title":"No id"}"#.utf8))
    }
  }

  @Test func roundTripIsUnchanged() throws {
    var item = LibraryItem(title: "Round trip")
    item.setAuthors([Author(givenName: "Ada", familyName: "Lovelace")])
    item.resources = [Resource(itemID: item.id, type: .pdf, path: "PDFs/x.pdf", availability: .local)]
    item.tags = ["a"]
    // Dates are stored to whole seconds, so compare what is written, not the in-memory value.
    let data = try PortableJSON.encoder().encode(item)
    let decoded = try PortableJSON.decoder().decode(LibraryItem.self, from: data)
    #expect(try PortableJSON.encoder().encode(decoded) == data)
    #expect(decoded.authors == item.authors && decoded.resources.map(\.relativePath) == ["PDFs/x.pdf"])
  }

  @Test func migrationsRunOnceAndRecordTheirVersion() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try LocalDatabase(url: url)
    #expect(db.schemaVersion == LocalDatabase.currentSchemaVersion)
    try db.execute("PRAGMA user_version=\(LocalDatabase.currentSchemaVersion + 1)")
    #expect(throws: LibraryError.self) { _ = try LocalDatabase(url: url) }
  }
}
