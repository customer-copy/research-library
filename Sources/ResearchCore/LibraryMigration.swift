import Foundation

public struct LibraryMigrationProgress: Sendable {
  public var filesDone = 0
  public var totalFiles = 0
  public var bytesDone: Int64 = 0
  public var totalBytes: Int64 = 0
  public var currentFile = ""
}

public struct LibraryMigrationReport: Sendable {
  public var totalFiles = 0
  public var filesCopied = 0
  public var filesAlreadyCopied = 0
  public var bytesCopied: Int64 = 0
  public var attachmentsChecked = 0
  /// Files that are not safely present in the destination. Non-empty means "do not switch".
  public var problems: [String] = []
  /// Attachments whose bytes already differed from their recorded hash in the original
  /// library. The copy is byte-identical to the source; these are reported, not blocking.
  public var preexistingHashDifferences: [String] = []
  public var isComplete: Bool { problems.isEmpty }
}

/// Copies a library folder (for example from iCloud Drive) to a local folder, one file at a
/// time: download if cloud-only, copy, verify the copy's SHA-256 against the source bytes,
/// then optionally let iCloud release its local copy. Peak extra disk use is about one file.
///
/// The source is never modified or deleted (eviction only removes the local cached copy of
/// an iCloud file; the file stays in iCloud). The copy is resumable: rerunning skips files
/// already verified, so an interruption (full disk, quit, offline) loses no work.
public enum LibraryMigration {
  public static let stateFolderName = ".research-library-migration"
  static let manifestName = "verified.tsv"

  public static func copyLibrary(
    from source: URL, to destination: URL,
    reserveBytes: Int64 = 5 * 1024 * 1024 * 1024,
    evictCloudSource: Bool = true,
    downloadTimeout: Duration = .seconds(600),
    availableBytes: (@Sendable (URL) -> Int64?)? = nil,
    progress: @escaping @Sendable (LibraryMigrationProgress) -> Void = { _ in }
  ) async throws -> LibraryMigrationReport {
    let source = source.resolvingSymlinksInPath().standardizedFileURL
    let destination = destination.resolvingSymlinksInPath().standardizedFileURL
    try validate(source: source, destination: destination)

    let state = destination.appendingPathComponent(stateFolderName, isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let manifestURL = state.appendingPathComponent(manifestName)
    var verified = try loadManifest(manifestURL)
    try Data("source\t\(source.path)\nstarted\t\(Date())\n".utf8)
      .write(to: state.appendingPathComponent("info.txt"), options: .atomic)

    let files = try enumerateFiles(source)
    var report = LibraryMigrationReport(totalFiles: files.count)
    var status = LibraryMigrationProgress(
      totalFiles: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
    progress(status)
    let manifest = try FileHandle(forWritingTo: manifestURL)
    defer { try? manifest.close() }
    try manifest.seekToEnd()

    for file in files {
      try Task.checkCancellation()
      status.currentFile = file.relative
      let target = destination.appendingPathComponent(file.relative)
      if verified[file.relative] != nil, size(of: target) == file.size {
        report.filesAlreadyCopied += 1
      } else {
        let free = availableBytes?(destination) ?? volumeAvailable(destination)
        if let free, free - file.size < reserveBytes {
          throw LibraryError.invalid(
            "Not enough disk space to continue: \(format(free)) free, and \(format(reserveBytes)) must stay free. "
              + "\(report.filesCopied + report.filesAlreadyCopied) of \(files.count) files are copied. "
              + "Free up space and run the move again; it will continue where it stopped.")
        }
        try await download(file.url, timeout: downloadTimeout)
        let hash = try copyVerified(file.url, to: target)
        verified[file.relative] = hash
        manifest.write(Data("\(file.relative)\t\(hash)\n".utf8))
        report.filesCopied += 1
        report.bytesCopied += file.size
        if evictCloudSource, isUbiquitous(file.url) {
          try? FileManager.default.evictUbiquitousItem(at: file.url)
        }
      }
      status.filesDone += 1
      status.bytesDone += file.size
      progress(status)
      if status.filesDone % 25 == 0 { await Task.yield() }
    }

    // Every source file must be present in the destination with its verified size.
    for file in files {
      let target = destination.appendingPathComponent(file.relative)
      if verified[file.relative] == nil || size(of: target) != file.size {
        report.problems.append(file.relative)
      }
    }
    // Cross-check attachments against the hashes recorded in each metadata file.
    let sidecars = try SidecarService(root: destination)
    for url in try sidecars.metadataFiles() {
      guard let item = try? sidecars.read(url) else { continue }
      for resource in item.resources {
        guard let path = resource.relativePath else { continue }
        report.attachmentsChecked += 1
        guard let copied = verified[path] else {
          if !FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path) {
            report.preexistingHashDifferences.append("\(path) (missing in original library)")
          }
          continue
        }
        if let expected = resource.sha256, expected != copied {
          report.preexistingHashDifferences.append(path)
        }
      }
    }
    if report.isComplete {
      try Data("source\t\(source.path)\ncompleted\t\(Date())\nfiles\t\(files.count)\n".utf8)
        .write(to: state.appendingPathComponent("info.txt"), options: .atomic)
    }
    return report
  }

  // MARK: - Steps

  static func validate(source: URL, destination: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Metadata").path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
      throw LibraryError.invalid("The current library folder has no Metadata folder; it does not look like a Research Library.")
    }
    let s = source.path + "/", d = destination.path + "/"
    guard !d.hasPrefix(s), !s.hasPrefix(d) else {
      throw LibraryError.invalid("Choose a destination outside the current library folder.")
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      let contents = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        .filter { $0 != ".DS_Store" }
      let resuming = contents.contains(stateFolderName)
      guard contents.isEmpty || resuming else {
        throw LibraryError.invalid("Choose an empty folder for the new library (or the folder of an earlier, unfinished move).")
      }
    }
  }

