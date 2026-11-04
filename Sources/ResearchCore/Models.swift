import Foundation

public enum ItemType: String, Codable, CaseIterable, Sendable {
  case journalArticle, preprint, conferencePaper, bookChapter, report, thesis, genericDocument,
    webResource
}
public struct Author: Codable, Identifiable, Hashable, Sendable {
  public var id = UUID()
  public var givenName = ""
  public var middleName = ""
  public var familyName = ""
  public var suffix = ""
  public var orcid: String?
  public init(givenName: String = "", familyName: String = "") {
    self.givenName = givenName
    self.familyName = familyName
  }
  public var displayName: String {
    [givenName, middleName, familyName, suffix].filter { !$0.isEmpty }.joined(separator: " ")
  }
}
public struct Authorship: Codable, Hashable, Sendable {
  public var authorID: UUID
  public var order: Int
  public var role: String = "author"
  public init(authorID: UUID, order: Int) {
    self.authorID = authorID
    self.order = order
  }
}
public enum ResourceType: String, Codable, Sendable {
  case publisherPage, landingPage, doi, pubmed, arxiv, pdf, supplement, webpage, other
}
public enum Availability: String, Codable, Sendable {
  case remote, local, unavailable, requiresAuthentication, missing
}
public struct Resource: Codable, Identifiable, Hashable, Sendable {
  public var id = UUID()
  public var itemID: UUID
  public var type: ResourceType
  public var remoteURL: String?
  public var relativePath: String?
  public var mimeType: String?
  public var sha256: String?
  public var originalSHA256: String?
  public var availability: Availability
  public var source = "user"
  public var dateAdded = Date()
  public var primary = false
  public init(
    itemID: UUID, type: ResourceType, url: String? = nil, path: String? = nil,
    availability: Availability = .remote
  ) {
    self.itemID = itemID
    self.type = type
    remoteURL = url
    relativePath = path
    self.availability = availability
  }
}
public struct Provenance: Codable, Hashable, Sendable {
  public var source: String
  public var date: Date
  public var explanation: String
  public init(_ source: String, _ explanation: String) {
    self.source = source
    self.explanation = explanation
    date = Date()
  }
}
public struct MetadataSnapshot: Codable, Hashable, Sendable {
  public var source: String
  public var retrievedAt = Date()
  public var format: String
  public var payload: String
  public init(source: String, format: String, payload: String) {
    self.source = source
    self.format = format
    self.payload = payload
  }
}
public enum PDFLookupStatus: String, Codable, Sendable {
  case pending, available, notFound, requiresAuthentication, needsReview, retry
}
public struct PDFLookup: Codable, Hashable, Sendable {
  public var status: PDFLookupStatus
  public var checkedAt: Date?
  public var detail: String
  public init(_ status: PDFLookupStatus, detail: String, checkedAt: Date? = nil) {
    self.status = status; self.detail = detail; self.checkedAt = checkedAt
  }
}
public struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
  public var id = UUID()
  public var type: ItemType = .journalArticle
  public var title = "Untitled"
  public var subtitle = ""
  public var abstract = ""
  public var publicationDate: String?
  public var year: Int?
  public var journal = ""
  public var volume = ""
  public var issue = ""
  public var pages = ""
  public var doi: String?
  public var pmid: String?
  public var pmcid: String?
  public var arxivID: String?
  public var canonicalURL: String?
  public var citationKey = ""
  public var dateAdded = Date()
  public var dateModified = Date()
  public var favorite = false
  public var read = false
  public var confidence: Double = 0.2
  public var provenance: [Provenance] = []
  public var notes = ""
  public var tags: [String] = []
  public var collections: [String] = []
  public var authors: [Author] = []
  public var authorships: [Authorship] = []
  public var resources: [Resource] = []
  public var humanEdited = false
  public var publisher: String?
  public var language: String?
  public var issn: [String]?
  public var isbn: [String]?
  public var keywords: [String]?
  public var licenseURLs: [String]?
  public var sourceMetadata: [MetadataSnapshot]?
  public var importedIDs: [String]?
  public var pdfFilenameHints: [String]?
  public var pdfLookup: PDFLookup?
  public init(id: UUID = UUID(), title: String = "Untitled") {
    self.id = id
    self.title = title
  }
  public var orderedAuthors: [Author] {
    if authorships.isEmpty { return authors }
    return authorships.sorted { $0.order < $1.order }.compactMap { link in
      authors.first { $0.id == link.authorID }
    }
  }
  public var authorText: String { orderedAuthors.map(\.displayName).joined(separator: "; ") }
  public var hasPDF: Bool {
    resources.contains { $0.type == .pdf && $0.relativePath != nil && $0.availability == .local }
  }
  public mutating func setAuthors(_ value: [Author]) {
    authors = value
    authorships = value.enumerated().map { Authorship(authorID: $0.element.id, order: $0.offset) }
  }
  public var citation: String {
    "\(authorText) (\(year.map(String.init) ?? "n.d.")). \(title). \(journal).\(doi.map { " https://doi.org/" + $0 } ?? "")"
  }
}
public enum IngestionState: String, Codable, Sendable {
  case discovered, waitingForResource, hashing, extractingIdentifiers, resolvingMetadata,
    checkingDuplicates, awaitingReview, importing, extractingText, indexing, complete, failed
}
public enum DuplicateChoice: String, Codable, Sendable { case automatic, attach, keepBoth, cancel }
/// Persisted before copying bytes. The destination and resource identity survive a restart.
public struct ImportCommitCheckpoint: Codable, Sendable {
  public var item: LibraryItem
  public var resource: Resource
  public var baseRecordHash: String?
  public init(item: LibraryItem, resource: Resource, baseRecordHash: String? = nil) {
    self.item = item
    self.resource = resource
    self.baseRecordHash = baseRecordHash
  }
}
public struct IngestionRequest: Codable, Identifiable, Sendable {
  public var id = UUID()
  public var createdAt = Date()
  public var source = "manual"
  public var sourceDevice: String?
  public var inputURL: String?
  public var inputFile: String?
  public var inboxCleanupComplete: Bool?
  public var importCommit: ImportCommitCheckpoint?
  public var inputText: String?
  public var doi: String?
  public var pmid: String?
  public var suggestedTitle: String?
  public var titleIsFilename: Bool?
  public var suggestedCollection: String?
  public var suggestedTags: [String] = []
  public var note = ""
  public var state: IngestionState = .discovered
  public var error: String?
  public var retryCount = 0
  public var resultID: UUID?
  public var candidateID: UUID?
  public var duplicateChoice: DuplicateChoice = .automatic
  public init(source: String = "manual", text: String? = nil, file: String? = nil) {
    self.source = source
    inputText = text
    inputFile = file
  }
}
public struct DocumentPage: Codable, Identifiable, Sendable {
  public var id: UUID
  public var itemID: UUID
  public var resourceID: UUID
  public var pageNumber: Int
  public var text: String
  public var method: String
  public var extractionVersion = 1
}
public struct Section: Codable, Identifiable, Sendable {
  public var id: UUID
  public var itemID: UUID
  public var heading: String
  public var type: String
  public var startPage: Int
  public var endPage: Int
  public var sequence: Int
  public var text: String
  public var extractionVersion = 1
}
public struct Chunk: Codable, Identifiable, Sendable {
  public var id: UUID
  public var itemID: UUID
  public var resourceID: UUID
  public var sectionID: UUID?
  public var startPage: Int
  public var endPage: Int
  public var sequence: Int
  public var text: String
  public var approximateTokens: Int
  public var extractionVersion = 1
}
public enum LibrarySort: Sendable, Equatable { case relevance, dateAdded, title, year, publicationDate }
public struct SearchFilters: Sendable {
  public var sort: LibrarySort = .relevance
  public var author = ""
  public var yearMin: Int?
  public var yearMax: Int?
  public var journal = ""
  public var tag: String?
  public var collection: String?
  public var favorite: Bool?
  public var read: Bool?
  public var hasPDF: Bool?
  public var needsReview = false
  public var recentlyAdded = false
  public init() {}
}
public struct RetrievalResult: Identifiable, Sendable {
  /// The library presents one row per article; its selection survives metadata/PDF refinement.
  public var id: String { item.id.uuidString }
  public var pageMatchID: String {
    item.id.uuidString + (resourceID?.uuidString ?? "") + String(pageStart ?? 0)
  }
  public var item: LibraryItem
  public var chunkID: UUID?
  public var resourceID: UUID?
  public var snippet: String
  public var score: Double
  public var pageStart: Int?
  public var pageEnd: Int?
  public var section: String?
  public init(
    item: LibraryItem, chunkID: UUID? = nil, resourceID: UUID? = nil, snippet: String = "",
    score: Double = 0, pageStart: Int? = nil, pageEnd: Int? = nil, section: String? = nil
  ) {
    self.item = item
    self.chunkID = chunkID
    self.resourceID = resourceID
    self.snippet = snippet
    self.score = score
    self.pageStart = pageStart
    self.pageEnd = pageEnd
    self.section = section
  }
}
public protocol RetrievalService: Sendable {
  func search(_ query: String, filters: SearchFilters, limit: Int, offset: Int) async throws
    -> [RetrievalResult]
}
public protocol SemanticIndex: Sendable {
  func index(_ chunk: Chunk) async throws
  func remove(_ id: UUID) async throws
  func search(_ query: String, limit: Int) async throws -> [UUID]
}
public enum LibraryError: Error, LocalizedError {
  case invalid(String)
  case database(String)
  case missingLibrary
  case conflict(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let s), .database(let s), .conflict(let s): return s
    case .missingLibrary: return "Select a library folder first."
    }
  }
}
public enum PortableJSON {
  public static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
  }
  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
}
