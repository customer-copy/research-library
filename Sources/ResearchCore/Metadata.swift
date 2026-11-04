import Foundation

public protocol MetadataProvider: Sendable {
  var name: String { get }
  func resolve(_ item: LibraryItem) async throws -> LibraryItem?
}
public protocol HTTPTransport: Sendable {
  func data(_ url: URL) async throws -> (Data, HTTPURLResponse)
}
/// A non-2xx HTTP response. The description keeps the historical "HTTP <code>" text so
/// callers that inspect messages (for example 401/403 access checks) behave as before.
public struct HTTPStatusError: Error, LocalizedError, Sendable {
  public let statusCode: Int
  public init(statusCode: Int) { self.statusCode = statusCode }
  public var errorDescription: String? { "HTTP \(statusCode)" }
}
public struct BioRxivProvider: MetadataProvider {
  public let transport: any HTTPTransport
  public let server: String
  public var name: String { server == "medrxiv" ? "medRxiv" : "bioRxiv" }

  public init(transport: any HTTPTransport, server: String = "biorxiv") {
    self.transport = transport
    self.server = server.lowercased() == "medrxiv" ? "medrxiv" : "biorxiv"
  }

  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    var lookup = item
    let doi = (lookup.doi ?? lookup.canonicalURL.flatMap(Identifiers.doi))?.lowercased()
    guard let doi, doi.hasPrefix("10.1101/") else { return nil }
    lookup.doi = doi
    let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
    guard let url = URL(string: "https://api.biorxiv.org/details/\(server)/\(encoded)/na/json") else {
      return nil
    }
    let (data, _) = try await transport.data(url)
    return try Self.normalize(data, item: lookup, server: server)
  }

  public static func normalize(
    _ data: Data, item: LibraryItem, server: String = "biorxiv"
  ) throws -> LibraryItem {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let collection = root["collection"] as? [[String: Any]], !collection.isEmpty
    else { throw LibraryError.invalid("Invalid \(server) metadata response") }
    guard let record = collection.first(where: {
      guard let returned = $0["doi"] as? String else { return false }
      return returned.caseInsensitiveCompare(item.doi ?? "") == .orderedSame
    }) ?? collection.first,
      let returnedDOI = record["doi"] as? String,
      returnedDOI.caseInsensitiveCompare(item.doi ?? "") == .orderedSame
    else { throw LibraryError.invalid("bioRxiv DOI mismatch") }

    var result = item
    let sourceName = server.caseInsensitiveCompare("medrxiv") == .orderedSame ? "medRxiv" : "bioRxiv"
    result.doi = returnedDOI.lowercased()
    result.title = clean(record["title"] as? String) ?? result.title
    result.abstract = clean(record["abstract"] as? String) ?? result.abstract
    result.publicationDate = normalizeDate(record["date"] as? String ?? record["published"] as? String)
    result.year = result.publicationDate.flatMap { Int(String($0.prefix(4))) }
    result.type = .preprint
    result.journal = sourceName
    result.publisher = result.journal
    if let category = record["category"] as? String, !category.isEmpty {
      result.keywords = Array(Set((result.keywords ?? []) + [category])).sorted()
    }
    if let license = record["license"] as? String,
      let url = try? Identifiers.canonicalURL(license).absoluteString {
      result.licenseURLs = Array(Set((result.licenseURLs ?? []) + [url])).sorted()
    }
    result.canonicalURL = "https://doi.org/\(result.doi!)"
    result.setAuthors(parseAuthors(record["authors"]))
    result.confidence = 0.99
    result.provenance.append(Provenance(sourceName, "Exact preprint DOI match"))
    result.sourceMetadata = [
      MetadataSnapshot(
        source: sourceName, format: "json",
        payload: String(
          decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          as: UTF8.self))
    ]
    return result
  }

  private static func clean(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func normalizeDate(_ value: String?) -> String? {
    guard let value else { return nil }
    let match = value.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression)
    return match.map { String(value[$0]) } ?? (value.count >= 4 ? String(value.prefix(4)) : nil)
  }

  private static func parseAuthors(_ value: Any?) -> [Author] {
    if let records = value as? [[String: Any]] {
      return records.map {
        Author(givenName: $0["given"] as? String ?? $0["first"] as? String ?? "",
          familyName: $0["family"] as? String ?? $0["last"] as? String ?? $0["name"] as? String ?? "")
      }
    }
    guard let text = value as? String else { return [] }
    return text.split(separator: ";").map { raw in
      let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if let comma = name.firstIndex(of: ",") {
        let given = String(name[name.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        let family = String(name[..<comma]).trimmingCharacters(in: .whitespaces)
        return Author(givenName: given, familyName: family)
      }
      let parts = name.split(separator: " ").map(String.init)
      return Author(givenName: parts.dropLast().joined(separator: " "), familyName: parts.last ?? "")
    }
  }
}
public final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, (try? Identifiers.canonicalURL(url.absoluteString)) != nil,
      !NetworkSafety.resolvesToNonPublicAddress(url.host ?? "") else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
/// Spaces requests per host. A slot is reserved *before* waiting, so concurrent callers queue
/// one after another instead of all computing the same delay and firing together.
public struct HostRateLimiter: Sendable {
  private var nextSlot: [String: Date] = [:]
  public init() {}
  /// Minimum spacing per host, following each service's published guidance.
  public static func interval(for host: String) -> TimeInterval {
    switch host.lowercased() {
    case "export.arxiv.org": return 3  // arXiv API terms: one request every three seconds
    case "eutils.ncbi.nlm.nih.gov": return 0.34  // NCBI: three requests per second without a key
    case "api.crossref.org", "api.openalex.org", "www.ebi.ac.uk", "api.datacite.org", "api.biorxiv.org":
      return 0.25
    default: return 1  // publisher pages
    }
  }
  /// Returns when the caller may send, and books the following slot.
  public mutating func reserve(host: String, now: Date = Date()) -> Date {
    let slot = max(now, nextSlot[host] ?? .distantPast)
    nextSlot[host] = slot.addingTimeInterval(Self.interval(for: host))
    return slot
  }
}

/// A small least-recently-used response cache. Keys omit credentials such as `api_key`.
public struct ResponseCache: Sendable {
  private var entries: [String: (Data, HTTPURLResponse)] = [:]
  private var order: [String] = []
  public let capacity: Int
  public init(capacity: Int = 200) { self.capacity = capacity }
  public static func key(_ url: URL) -> String {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
    parts.queryItems = parts.queryItems?.filter { !["api_key", "apikey", "mailto", "email"].contains($0.name.lowercased()) }
    if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
    return parts.string ?? url.absoluteString
  }
  public mutating func get(_ key: String) -> (Data, HTTPURLResponse)? {
    guard let value = entries[key] else { return nil }
    order.removeAll { $0 == key }; order.append(key)
    return value
  }
  public mutating func set(_ key: String, _ value: (Data, HTTPURLResponse)) {
    if entries[key] == nil { order.append(key) }
    entries[key] = value
    while order.count > capacity { entries[order.removeFirst()] = nil }
  }
  public var count: Int { entries.count }
}

public actor NativeHTTPTransport: HTTPTransport {
  /// Optional contact address sent to metadata services. Crossref and OpenAlex route requests
  /// that include one to their faster "polite" pools; NCBI asks for it too. Set in Settings.
  public static let contactEmailKey = "metadataContactEmail"
  private let session: URLSession
  private var limiter = HostRateLimiter()
  private var cache = ResponseCache()
  private let contactEmail: String?
  public init(contactEmail: String? = UserDefaults.standard.string(forKey: NativeHTTPTransport.contactEmailKey)) {
    let email = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.contactEmail = (email?.contains("@") == true) ? email : nil
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    // Whole-transfer limit; PDFs on slow connections need far longer than an API call.
    config.timeoutIntervalForResource = 300
    var agent = "ResearchLibrary/1.0 (native personal reference manager"
    if let email = self.contactEmail { agent += "; mailto:\(email)" }
    config.httpAdditionalHeaders = ["User-Agent": agent + ")"]
    session = URLSession(
      configuration: config, delegate: SafeRedirectDelegate(), delegateQueue: nil)
  }
  /// Adds the contact address as the query parameter each polite-pool API expects.
  func withContact(_ url: URL) -> URL {
    guard let email = contactEmail, let host = url.host?.lowercased(),
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    let name: String
    switch host {
    case "api.crossref.org", "api.openalex.org": name = "mailto"
    case "eutils.ncbi.nlm.nih.gov": name = "email"
    default: return url
    }
    var items = parts.queryItems ?? []
    guard !items.contains(where: { $0.name == name }) else { return url }
    items.append(URLQueryItem(name: name, value: email))
    parts.queryItems = items
    return parts.url ?? url
  }
  public func data(_ requested: URL) async throws -> (Data, HTTPURLResponse) {
    _ = try Identifiers.canonicalURL(requested.absoluteString)
    // A public-looking name can still point at this Mac or the LAN; check what it resolves to.
    if let host = requested.host, NetworkSafety.resolvesToNonPublicAddress(host) {
      throw LibraryError.invalid("Local and private network URLs cannot be fetched.")
    }
    let key = ResponseCache.key(requested)
    if let cached = cache.get(key) { return cached }
    let url = withContact(requested)
    let host = url.host?.lowercased() ?? ""
    for attempt in 0..<3 {
      let slot = limiter.reserve(host: host)
      let wait = slot.timeIntervalSinceNow
      if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse else {
        throw LibraryError.invalid("Non-HTTP response")
      }
      guard data.count <= 100 * 1024 * 1024 else {
        throw LibraryError.invalid("Remote resource exceeds 100 MB")
      }
      if [429, 500, 502, 503, 504].contains(http.statusCode) && attempt < 2 {
        let retry = min(
          30,
          Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt + 1))
        )
        try await Task.sleep(for: .seconds(retry))
        continue
      }
      guard (200..<300).contains(http.statusCode) else {
        throw HTTPStatusError(statusCode: http.statusCode)
      }
      if data.count < 2 * 1024 * 1024 { cache.set(key, (data, http)) }
      return (data, http)
    }
    throw LibraryError.invalid("Provider unavailable")
  }
}
public struct CrossrefProvider: MetadataProvider {
  public let name = "Crossref"
  public let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }
  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    var lookup = item
    if lookup.doi == nil {
      guard MetadataResolutionService.searchableTitle(item.title) else { return nil }
      var components = URLComponents(string: "https://api.crossref.org/works")!
      components.queryItems = [
        URLQueryItem(name: "query.bibliographic", value: item.title),
        URLQueryItem(name: "rows", value: "5"),
      ]
      let (data, _) = try await transport.data(components.url!)
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let message = root["message"] as? [String: Any],
        let works = message["items"] as? [[String: Any]]
      else { return nil }
      let matches = works.filter { work in
        guard let title = (work["title"] as? [String])?.first,
          MetadataResolutionService.sameTitle(title, item.title)
        else { return false }
        if let year = item.year,
          let dates = (work["published"] ?? work["issued"]) as? [String: Any],
          let returned = (dates["date-parts"] as? [[Int]])?.first?.first,
          abs(year - returned) > 1
        {
          return false
        }
        if let author = item.orderedAuthors.first?.familyName, !author.isEmpty {
          let names = (work["author"] as? [[String: Any]] ?? []).compactMap {
            $0["family"] as? String
          }
          if !names.contains(where: { $0.caseInsensitiveCompare(author) == .orderedSame }) {
            return false
          }
        }
        return true
      }
      guard matches.count == 1, let work = matches.first, let doi = work["DOI"] as? String else {
        return nil
      }
      lookup.doi = doi.lowercased()
      var result = try Self.normalize(
        JSONSerialization.data(withJSONObject: ["message": work]), item: lookup)
      result.confidence = 0.9
      result.provenance.removeAll { $0.source == name && $0.explanation == "Exact DOI match" }
      result.provenance.append(Provenance(name, "Unique exact title match; DOI discovered"))
      return result
    }
    guard let doi = lookup.doi,
      let url = URL(
        string: "https://api.crossref.org/works/"
          + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi))
    else { return nil }
    let (data, _) = try await transport.data(url)
    return try Self.normalize(data, item: lookup)
  }
  public static func normalize(_ data: Data, item: LibraryItem) throws -> LibraryItem {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let m = root["message"] as? [String: Any], let doi = m["DOI"] as? String,
      doi.lowercased() == item.doi?.lowercased()
    else { throw LibraryError.invalid("Crossref identifier mismatch") }
    var result = item
    result.title = (m["title"] as? [String])?.first ?? result.title
    result.subtitle = (m["subtitle"] as? [String])?.first ?? ""
    result.journal = (m["container-title"] as? [String])?.first ?? ""
    result.abstract = (m["abstract"] as? String ?? "").replacingOccurrences(
      of: "<[^>]+>", with: "", options: .regularExpression)
    result.volume = m["volume"] as? String ?? ""
    result.issue = m["issue"] as? String ?? ""
    result.pages = m["page"] as? String ?? ""
    let date = (m["published"] ?? m["issued"]) as? [String: Any]
    result.year = (date?["date-parts"] as? [[Int]])?.first?.first
    result.publicationDate = MetadataResolutionService.dateParts(
      (date?["date-parts"] as? [[Int]])?.first)
    result.publisher = m["publisher"] as? String
    result.language = m["language"] as? String
    result.issn = m["ISSN"] as? [String]
    result.isbn = m["ISBN"] as? [String]
    result.keywords = m["subject"] as? [String]
    result.licenseURLs = (m["license"] as? [[String: Any]])?.compactMap { $0["URL"] as? String }
    result.canonicalURL = m["URL"] as? String ?? result.canonicalURL ?? "https://doi.org/\(doi)"
    switch m["type"] as? String {
    case "proceedings-article": result.type = .conferencePaper
    case "book-chapter": result.type = .bookChapter
    case "posted-content": result.type = .preprint
    case "report": result.type = .report
    case "dissertation": result.type = .thesis
    default: break
    }
    result.setAuthors(
      (m["author"] as? [[String: Any]] ?? []).map { a in
        var value = Author(
          givenName: a["given"] as? String ?? "",
          familyName: a["family"] as? String ?? a["name"] as? String ?? "")
        value.orcid = a["ORCID"] as? String
        return value
      })
    result.confidence = 0.99
    result.provenance.append(Provenance("Crossref", "Exact DOI match"))
    result.sourceMetadata = [
      MetadataSnapshot(
        source: "Crossref", format: "json",
        payload: String(
          decoding: try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]),
          as: UTF8.self))
    ]
    return result
  }
}
private final class BibliographicXML: NSObject, XMLParserDelegate {
  var fields: [String: String] = [:]
  var authors: [Author] = []
  var stack: [String] = []
  var textStack: [String] = []
  var currentAuthor = Author()
  var inAuthor = false
  var idType = ""
  var identifiers: [String: String] = [:]
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    stack.append(name)
    textStack.append("")
    if name == "Author" || name == "author" {
      currentAuthor = Author()
      inAuthor = true
    }
    if name == "ArticleId" { idType = attributes["IdType"] ?? "" }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if !textStack.isEmpty { textStack[textStack.count - 1] += string }
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    let value = (textStack.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    _ = stack.popLast()
    if !textStack.isEmpty { textStack[textStack.count - 1] += value + " " }
    // Referenced papers have their own ArticleId values; they are not this article's identifiers.
    if stack.contains("ReferenceList") { return }
    if name == "ArticleTitle" || (name == "title" && stack.contains("entry")) {
      fields["title"] = value
    }
    if name == "Title" && stack.contains("Journal") { fields["journal"] = value }
    if name == "AbstractText" || name == "summary" {
      fields["abstract", default: ""] += value + "\n"
    }
    if name == "Year" && fields["year"] == nil { fields["year"] = value }
    if name == "published" { fields["year"] = String(value.prefix(4)) }
    if name == "published" { fields["publicationDate"] = String(value.prefix(10)) }
    if stack.contains("PubDate"), ["Year", "Month", "Day"].contains(name) { fields[name] = value }
    if name == "Language" { fields["language"] = value }
    if name == "ISSN" { fields["issn"] = value }
    if name == "arxiv:doi" { identifiers["doi"] = Identifiers.doi(value) }
    if name == "arxiv:journal_ref" { fields["journal"] = value }
    if name == "id" && stack.contains("entry") { fields["arxivID"] = Identifiers.arxiv(value) }
    if name == "PMID" { fields["pmid"] = value }
    if name == "Volume" { fields["volume"] = value }
    if name == "Issue" { fields["issue"] = value }
    if name == "MedlinePgn" { fields["pages"] = value }
    if name == "ArticleId" { identifiers[idType] = value }
    if inAuthor {
      if name == "LastName" || name == "CollectiveName" { currentAuthor.familyName = value }
      if name == "ForeName" { currentAuthor.givenName = value }
      if name == "name" {
        let parts = value.split(separator: " ").map(String.init)
        currentAuthor.familyName = parts.last ?? ""
        currentAuthor.givenName = parts.dropLast().joined(separator: " ")
      }
      if name == "Author" || name == "author" {
        authors.append(currentAuthor)
        inAuthor = false
      }
    }
  }
}
public struct PubMedProvider: MetadataProvider {
  public let name = "PubMed"
  public let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }
  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    guard let pmid = item.pmid, pmid.allSatisfy(\.isNumber),
      let url = URL(
        string:
          "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&retmode=xml&tool=ResearchLibrary&id=\(pmid)"
      )
    else { return nil }
    let (data, _) = try await transport.data(url)
    return try Self.normalize(data, item: item)
  }
  public static func normalize(_ data: Data, item: LibraryItem) throws -> LibraryItem {
    let p = XMLParser(data: data)
    p.shouldResolveExternalEntities = false
    let delegate = BibliographicXML()
    p.delegate = delegate
    guard p.parse(), delegate.fields["pmid"] == item.pmid, let title = delegate.fields["title"]
    else { throw LibraryError.invalid("Invalid PubMed metadata") }
    if let expected = item.doi, let returned = delegate.identifiers["doi"],
      expected.lowercased() != returned.lowercased()
    {
      throw LibraryError.invalid("PubMed DOI mismatch")
    }
    var result = item
    result.title = title
    result.journal = delegate.fields["journal"] ?? ""
    result.abstract = delegate.fields["abstract"] ?? ""
    result.year = delegate.fields["year"].flatMap(Int.init)
    result.doi = delegate.identifiers["doi"]?.lowercased() ?? result.doi
    result.pmcid = delegate.identifiers["pmc"] ?? result.pmcid
    result.volume = delegate.fields["volume"] ?? ""
    result.issue = delegate.fields["issue"] ?? ""
    result.pages = delegate.fields["pages"] ?? ""
    result.language = delegate.fields["language"]
    result.issn = delegate.fields["issn"].map { [$0] }
    let months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    if let year = delegate.fields["Year"].flatMap(Int.init) {
      var parts = [year]
      if let month = delegate.fields["Month"],
        let number = Int(month) ?? months.firstIndex(of: String(month.prefix(3))).map({ $0 + 1 })
      {
        parts.append(number)
        if let day = delegate.fields["Day"].flatMap(Int.init) { parts.append(day) }
      }
      result.publicationDate = MetadataResolutionService.dateParts(parts)
    }
    result.setAuthors(delegate.authors)
    result.confidence = 0.99
    result.provenance.append(Provenance("PubMed", "Exact PMID match"))
    result.sourceMetadata = [
      MetadataSnapshot(
        source: "PubMed", format: "xml", payload: String(decoding: data, as: UTF8.self))
    ]
    return result
  }
}
public struct ArxivProvider: MetadataProvider {
  public let name = "arXiv"
  public let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }
  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    guard let id = item.arxivID,
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(encoded)")
    else { return nil }
    let (data, _) = try await transport.data(url)
    return try Self.normalize(data, item: item)
  }
  public static func normalize(_ data: Data, item: LibraryItem) throws -> LibraryItem {
    let p = XMLParser(data: data)
    p.shouldResolveExternalEntities = false
    let d = BibliographicXML()
    p.delegate = d
    guard p.parse(), let returnedID = d.fields["arxivID"],
      returnedID.replacingOccurrences(of: "v[0-9]+$", with: "", options: .regularExpression)
        == item.arxivID?.replacingOccurrences(of: "v[0-9]+$", with: "", options: .regularExpression),
      let title = d.fields["title"], !title.isEmpty
    else { throw LibraryError.invalid("Invalid arXiv metadata") }
    if let expected = item.doi, let returned = d.identifiers["doi"],
      expected.lowercased() != returned.lowercased()
    {
      throw LibraryError.invalid("arXiv DOI mismatch")
    }
    var r = item
    r.title = title
    r.abstract = d.fields["abstract"] ?? ""
    r.year = d.fields["year"].flatMap(Int.init)
    r.publicationDate = d.fields["publicationDate"]
    r.doi = d.identifiers["doi"] ?? r.doi
    r.journal = d.fields["journal"] ?? ""
    r.setAuthors(d.authors)
    r.type = .preprint
    r.confidence = 0.98
    r.provenance.append(Provenance("arXiv", "Exact arXiv identifier"))
    r.sourceMetadata = [
      MetadataSnapshot(
        source: "arXiv", format: "xml", payload: String(decoding: data, as: UTF8.self))
    ]
    return r
  }
}
public struct MetadataResolutionService: Sendable {
  public let providers: [any MetadataProvider]
  public init(providers: [any MetadataProvider]) { self.providers = providers }
  public static func live(transport: any HTTPTransport) -> Self {
    Self(providers: [
      BioRxivProvider(transport: transport), BioRxivProvider(transport: transport, server: "medrxiv"),
      CrossrefProvider(transport: transport), DataCiteProvider(transport: transport),
      EuropePMCProvider(transport: transport), PubMedProvider(transport: transport),
      ArxivProvider(transport: transport), PublisherMetadataProvider(transport: transport),
    ])
  }
  public func resolve(_ item: LibraryItem) async -> LibraryItem {
    var result = item
    // A second pass allows an arXiv/PMID/PMCID record to reveal a DOI used by an earlier provider.
    var attempted = Set<String>()
    for _ in 0..<2 {
      let before = [result.doi, result.pmid, result.pmcid, result.arxivID]
      for provider in providers {
        if Task.isCancelled { return result }
        let key =
          provider.name + ":"
          + [
            result.doi, result.pmid, result.pmcid, result.arxivID,
            result.canonicalURL, result.title,
          ].map { $0 ?? "" }.joined(separator: "|")
        guard attempted.insert(key).inserted else { continue }
        do {
          if let enriched = try await provider.resolve(result) {
            result = Self.merge(result, enriched)
          }
        } catch {
          let explanation = "Metadata unavailable: \(error.localizedDescription)"
          if !result.provenance.contains(where: {
            $0.source == provider.name && $0.explanation == explanation
          }) {
            result.provenance.append(Provenance(provider.name, explanation))
          }
        }
      }
      if before == [result.doi, result.pmid, result.pmcid, result.arxivID] { break }
    }
    return result
  }
  public static func searchableTitle(_ title: String) -> Bool {
    title != "Untitled" && title.count >= 20
      && normalizedTitle(title).split(separator: " ").count >= 4
  }
  public static func normalizedTitle(_ title: String) -> String {
    title.folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
    )
    .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(
      separator: " ")
  }
  public static func sameTitle(_ a: String, _ b: String) -> Bool {
    normalizedTitle(a) == normalizedTitle(b)
  }
  public static func dateParts(_ parts: [Int]?) -> String? {
    guard let parts, let year = parts.first else { return nil }
    return ([String(year)] + parts.dropFirst().prefix(2).map { String(format: "%02d", $0) }).joined(
      separator: "-")
  }
  public static func merge(_ existing: LibraryItem, _ incoming: LibraryItem) -> LibraryItem {
    if let expected = existing.doi, let returned = incoming.doi,
      expected.lowercased() != returned.lowercased()
    {
      return existing
    }
    if let expected = existing.pmid, let returned = incoming.pmid, expected != returned {
      return existing
    }
    var result = existing
    // Empty responses cannot erase earlier values; human corrections stay authoritative.
    if !existing.humanEdited {
      if !incoming.title.isEmpty, incoming.title != "Untitled",
        existing.title == "Untitled" || incoming.confidence > existing.confidence
      {
        result.title = incoming.title
      }
      if result.subtitle.isEmpty { result.subtitle = incoming.subtitle }
      if incoming.abstract.count > result.abstract.count { result.abstract = incoming.abstract }
      if result.journal.isEmpty { result.journal = incoming.journal }
      if result.volume.isEmpty { result.volume = incoming.volume }
      if result.issue.isEmpty { result.issue = incoming.issue }
      if result.pages.isEmpty { result.pages = incoming.pages }
      result.year = result.year ?? incoming.year
      if (incoming.publicationDate?.count ?? 0) > (result.publicationDate?.count ?? 0) {
        result.publicationDate = incoming.publicationDate
      }
      if result.authors.isEmpty {
        result.setAuthors(incoming.orderedAuthors)
      } else if result.orderedAuthors.count == incoming.orderedAuthors.count {
        let candidate = incoming.orderedAuthors
        for (position, current) in result.orderedAuthors.enumerated() {
          let author = candidate[position]
          if author.familyName.caseInsensitiveCompare(current.familyName) == .orderedSame,
            let index = result.authors.firstIndex(where: { $0.id == current.id })
          {
            if author.givenName.count > result.authors[index].givenName.count {
              result.authors[index].givenName = author.givenName
            }
            result.authors[index].orcid = result.authors[index].orcid ?? author.orcid
          }
        }
      }
      if existing.confidence < incoming.confidence { result.type = incoming.type }
    }
    result.doi = result.doi ?? incoming.doi
    result.pmid = result.pmid ?? incoming.pmid
    result.pmcid = result.pmcid ?? incoming.pmcid
    result.arxivID = result.arxivID ?? incoming.arxivID
    result.canonicalURL = result.canonicalURL ?? incoming.canonicalURL
    result.publisher = result.publisher?.isEmpty == false ? result.publisher : incoming.publisher
    result.language = result.language?.isEmpty == false ? result.language : incoming.language
    for keyPath in [\LibraryItem.issn, \.isbn, \.keywords, \.licenseURLs] {
      let values = Array(Set((result[keyPath: keyPath] ?? []) + (incoming[keyPath: keyPath] ?? [])))
        .sorted()
      if !values.isEmpty { result[keyPath: keyPath] = values }
    }
    result.importedIDs = Array(Set((result.importedIDs ?? []) + (incoming.importedIDs ?? []))).sorted()
    result.pdfFilenameHints = Array(Set((result.pdfFilenameHints ?? []) + (incoming.pdfFilenameHints ?? []))).sorted()
    result.pdfLookup = result.pdfLookup ?? incoming.pdfLookup
    if result.citationKey.isEmpty { result.citationKey = incoming.citationKey }
    for snapshot in incoming.sourceMetadata ?? [] {
      var snapshots = result.sourceMetadata ?? []
      if snapshots.contains(where: { $0.source == snapshot.source && $0.payload == snapshot.payload && $0.format == snapshot.format }) { continue }
      snapshots.removeAll { $0.source == snapshot.source }
      snapshots.append(snapshot)
      result.sourceMetadata = snapshots
    }
    for entry in incoming.provenance
    where !result.provenance.contains(where: {
      $0.source == entry.source && $0.explanation == entry.explanation
    }) { result.provenance.append(entry) }
    for resource in incoming.resources
    where !result.resources.contains(where: {
      $0.id == resource.id || ($0.remoteURL != nil && $0.remoteURL == resource.remoteURL)
    }) {
      var resource = resource
      resource.itemID = result.id
      result.resources.append(resource)
    }
    result.confidence = max(result.confidence, incoming.confidence)
    return result
  }
}