  struct SourceFile { let url: URL; let relative: String; let size: Int64 }

  static func enumerateFiles(_ root: URL) throws -> [SourceFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
      throw LibraryError.invalid("Could not read the library folder")
    }
    var files: [SourceFile] = []
    let prefix = root.path + "/"
    for case let url as URL in walker {
      let name = url.lastPathComponent
      // Hidden files are temporary (.partial, .part) or Finder/iCloud bookkeeping.
      if name.hasPrefix(".") {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
        continue
      }
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      let path = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard path.hasPrefix(prefix) else { continue }
      files.append(SourceFile(url: url, relative: String(path.dropFirst(prefix.count)), size: Int64(values.fileSize ?? 0)))
    }
    return files.sorted { $0.relative < $1.relative }
  }

  static func download(_ url: URL, timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
      do { try Files.materialize(url); return } catch is ResourceDownloadPending {
        guard ContinuousClock.now < deadline else {
          throw LibraryError.invalid("Timed out downloading \(url.lastPathComponent) from iCloud. Check your connection and run the move again.")
        }
        try await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  /// Copies under file coordination to a temporary name, verifies the copy's hash equals
  /// the source's, then moves it into place. Returns the verified hash.
  static func copyVerified(_ source: URL, to target: URL) throws -> String {
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
    defer { try? FileManager.default.removeItem(at: temporary) }
    return try Files.coordinatedRead(source) { file in
      try FileManager.default.copyItem(at: file, to: temporary)
      let expected = try Files.hash(file)
      guard try Files.hash(temporary) == expected else {
        throw LibraryError.invalid("Copy verification failed for \(source.lastPathComponent)")
      }
      if FileManager.default.fileExists(atPath: target.path) {
        // An unverified leftover from an interrupted run.
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.moveItem(at: temporary, to: target)
      return expected
    }
  }

  static func loadManifest(_ url: URL) throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      FileManager.default.createFile(atPath: url.path, contents: nil)
      return [:]
    }
    var result: [String: String] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 1)
      if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
    }
    return result
  }

  static func size(of url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }
  static func isUbiquitous(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
  }
  static func volumeAvailable(_ url: URL) -> Int64? {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe = probe.deletingLastPathComponent()
    }
    return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
  }
  static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// A small iCloud folder the iPhone/iPad capture app and Shortcut write into, so the main
/// library can live on local disk. The Mac moves each capture into the library's Inbox.
public enum CaptureInbox {
  public static let bookmarkKey = "captureInboxBookmark"

