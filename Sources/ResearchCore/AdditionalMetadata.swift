import Foundation

public struct DataCiteProvider: MetadataProvider {
  public let name = "DataCite"
  public let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }
  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    guard let doi = item.doi,
      !(item.sourceMetadata ?? []).contains(where: { $0.source == "Crossref" }),
      let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://api.datacite.org/dois/\(encoded)")
    else { return nil }
    let (data, _) = try await transport.data(url)
    return try Self.normalize(data, item: item)
  }
  public static func normalize(_ data: Data, item: LibraryItem) throws -> LibraryItem {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let record = root["data"] as? [String: Any],
      let fields = record["attributes"] as? [String: Any],
      let doi = fields["doi"] as? String, doi.lowercased() == item.doi?.lowercased()
    else { throw LibraryError.invalid("DataCite identifier mismatch") }
    var result = item
    result.title =
      (fields["titles"] as? [[String: Any]])?.first?["title"] as? String ?? result.title
    result.year = fields["publicationYear"] as? Int
    result.publisher =
      fields["publisher"] as? String ?? (fields["publisher"] as? [String: Any])?["name"] as? String
    result.language = fields["language"] as? String
    result.canonicalURL = fields["url"] as? String ?? result.canonicalURL
    result.keywords = (fields["subjects"] as? [[String: Any]])?.compactMap {
      $0["subject"] as? String
    }
    result.licenseURLs = (fields["rightsList"] as? [[String: Any]])?.compactMap {
      $0["rightsUri"] as? String
    }
    result.abstract =
      (fields["descriptions"] as? [[String: Any]])?.first(where: {
        ($0["descriptionType"] as? String)?.lowercased() == "abstract"
      })?["description"] as? String ?? ""
    result.publicationDate =
      (fields["dates"] as? [[String: Any]])?.first(where: {
        ["issued", "published"].contains(($0["dateType"] as? String)?.lowercased() ?? "")
      })?["date"] as? String
    result.setAuthors(
      (fields["creators"] as? [[String: Any]] ?? []).map { creator in
        var author = Author(
          givenName: creator["givenName"] as? String ?? "",
          familyName: creator["familyName"] as? String ?? creator["name"] as? String ?? "")
        author.orcid =
          (creator["nameIdentifiers"] as? [[String: Any]])?.first(where: {
            ($0["nameIdentifierScheme"] as? String)?.lowercased() == "orcid"
          })?["nameIdentifier"] as? String
        return author
      })
    result.confidence = 0.99
    result.provenance.append(Provenance("DataCite", "Exact DOI match"))
    result.sourceMetadata = [
      MetadataSnapshot(
        source: "DataCite", format: "json",
        payload: String(
          decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
          as: UTF8.self))
    ]
    return result
  }
}

