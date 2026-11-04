import Foundation
import PDFKit

struct PDFCandidate: Sendable {
  var url: URL
  var authoritative: Bool
}
/// Enumerates PDFs without downloading unrelated cloud files.
enum PDFDiscovery {
  static func normalized(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
  }
  static func titleMatches(_ text: String, item: LibraryItem) -> Bool {
    let title = normalized(item.title)
    return title.count >= 25 && normalized(text).contains(title)
  }
  static func catalog(_ root: URL) throws -> [URL] {
    var result: [URL] = []
    var failure: Error?
    guard let enumerator = FileManager.default.enumerator(at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
      errorHandler: { _, error in failure = error; return false }) else {
      throw LibraryError.invalid("Unable to search the library folder")
    }
    // Review imports still contain usable PDFs. Every candidate is content-validated before
    // attachment, so a prior import warning must not make those files invisible forever.
    let excluded: Set<String> = ["Recovery", "Exports", "Metadata", "Deletions"]
    for case let file as URL in enumerator {
      if file.deletingLastPathComponent() == root && excluded.contains(file.lastPathComponent) {
        enumerator.skipDescendants(); continue
      }
      let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
      if values.isDirectory != true && file.pathExtension.lowercased() == "pdf" { result.append(file) }
      // Older iCloud providers expose evicted files as hidden .filename.pdf.icloud stubs.
      if values.isDirectory != true, file.lastPathComponent.hasPrefix("."),
        file.lastPathComponent.lowercased().hasSuffix(".pdf.icloud") {
        result.append(file.deletingLastPathComponent().appendingPathComponent(
          String(file.lastPathComponent.dropFirst().dropLast(".icloud".count))))
      }
    }
    if let failure { throw failure }
    return result
  }
  static func localCandidates(_ files: [URL], item: LibraryItem) -> [URL] {
    let generated = [Files.filename(item), Files.filename(item,
      pattern: UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}")]
    let names = Set(((item.pdfFilenameHints ?? []) + generated).map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
    return files.filter {
      let filename = normalized($0.deletingPathExtension().lastPathComponent)
      let title = normalized(item.title)
      // Organized filenames are shortened to fit the filesystem. Require a substantial title
      // prefix here, then validate actual PDF contents before attaching the candidate.
      let shortenedTitle = title.count >= 40 && filename.contains(String(title.prefix(60)))
      return names.contains($0.lastPathComponent.lowercased())
        || titleMatches($0.lastPathComponent, item: item) || shortenedTitle
    }
  }
  static func residentContentCandidates(_ files: [URL], item: LibraryItem) -> [URL] {
    files.filter { file in
      guard Files.hasResidentData(file), let pdf = PDFDocument(url: file), !pdf.isLocked else { return false }
      let text = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "")
        + "\n" + (0..<min(3, pdf.pageCount)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
      let exactDOI = item.doi.map { Identifiers.containsDOI($0, in: text) } ?? false
      return exactDOI || titleMatches(text, item: item)
    }
  }
  static func validate(_ data: Data, item: LibraryItem, authoritative: Bool) throws {
    guard data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data),
      !pdf.isLocked, pdf.pageCount > 0 else { throw LibraryError.invalid("The returned file is not a readable PDF") }
    let text = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "")
      + "\n" + (pdf.page(at: 0)?.string ?? "")
    let found = Identifiers.doi(text)
    if let expected = item.doi, let found, expected.lowercased() != found.lowercased(),
      !Identifiers.containsDOI(expected, in: text) {
      throw LibraryError.conflict("The PDF has a different DOI; review the match before attaching it.")
    }
    guard authoritative || titleMatches(text, item: item)
      || (item.doi != nil && Identifiers.containsDOI(item.doi!, in: text)) else {
      throw LibraryError.conflict("The PDF could not be confidently matched to this reference.")
    }
  }
  static func validate(_ file: URL, item: LibraryItem, authoritative: Bool) throws {
    let handle = try FileHandle(forReadingFrom: file)
    let header = try handle.read(upToCount: 5) ?? Data()
    try? handle.close()
    guard header == Data("%PDF-".utf8), let pdf = PDFDocument(url: file), !pdf.isLocked,
      pdf.pageCount > 0 else { throw LibraryError.invalid("The archive entry is not a readable PDF") }
    let text = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "")
      + "\n" + (pdf.page(at: 0)?.string ?? "")
    let found = Identifiers.doi(text)
    if let expected = item.doi, let found, expected.lowercased() != found.lowercased(),
      !Identifiers.containsDOI(expected, in: text) {
      throw LibraryError.conflict("The PDF has a different DOI; review the match before attaching it.")
    }
    guard authoritative || titleMatches(text, item: item)
      || (item.doi != nil && Identifiers.containsDOI(item.doi!, in: text)) else {
      throw LibraryError.conflict("The PDF could not be confidently matched to this reference.")
    }
  }
  static func doi(_ file: URL) -> String? {
    guard let pdf = PDFDocument(url: file), !pdf.isLocked else { return nil }
    let text = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "")
      + "\n" + (pdf.page(at: 0)?.string ?? "")
    return Identifiers.doi(text)
  }
}

