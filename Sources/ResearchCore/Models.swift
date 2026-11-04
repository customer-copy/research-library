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

// MARK: - Tolerant decoding

// Metadata files outlive app versions. A field that a newer build added (or an older build
// never wrote) must not make a whole paper unreadable, so every property that has a default
// in the model falls back to it when absent. Required identity fields stay required.
extension KeyedDecodingContainer {
  func value<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
    try decodeIfPresent(T.self, forKey: key) ?? fallback()
  }
}
extension Author {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.value(.id, or: UUID() as UUID)
    givenName = try c.value(.givenName, or: "" as String)
    middleName = try c.value(.middleName, or: "" as String)
    familyName = try c.value(.familyName, or: "" as String)
    suffix = try c.value(.suffix, or: "" as String)
    orcid = try c.decodeIfPresent(String.self, forKey: .orcid)
  }
}
extension Authorship {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    authorID = try c.decode(UUID.self, forKey: .authorID)
    order = try c.decode(Int.self, forKey: .order)
    role = try c.value(.role, or: "author" as String)
  }
}
extension Resource {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.value(.id, or: UUID() as UUID)
    itemID = try c.decode(UUID.self, forKey: .itemID)
    type = try c.decode(ResourceType.self, forKey: .type)
    remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
    relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
    mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
    sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
    originalSHA256 = try c.decodeIfPresent(String.self, forKey: .originalSHA256)
    availability = try c.decode(Availability.self, forKey: .availability)
    source = try c.value(.source, or: "user" as String)
    dateAdded = try c.value(.dateAdded, or: Date() as Date)
    primary = try c.value(.primary, or: false as Bool)
  }
}
extension MetadataSnapshot {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    source = try c.decode(String.self, forKey: .source)
    retrievedAt = try c.value(.retrievedAt, or: Date() as Date)
    format = try c.decode(String.self, forKey: .format)
    payload = try c.decode(String.self, forKey: .payload)
  }
}
extension LibraryItem {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    type = try c.value(.type, or: .journalArticle as ItemType)
    title = try c.value(.title, or: "Untitled" as String)
    subtitle = try c.value(.subtitle, or: "" as String)
    abstract = try c.value(.abstract, or: "" as String)
    publicationDate = try c.decodeIfPresent(String.self, forKey: .publicationDate)
    year = try c.decodeIfPresent(Int.self, forKey: .year)
    journal = try c.value(.journal, or: "" as String)
    volume = try c.value(.volume, or: "" as String)
    issue = try c.value(.issue, or: "" as String)
    pages = try c.value(.pages, or: "" as String)
    doi = try c.decodeIfPresent(String.self, forKey: .doi)
    pmid = try c.decodeIfPresent(String.self, forKey: .pmid)
    pmcid = try c.decodeIfPresent(String.self, forKey: .pmcid)
    arxivID = try c.decodeIfPresent(String.self, forKey: .arxivID)
    canonicalURL = try c.decodeIfPresent(String.self, forKey: .canonicalURL)
    citationKey = try c.value(.citationKey, or: "" as String)
    dateAdded = try c.value(.dateAdded, or: Date.distantPast as Date)
    dateModified = try c.value(.dateModified, or: Date.distantPast as Date)
    favorite = try c.value(.favorite, or: false as Bool)
    read = try c.value(.read, or: false as Bool)
    confidence = try c.value(.confidence, or: 0.2 as Double)
    provenance = try c.value(.provenance, or: [] as [Provenance])
    notes = try c.value(.notes, or: "" as String)
    tags = try c.value(.tags, or: [] as [String])
    collections = try c.value(.collections, or: [] as [String])
    authors = try c.value(.authors, or: [] as [Author])
    authorships = try c.value(.authorships, or: [] as [Authorship])
    resources = try c.value(.resources, or: [] as [Resource])
    humanEdited = try c.value(.humanEdited, or: false as Bool)
    publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
    language = try c.decodeIfPresent(String.self, forKey: .language)
    issn = try c.decodeIfPresent([String].self, forKey: .issn)
    isbn = try c.decodeIfPresent([String].self, forKey: .isbn)
    keywords = try c.decodeIfPresent([String].self, forKey: .keywords)
    licenseURLs = try c.decodeIfPresent([String].self, forKey: .licenseURLs)
    sourceMetadata = try c.decodeIfPresent([MetadataSnapshot].self, forKey: .sourceMetadata)
    importedIDs = try c.decodeIfPresent([String].self, forKey: .importedIDs)
    pdfFilenameHints = try c.decodeIfPresent([String].self, forKey: .pdfFilenameHints)
    pdfLookup = try c.decodeIfPresent(PDFLookup.self, forKey: .pdfLookup)
  }
}
extension IngestionRequest {
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    createdAt = try c.value(.createdAt, or: Date() as Date)
    source = try c.value(.source, or: "manual" as String)
    sourceDevice = try c.decodeIfPresent(String.self, forKey: .sourceDevice)
    inputURL = try c.decodeIfPresent(String.self, forKey: .inputURL)
    inputFile = try c.decodeIfPresent(String.self, forKey: .inputFile)
    inboxCleanupComplete = try c.decodeIfPresent(Bool.self, forKey: .inboxCleanupComplete)
    importCommit = try c.decodeIfPresent(ImportCommitCheckpoint.self, forKey: .importCommit)
    inputText = try c.decodeIfPresent(String.self, forKey: .inputText)
    doi = try c.decodeIfPresent(String.self, forKey: .doi)
    pmid = try c.decodeIfPresent(String.self, forKey: .pmid)
    suggestedTitle = try c.decodeIfPresent(String.self, forKey: .suggestedTitle)
    titleIsFilename = try c.decodeIfPresent(Bool.self, forKey: .titleIsFilename)
    suggestedCollection = try c.decodeIfPresent(String.self, forKey: .suggestedCollection)
    suggestedTags = try c.value(.suggestedTags, or: [] as [String])
    note = try c.value(.note, or: "" as String)
    state = try c.value(.state, or: .discovered as IngestionState)
    error = try c.decodeIfPresent(String.self, forKey: .error)
    retryCount = try c.value(.retryCount, or: 0 as Int)
    resultID = try c.decodeIfPresent(UUID.self, forKey: .resultID)
    candidateID = try c.decodeIfPresent(UUID.self, forKey: .candidateID)
    duplicateChoice = try c.value(.duplicateChoice, or: .automatic as DuplicateChoice)
  }
}

// A value from a newer app version decodes to a safe fallback instead of failing the file.
extension ItemType {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ItemType(rawValue: raw) ?? .genericDocument
  }
}
extension ResourceType {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = ResourceType(rawValue: raw) ?? .other
  }
}
extension Availability {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = Availability(rawValue: raw) ?? .unavailable
  }
}
extension PDFLookupStatus {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = PDFLookupStatus(rawValue: raw) ?? .needsReview
  }
}
extension IngestionState {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = IngestionState(rawValue: raw) ?? .awaitingReview
  }
}
extension DuplicateChoice {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = DuplicateChoice(rawValue: raw) ?? .automatic
  }
}