public struct EuropePMCProvider: MetadataProvider {
  public let name = "Europe PMC"
  public let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }
  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    let query: String
    if let pmid = item.pmid, pmid.allSatisfy(\.isNumber) {
      query = "EXT_ID:\(pmid) AND SRC:MED"
    } else if let doi = item.doi {
      query = "DOI:\"\(doi)\""
    } else if let pmcid = item.pmcid {
      query = "PMCID:\(pmcid)"
    } else {
      return nil
    }
    var components = URLComponents(
      string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search")!
    components.queryItems = [
      URLQueryItem(name: "query", value: query),
      URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "resultType", value: "core"),
      URLQueryItem(name: "pageSize", value: "5"),
    ]
    let (data, _) = try await transport.data(components.url!)
    return try Self.normalize(data, item: item)
  }
  public static func normalize(_ data: Data, item: LibraryItem) throws -> LibraryItem? {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let list = root["resultList"] as? [String: Any],
      let records = list["result"] as? [[String: Any]]
    else { throw LibraryError.invalid("Invalid Europe PMC metadata") }
    let matches = records.filter { record in
      if let doi = item.doi, let returned = record["doi"] as? String,
        returned.lowercased() != doi.lowercased()
      {
        return false
      }
      if let pmid = item.pmid {
        return record["id"] as? String == pmid && record["source"] as? String == "MED"
      }
      if let doi = item.doi { return (record["doi"] as? String)?.lowercased() == doi.lowercased() }
      return record["pmcid"] as? String == item.pmcid
    }
    guard let record = matches.first(where: { $0["source"] as? String == "MED" }) ?? matches.first
    else { return nil }
    var result = item
    result.title = WebMetadata.clean(record["title"] as? String ?? result.title)
    result.abstract = WebMetadata.clean(record["abstractText"] as? String ?? "")
    result.doi = record["doi"] as? String ?? result.doi
    if record["source"] as? String == "MED" { result.pmid = record["id"] as? String }
    result.pmcid = record["pmcid"] as? String ?? result.pmcid
    result.year = Int(record["pubYear"] as? String ?? "")
    result.publicationDate = record["firstPublicationDate"] as? String
    let info = record["journalInfo"] as? [String: Any] ?? [:]
    let journal = info["journal"] as? [String: Any] ?? [:]
    result.journal = journal["title"] as? String ?? ""
    result.volume = info["volume"] as? String ?? ""
    result.issue = info["issue"] as? String ?? ""
    result.pages = record["pageInfo"] as? String ?? ""
    result.language = record["language"] as? String
    result.issn = [journal["issn"] as? String, journal["essn"] as? String].compactMap { $0 }
    let authors = (record["authorList"] as? [String: Any])?["author"] as? [[String: Any]] ?? []
    result.setAuthors(
      authors.map { value in
        var author = Author(
          givenName: value["firstName"] as? String ?? "",
          familyName: value["lastName"] as? String ?? value["fullName"] as? String ?? "")
        let identifier = value["authorId"] as? [String: Any]
        if identifier?["type"] as? String == "ORCID" {
          author.orcid = identifier?["value"] as? String
        }
        return author
      })
    result.keywords =
      ((record["keywordList"] as? [String: Any])?["keyword"] as? [String] ?? [])
      + (((record["meshHeadingList"] as? [String: Any])?["meshHeading"] as? [[String: Any]])?
        .compactMap {
          $0["descriptorName"] as? String
        } ?? [])
    result.confidence = 0.99
    result.provenance.append(Provenance("Europe PMC", "Exact identifier match; full metadata"))
    result.sourceMetadata = [
      MetadataSnapshot(
        source: "Europe PMC", format: "json",
        payload: String(
          decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          as: UTF8.self))
    ]
    return result
  }
}

