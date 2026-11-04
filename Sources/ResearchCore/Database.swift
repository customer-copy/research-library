import CSQLite
import Foundation

final class SearchCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func check() throws { if isCancelled { throw CancellationError() } }
}

public final class LocalDatabase: @unchecked Sendable {
  private var db: OpaquePointer?
  public init(url: URL, readOnly: Bool = false) throws {
    if !readOnly { try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    guard
      sqlite3_open_v2(
        url.path, &db, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
          | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else { throw LibraryError.database("Cannot open local database") }
    sqlite3_busy_timeout(db, readOnly ? 250 : 5000)
    if readOnly { try execute("PRAGMA query_only=ON;") }
    else {
      try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")
      try migrate()
    }
  }
  deinit { sqlite3_close(db) }
  public func execute(_ sql: String) throws {
    var err: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(db, sql, nil, nil, &err)
    if status != SQLITE_OK {
      let message = err.map { String(cString: $0) } ?? "SQLite error"
      sqlite3_free(err)
      if status == SQLITE_INTERRUPT { throw CancellationError() }
      throw LibraryError.database(message)
    }
  }
  public func rows(_ sql: String, _ bindings: [String?] = []) throws -> [[String: String]] {
    var output: [[String: String]] = []
    try scan(sql, bindings) { output.append($0); return true }
    return output
  }
  /// Stop the SQLite cursor as soon as enough distinct articles have been found.
  private func scan(_ sql: String, _ bindings: [String?], visit: ([String: String]) throws -> Bool) throws {
    var statement: OpaquePointer?
    let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard status == SQLITE_OK else {
      if status == SQLITE_INTERRUPT { throw CancellationError() }
      throw LibraryError.database(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_parameter_count(statement) == bindings.count else {
      throw LibraryError.database("Incorrect number of database query parameters")
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, value) in bindings.enumerated() {
      if let value {
        guard sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) == SQLITE_OK else {
          throw LibraryError.database("Unable to bind database query parameter")
        }
      } else {
        guard sqlite3_bind_null(statement, Int32(i + 1)) == SQLITE_OK else {
          throw LibraryError.database("Unable to bind database query parameter")
        }
      }
    }
    var rc = sqlite3_step(statement)
    while rc == SQLITE_ROW {
      var row: [String: String] = [:]
      for i in 0..<sqlite3_column_count(statement) {
        if let value = sqlite3_column_text(statement, i) {
          row[String(cString: sqlite3_column_name(statement, i))] = String(cString: value)
        }
      }
      if try !visit(row) { return }
      rc = sqlite3_step(statement)
    }
    guard rc == SQLITE_DONE else {
      if rc == SQLITE_INTERRUPT { throw CancellationError() }
      throw LibraryError.database(String(cString: sqlite3_errmsg(db)))
    }
  }
  func withSearchCancellation<T>(_ token: SearchCancellation?, _ body: () throws -> T) throws -> T {
    guard let token else { return try body() }
    try token.check()
    let context = Unmanaged.passRetained(token)
    sqlite3_progress_handler(db, 1000, { pointer in
      guard let pointer else { return 0 }
      return Unmanaged<SearchCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
    }, context.toOpaque())
    defer { sqlite3_progress_handler(db, 0, nil, nil); context.release() }
    return try body()
  }
  public func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  public var schemaVersion: Int {
    Int((try? rows("PRAGMA user_version"))?.first?["user_version"] ?? "0") ?? 0
  }
  /// The index schema version this build writes. Each step below runs exactly once, inside a
  /// transaction, and records its version, so launches don't repeat work (or re-parse every
  /// item's JSON) and a failed step leaves the previous version intact.
  public static let currentSchemaVersion = 2
  private func migrate() throws {
    guard schemaVersion <= Self.currentSchemaVersion else {
      throw LibraryError.database(
        "Local index is from a newer application; rebuild with a compatible version.")
    }
    if schemaVersion == 0 {
      try transaction {
        try execute(
          """
          CREATE TABLE items(id TEXT PRIMARY KEY, json TEXT NOT NULL, title TEXT, authors TEXT, year INTEGER, journal TEXT, doi TEXT, pmid TEXT, pmcid TEXT, arxiv TEXT, favorite INTEGER, read INTEGER, has_pdf INTEGER, confidence REAL, added REAL);
          CREATE INDEX items_identifiers ON items(doi,pmid,pmcid,arxiv);
          CREATE INDEX items_title ON items(title COLLATE NOCASE);
          CREATE INDEX items_year ON items(year); CREATE INDEX items_added ON items(added);
          CREATE TABLE authors(id TEXT PRIMARY KEY, given_name TEXT, family_name TEXT, orcid TEXT);
          CREATE TABLE item_authors(item_id TEXT REFERENCES items(id) ON DELETE CASCADE, author_id TEXT REFERENCES authors(id), sequence INTEGER, PRIMARY KEY(item_id,sequence));
          CREATE TABLE resources(id TEXT PRIMARY KEY, item_id TEXT REFERENCES items(id) ON DELETE CASCADE, hash TEXT, path TEXT, type TEXT); CREATE INDEX resource_hash ON resources(hash);
          CREATE TABLE tags(name TEXT PRIMARY KEY); CREATE TABLE collections(name TEXT PRIMARY KEY);
          CREATE TABLE item_tags(item_id TEXT REFERENCES items(id) ON DELETE CASCADE, name TEXT REFERENCES tags(name), PRIMARY KEY(item_id,name));
          CREATE TABLE item_collections(item_id TEXT REFERENCES items(id) ON DELETE CASCADE, name TEXT REFERENCES collections(name), PRIMARY KEY(item_id,name));
          CREATE TABLE pages(id TEXT PRIMARY KEY, item_id TEXT REFERENCES items(id) ON DELETE CASCADE, resource_id TEXT, page INTEGER, text TEXT, method TEXT, version INTEGER);
          CREATE TABLE sections(id TEXT PRIMARY KEY, item_id TEXT REFERENCES items(id) ON DELETE CASCADE, json TEXT);
          CREATE TABLE chunks(id TEXT PRIMARY KEY, item_id TEXT REFERENCES items(id) ON DELETE CASCADE, resource_id TEXT, start_page INTEGER, end_page INTEGER, sequence INTEGER, text TEXT, json TEXT);
          CREATE INDEX chunks_item ON chunks(item_id); CREATE INDEX pages_item ON pages(item_id);
          CREATE TABLE embeddings(chunk_id TEXT REFERENCES chunks(id) ON DELETE CASCADE, provider TEXT, model TEXT, dimensions INTEGER, version TEXT, created REAL, index_id TEXT);
          CREATE VIRTUAL TABLE item_fts USING fts5(item_id UNINDEXED,title,authors,abstract,journal,identifiers,tags,collections,notes, tokenize='unicode61 remove_diacritics 2');
          CREATE VIRTUAL TABLE page_fts USING fts5(item_id UNINDEXED,resource_id UNINDEXED,page UNINDEXED,text, tokenize='unicode61 remove_diacritics 2');
          PRAGMA user_version=1;
          """)
      }
    }
    if schemaVersion == 1 {
      // v2: hash aliases, import origins, normalized identifier indexes, FTS rowid lookups,
      // sidecar revisions; backfills existing rows.
      try transaction {
        try execute(
          "CREATE TABLE IF NOT EXISTS resource_hash_aliases(hash TEXT PRIMARY KEY, item_id TEXT REFERENCES items(id) ON DELETE CASCADE)"
        )
        try execute("CREATE TABLE IF NOT EXISTS import_origins(external_id TEXT PRIMARY KEY, item_id TEXT REFERENCES items(id) ON DELETE CASCADE)")
        try execute("CREATE INDEX IF NOT EXISTS import_origins_item ON import_origins(item_id)")
        for column in ["doi", "pmid", "pmcid", "arxiv"] {
          try execute("CREATE INDEX IF NOT EXISTS items_\(column)_normalized ON items(lower(\(column)))")
        }
        try execute("CREATE TABLE IF NOT EXISTS item_fts_lookup(item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, fts_rowid INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS sidecar_revisions(path TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, revision TEXT NOT NULL)")
        if try rows("SELECT name FROM sqlite_master WHERE name='page_fts_lookup'").isEmpty {
          try execute("CREATE TABLE page_fts_lookup(fts_rowid INTEGER PRIMARY KEY, item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, resource_id TEXT NOT NULL, page INTEGER NOT NULL)")
          _ = try rows("INSERT INTO page_fts_lookup SELECT p.rowid,p.item_id,p.resource_id,p.page FROM page_fts p JOIN items i ON i.id=p.item_id")
          try execute("CREATE INDEX page_fts_lookup_item ON page_fts_lookup(item_id,resource_id,page)")
        }
        try execute("CREATE INDEX IF NOT EXISTS chunks_resource_pages ON chunks(item_id,resource_id,start_page,end_page)")
        _ = try rows("INSERT OR IGNORE INTO item_fts_lookup SELECT item_id, rowid FROM item_fts")
        _ = try rows("INSERT OR IGNORE INTO import_origins SELECT origin.value, i.id FROM items i, json_each(i.json, '$.importedIDs') origin")
        try execute("PRAGMA user_version=2")
      }
    }
  }
  public func upsert(_ item: LibraryItem) throws {
    try transaction {
      let id = item.id.uuidString
      let json = String(data: try PortableJSON.encoder().encode(item), encoding: .utf8)!
      _ = try rows(
        "INSERT INTO items VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json,title=excluded.title,authors=excluded.authors,year=excluded.year,journal=excluded.journal,doi=excluded.doi,pmid=excluded.pmid,pmcid=excluded.pmcid,arxiv=excluded.arxiv,favorite=excluded.favorite,read=excluded.read,has_pdf=excluded.has_pdf,confidence=excluded.confidence,added=excluded.added",
        [
          id, json, item.title, item.authorText, item.year.map(String.init), item.journal, item.doi,
          item.pmid, item.pmcid, item.arxivID, item.favorite ? "1" : "0", item.read ? "1" : "0",
          item.hasPDF ? "1" : "0", String(item.confidence),
          String(item.dateAdded.timeIntervalSince1970),
        ])
      for table in [
        "item_authors", "resources", "item_tags", "item_collections", "resource_hash_aliases", "import_origins",
      ] {
        _ = try rows("DELETE FROM \(table) WHERE item_id=?", [id])
      }
      for externalID in item.importedIDs ?? [] {
        _ = try rows("INSERT OR REPLACE INTO import_origins VALUES(?,?)", [externalID, id])
      }
      for link in item.authorships {
        if let a = item.authors.first(where: { $0.id == link.authorID }) {
          _ = try rows(
            "INSERT OR REPLACE INTO authors VALUES(?,?,?,?)",
            [a.id.uuidString, a.givenName, a.familyName, a.orcid])
          _ = try rows(
            "INSERT INTO item_authors VALUES(?,?,?)", [id, a.id.uuidString, String(link.order)])
        }
      }
      for r in item.resources {
        _ = try rows(
          "INSERT INTO resources VALUES(?,?,?,?,?)",
          [r.id.uuidString, id, r.sha256, r.relativePath, r.type.rawValue])
        if let original = r.originalSHA256 {
          _ = try rows("INSERT OR REPLACE INTO resource_hash_aliases VALUES(?,?)", [original, id])
        }
      }
      for (table, join, values) in [
        ("tags", "item_tags", item.tags), ("collections", "item_collections", item.collections),
      ] {
        for v in Set(values) {
          _ = try rows("INSERT OR IGNORE INTO \(table) VALUES(?)", [v])
          _ = try rows("INSERT INTO \(join) VALUES(?,?)", [id, v])
        }
      }
      _ = try rows("DELETE FROM item_fts WHERE rowid IN (SELECT fts_rowid FROM item_fts_lookup WHERE item_id=?)", [id])
      _ = try rows(
        "INSERT INTO item_fts VALUES(?,?,?,?,?,?,?,?,?)",
        [
          id, item.title, item.authorText, item.abstract, item.journal,
          [item.doi, item.pmid, item.pmcid, item.arxivID].compactMap { $0 }.joined(separator: " "),
          (item.tags + (item.keywords ?? [])).joined(separator: " "),
          item.collections.joined(separator: " "), item.notes,
        ])
      _ = try rows("INSERT OR REPLACE INTO item_fts_lookup VALUES(?,last_insert_rowid())", [id])
    }
  }
  func containsSameRecord(_ item: LibraryItem) throws -> Bool {
    let json = String(data: try PortableJSON.encoder().encode(item), encoding: .utf8)!
    return try rows("SELECT json FROM items WHERE id=?", [item.id.uuidString]).first?["json"] == json
  }
  public func item(_ id: UUID) throws -> LibraryItem? {
    try rows("SELECT json FROM items WHERE id=?", [id.uuidString]).first.flatMap { row in
      try row["json"].map {
        try PortableJSON.decoder().decode(LibraryItem.self, from: Data($0.utf8))
      }
    }
  }
  public func exactDuplicate(hash: String) throws -> UUID? {
    try rows(
      "SELECT item_id FROM resources WHERE hash=? UNION ALL SELECT item_id FROM resource_hash_aliases WHERE hash=? LIMIT 1",
      [hash, hash]
    ).first?["item_id"]
    .flatMap(UUID.init(uuidString:))
  }
  public func importedDuplicate(_ item: LibraryItem) throws -> UUID? {
    for externalID in item.importedIDs ?? [] {
      if let id = try rows("SELECT item_id FROM import_origins WHERE external_id=? LIMIT 1", [externalID])
        .first?["item_id"].flatMap(UUID.init(uuidString:)) { return id }
    }
    return nil
  }
  public func identifierDuplicate(_ item: LibraryItem) throws -> UUID? {
    for (column, value) in [
      ("doi", item.doi), ("pmid", item.pmid), ("pmcid", item.pmcid), ("arxiv", item.arxivID),
    ] {
      if let value,
        let id = try rows("SELECT id FROM items WHERE lower(\(column))=lower(?) LIMIT 1", [value])
          .first?["id"].flatMap(UUID.init(uuidString:))
      {
        return id
      }
    }
    return nil
  }
  /// Paths for already-indexed local PDFs whose extracted text contains an exact DOI. This lets
  /// the reader reconnect an imported record to its managed iCloud PDF even when filenames differ.
  public func indexedPDFPaths(containingDOI doi: String) throws -> [String] {
    try rows(
      """
      SELECT DISTINCT r.path AS path FROM pages p
      JOIN resources r ON r.id=p.resource_id
      WHERE r.type='pdf' AND r.path IS NOT NULL AND lower(p.text) LIKE lower(?)
      LIMIT 20
      """, ["%" + doi + "%"]
    ).compactMap { $0["path"] }
  }
  public func titleDuplicate(_ item: LibraryItem) throws -> UUID? {
    guard item.title.count > 15 else { return nil }
    let exact = try rows(
      "SELECT id FROM items WHERE lower(title)=lower(?) AND (? IS NULL OR year=?) LIMIT 1",
      [item.title, item.year.map(String.init), item.year.map(String.init)]
    ).first?["id"].flatMap(UUID.init(uuidString:))
    if let exact { return exact }
    guard let year = item.year, let author = item.orderedAuthors.first?.familyName, !author.isEmpty
    else { return nil }
    func words(_ value: String) -> Set<String> {
      Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
    let input = words(item.title)
    guard input.count >= 5 else { return nil }
    for row in try rows(
      "SELECT id,title FROM items WHERE year=? AND authors LIKE ? LIMIT 500",
      [String(year), "%" + author + "%"])
    {
      let other = words(row["title"] ?? "")
      let overlap =
        Double(input.intersection(other).count) / Double(max(1, input.union(other).count))
      if overlap >= 0.9 { return row["id"].flatMap(UUID.init(uuidString:)) }
    }
    return nil
  }
  public func index(
    pages: [DocumentPage], sections: [Section], chunks: [Chunk], itemID: UUID, resourceID: UUID
  ) throws {
    try transaction {
      let id = itemID.uuidString
      let rid = resourceID.uuidString
      for table in ["pages", "chunks"] {
        _ = try rows("DELETE FROM \(table) WHERE item_id=? AND resource_id=?", [id, rid])
      }
      // page_fts's item/resource columns are UNINDEXED (a WHERE on them scans every page in
      // the library); delete by rowid through the indexed lookup table instead.
      _ = try rows(
        "DELETE FROM page_fts WHERE rowid IN (SELECT fts_rowid FROM page_fts_lookup WHERE item_id=? AND resource_id=?)",
        [id, rid])
      _ = try rows("DELETE FROM page_fts_lookup WHERE item_id=? AND resource_id=?", [id, rid])
      for p in pages {
        _ = try rows(
          "INSERT INTO pages VALUES(?,?,?,?,?,?,?)",
          [
            p.id.uuidString, id, rid, String(p.pageNumber), p.text, p.method,
            String(p.extractionVersion),
          ])
        _ = try rows(
          "INSERT INTO page_fts VALUES(?,?,?,?)", [id, rid, String(p.pageNumber), p.text])
        _ = try rows("INSERT INTO page_fts_lookup VALUES(last_insert_rowid(),?,?,?)",
          [id, rid, String(p.pageNumber)])
      }
      for s in sections {
        _ = try rows(
          "INSERT OR REPLACE INTO sections VALUES(?,?,?)",
          [
            s.id.uuidString, id,
            String(data: try PortableJSON.encoder().encode(s), encoding: .utf8),
          ])
      }
      for c in chunks {
        _ = try rows(
          "INSERT INTO chunks VALUES(?,?,?,?,?,?,?,?)",
          [
            c.id.uuidString, id, rid, String(c.startPage), String(c.endPage), String(c.sequence),
            c.text, String(data: try PortableJSON.encoder().encode(c), encoding: .utf8),
          ])
      }
    }
  }
  public func remove(_ id: UUID) throws {
    try transaction {
      _ = try rows("DELETE FROM item_fts WHERE rowid IN (SELECT fts_rowid FROM item_fts_lookup WHERE item_id=?)", [id.uuidString])
      _ = try rows("DELETE FROM page_fts WHERE rowid IN (SELECT fts_rowid FROM page_fts_lookup WHERE item_id=?)", [id.uuidString])
      _ = try rows("DELETE FROM page_fts_lookup WHERE item_id=?", [id.uuidString])
      _ = try rows("DELETE FROM items WHERE id=?", [id.uuidString])
      _ = try rows("DELETE FROM authors WHERE id NOT IN (SELECT author_id FROM item_authors)")
      _ = try rows("DELETE FROM tags WHERE name NOT IN (SELECT name FROM item_tags)")
      _ = try rows("DELETE FROM collections WHERE name NOT IN (SELECT name FROM item_collections)")
    }
  }
  public func reset() throws {
    try transaction {
      for table in ["item_fts", "page_fts", "items", "authors", "tags", "collections"] {
        try execute("DELETE FROM \(table)")
      }
    }
  }
  public func organization(_ table: String) throws -> [String] {
    guard ["tags", "collections"].contains(table) else { return [] }
    return try rows("SELECT name FROM \(table) ORDER BY name COLLATE NOCASE").compactMap {
      $0["name"]
    }
  }
  private func ftsQuery(_ input: String) -> String {
    let regex = try! NSRegularExpression(pattern: "\"[^\"]+\"|[^\\s]+")
    let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
    return matches.compactMap {
      Range($0.range, in: input).map {
        let token = String(input[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      }
    }.joined(separator: " AND ")
  }
  public func search(
    _ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 100, offset: Int = 0,
    metadataOnly: Bool = false
  ) throws -> [RetrievalResult] {
    try search(query, filters: filters, limit: limit, offset: offset,
      metadataOnly: metadataOnly, cancellation: nil)
  }
  func search(
    _ query: String, filters: SearchFilters, limit: Int, offset: Int, metadataOnly: Bool,
    cancellation: SearchCancellation?
  ) throws -> [RetrievalResult] {
    try withSearchCancellation(cancellation) {
      // All phases use the same WAL snapshot, including excerpts and citation details.
      let ownsSnapshot = sqlite3_get_autocommit(db) != 0
      if ownsSnapshot { try execute("BEGIN") }
      do {
        let values = try groupedSearch(query, filters: filters, limit: limit, offset: offset,
          metadataOnly: metadataOnly, cancellation: cancellation)
        try cancellation?.check()
        if ownsSnapshot { try execute("COMMIT") }
        return values
      } catch {
        if ownsSnapshot {
          sqlite3_progress_handler(db, 0, nil, nil)
          try? execute("ROLLBACK")
        }
        throw error
      }
    }
  }
  private func groupedSearch(
    _ query: String, filters: SearchFilters, limit: Int, offset: Int, metadataOnly: Bool,
    cancellation: SearchCancellation?
  ) throws -> [RetrievalResult] {
    var conditions: [String] = []
    var args: [String?] = []
    func condition(_ sql: String, _ value: String?) {
      conditions.append(sql)
      args.append(value)
    }
    if !filters.author.isEmpty { condition("i.authors LIKE ?", "%\(filters.author)%") }
    if !filters.journal.isEmpty { condition("i.journal LIKE ?", "%\(filters.journal)%") }
    if let y = filters.yearMin { condition("i.year>=?", String(y)) }
    if let y = filters.yearMax { condition("i.year<=?", String(y)) }
    if let v = filters.favorite { condition("i.favorite=?", v ? "1" : "0") }
    if let v = filters.read { condition("i.read=?", v ? "1" : "0") }
    if let v = filters.hasPDF { condition("i.has_pdf=?", v ? "1" : "0") }
    if let v = filters.tag {
      condition("EXISTS(SELECT 1 FROM item_tags t WHERE t.item_id=i.id AND t.name=?)", v)
    }
    if let v = filters.collection {
      condition("EXISTS(SELECT 1 FROM item_collections t WHERE t.item_id=i.id AND t.name=?)", v)
    }
    if filters.needsReview { conditions.append("(i.confidence<0.7 OR json_extract(i.json, '$.pdfLookup.status') IN ('needsReview','requiresAuthentication','notFound','retry'))") }
    if filters.recentlyAdded {
      condition("i.added>=?", String(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970))
    }
    let whereClause = conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ")
    let bound = max(1, min(500, limit))
    let start = max(0, offset)
    let sortOrder: String
    switch filters.sort {
    case .title: sortOrder = "CASE WHEN trim(i.title)='' THEN 1 ELSE 0 END,lower(trim(i.title)) ASC,i.added DESC,i.id"
    case .year: sortOrder = "CASE WHEN i.year IS NULL THEN 1 ELSE 0 END,i.year DESC,i.added DESC,i.id"
    case .publicationDate:
      sortOrder = "CASE WHEN json_extract(i.json,'$.publicationDate') IS NULL OR json_extract(i.json,'$.publicationDate')='' THEN 1 ELSE 0 END,json_extract(i.json,'$.publicationDate') DESC, i.year DESC, i.added DESC, i.id"
    case .dateAdded, .relevance: sortOrder = "i.added DESC,i.id"
    }
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return try rows("SELECT i.json FROM items i WHERE 1=1\(whereClause) ORDER BY \(sortOrder) LIMIT \(bound) OFFSET \(start)", args).map { row in
        try cancellation?.check()
        return RetrievalResult(item: try PortableJSON.decoder().decode(LibraryItem.self, from: Data(row["json"]!.utf8)))
      }
    }
    let q = ftsQuery(query)
    let wanted = start > Int.max - bound ? Int.max : start + bound
    var selected: [[String: String]]
    if filters.sort == .relevance {
      var candidates: [[String: String]] = []
      var seen = Set<String>()
      try scan("""
        SELECT i.id,item_fts.rowid AS hit_rowid,0 AS tier,rank AS score
        FROM item_fts JOIN items i ON i.id=item_fts.item_id
        WHERE item_fts MATCH ? AND rank MATCH 'bm25(0,12,5,3,2,6,3,3,2)'\(whereClause)
        ORDER BY rank
        """, [q] + args) { row in
        try cancellation?.check()
        if let id = row["id"], seen.insert(id).inserted { candidates.append(row) }
        return candidates.count < wanted
      }
      if !metadataOnly && candidates.count < wanted {
        try scan("""
          SELECT i.id,page_fts.rowid AS hit_rowid,1 AS tier,rank AS score,resource_id,page
          FROM page_fts JOIN items i ON i.id=page_fts.item_id
          WHERE page_fts MATCH ?\(whereClause) ORDER BY rank
          """, [q] + args) { row in
          try cancellation?.check()
          if let id = row["id"], seen.insert(id).inserted { candidates.append(row) }
          return candidates.count < wanted
        }
      }
      selected = Array(candidates.dropFirst(start).prefix(bound))
    } else {
      let body = metadataOnly ? "" : " UNION SELECT item_id FROM page_fts WHERE page_fts MATCH ?"
      let found = try rows("""
        WITH matching AS (SELECT item_id FROM item_fts WHERE item_fts MATCH ?\(body))
        SELECT DISTINCT i.id FROM matching h JOIN items i ON i.id=h.item_id
        WHERE 1=1\(whereClause) ORDER BY \(sortOrder) LIMIT \(bound) OFFSET \(start)
        """, (metadataOnly ? [q] : [q, q]) + args)
      let ids = found.compactMap { $0["id"] }
      guard !ids.isEmpty else { return [] }
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      let metadata = try rows("""
        SELECT item_id AS id,rowid AS hit_rowid,0 AS tier,bm25(item_fts,0,12,5,3,2,6,3,3,2) AS score
        FROM item_fts WHERE item_fts MATCH ? AND rowid IN
          (SELECT fts_rowid FROM item_fts_lookup WHERE item_id IN (\(placeholders)))
        """, [q] + ids)
      var hits = Dictionary(uniqueKeysWithValues: metadata.map { ($0["id"]!, $0) })
      let bodyIDs = ids.filter { hits[$0] == nil }
      if !bodyIDs.isEmpty && !metadataOnly {
        let placeholders = Array(repeating: "?", count: bodyIDs.count).joined(separator: ",")
        try scan("""
          SELECT item_id AS id,rowid AS hit_rowid,1 AS tier,bm25(page_fts) AS score,resource_id,page
          FROM page_fts WHERE page_fts MATCH ? AND rowid IN
            (SELECT fts_rowid FROM page_fts_lookup WHERE item_id IN (\(placeholders)))
          ORDER BY score,rowid
          """, [q] + bodyIDs) { row in
          try cancellation?.check()
          if let id = row["id"], hits[id] == nil { hits[id] = row }
          return hits.count < ids.count
        }
      }
      selected = ids.compactMap { hits[$0] }
    }
    return try hydrateSearchHits(selected, query: q, cancellation: cancellation)
  }

  /// Excerpts and citation details are computed only for the selected article page.
  private func hydrateSearchHits(_ hits: [[String: String]], query: String,
    cancellation: SearchCancellation?) throws -> [RetrievalResult] {
    guard !hits.isEmpty else { return [] }
    let ids = Array(Set(hits.compactMap { $0["id"] }))
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
    let records = try rows("SELECT id,json FROM items WHERE id IN (\(placeholders))", ids)
    var items: [String: LibraryItem] = [:]
    for row in records {
      try cancellation?.check()
      items[row["id"]!] = try PortableJSON.decoder().decode(LibraryItem.self, from: Data(row["json"]!.utf8))
    }
    var snippets: [String: String] = [:]
    for (tier, table, column) in [("0", "item_fts", 1), ("1", "page_fts", 3)] {
      let rowIDs = hits.filter { $0["tier"] == tier }.compactMap { $0["hit_rowid"] }
      if rowIDs.isEmpty { continue }
      let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
      for row in try rows("SELECT rowid,snippet(\(table),\(column),'','',' … ',32) AS excerpt FROM \(table) WHERE \(table) MATCH ? AND rowid IN (\(placeholders))", [query] + rowIDs) {
        snippets[tier + ":" + row["rowid"]!] = row["excerpt"]
      }
    }
    let pages = hits.filter { $0["page"] != nil }
    var details: [String: [String: String]] = [:]
    for index in stride(from: 0, to: pages.count, by: 200) {
      let batch = Array(pages[index..<min(index + 200, pages.count)])
      let values = Array(repeating: "(?,?,?)", count: batch.count).joined(separator: ",")
      let bindings = batch.flatMap { [$0["id"], $0["resource_id"], $0["page"]] }
      for row in try rows("""
        WITH requested(item_id,resource_id,page) AS (VALUES \(values)), matched AS (
          SELECT r.item_id,c.id,json_extract(c.json,'$.sectionID') AS section_id,
            ROW_NUMBER() OVER(PARTITION BY r.item_id ORDER BY c.sequence,c.id) AS position
          FROM requested r JOIN chunks c ON c.item_id=r.item_id AND c.resource_id=r.resource_id
            AND c.start_page<=r.page AND c.end_page>=r.page)
        SELECT m.item_id,m.id,json_extract(s.json,'$.heading') AS heading
        FROM matched m LEFT JOIN sections s ON s.id=m.section_id WHERE position=1
        """, bindings) { details[row["item_id"]!] = row }
    }
    return try hits.compactMap { row in
      try cancellation?.check()
      guard let id = row["id"], let item = items[id] else { return nil }
      let detail = details[id]
      let page = row["page"].flatMap(Int.init)
      let score = Double(row["score"] ?? "0") ?? 0
      return RetrievalResult(item: item, chunkID: detail?["id"].flatMap(UUID.init(uuidString:)),
        resourceID: row["resource_id"].flatMap(UUID.init(uuidString:)),
        snippet: snippets[(row["tier"] ?? "0") + ":" + (row["hit_rowid"] ?? "")] ?? "",
        score: -score + (row["tier"] == "0" ? 10 : 0), pageStart: page, pageEnd: page,
        section: detail?["heading"])
    }
  }

  public func matchingPages(_ query: String, itemID: UUID, limit: Int = 5, offset: Int = 0) throws -> [RetrievalResult] {
    try matchingPages(query, itemID: itemID, limit: limit, offset: offset, cancellation: nil)
  }
  func matchingPages(_ query: String, itemID: UUID, limit: Int, offset: Int,
    cancellation: SearchCancellation?) throws -> [RetrievalResult] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return try withSearchCancellation(cancellation) {
      try execute("BEGIN")
      do {
        let q = ftsQuery(query)
        let hits = try rows("""
          SELECT item_id AS id,rowid AS hit_rowid,1 AS tier,bm25(page_fts) AS score,resource_id,page
          FROM page_fts WHERE page_fts MATCH ? AND rowid IN
            (SELECT fts_rowid FROM page_fts_lookup WHERE item_id=?)
          ORDER BY score,rowid LIMIT \(max(1,min(20,limit))) OFFSET \(max(0,offset))
          """, [q,itemID.uuidString])
        // One article can supply several page matches; hydrate per page to retain citation identity.
        var results: [RetrievalResult] = []
        for hit in hits { results += try hydrateSearchHits([hit], query: q, cancellation: cancellation) }
        try cancellation?.check()
        try execute("COMMIT")
        return results
      } catch {
        sqlite3_progress_handler(db, 0, nil, nil)
        try? execute("ROLLBACK")
        throw error
      }
    }
  }
}

/// A separate, read-only WAL connection. Search never waits for LibraryService's import actor.
actor LibrarySearchReader {
  private let url: URL
  private var database: LocalDatabase?
  init(url: URL) { self.url = url }
  private func connection() throws -> LocalDatabase {
    if let database { return database }
    let opened = try LocalDatabase(url: url, readOnly: true)
    database = opened
    return opened
  }
  nonisolated func search(_ query: String, filters: SearchFilters, limit: Int, offset: Int,
    metadataOnly: Bool = false) async throws -> [RetrievalResult] {
    let cancellation = SearchCancellation()
    return try await withTaskCancellationHandler(operation: {
      try await perform(query, filters: filters, limit: limit, offset: offset,
        metadataOnly: metadataOnly, cancellation: cancellation)
    }, onCancel: { cancellation.cancel() })
  }
  private func perform(_ query: String, filters: SearchFilters, limit: Int, offset: Int,
    metadataOnly: Bool, cancellation: SearchCancellation) throws -> [RetrievalResult] {
    try cancellation.check()
    return try connection().search(query, filters: filters, limit: limit, offset: offset,
      metadataOnly: metadataOnly, cancellation: cancellation)
  }
  nonisolated func matchingPages(_ query: String, itemID: UUID, limit: Int, offset: Int) async throws -> [RetrievalResult] {
    let cancellation = SearchCancellation()
    return try await withTaskCancellationHandler(operation: {
      try await performPages(query, itemID: itemID, limit: limit, offset: offset, cancellation: cancellation)
    }, onCancel: { cancellation.cancel() })
  }
  private func performPages(_ query: String, itemID: UUID, limit: Int, offset: Int,
    cancellation: SearchCancellation) throws -> [RetrievalResult] {
    try cancellation.check()
    return try connection().matchingPages(query, itemID: itemID, limit: limit, offset: offset,
      cancellation: cancellation)
  }
}
