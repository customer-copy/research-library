import Foundation
import ResearchCore

@main struct LibraryTool {
  static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count >= 2 else {
        throw LibraryError.invalid(
          "Usage: ResearchLibraryTool <library-folder> add <DOI/PMID/URL> | import <file> | search <query> | rebuild | integrity | export <json/bib/ris>"
        )
      }
      if args[0] == "benchmark-search" {
        try benchmarkSearch(args)
        return
      }
      let root = URL(fileURLWithPath: args[0], isDirectory: true)
      let service = try LibraryService(root: root)
      try await service.synchronizeSidecars()
      switch args[1] {
      case "add":
        guard args.count >= 3 else { throw LibraryError.invalid("Provide a URL or identifier") }
        let request = IngestionRequest(source: "cli", text: args[2])
        try await service.submit(request)
        await service.processPending()
        if let item = try await service.item(request.id) {
          print(String(data: try PortableJSON.encoder().encode(item), encoding: .utf8)!)
        } else {
          print("Queued; inspect Inbox/Requests for processing or review status.")
        }
      case "import":
        guard args.count >= 3 else { throw LibraryError.invalid("Provide a PDF or file") }
        _ = try await service.captureFile(URL(fileURLWithPath: args[2]))
        await service.processPending()
        print("Capture processed")
      case "search":
        let results = try await service.search(args.count > 2 ? args[2] : "", limit: 100)
        for result in results {
          print(
            "\(result.item.id)\t\(result.item.title)\t\(result.pageStart.map{ "page \($0)" } ?? "metadata")\t\(result.snippet)"
          )
        }
      case "rebuild": print("Rebuilt; \(try await service.rebuild().count) issues")
      case "integrity":
        for issue in try await service.integrity() { print("\(issue.path): \(issue.message)") }
      case "export":
        guard args.count > 2, let format = ExportFormat(rawValue: args[2]) else {
          throw LibraryError.invalid("Choose json, bib, or ris")
        }
        print(try await service.export(format: format).path)
      default: throw LibraryError.invalid("Unknown command")
      }
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  /// Timing/counts only. The optional migration flag is used only on a disposable index copy.
  static func benchmarkSearch(_ args: [String]) throws {
    let opened = ContinuousClock.now
    let db = try LocalDatabase(url: URL(fileURLWithPath: args[1]),
      readOnly: !args.contains("--migrate-copy"))
    func milliseconds(_ duration: Duration) -> Double {
      let parts = duration.components
      return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
    let opening = milliseconds(opened.duration(to: .now))
    let counts = try db.rows("SELECT (SELECT count(*) FROM items) AS items,(SELECT count(*) FROM page_fts) AS indexedPages").first ?? [:]
    var measurements: [[String: Any]] = []
    for query in ["cell", "microglia", "from pixels", "10.1146/annurev-cellbio-111524-111428"] {
      var previews: [Double] = [], searches: [Double] = [], legacy: [Double] = []
      var resultCount = 0, distinct = 0, oldDistinct = 0
      for _ in 0..<3 {
        let q = query.split(separator: " ").map { "\"\($0)\"" }.joined(separator: " AND ")
        let oldStart = ContinuousClock.now
        let old = try db.rows("""
          SELECT i.id,h.snippet,h.score FROM (
            SELECT item_id,snippet(item_fts,1,'','',' … ',24) AS snippet,bm25(item_fts,0,12,5,3,2,6,3,3,2)-10 AS score FROM item_fts WHERE item_fts MATCH ?
            UNION ALL SELECT item_id,snippet(page_fts,3,'','',' … ',32),bm25(page_fts) FROM page_fts WHERE page_fts MATCH ?
          ) h JOIN items i ON i.id=h.item_id ORDER BY h.score LIMIT 100
          """, [q,q])
        legacy.append(milliseconds(oldStart.duration(to: .now)))
        oldDistinct = Set(old.compactMap { $0["id"] }).count
        let previewStart = ContinuousClock.now
        _ = try db.search(query, metadataOnly: true)
        previews.append(milliseconds(previewStart.duration(to: .now)))
        let searchStart = ContinuousClock.now
        let values = try db.search(query)
        searches.append(milliseconds(searchStart.duration(to: .now)))
        resultCount = values.count
        distinct = Set(values.map { $0.item.id }).count
      }
      measurements.append(["query": query, "legacySQLMedianMilliseconds": legacy.sorted()[1],
        "metadataPreviewMedianMilliseconds": previews.sorted()[1], "completeSearchMedianMilliseconds": searches.sorted()[1],
        "resultRows": resultCount, "distinctPapers": distinct, "legacyDistinctPapersIn100Rows": oldDistinct])
    }
    let report: [String: Any] = ["counts": counts, "openAndOptionalMigrationMilliseconds": opening,
      "measurements": measurements,
      "limitations": "Warm median of three runs. Legacy measures SQL only; new search includes decoding, excerpts and citation hydration. Excludes UI rendering and background contention."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    if args.count > 2, args[2] != "--migrate-copy" {
      try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    }
    print(String(decoding: data, as: UTF8.self))
  }
}