public struct PublisherMetadataProvider: MetadataProvider {
  public let name = "Publisher"
  public let transport: any HTTPTransport
  public init(transport: any HTTPTransport) { self.transport = transport }
  public func resolve(_ item: LibraryItem) async throws -> LibraryItem? {
    guard let address = item.doi.map({ "https://doi.org/\($0)" }) ?? item.canonicalURL,
      let url = try? Identifiers.canonicalURL(address)
    else { return nil }
    let (data, response) = try await transport.data(url)
    guard data.count <= 5 * 1024 * 1024, !data.starts(with: Data("%PDF-".utf8)),
      response.mimeType != "application/pdf", let html = String(data: data, encoding: .utf8)
    else { return nil }
    return try Self.normalize(html, item: item, pageURL: response.url ?? url)
  }
  public static func normalize(_ html: String, item: LibraryItem, pageURL: URL) throws
    -> LibraryItem?
  {
    let articles = WebMetadata.structuredArticles(html)
    func articleDOI(_ record: [String: Any]) -> String? {
      let identifier =
        record["identifier"] as? String
        ?? (record["identifier"] as? [String: Any])?["value"] as? String
        ?? record["sameAs"] as? String ?? record["@id"] as? String
      return identifier.flatMap(Identifiers.doi)
    }
    let structured = articles.first { record in
      let doi = articleDOI(record)
      if let expected = item.doi, let doi, doi != expected.lowercased() { return false }
      if let doi, doi == item.doi?.lowercased() { return true }
      let title = record["headline"] as? String ?? record["name"] as? String ?? ""
      return MetadataResolutionService.searchableTitle(title)
        && MetadataResolutionService.sameTitle(title, item.title)
    }
    let title =
      WebMetadata.meta("citation_title", html: html)
      ?? WebMetadata.meta("dc.title", html: html)
      ?? structured?["headline"] as? String ?? structured?["name"] as? String
    let doi =
      WebMetadata.meta("citation_doi", html: html).flatMap(Identifiers.doi)
      ?? WebMetadata.meta("dc.identifier", html: html).flatMap(Identifiers.doi)
      ?? structured.flatMap(articleDOI)
    let exactDOI = doi != nil && doi == item.doi?.lowercased()
    let exactTitle =
      title.map {
        MetadataResolutionService.searchableTitle($0)
          && MetadataResolutionService.sameTitle($0, item.title)
      } ?? false
    if let expected = item.doi, let doi, doi != expected.lowercased() { return nil }
    guard exactDOI || exactTitle else { return nil }
    var result = item
    result.title = title ?? result.title
    result.doi = doi ?? result.doi
    result.journal = WebMetadata.meta("citation_journal_title", html: html) ?? ""
    result.abstract =
      WebMetadata.meta("citation_abstract", html: html)
      ?? WebMetadata.meta("dc.description", html: html)
      ?? structured?["abstract"] as? String ?? structured?["description"] as? String
      ?? WebMetadata.meta("description", html: html) ?? ""
    result.publicationDate =
      (WebMetadata.meta("citation_publication_date", html: html)
      ?? WebMetadata.meta("dc.date", html: html)
      ?? structured?["datePublished"] as? String)?.replacingOccurrences(of: "/", with: "-")
    result.year = result.publicationDate.flatMap { Int($0.prefix(4)) }
    result.volume = WebMetadata.meta("citation_volume", html: html) ?? ""
    result.issue = WebMetadata.meta("citation_issue", html: html) ?? ""
    let first = WebMetadata.meta("citation_firstpage", html: html)
    let last = WebMetadata.meta("citation_lastpage", html: html)
    result.pages = [first, last].compactMap { $0 }.joined(separator: "-")
    result.publisher =
      WebMetadata.meta("citation_publisher", html: html)
      ?? (structured?["publisher"] as? [String: Any])?["name"] as? String
    result.language =
      WebMetadata.meta("citation_language", html: html) ?? WebMetadata.meta(
        "dc.language", html: html)
      ?? structured?["inLanguage"] as? String
    result.issn = WebMetadata.values("citation_issn", html: html)
    result.isbn = WebMetadata.values("citation_isbn", html: html)
    result.keywords =
      (WebMetadata.values("citation_keywords", html: html)
      + WebMetadata.values("keywords", html: html))
      .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ";,")) }.map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }
    result.setAuthors(
      WebMetadata.values("citation_author", html: html).map { name in
        if name.contains(",") {
          let parts = name.components(separatedBy: ",")
          return Author(
            givenName: parts.dropFirst().joined(separator: " ").trimmingCharacters(
              in: .whitespaces), familyName: parts[0])
        }
        let parts = name.split(separator: " ").map(String.init)
        return Author(
          givenName: parts.dropLast().joined(separator: " "), familyName: parts.last ?? "")
      })
    if result.authors.isEmpty {
      let authorValue = structured?["author"]
      let authors =
        authorValue as? [[String: Any]] ?? (authorValue as? [String: Any]).map { [$0] } ?? []
      result.setAuthors(
        authors.map { author in
          let name = author["name"] as? String ?? ""
          let parts = name.split(separator: " ").map(String.init)
          var value = Author(
            givenName: author["givenName"] as? String ?? parts.dropLast().joined(separator: " "),
            familyName: author["familyName"] as? String ?? parts.last ?? "")
          if let id = author["sameAs"] as? String, id.contains("orcid.org/") { value.orcid = id }
          return value
        })
    }
    if let keywords = structured?["keywords"] as? [String] {
      result.keywords = (result.keywords ?? []) + keywords
    } else if let keywords = structured?["keywords"] as? String {
      result.keywords =
        (result.keywords ?? [])
        + keywords.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    if let license = structured?["license"] as? String { result.licenseURLs = [license] }
    result.title = WebMetadata.clean(result.title)
    result.abstract = WebMetadata.clean(result.abstract)
    result.canonicalURL = try Identifiers.canonicalURL(pageURL.absoluteString).absoluteString
    result.confidence = exactDOI ? 0.99 : 0.9
    result.provenance.append(
      Provenance(
        "Publisher",
        exactDOI ? "Exact DOI match; publisher metadata" : "Exact title match; publisher metadata"))
    var tags: [String: Any] = [
      "meta": WebMetadata.bibliographicTags(html), "pageURL": pageURL.absoluteString,
    ]
    if let structured { tags["structuredArticle"] = structured }
    result.sourceMetadata = [
      MetadataSnapshot(
        source: "Publisher", format: "json",
        payload: String(
          decoding: try JSONSerialization.data(withJSONObject: tags, options: [.sortedKeys]),
          as: UTF8.self))
    ]
    return result
  }
}
