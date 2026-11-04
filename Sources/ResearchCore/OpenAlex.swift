import Foundation
import Security

/// A compact, source-backed OpenAlex work record. The complete response is retained in
/// `rawJSON` so fields can be reinterpreted without another network request.
public struct OpenAlexWorkRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var doi: String?
  public var title: String
  public var publicationDate: String?
  public var journal: String?
  public var authors: [String]
  public var topics: [String]
  public var citedByCount: Int
  public var openAccessURL: String?
  public var rawJSON: String
  public var retrievedAt: Date

  public init(id: String, doi: String? = nil, title: String, publicationDate: String? = nil,
              journal: String? = nil, authors: [String] = [], topics: [String] = [],
              citedByCount: Int = 0, openAccessURL: String? = nil, rawJSON: String = "",
              retrievedAt: Date = Date()) {
    self.id = id; self.doi = doi; self.title = title; self.publicationDate = publicationDate
    self.journal = journal; self.authors = authors; self.topics = topics
    self.citedByCount = citedByCount; self.openAccessURL = openAccessURL
    self.rawJSON = rawJSON; self.retrievedAt = retrievedAt
  }

  public var year: Int? { publicationDate.flatMap { Int($0.prefix(4)) } }

  public static func decode(_ data: Data, retrievedAt: Date = Date()) throws -> OpenAlexWorkRecord {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? String, let title = object["title"] as? String else {
      throw LibraryError.invalid("OpenAlex returned an invalid work")
    }
    let primary = object["primary_location"] as? [String: Any]
    let source = primary?["source"] as? [String: Any]
    let landing = primary?["landing_page_url"] as? String
    let pdf = primary?["pdf_url"] as? String
    let oa = object["open_access"] as? [String: Any]
    let authors = (object["authorships"] as? [[String: Any]] ?? []).compactMap {
      ($0["author"] as? [String: Any])?["display_name"] as? String
    }
    var topics = (object["topics"] as? [[String: Any]] ?? []).compactMap {
      ($0["display_name"] as? String) ?? (($0["subfield"] as? [String: Any])?["display_name"] as? String)
    }
    if topics.isEmpty { topics = (object["concepts"] as? [[String: Any]] ?? []).compactMap { $0["display_name"] as? String } }
    let raw = String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
    return OpenAlexWorkRecord(
      id: id, doi: (object["doi"] as? String)?.replacingOccurrences(of: "https://doi.org/", with: ""),
      title: title, publicationDate: object["publication_date"] as? String,
      journal: source?["display_name"] as? String, authors: authors, topics: topics,
      citedByCount: object["cited_by_count"] as? Int ?? 0,
      openAccessURL: pdf ?? landing ?? oa?["oa_url"] as? String, rawJSON: raw, retrievedAt: retrievedAt)
  }
}

public struct OpenAlexDashboardSnapshot: Codable, Sendable {
  public var generatedAt: Date
  public var syncedCount: Int
  public var matchedCount: Int
  public var feed: [OpenAlexWorkRecord]
  public var matched: [OpenAlexWorkRecord]
  public var localCounts: [String: Int]
  /// Small local-only data used to draw Overview immediately while the index refreshes.
  public var summary: DashboardSummary?
  public init(generatedAt: Date = Date(), syncedCount: Int = 0, matchedCount: Int = 0,
              feed: [OpenAlexWorkRecord] = [], matched: [OpenAlexWorkRecord] = [],
              localCounts: [String: Int] = [:], summary: DashboardSummary? = nil) {
    self.generatedAt = generatedAt; self.syncedCount = syncedCount; self.matchedCount = matchedCount
    self.feed = feed; self.matched = matched; self.localCounts = localCounts; self.summary = summary
  }
}
public struct DashboardTopic: Codable, Hashable, Identifiable, Sendable {
  public var name: String
  public var count: Int
  public var id: String { name }
  public init(name: String, count: Int) { self.name = name; self.count = count }
}
public struct DashboardReadingItem: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var journal: String
  public var year: Int?
  public init(id: UUID, title: String, journal: String, year: Int?) {
    self.id = id; self.title = title; self.journal = journal; self.year = year
  }
}
public struct DashboardSummary: Codable, Sendable {
  public var generatedAt: Date
  public var counts: [String: Int]
  public var continueReading: [DashboardReadingItem]
  public var topics: [DashboardTopic]
  public init(generatedAt: Date = Date(), counts: [String: Int] = [:],
              continueReading: [DashboardReadingItem] = [], topics: [DashboardTopic] = []) {
    self.generatedAt = generatedAt; self.counts = counts
    self.continueReading = continueReading; self.topics = topics
  }
}

