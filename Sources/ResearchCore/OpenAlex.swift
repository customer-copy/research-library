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
  public func work(for item: LibraryItem) async throws -> OpenAlexWorkRecord? {
    if let doi = item.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty {
      let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
      let (data, response) = try await transport.data(try url(path: "works/https://doi.org/\(encoded)"))
      if response.statusCode == 404 { return nil }
      guard (200..<300).contains(response.statusCode) else { throw LibraryError.invalid("OpenAlex request failed (HTTP \(response.statusCode))") }
      return try OpenAlexWorkRecord.decode(data)
    }
    guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let (data, response) = try await transport.data(try url(path: "works", query: ["search": item.title, "per-page": "5"]))
    guard (200..<300).contains(response.statusCode), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = root["results"] as? [[String: Any]] else { return nil }
    let normalized = item.title.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    for value in results {
      let candidate = (value["title"] as? String ?? "").lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
      if candidate == normalized || candidate.contains(normalized) || normalized.contains(candidate) {
        return try OpenAlexWorkRecord.decode(try JSONSerialization.data(withJSONObject: value))
      }
    }
    return nil
  }
  public func recentWorks(search: String?, from date: String, limit: Int = 20) async throws -> [OpenAlexWorkRecord] {
    var query = ["filter": "from_publication_date:\(date)", "sort": "publication_date:desc", "per-page": String(min(max(limit, 1), 100))]
    if let search, !search.isEmpty { query["search"] = search }
    let (data, response) = try await transport.data(try url(path: "works", query: query))
    guard (200..<300).contains(response.statusCode), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let results = root["results"] as? [[String: Any]] else { throw LibraryError.invalid("OpenAlex feed request failed (HTTP \(response.statusCode))") }
    return try results.map { try OpenAlexWorkRecord.decode(try JSONSerialization.data(withJSONObject: $0)) }
  }
}
