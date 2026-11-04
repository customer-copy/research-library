import CryptoKit
import Foundation
import Darwin
import OSLog

public enum Identifiers {
  static func capture(_ pattern: String, _ text: String, group: Int = 0) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let r = Range(m.range(at: group), in: text)
    else { return nil }
    return String(text[r])
  }
  public static func doi(_ text: String) -> String? {
    // PDF text extraction preserves layout line breaks. A publisher DOI may wrap after
    // its slash, or before the numeric continuation of a hyphenated suffix.
    var unfolded = text
    for _ in 0..<3 {
      unfolded = unfolded.replacingOccurrences(
        of: "(10\\.\\d{4,9}/[-._;()/:A-Z0-9]*-)[\\t ]*\\r?\\n[\\t ]*([0-9][-._;()/:A-Z0-9]*)",
        with: "$1$2", options: [.regularExpression, .caseInsensitive])
      unfolded = unfolded.replacingOccurrences(
        of: "(10\\.\\d{4,9}/)[\\t ]*\\r?\\n[\\t ]*([-._;()/:A-Z0-9]+)",
        with: "$1$2", options: [.regularExpression, .caseInsensitive])
    }
    guard
      var value = capture("10\\.\\d{4,9}/[-._;()/:A-Z0-9]+", unfolded)?.trimmingCharacters(
        in: CharacterSet(charactersIn: ".,; ")
      ).lowercased()
    else { return nil }
    while value.hasSuffix(")")
      && value.filter({ $0 == ")" }).count > value.filter({ $0 == "(" }).count
    { value.removeLast() }
    return value
  }
  static func containsDOI(_ doi: String, in text: String) -> Bool {
    // Match the known identifier across PDF line breaks without accepting an unrelated
    // truncated DOI or removing all whitespace from the surrounding document.
    let pattern = doi.map { NSRegularExpression.escapedPattern(for: String($0)) }
      .joined(separator: "(?:[\\t ]*\\r?\\n[\\t ]*)?")
    return capture(pattern, text) != nil
  }
  public static func pmcid(_ text: String) -> String? {
    capture("\\bPMC[0-9]+\\b", text)?.uppercased()
  }
  public static func pmid(_ text: String) -> String? {
    capture("(?:PMID\\s*:?\\s*|pubmed\\.ncbi\\.nlm\\.nih\\.gov/)([0-9]{1,9})", text, group: 1)
  }
  public static func arxiv(_ text: String) -> String? {
    capture(
      "(?:arxiv\\s*:?\\s*|arxiv\\.org/(?:abs|pdf)/)([0-9]{4}\\.[0-9]{4,5}(?:v[0-9]+)?|[a-z.-]+/[0-9]{7}(?:v[0-9]+)?)",
      text, group: 1)
  }
  public static func canonicalURL(_ text: String) throws -> URL {
    guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = c.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")),
      !host.isEmpty, c.user == nil, c.password == nil
    else { throw LibraryError.invalid("Use an HTTP or HTTPS URL without embedded credentials.") }
    // Network captures cannot probe loopback/private/link-local hosts.
    let blocked = [
      "localhost", "127.", "0.", "10.", "192.168.", "169.254.", "::1", "fc", "fd", "fe80:",
    ]
    if blocked.contains(where: {
      host == $0 || host.hasPrefix($0) && ($0.contains(".") || $0.contains(":"))
    }) || host.hasSuffix(".local")
      || (host.hasPrefix("172.")
        && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
    {
      throw LibraryError.invalid("Local and private network URLs cannot be fetched.")
    }
    if host.allSatisfy(\.isNumber) || NetworkSafety.isBlockedLiteral(host)
      || (host.contains(":")
        && (host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")))
    {
      throw LibraryError.invalid("Private network URLs cannot be fetched.")
    }
    c.scheme = scheme
    // IPv6 literals must keep their brackets in a URL.
    if host.contains(":") { c.percentEncodedHost = "[\(host)]" } else { c.host = host }
    c.fragment = nil
    c.queryItems = c.queryItems?.filter {
      !$0.name.lowercased().hasPrefix("utm_")
        && !["fbclid", "gclid"].contains($0.name.lowercased())
    }
    if c.queryItems?.isEmpty == true { c.queryItems = nil }
    if c.path.isEmpty { c.path = "/" }
    guard let url = c.url else { throw LibraryError.invalid("Invalid URL") }
    return url
  }
}
public enum Files {
  struct Revision: Codable, Equatable, Sendable {
    let size: Int64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let flags: UInt32
  }
  static func revision(_ url: URL) -> Revision? {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
    }
    guard result == 0 else { return nil }
    return Revision(size: Int64(info.st_size), inode: UInt64(info.st_ino),
      modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
      changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
      flags: info.st_flags)
  }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let d = try handle.read(upToCount: 1024 * 1024), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func stableID(_ value: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
  public static func sanitized(_ value: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t").union(.controlCharacters)
    let result = value.components(separatedBy: bad).joined(separator: " ").split(
      whereSeparator: \.isWhitespace
    ).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String((result.isEmpty ? "Untitled" : result).prefix(150))
  }
  public static func filename(_ item: LibraryItem, pattern: String = "{year} - {author} - {title}")
    -> String
  {
    sanitized(
      pattern.replacingOccurrences(of: "{year}", with: item.year.map(String.init) ?? "undated")
        .replacingOccurrences(
          of: "{author}", with: item.orderedAuthors.first?.familyName ?? "Unknown"
        ).replacingOccurrences(of: "{title}", with: String(item.title.prefix(80)))) + ".pdf"
  }
  public static func uniqueURL(_ proposed: URL) -> URL {
    var url = proposed
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = proposed.deletingPathExtension().appendingPathExtension(
        "\(n)." + proposed.pathExtension)
      n += 1
    }
    return url
  }
  public static func safeURL(root: URL, relative: String) throws -> URL {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
      throw LibraryError.invalid("Unsafe attachment path")
    }
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let url = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard url.path.hasPrefix(root.path + "/") else {
      throw LibraryError.invalid("Attachment escapes library")
    }
    return url
  }
  public static func materialize(_ url: URL) throws {
    if hasResidentData(url) { return }
    var freshURL = url
    freshURL.removeAllCachedResourceValues()
    let v = try freshURL.resourceValues(forKeys: [
      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
      .ubiquitousItemDownloadingErrorKey,
    ])
    if v.isUbiquitousItem == true && !isDownloadAvailable(v.ubiquitousItemDownloadingStatus) {
      // File Provider may omit the legacy download status for newly written cloud files.
      // Resident bytes are usable through coordination; a dataless placeholder still downloads.
      if hasResidentData(url) { return }
      if let error = v.ubiquitousItemDownloadingError {
        throw LibraryError.invalid("iCloud download failed: " + error.localizedDescription)
      }
      try FileManager.default.startDownloadingUbiquitousItem(at: url)
      throw ResourceDownloadPending()
    }
  }
  static func hasResidentData(_ url: URL) -> Bool {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
    }
    return result == 0 && info.st_size > 0 && (info.st_flags & UInt32(SF_DATALESS)) == 0
  }
  static func localModificationDate(_ url: URL) -> Date? {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
    }
    guard result == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
  }
  public static func isDownloadAvailable(_ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
    status == .current || status == .downloaded
  }
  public static func coordinatedRead<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
    var error: NSError?
    var result: Result<T, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
      result = Result { try operation(u) }
    }
    if let error { throw error }
    guard let result else { throw LibraryError.invalid("File coordination failed") }
    return try result.get()
  }
  public static func atomicWrite(_ data: Data, to url: URL) throws {
    var error: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
      result = Result { try data.write(to: u, options: .atomic) }
    }
    if let error { throw error }
    try result?.get()
  }
  /// Install without replacing an unrelated destination or loading the entire PDF into memory.
  static func installVerifiedCopy(_ source: URL, to destination: URL, expectedHash: String) throws {
    var error: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(readingItemAt: source, options: [],
      writingItemAt: destination, options: [], error: &error) { original, target in
      result = Result {
        if FileManager.default.fileExists(atPath: target.path) {
          guard try hash(target) == expectedHash else {
            throw LibraryError.conflict("The organized destination contains a different file. Original retained.")
          }
          return
        }
        guard try hash(original) == expectedHash else {
          throw LibraryError.conflict("The Inbox file changed during import. Original retained.")
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID()).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: original, to: temporary)
        guard try hash(temporary) == expectedHash else {
          throw LibraryError.invalid("Organized copy verification failed. Original retained.")
        }
        try Task.checkCancellation()
        // moveItem refuses an existing target; coordination and that check both prevent clobbering.
        try FileManager.default.moveItem(at: temporary, to: target)
      }
    }
    if let error { throw error }
    guard let result else { throw LibraryError.invalid("Import file coordination failed") }
    try result.get()
  }
  public static func atomicCopy(_ source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try coordinatedRead(source) { file in
      try FileManager.default.copyItem(at: file, to: temporary)
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporary, to: destination)
  }
  /// How many earlier versions of each item's metadata are kept in Recovery/Metadata/<id>/.
  public static let recoveryVersionsPerItem = 20
  /// Deletes all but the `keep` most recently modified .json files in `folder`.
  static func pruneOldest(in folder: URL, keep: Int) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
    ).filter({ $0.pathExtension == "json" }), files.count > keep else { return }
    let dated = files.map { url in
      (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
    }.sorted { $0.1 > $1.1 }
    for (url, _) in dated.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
  }
  public static func permanentlyRemove(_ url: URL) throws {
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { file in
      result = Result {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw LibraryError.invalid("Deletion coordination failed") }
    try result.get()
  }
}