/// Exact identifier searches, with links supplied by the repository or publisher.
struct OnlinePDFDiscovery {
  let transport: any HTTPTransport
  /// OpenAlex supplies DOI-keyed open-access locations, including direct PDF URLs when known.
  /// It is useful for open articles hosted by publishers that reject automated landing-page requests.
  func openAlex(_ item: LibraryItem) async throws -> [PDFCandidate] {
    guard let doi = item.doi,
      let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://api.openalex.org/works/https://doi.org/\(encoded)")
    else { return [] }
    let (data, _) = try await transport.data(url)
    guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      (record["doi"] as? String).flatMap(Identifiers.doi)?.lowercased() == doi.lowercased(),
      (record["open_access"] as? [String: Any])?["is_oa"] as? Bool == true
    else { return [] }
    let best = (record["best_oa_location"] as? [String: Any]).map { [$0] } ?? []
    let locations = best + (record["locations"] as? [[String: Any]] ?? [])
    var seen: Set<String> = []
    return locations.compactMap { location in
      guard let value = location["pdf_url"] as? String,
        let pdf = try? Identifiers.canonicalURL(value), seen.insert(pdf.absoluteString).inserted
      else { return nil }
      return PDFCandidate(url: pdf, authoritative: true)
    }
  }
  func europePMC(_ item: LibraryItem) async throws -> (pmcid: String?, candidates: [PDFCandidate]) {
    let query: String
    if let id = item.pmid { query = "EXT_ID:" + id + " AND SRC:MED" }
    else if let doi = item.doi { query = "DOI:\"" + doi + "\"" }
    else { return (nil, []) }
    var components = URLComponents(string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search")!
    components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "resultType", value: "core"), URLQueryItem(name: "pageSize", value: "5")]
    let (data, _) = try await transport.data(components.url!)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let records = (json?["resultList"] as? [String: Any])?["result"] as? [[String: Any]] ?? []
    guard let record = records.first(where: {
      if let doi = item.doi { return ($0["doi"] as? String)?.lowercased() == doi.lowercased() }
      return ($0["id"] as? String) == item.pmid && ($0["source"] as? String) == "MED"
    }) else { return (nil, []) }
    let links = (record["fullTextUrlList"] as? [String: Any])?["fullTextUrl"] as? [[String: Any]] ?? []
    let candidates = links.compactMap { link -> PDFCandidate? in
      guard (link["documentStyle"] as? String)?.lowercased() == "pdf",
        let value = link["url"] as? String, let url = try? Identifiers.canonicalURL(value),
        !Self.isPMCWebPage(url) else { return nil }
      return PDFCandidate(url: url, authoritative: true)
    }
    return ((record["pmcid"] as? String).flatMap(Identifiers.pmcid), candidates)
  }
  static func isPMCWebPage(_ url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    return host == "pmc.ncbi.nlm.nih.gov" || host == "www.ncbi.nlm.nih.gov" || host == "ncbi.nlm.nih.gov"
  }
  func pmc(_ pmcid: String, item: LibraryItem) async throws -> [PDFCandidate] {
    // Current PMC distribution uses version prefixes and per-version JSON metadata.
    var components = URLComponents(string: "https://pmc-oa-opendata.s3.amazonaws.com/")!
    components.queryItems = [URLQueryItem(name: "list-type", value: "2"),
      URLQueryItem(name: "prefix", value: pmcid + "."), URLQueryItem(name: "delimiter", value: "/")]
    let (data, _) = try await transport.data(components.url!)
    let xml = String(decoding: data, as: UTF8.self)
    let regex = try NSRegularExpression(pattern: "<Prefix>(" + NSRegularExpression.escapedPattern(for: pmcid) + "\\.[0-9]+/)</Prefix>")
    let prefixes = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
      Range($0.range(at: 1), in: xml).map { String(xml[$0]) }
    }
    var result: [PDFCandidate] = []
    for prefix in Array(Set(prefixes)).sorted().prefix(5) {
      try Task.checkCancellation()
      let version = String(prefix.dropLast())
      let url = URL(string: "https://pmc-oa-opendata.s3.amazonaws.com/metadata/" + version + ".json")!
      let (metadata, _) = try await transport.data(url)
      guard let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
        (json["pmcid"] as? String) == pmcid else { continue }
      if let expected = item.doi, let returned = json["doi"] as? String,
        expected.lowercased() != returned.lowercased() { continue }
      let returnedPMID = (json["pmid"] as? String) ?? (json["pmid"] as? Int).map(String.init)
      if let expected = item.pmid, let returnedPMID, expected != returnedPMID { continue }
      guard let value = json["pdf_url"] as? String else { continue }
      let https = value.hasPrefix("s3://pmc-oa-opendata/")
        ? "https://pmc-oa-opendata.s3.amazonaws.com/" + String(value.dropFirst("s3://pmc-oa-opendata/".count)) : value
      guard let pdf = try? Identifiers.canonicalURL(https), pdf.host == "pmc-oa-opendata.s3.amazonaws.com" else { continue }
      result.append(PDFCandidate(url: pdf, authoritative: true))
    }
    return result
  }
}
