import Foundation
import Testing
@testable import ResearchCore

/// Replays canned OpenAlex responses and records every requested URL.
private actor OpenAlexFixture: HTTPTransport {
  enum Reply { case json(Any), status(Int) }
  private let reply: @Sendable (URL) -> Reply
  private(set) var requests: [URL] = []
  init(_ reply: @escaping @Sendable (URL) -> Reply) { self.reply = reply }
  func data(_ url: URL) async throws -> (Data, HTTPURLResponse) {
    requests.append(url)
    switch reply(url) {
    case .status(let code):
      // Mirrors NativeHTTPTransport, which throws on any non-2xx response.
      throw HTTPStatusError(statusCode: code)
    case .json(let object):
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (try JSONSerialization.data(withJSONObject: object), response)
    }
  }
}

private func work(_ title: String, year: Int? = 2021, authors: [String] = ["Ada Lovelace"],
  id: String = "https://openalex.org/W1", doi: String? = nil) -> [String: Any] {
  var value: [String: Any] = [
    "id": id, "title": title,
    "authorships": authors.map { ["author": ["display_name": $0]] },
  ]
  if let year { value["publication_year"] = year; value["publication_date"] = "\(year)-03-01" }
  if let doi { value["doi"] = "https://doi.org/" + doi }
  return value
}

private func item(_ title: String, year: Int? = 2021, family: String? = "Lovelace",
  doi: String? = nil) -> LibraryItem {
  var item = LibraryItem(title: title)
  item.year = year
  item.doi = doi
  if let family { item.setAuthors([Author(givenName: "Ada", familyName: family)]) }
  return item
}

@Suite struct OpenAlexTests {
  let title = "Single-cell atlas of the enteric nervous system"

  // MARK: Lookup

  @Test func unknownDOIReturnsNilWithoutTitleFallback() async throws {
    let fixture = OpenAlexFixture { _ in .status(404) }
    let client = OpenAlexClient(transport: fixture, apiKey: nil)
    let result = try await client.work(for: item(title, doi: "10.1000/missing"))
    #expect(result == nil)
    #expect(await fixture.requests.count == 1)
  }

  @Test func serverErrorsStillThrow() async throws {
    let client = OpenAlexClient(transport: OpenAlexFixture { _ in .status(500) }, apiKey: nil)
    await #expect(throws: HTTPStatusError.self) {
      _ = try await client.work(for: item(title, doi: "10.1000/x"))
    }
  }

  @Test func statusErrorKeepsHistoricalMessage() {
    #expect(HTTPStatusError(statusCode: 403).localizedDescription == "HTTP 403")
  }

  @Test func titleSearchAcceptsExactCorroboratedMatch() async throws {
    let fixture = OpenAlexFixture { _ in .json(["results": [
      work("Single-cell atlas of the enteric nervous system and its glia", id: "W-longer"),
      work("Single-Cell Atlas of the <i>Enteric</i> Nervous System", id: "W-exact"),
    ]]) }
    let client = OpenAlexClient(transport: fixture, apiKey: nil)
    let record = try await client.work(for: item(title))
    #expect(record?.id == "W-exact")
  }

  // MARK: Title matching rules

  @Test func substringAndEmptyTitlesNeverMatch() {
    let results = [work("Single-cell atlas of the enteric nervous system and glia"), work("")]
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title), in: results) == nil)
    #expect(OpenAlexMatch.bestTitleMatch(for: item("Atlas"), in: [work("Atlas")]) == nil)
  }

  @Test func yearAndAuthorMustAgree() {
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title), in: [work(title, year: 2018)]) == nil)
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title), in: [work(title, year: 2022)]) != nil)
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title), in: [work(title, authors: ["Grace Hopper"])]) == nil)
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title, family: "Lövelace"), in: [work(title)]) != nil)
  }

  @Test func uncorroboratedOrAmbiguousTitlesAreRejected() {
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title, year: nil, family: nil), in: [work(title)]) == nil)
    let twins = [work(title, id: "W1"), work(title, id: "W2")]
    #expect(OpenAlexMatch.bestTitleMatch(for: item(title), in: twins) == nil)
  }

  // MARK: Merge rules

  private func record(doi: String? = "10.1000/openalex", title: String = "OpenAlex Title",
    journal: String? = "Nature", authors: [String] = ["Grace Hopper"], raw: String = "{\"v\":1}") -> OpenAlexWorkRecord {
    OpenAlexWorkRecord(id: "W1", doi: doi, title: title, publicationDate: "2021-03-01",
      journal: journal, authors: authors, topics: ["Neuroscience"], rawJSON: raw)
  }

  @Test func existingDOIAndAuthorsAreNeverReplaced() throws {
    var original = item(title, doi: "10.1000/mine")
    original.authors[0].orcid = "0000-0002-1825-0097"
    original.setAuthors(original.authors)
    let merged = try #require(OpenAlexMerge.apply(record(), to: original))
    #expect(merged.doi == "10.1000/mine")
    #expect(merged.authors.map(\.familyName) == ["Lovelace"])
    #expect(merged.authors.first?.orcid == "0000-0002-1825-0097")
    #expect(merged.title == "OpenAlex Title")  // DOI match: OpenAlex title is trusted
  }

  @Test func titleMatchOnlyFillsEmptyFields() throws {
    var original = item(title, family: nil)
    original.journal = "Cell"
    let merged = try #require(OpenAlexMerge.apply(record(title: title), to: original))
    #expect(merged.journal == "Cell")
    #expect(merged.doi == "10.1000/openalex")
    #expect(merged.authors.map(\.familyName) == ["Hopper"])
  }

  @Test func humanEditsArePreserved() throws {
    var original = item(title)
    original.humanEdited = true
    let merged = try #require(OpenAlexMerge.apply(record(), to: original))
    #expect(merged.title == title)
    #expect(merged.doi == nil)
    #expect(merged.sourceMetadata?.first?.source == "OpenAlex")
  }

  @Test func repeatingTheSameRecordChangesNothing() throws {
    let first = try #require(OpenAlexMerge.apply(record(), to: item(title, doi: "10.1000/mine")))
    #expect(OpenAlexMerge.apply(record(), to: first) == nil)
    #expect(OpenAlexMerge.apply(record(raw: "{\"v\":2}"), to: first) != nil)
  }

  // MARK: Dashboard paging

  @Test func dashboardItemsReturnsMoreThan500() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenAlexPaging-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let dbURL = root.appendingPathComponent("index.sqlite")
    let library = try LibraryService(root: root, databaseURL: dbURL, providers: [])
    let db = try LocalDatabase(url: dbURL)
    for n in 0..<620 { try db.upsert(LibraryItem(title: "Paper \(n)")) }
    let all = try await library.dashboardItems()
    #expect(all.count == 620)
    #expect(Set(all.map(\.id)).count == 620)
    #expect(try await library.dashboardItems(limit: 510).count == 510)
  }
}