public enum OpenAlexCredentialStore {
  private static let service = "org.researchlibrary.openalex"
  private static let account = "api-key"
  public static func read() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  public static func save(_ value: String) throws {
    let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query; item[kSecValueData as String] = data
      guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LibraryError.invalid("Could not save the OpenAlex API key") }
    } else if status != errSecSuccess { throw LibraryError.invalid("Could not save the OpenAlex API key") }
  }
  public static func remove() { let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]; SecItemDelete(query as CFDictionary) }
}

public struct OpenAlexClient: Sendable {
  public let transport: any HTTPTransport
  public let apiKey: String?
  public init(transport: any HTTPTransport = NativeHTTPTransport(), apiKey: String? = OpenAlexCredentialStore.read()) {
    self.transport = transport; self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
  }
  private func url(path: String, query: [String: String] = [:]) throws -> URL {
    var components = URLComponents(string: "https://api.openalex.org/" + path)!
    var values = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    if let apiKey { values.append(URLQueryItem(name: "api_key", value: apiKey)) }
    components.queryItems = values
    guard let result = components.url else { throw LibraryError.invalid("Invalid OpenAlex request") }
    return result
  }
  /// Fetches a URL, treating "not found" as a normal empty answer rather than an error.
  private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse)? {
    do {
      let (data, response) = try await transport.data(url)
      if response.statusCode == 404 { return nil }
      guard (200..<300).contains(response.statusCode) else {
        throw HTTPStatusError(statusCode: response.statusCode)
      }
      return (data, response)
    } catch let error as HTTPStatusError where error.statusCode == 404 {
      return nil
    }
  }
  /// Looks up the OpenAlex work for a library item.
  ///
  /// - With a DOI: exact DOI lookup only. An unknown DOI returns nil; it never falls back
  ///   to a title search, because a DOI that OpenAlex lacks is not evidence of another work.
  /// - Without a DOI: a title search, accepted only under `OpenAlexMatch.bestTitleMatch`.
  public func work(for item: LibraryItem) async throws -> OpenAlexWorkRecord? {
    if let doi = item.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty {
      let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
      guard let response = try await fetch(try url(path: "works/https://doi.org/\(encoded)")) else { return nil }
      return try OpenAlexWorkRecord.decode(response.0)
    }
    guard !OpenAlexMatch.normalizedTitle(item.title).isEmpty else { return nil }
    guard let response = try await fetch(try url(path: "works", query: ["search": item.title, "per-page": "10"])),
      let root = try JSONSerialization.jsonObject(with: response.0) as? [String: Any],
      let results = root["results"] as? [[String: Any]],
      let match = OpenAlexMatch.bestTitleMatch(for: item, in: results) else { return nil }
    return try OpenAlexWorkRecord.decode(try JSONSerialization.data(withJSONObject: match))
  }
  public func recentWorks(search: String?, from date: String, limit: Int = 20) async throws -> [OpenAlexWorkRecord] {
    var query = ["filter": "from_publication_date:\(date)", "sort": "publication_date:desc", "per-page": String(min(max(limit, 1), 100))]
    if let search, !search.isEmpty { query["search"] = search }
    let (data, response) = try await transport.data(try url(path: "works", query: query))
    guard (200..<300).contains(response.statusCode), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = root["results"] as? [[String: Any]] else { throw LibraryError.invalid("OpenAlex feed request failed (HTTP \(response.statusCode))") }
    return try results.map { try OpenAlexWorkRecord.decode(try JSONSerialization.data(withJSONObject: $0)) }
  }
}


