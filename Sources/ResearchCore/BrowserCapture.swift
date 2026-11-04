import Foundation

/// A small, validated handoff from the Safari extension to the app that owns the library bookmark.
/// The extension cannot read the library, notes, PDFs, or the app's security-scoped bookmark.
public enum BrowserCapture {
  /// A UUID-only notification. Rich metadata stays in the durable local Inbox payload.
  public static func chromeID(from url: URL) throws -> UUID {
    guard url.scheme == "researchlibrary", url.host == "chrome-capture", url.path.isEmpty,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let query = parts.queryItems, query.count == 1, query[0].name == "id",
      let value = query[0].value, let id = UUID(uuidString: value)
    else { throw LibraryError.invalid("Invalid Chrome capture notification") }
    return id
  }
  public static func request(from url: URL) throws -> IngestionRequest {
    guard url.scheme == "researchlibrary", url.host == "capture", url.path.isEmpty,
      url.absoluteString.utf8.count <= 24_000,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw LibraryError.invalid("Invalid browser capture link") }
    let pairs = components.queryItems ?? []
    guard Set(pairs.map(\.name)).count == pairs.count else {
      throw LibraryError.invalid("Duplicate browser capture fields")
    }
    let fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
    guard fields["version"] == "1", let token = fields["id"], let id = UUID(uuidString: token),
      let value = fields["url"], value.utf8.count <= 8_000
    else { throw LibraryError.invalid("Incomplete browser capture") }
    let page = try Identifiers.canonicalURL(value)
    var request = IngestionRequest(source: "safariExtension", text: page.absoluteString)
    request.id = id
    request.inputURL = page.absoluteString
    if let pdf = fields["pdfURL"], !pdf.isEmpty {
      guard pdf.utf8.count <= 8_000 else { throw LibraryError.invalid("PDF link is too long") }
      request.inputURL = try Identifiers.canonicalURL(pdf).absoluteString
    }
    if let title = fields["title"], !title.isEmpty { request.suggestedTitle = String(title.prefix(500)) }
    if let doi = fields["doi"], !doi.isEmpty {
      guard doi.count <= 200, let identifier = Identifiers.doi(doi) else {
        throw LibraryError.invalid("Invalid DOI in browser capture")
      }
      request.doi = identifier
    }
    if let pmid = fields["pmid"], !pmid.isEmpty {
      guard (1...9).contains(pmid.count), pmid.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw LibraryError.invalid("Invalid PMID in browser capture")
      }
      request.pmid = pmid
    }
    return request
  }
}

/// Bounded page data extracted by the browser, never instructions or executable content.
public struct ChromePageMetadata: Codable, Sendable {
  public struct PageAuthor: Codable, Sendable {
    public var name: String?
    public var givenName: String?
    public var familyName: String?
    public var orcid: String?
  }
  public var title: String?
  public var authors: [PageAuthor]?
  public var doi: String?
  public var pmid: String?
  public var journal: String?
  public var publicationDate: String?
  public var abstract: String?
  public var volume: String?
  public var issue: String?
  public var pages: String?
  public var publisher: String?
  public var language: String?
  public var issn: [String]?
  public var keywords: [String]?

  public func item(id: UUID, page: URL, pdf: URL?) -> LibraryItem {
    var item = LibraryItem(id: id, title: String((title ?? page.host ?? "Article").prefix(1000)))
    item.canonicalURL = page.absoluteString
    item.doi = doi.flatMap(Identifiers.doi)
    if let pmid, pmid.range(of: "^[0-9]{1,9}$", options: .regularExpression) != nil { item.pmid = pmid }
    item.journal = String((journal ?? "").prefix(500))
    item.abstract = String((abstract ?? "").prefix(20000))
    item.publicationDate = publicationDate.map { String($0.prefix(30)).replacingOccurrences(of: "/", with: "-") }
    item.year = item.publicationDate.flatMap { Int($0.prefix(4)) }
    item.volume = String((volume ?? "").prefix(100)); item.issue = String((issue ?? "").prefix(100))
    item.pages = String((pages ?? "").prefix(100)); item.publisher = publisher.map { String($0.prefix(500)) }
    item.language = language.map { String($0.prefix(30)) }
    item.issn = issn.map { Array($0.prefix(10)).map { String($0.prefix(30)) } }
    item.keywords = keywords.map { Array($0.prefix(100)).map { String($0.prefix(200)) } }
    item.setAuthors(Array((authors ?? []).prefix(300)).map { value in
      let name = String((value.name ?? "").prefix(300))
      var author = Author(givenName: String((value.givenName ?? "").prefix(200)), familyName: String((value.familyName ?? "").prefix(200)))
      if author.familyName.isEmpty {
        if let comma = name.firstIndex(of: ",") {
          author.familyName = String(name[..<comma]).trimmingCharacters(in: .whitespaces)
          author.givenName = String(name[name.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        } else {
          let parts = name.split(separator: " ")
          author.familyName = parts.last.map(String.init) ?? name
          author.givenName = parts.dropLast().joined(separator: " ")
        }
      }
      author.orcid = value.orcid.map { String($0.prefix(100)) }
      return author
    })
    item.confidence = item.doi == nil ? 0.7 : 0.95
    item.resources = [Resource(itemID: id, type: .publisherPage, url: page.absoluteString)]
    if let pdf { item.resources.append(Resource(itemID: id, type: .pdf, url: pdf.absoluteString)) }
    item.provenance = [Provenance("Chrome page", "Citation metadata captured from the page on the user's click")]
    if let payload = try? JSONEncoder().encode(self), let json = String(data: payload, encoding: .utf8) {
      item.sourceMetadata = [MetadataSnapshot(source: "Chrome page", format: "json", payload: json)]
    }
    return item
  }
}

public struct ChromeCaptureEnvelope: Codable, Sendable {
  public var version: Int
  public var id: UUID
  public var url: String
  public var pdfURL: String?
  public var metadata: ChromePageMetadata
  public var phase: String
  public var error: String?

  public static func read(id: UUID, root: URL) throws -> ChromeCaptureEnvelope {
    let relative = "Inbox/BrowserCaptures/\(id.uuidString.lowercased()).json"
    let path = try Files.safeURL(root: root, relative: relative)
    let data = try Files.coordinatedRead(path) { try Data(contentsOf: $0) }
    guard data.count <= 128 * 1024 else { throw LibraryError.invalid("Browser metadata is too large") }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == 2, value.id == id, ["pending", "ready", "failed"].contains(value.phase) else {
      throw LibraryError.invalid("Invalid browser metadata payload")
    }
    _ = try Identifiers.canonicalURL(value.url)
    if let pdf = value.pdfURL { _ = try Identifiers.canonicalURL(pdf) }
    return value
  }
}