  #if os(macOS)
    public static func store(_ url: URL) throws {
      let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }
    public static func restore() -> URL? {
      guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
      else { return nil }
      if stale {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try? store(url)
      }
      return url
    }
    public static func clear() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
  #endif

  /// Moves pending captures from `captureRoot` into `library`. Files still downloading
  /// from iCloud are left for the next call. Unreadable or unsafe requests are moved to
  /// `Inbox/Rejected/` in the capture folder with a reason file. Each capture is copied into the library before
  /// its original is removed, so an interruption at any point loses nothing (a repeat run
  /// finds the request already present and just finishes removing the original).
  @discardableResult
  public static func importPending(from captureRoot: URL, into library: URL, now: Date = Date()) throws -> Int {
    let captureRoot = captureRoot.resolvingSymlinksInPath().standardizedFileURL
    let library = library.resolvingSymlinksInPath().standardizedFileURL
    guard captureRoot.path != library.path else { return 0 }
    let requestsDir = captureRoot.appendingPathComponent("Inbox/Requests")
    let inboxDir = captureRoot.appendingPathComponent("Inbox")
    guard FileManager.default.fileExists(atPath: inboxDir.path) else { return 0 }
    let sidecars = try SidecarService(root: library)
    var imported = 0
    var referenced = Set<String>()

    let requestFiles = ((try? FileManager.default.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    for url in requestFiles {
      do {
        try Files.materialize(url)
        var request = try Files.coordinatedRead(url) {
          try PortableJSON.decoder().decode(IngestionRequest.self, from: Data(contentsOf: $0))
        }
        var sourceFile: URL?
        if let input = request.inputFile {
          referenced.insert(input)
          guard input.hasPrefix("Inbox/"), !input.dropFirst(6).contains("/") else {
            throw LibraryError.invalid("Unsafe capture path")
          }
          let file = try Files.safeURL(root: captureRoot, relative: input)
          guard FileManager.default.fileExists(atPath: file.path) else { continue }  // not synced yet
          try Files.materialize(file)
          sourceFile = file
        }
        let target = library.appendingPathComponent("Inbox/Requests/\(request.id.uuidString).json")
        if !FileManager.default.fileExists(atPath: target.path) {
          if let file = sourceFile, let input = request.inputFile {
            var destination = try Files.safeURL(root: library, relative: input)
            if FileManager.default.fileExists(atPath: destination.path),
              (try? Files.hash(destination)) != (try? Files.hash(file)) {
              destination = Files.uniqueURL(destination)
              request.inputFile = "Inbox/" + destination.lastPathComponent
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
              try Files.atomicCopy(file, to: destination)
            }
          }
          if request.sourceDevice == nil { request.sourceDevice = "iCloud capture Inbox" }
          try sidecars.saveRequest(request)
        }
        try Files.permanentlyRemove(url)
        if let file = sourceFile { try Files.permanentlyRemove(file) }
        imported += 1
      } catch is ResourceDownloadPending {
        continue
      } catch {
        // A malformed or unsafe request must not block the ones after it: set it aside.
        let rejected = inboxDir.appendingPathComponent("Rejected", isDirectory: true)
        try? FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: url, to: Files.uniqueURL(rejected.appendingPathComponent(url.lastPathComponent)))
        try? Data("\(error.localizedDescription)\n".utf8)
          .write(to: rejected.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".reason.txt"))
      }
    }

    // Loose files (for example saved straight into the folder from the Files app).
    // Files named "<request UUID>-…" belong to a request that may not have synced yet;
    // they are only treated as loose after an hour.
    let loose = ((try? FileManager.default.contentsOfDirectory(
      at: inboxDir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])) ?? [])
    for file in loose {
      let name = file.lastPathComponent
      guard !name.hasPrefix("."), !referenced.contains("Inbox/" + name),
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      if name.count > 37, UUID(uuidString: String(name.prefix(36))) != nil,
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
        now.timeIntervalSince(modified) < 3600 { continue }
      do {
        try Files.materialize(file)
        let destination = Files.uniqueURL(library.appendingPathComponent("Inbox/" + Files.sanitized(name)))
        try Files.atomicCopy(file, to: destination)
        try Files.permanentlyRemove(file)
        imported += 1
      } catch is ResourceDownloadPending { continue }
    }
    return imported
  }
}