/// Strict rules for accepting an OpenAlex title-search result as the same work.
public enum OpenAlexMatch {
  /// Lowercased, diacritic-folded, tag-stripped title keeping only letters and digits,
  /// with runs of whitespace collapsed.
  public static func normalizedTitle(_ title: String) -> String {
    let stripped = title.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let folded = stripped.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let kept = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
  }
  static func folded(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
  /// Accepts a candidate only when all of these hold:
  /// 1. Its normalized title equals the item's (no substring matches; empty titles never match).
  /// 2. At least one corroborating field is checked: the year (within one year, for
  ///    preprint/print gaps) and/or the first author's family name among the first
  ///    three OpenAlex authors. If the item has neither, nothing is accepted.
  /// 3. Exactly one candidate passes; ambiguous results are rejected.
  public static func bestTitleMatch(for item: LibraryItem, in results: [[String: Any]]) -> [String: Any]? {
    let title = normalizedTitle(item.title)
    guard title.count >= 10 else { return nil }
    let family = folded(item.authors.first?.familyName ?? "").trimmingCharacters(in: .whitespaces)
    guard item.year != nil || !family.isEmpty else { return nil }
    let passing = results.filter { candidate in
      guard normalizedTitle(candidate["title"] as? String ?? "") == title else { return false }
      if let year = item.year {
        guard let candidateYear = candidate["publication_year"] as? Int, abs(candidateYear - year) <= 1 else { return false }
      }
      if !family.isEmpty {
        let names = (candidate["authorships"] as? [[String: Any]] ?? []).prefix(3).compactMap {
          ($0["author"] as? [String: Any])?["display_name"] as? String
        }
        guard names.contains(where: { folded($0).contains(family) }) else { return false }
      }
      return true
    }
    return passing.count == 1 ? passing[0] : nil
  }
}

/// How an OpenAlex record updates a library item. Pure, so it can be tested without a library.
public enum OpenAlexMerge {
  /// Returns the updated item, or nil when the record would change nothing.
  ///
  /// - Human-edited items keep all bibliographic fields; only the cached OpenAlex response
  ///   is refreshed.
  /// - An existing DOI is never replaced, and existing authors (with their ORCIDs) are
  ///   never replaced; authors are filled only when the item has none.
  /// - When the item was matched by DOI, OpenAlex's title, date and journal are trusted.
  ///   When it was matched by title, those fields are only filled where empty.
  public static func apply(_ record: OpenAlexWorkRecord, to original: LibraryItem) -> LibraryItem? {
    var item = original
    let matchedByDOI = !(original.doi ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    if !item.humanEdited {
      let titleEmpty = OpenAlexMatch.normalizedTitle(item.title).isEmpty || item.title == "Untitled"
      if !record.title.isEmpty && (matchedByDOI || titleEmpty) { item.title = record.title }
      if let date = record.publicationDate, matchedByDOI || item.publicationDate == nil { item.publicationDate = date }
      if let year = record.year, matchedByDOI || item.year == nil { item.year = year }
      if let journal = record.journal, !journal.isEmpty, matchedByDOI || item.journal.isEmpty { item.journal = journal }
      if (item.doi ?? "").isEmpty, let doi = record.doi, !doi.isEmpty { item.doi = doi }
      if item.authors.isEmpty && !record.authors.isEmpty {
        item.setAuthors(record.authors.map { name in
          let parts = name.split(separator: " ")
          return Author(givenName: parts.dropLast().joined(separator: " "), familyName: parts.last.map(String.init) ?? String(name))
        })
      }
      let mergedKeywords = Array(Set((item.keywords ?? []) + record.topics)).sorted()
      if !mergedKeywords.isEmpty { item.keywords = mergedKeywords }
    }
    var snapshots = item.sourceMetadata ?? []
    let previous = snapshots.first { $0.source == "OpenAlex" }?.payload
    if previous != record.rawJSON {
      snapshots.removeAll { $0.source == "OpenAlex" }
      snapshots.append(MetadataSnapshot(source: "OpenAlex", format: "json", payload: record.rawJSON))
      item.sourceMetadata = snapshots
    }
    guard item != original else { return nil }
    item.provenance.append(Provenance("OpenAlex", matchedByDOI
      ? "Exact DOI match; complete work response cached"
      : "Exact title match corroborated by year/first author; complete work response cached"))
    return item
  }
}
