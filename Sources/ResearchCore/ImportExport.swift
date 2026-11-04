import Foundation

public enum ExportFormat: String, CaseIterable, Sendable { case json, bib, ris }
public enum ExportService {
  public static func encode(_ items: [LibraryItem], format: ExportFormat) throws -> Data {
    if format == .json { return try PortableJSON.encoder().encode(items) }
    func bibEscape(_ value: String) -> String {
      value.replacingOccurrences(of: "\\", with: "\\textbackslash{}").replacingOccurrences(
        of: "{", with: "\\{"
      ).replacingOccurrences(of: "}", with: "\\}").replacingOccurrences(of: "\n", with: " ")
    }
    var output = ""
    for item in items {
      if format == .bib {
        let key =
          item.citationKey.isEmpty
          ? "item" + item.id.uuidString.replacingOccurrences(of: "-", with: "")
          : Files.sanitized(item.citationKey).replacingOccurrences(of: " ", with: "_")
        let fields: [(String, String)] = [
          ("title", item.title),
          (
            "author",
            item.orderedAuthors.map { $0.familyName + ", " + $0.givenName }.joined(
              separator: " and ")
          ), ("year", item.year.map(String.init) ?? ""), ("journal", item.journal),
          ("doi", item.doi ?? ""), ("pmid", item.pmid ?? ""), ("url", item.canonicalURL ?? ""),
          ("abstract", item.abstract), ("keywords", item.tags.joined(separator: ", ")),
          ("note", item.notes), ("volume", item.volume), ("number", item.issue),
          ("pages", item.pages), ("collections", item.collections.joined(separator: "; ")),
        ]
        output +=
          "@article{\(key),\n"
          + fields.filter { !$0.1.isEmpty }.map { "  \($0.0) = {\(bibEscape($0.1))}" }.joined(
            separator: ",\n") + "\n}\n\n"
      } else {
        func field(_ tag: String, _ value: String) -> String {
          value.isEmpty ? "" : "\(tag)  - \(value.replacingOccurrences(of:"\n",with:" "))\n"
        }
        output +=
          "TY  - JOUR\n" + field("TI", item.title)
          + item.orderedAuthors.map { field("AU", $0.familyName + ", " + $0.givenName) }.joined()
          + field("PY", item.year.map(String.init) ?? "") + field("JO", item.journal)
          + field("DO", item.doi ?? "") + field("UR", item.canonicalURL ?? "")
          + field("AB", item.abstract) + item.tags.map { field("KW", $0) }.joined()
          + field("N1", item.notes) + "ER  - \n\n"
      }
    }
    return Data(output.utf8)
  }
}
public enum ImportService {
  public static func parse(_ data: Data, format: String) throws -> [LibraryItem] {
    if format.lowercased() == "bib" { return try bibtex(String(decoding: data, as: UTF8.self)) }
    if let native = try? PortableJSON.decoder().decode([LibraryItem].self, from: data) {
      return native
    }
    let root = try JSONSerialization.jsonObject(with: data)
    if let envelope = root as? [String: Any], let obj = envelope["item"] {
      return [
        try PortableJSON.decoder().decode(
          LibraryItem.self, from: JSONSerialization.data(withJSONObject: obj))
      ]
    }
    let records: [[String: Any]]
    if let array = root as? [[String: Any]] {
      records = array
    } else if let dict = root as? [String: Any],
      let array = (dict["references"] ?? dict["items"] ?? dict["papers"]) as? [[String: Any]]
    {
      records = array
    } else {
      throw LibraryError.invalid("Expected a Paperpile JSON list or bibliography export")
    }
    return records.map { record in
      var item = LibraryItem(title: record["title"] as? String ?? "Untitled")
      if let externalID = record["_id"] as? String {
        item.id = Files.stableID("paperpile:" + externalID)
        item.importedIDs = ["paperpile:" + externalID]
        item.sourceMetadata = [MetadataSnapshot(source: "Paperpile:" + externalID, format: "json",
          payload: String(data: (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}")]
      }
      item.doi = (record["doi"] as? String ?? record["DOI"] as? String).flatMap(Identifiers.doi)
      item.pmid = record["pmid"] as? String
      item.abstract = record["abstract"] as? String ?? ""
      item.journal = record["journal"] as? String ?? record["container-title"] as? String ?? ""
      let published = record["published"] as? [String: Any] ?? [:]
      func number(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap(Int.init) }
      item.year = number(record["year"]) ?? number(published["year"])
      if let year = item.year {
        item.publicationDate = String(year)
        if let month = number(published["month"]), (1...12).contains(month) {
          item.publicationDate! += String(format: "-%02d", month)
          if let day = number(published["day"]), (1...31).contains(day) { item.publicationDate! += String(format: "-%02d", day) }
        }
      }
      item.pmcid = (record["pmc"] as? String ?? record["pmcid"] as? String).flatMap(Identifiers.pmcid)
      item.arxivID = record["arxiv"] as? String
      item.citationKey = record["citekey"] as? String ?? record["citationKey"] as? String ?? ""
      item.volume = record["volume"] as? String ?? ""
      item.issue = record["issue"] as? String ?? ""
      item.pages = record["pages"] as? String ?? ""
      item.publisher = record["publisher"] as? String
      item.language = record["language"] as? String
      item.issn = names(record["issn"]) + names(record["issn_alt"])
      if let issn = record["issn"] as? String { item.issn = [issn] }
      if let created = record["created"] as? Double, created > 0 { item.dateAdded = Date(timeIntervalSince1970: created) }
      let kind = (record["pubtype"] as? String ?? record["kind"] as? String ?? "").lowercased()
      if kind.contains("preprint") { item.type = .preprint }
      else if kind.contains("book") { item.type = .bookChapter }
      else if kind.contains("thesis") { item.type = .thesis }
      else if kind.contains("conference") { item.type = .conferencePaper }
      else if kind.contains("website") { item.type = .webResource }
      else if kind.contains("report") { item.type = .report }
      else if kind.contains("misc") || kind.contains("patent") || kind.contains("dataset") || kind.contains("computer") { item.type = .genericDocument }
      item.notes = record["notes"] as? String ?? record["note"] as? String ?? ""
      let urls = (record["url"] as? [String]) ?? (record["url"] as? String).map { [$0] } ?? []
      let safeURLs = urls.compactMap { try? Identifiers.canonicalURL($0).absoluteString }
      item.canonicalURL = safeURLs.first ?? item.doi.map { "https://doi.org/" + $0 }
        ?? item.pmid.map { "https://pubmed.ncbi.nlm.nih.gov/" + $0 + "/" }
      item.tags = names(record["labels"] ?? record["tags"])
      item.collections = names(record["folders"] ?? record["collections"]).filter { UUID(uuidString: $0) == nil }
      item.pdfFilenameHints = (record["attachments"] as? [[String: Any]] ?? []).filter {
        ($0["mimeType"] as? String) == "application/pdf" || ($0["article_pdf"] as? Int) == 1
      }.flatMap { attachment in
        [attachment["filename"] as? String, attachment["source_filename"] as? String].compactMap { $0 }
      }
      item.pdfLookup = PDFLookup(.pending, detail: "The PDF will be located in your library folder or online when you open this paper.")
      item.setAuthors(
        ((record["authors"] ?? record["author"]) as? [[String: Any]] ?? []).map {
          var author = Author(
            givenName: $0["given"] as? String ?? $0["first"] as? String ?? $0["givenName"]
              as? String ?? "",
            familyName: $0["family"] as? String ?? $0["last"] as? String ?? $0["familyName"]
              as? String ?? "")
          author.orcid = $0["orcid"] as? String
          return author
        })
      for url in Array(Set(safeURLs + [item.canonicalURL].compactMap { $0 })).sorted() {
        item.resources.append(Resource(itemID: item.id, type: .publisherPage, url: url))
      }
      for attachment in record["attachments"] as? [[String: Any]] ?? [] {
        if let url = attachment["url"] as? String {
          item.resources.append(Resource(itemID: item.id, type: .pdf, url: url))
        }
      }
      item.confidence = item.doi != nil || item.pmid != nil ? 0.9 : 0.5
      return item
    }
  }
  public static func attachmentPaths(_ data: Data) -> [[String]] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    let records =
      (root as? [[String: Any]]) ?? ((root as? [String: Any])?["references"] as? [[String: Any]])
      ?? ((root as? [String: Any])?["items"] as? [[String: Any]])
      ?? ((root as? [String: Any])?["papers"] as? [[String: Any]]) ?? []
    return records.map { record in
      var paths = (record["attachments"] as? [[String: Any]] ?? []).compactMap {
        ($0["path"] ?? $0["localPath"] ?? $0["file"]) as? String
      }
      if let pdf = record["pdf"] as? String { paths.append(pdf) }
      return paths.filter { !$0.hasPrefix("http") }
    }
  }
  private static func names(_ value: Any?) -> [String] {
    if let strings = value as? [String] { return strings }
    return (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
  }
  public static func bibtex(_ text: String) throws -> [LibraryItem] {
    // Balanced-brace scanner retains nested TeX rather than using a flat regex.
    let chars = Array(text)
    var i = 0
    var records: [LibraryItem] = []
    func skip() { while i < chars.count && (chars[i].isWhitespace || chars[i] == ",") { i += 1 } }
    while i < chars.count {
      guard chars[i] == "@" else {
        i += 1
        continue
      }
      i += 1
      let start = i
      while i < chars.count && chars[i] != "{" && chars[i] != "(" { i += 1 }
      let kind = String(chars[start..<i]).lowercased()
      guard i < chars.count else { throw LibraryError.invalid("Unclosed BibTeX entry") }
      i += 1
      let keyStart = i
      while i < chars.count && chars[i] != "," && chars[i] != "}" { i += 1 }
      let key = String(chars[keyStart..<i])
      if kind == "comment" || kind == "preamble" || kind == "string" {
        while i < chars.count && chars[i] != "}" { i += 1 }
        i += 1
        continue
      }
      var fields: [String: String] = [:]
      while i < chars.count {
        skip()
        if i >= chars.count { break }
        if chars[i] == "}" || chars[i] == ")" {
          i += 1
          break
        }
        let nameStart = i
        while i < chars.count && chars[i] != "=" { i += 1 }
        guard i < chars.count else { throw LibraryError.invalid("Invalid BibTeX field") }
        let name = String(chars[nameStart..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        i += 1
        skip()
        guard i < chars.count else { break }
        var value = ""
        if chars[i] == "{" {
          i += 1
          var depth = 1
          while i < chars.count && depth > 0 {
            let c = chars[i]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if depth > 0 { value.append(c) }
            i += 1
          }
          guard depth == 0 else { throw LibraryError.invalid("Unbalanced BibTeX braces") }
        } else if chars[i] == "\"" {
          i += 1
          while i < chars.count && chars[i] != "\"" {
            value.append(chars[i])
            i += 1
          }
          i += 1
        } else {
          while i < chars.count && chars[i] != "," && chars[i] != "}" {
            value.append(chars[i])
            i += 1
          }
        }
        fields[name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      var item = LibraryItem(title: fields["title"] ?? "Untitled")
      item.citationKey = key
      item.journal = fields["journal"] ?? fields["booktitle"] ?? ""
      item.year = fields["year"].flatMap(Int.init)
      item.doi = fields["doi"].flatMap(Identifiers.doi)
      item.pmid = fields["pmid"]
      item.abstract = fields["abstract"] ?? ""
      item.notes = fields["note"] ?? ""
      item.canonicalURL = fields["url"]
      item.tags = (fields["keywords"] ?? "").split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
      item.collections = (fields["collections"] ?? "").split(separator: ";").map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
      item.volume = fields["volume"] ?? ""
      item.issue = fields["number"] ?? ""
      item.pages = fields["pages"] ?? ""
      item.setAuthors(
        (fields["author"] ?? "").components(separatedBy: " and ").filter { !$0.isEmpty }.map {
          author in
          let pieces = author.components(separatedBy: ",")
          if pieces.count > 1 {
            return Author(
              givenName: pieces[1].trimmingCharacters(in: .whitespaces),
              familyName: pieces[0].trimmingCharacters(in: .whitespaces))
          }
          let words = author.split(separator: " ")
          return Author(
            givenName: words.dropLast().joined(separator: " "),
            familyName: words.last.map(String.init) ?? "")
        })
      item.confidence = 0.8
      records.append(item)
    }
    return records
  }
}