public struct SidecarService: Sendable {
  public let root: URL
  public init(root: URL) throws {
    self.root = root
    for dir in [
      "Metadata", "PDFs", "Inbox", "Inbox/Requests", "Needs Review", "Exports", "Recovery",
    ] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
  }
  public func url(_ id: UUID) -> URL {
    root.appendingPathComponent("Metadata/\(id.uuidString).json")
  }
  public func save(_ item: LibraryItem) throws {
    let target = url(item.id)
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(
      writingItemAt: target, options: .forReplacing, error: &coordinationError
    ) { url in
      result = Result {
        var fresh =
          try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(item))
          as! [String: Any]
        var envelope: [String: Any] = ["schemaVersion": 1]
        if FileManager.default.fileExists(atPath: url.path) {
          let oldData = try Data(contentsOf: url)
          guard let old = try JSONSerialization.jsonObject(with: oldData) as? [String: Any],
            let version = old["schemaVersion"] as? Int, version == 1
          else { throw LibraryError.invalid("Cannot overwrite unsupported or malformed metadata") }
          let prior = old["item"] as? [String: Any] ?? [:]
          if let decoded = try? PortableJSON.decoder().decode(
            LibraryItem.self, from: JSONSerialization.data(withJSONObject: prior)),
            decoded.dateModified.timeIntervalSince(item.dateModified) > 1
          {
            throw LibraryError.conflict(
              "Metadata changed on another device. Refresh and retry your edit.")
          }
          fresh = mergeUnknown(prior, fresh)
          for (key, value) in old where key != "item" { envelope[key] = value }
          let backup = root.appendingPathComponent("Recovery/Metadata/\(item.id.uuidString)")
          try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
          let hash = SHA256.hash(data: oldData).prefix(8).map { String(format: "%02x", $0) }
            .joined()
          let previous = backup.appendingPathComponent(hash + ".json")
          if !FileManager.default.fileExists(atPath: previous.path) {
            try oldData.write(to: previous, options: .atomic)
            Files.pruneOldest(in: backup, keep: Files.recoveryVersionsPerItem)
          }
        }
        envelope["item"] = fresh
        try JSONSerialization.data(
          withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]
        ).write(to: url, options: .atomic)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw LibraryError.invalid("Metadata coordination failed") }
    try result.get()
  }
  private func mergeUnknown(_ old: [String: Any], _ fresh: [String: Any]) -> [String: Any] {
    var result = old
    for key in [
      "doi", "pmid", "pmcid", "arxivID", "canonicalURL", "year", "publicationDate", "orcid",
      "remoteURL", "relativePath", "mimeType", "sha256",
    ] where fresh[key] == nil { result.removeValue(forKey: key) }
    for (key, value) in fresh {
      if let a = old[key] as? [String: Any], let b = value as? [String: Any] {
        result[key] = mergeUnknown(a, b)
      } else if let a = old[key] as? [[String: Any]], let b = value as? [[String: Any]] {
        result[key] = b.map { record in
          guard let id = record["id"] as? String,
            let prior = a.first(where: { $0["id"] as? String == id })
          else { return record }
          return mergeUnknown(prior, record)
        }
      } else {
        result[key] = value
      }
    }
    return result
  }
  public func read(_ url: URL) throws -> LibraryItem {
    try Files.materialize(url)
    return try Files.coordinatedRead(url) { u in
      let data = try Data(contentsOf: u)
      guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let version = envelope["schemaVersion"] as? Int, version == 1, let item = envelope["item"]
      else {
        throw LibraryError.invalid("Unsupported or malformed metadata: \(u.lastPathComponent)")
      }
      let value = try PortableJSON.decoder().decode(
        LibraryItem.self, from: JSONSerialization.data(withJSONObject: item))
      guard
        u.deletingPathExtension().lastPathComponent.lowercased() == value.id.uuidString.lowercased()
      else { throw LibraryError.invalid("Metadata filename/UUID mismatch") }
      return value
    }
  }
  public func metadataFiles() throws -> [URL] {
    try Files.coordinatedRead(root.appendingPathComponent("Metadata")) {
      try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).filter {
        $0.pathExtension == "json"
      }
    }
  }
  public func saveRequest(_ request: IngestionRequest) throws {
    try Files.atomicWrite(
      PortableJSON.encoder().encode(request),
      to: root.appendingPathComponent("Inbox/Requests/\(request.id.uuidString).json"))
  }
  public func requests() throws -> [IngestionRequest] {
    let urls = try Files.coordinatedRead(root.appendingPathComponent("Inbox/Requests")) {
      try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).filter {
        $0.pathExtension == "json"
      }
    }
    return urls.compactMap { url in
      do {
        try Files.materialize(url)
        return try Files.coordinatedRead(url) {
          try PortableJSON.decoder().decode(IngestionRequest.self, from: Data(contentsOf: $0))
        }
      } catch {
        Logger(subsystem: "org.researchlibrary.app", category: "CaptureQueue").error(
          "Capture unavailable: \(url.lastPathComponent,privacy:.public) \(error.localizedDescription,privacy:.public)"
        )
        return nil
      }
    }
  }
}

public struct ResourceDownloadPending: Error, LocalizedError {
  public init() {}
  public var errorDescription: String? { "iCloud download pending; this capture will retry." }
}