public enum WebMetadata {
  public static func meta(_ key: String, html: String) -> String? {
    values(key, html: html).first
  }
  public static func values(_ key: String, html: String) -> [String] {
    let pattern = "<meta\\b[^>]*>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return []
    }
    var values: [String] = []
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range, in: html) else { continue }
      let tag = String(html[range])
      let name = Identifiers.capture("(?:name|property)\\s*=\\s*[\"']([^\"']+)[\"']", tag, group: 1)
      if name?.lowercased() == key.lowercased() {
        if let content = attribute("content", tag: tag) { values.append(clean(content)) }
      }
    }
    return values
  }
  private static func attribute(_ name: String, tag: String) -> String? {
    Identifiers.capture("\\b" + name + "\\s*=\\s*([\"'])(.*?)\\1", tag, group: 2)
  }
  public static func clean(_ value: String) -> String {
    var result = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    for (entity, replacement) in [
      "&amp;": "&", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">",
      "&nbsp;": " ",
    ] {
      result = result.replacingOccurrences(of: entity, with: replacement)
    }
    if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
      for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        .reversed()
      {
        guard let range = Range(match.range, in: result),
          let digits = Range(match.range(at: 1), in: result)
        else { continue }
        let code = String(result[digits])
        if let number = code.hasPrefix("x") ? Int(code.dropFirst(), radix: 16) : Int(code),
          let scalar = UnicodeScalar(number)
        {
          result.replaceSubrange(range, with: String(scalar))
        }
      }
    }
    return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
  public static func bibliographicTags(_ html: String) -> [String: [String]] {
    guard let regex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive)
    else { return [:] }
    var fields: [String: [String]] = [:]
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range, in: html) else { continue }
      let tag = String(html[range])
      guard let name = attribute("name", tag: tag) ?? attribute("property", tag: tag),
        let value = attribute("content", tag: tag)
      else { continue }
      let key = name.lowercased()
      if ["citation_", "dc.", "dcterms.", "prism."].contains(where: key.hasPrefix)
        || ["description", "keywords", "og:title", "og:description"].contains(key)
      {
        fields[key, default: []].append(clean(value))
      }
    }
    return fields
  }
  /// Finds direct PDF links advertised in ordinary scholarly publisher markup. The caller still
  /// validates bytes and identifiers before a document can be attached to a library item.
  public static func pdfLinks(_ html: String, relativeTo pageURL: URL) -> [URL] {
    var values = values("citation_pdf_url", html: html)
      + values("eprints.document_url", html: html)
    let tagPattern = "<(?:link|a)\\b[^>]*>"
    guard let regex = try? NSRegularExpression(pattern: tagPattern, options: .caseInsensitive) else {
      return []
    }
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range, in: html) else { continue }
      let tag = String(html[range])
      guard let href = attribute("href", tag: tag) else { continue }
      let lower = tag.lowercased()
      let address = href.lowercased()
      let isTypedPDF = lower.contains("application/pdf")
      let isObviousPDF = address.contains(".pdf")
        || ((lower.contains("pdf") || lower.contains("download")) && address.contains("pdf"))
      if isTypedPDF || isObviousPDF { values.append(href) }
    }
    var seen: Set<String> = []
    return values.compactMap { value in
      guard let absolute = URL(string: value, relativeTo: pageURL)?.absoluteURL,
        let safe = try? Identifiers.canonicalURL(absolute.absoluteString),
        seen.insert(safe.absoluteString).inserted
      else { return nil }
      return safe
    }
  }
  public static func structuredArticles(_ html: String) -> [[String: Any]] {
    guard
      let regex = try? NSRegularExpression(
        pattern: "<script\\b[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return [] }
    func articles(_ value: Any) -> [[String: Any]] {
      if let array = value as? [Any] { return array.flatMap(articles) }
      guard let record = value as? [String: Any] else { return [] }
      var results: [[String: Any]] = []
      let types = record["@type"] as? [String] ?? (record["@type"] as? String).map { [$0] } ?? []
      if types.contains(where: { $0.hasSuffix("Article") }) { results.append(record) }
      if let graph = record["@graph"] { results += articles(graph) }
      return results
    }
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).flatMap { match in
      guard let range = Range(match.range(at: 1), in: html),
        let value = try? JSONSerialization.jsonObject(with: Data(html[range].utf8))
      else { return [[String: Any]]() }
      return articles(value)
    }
  }
}
