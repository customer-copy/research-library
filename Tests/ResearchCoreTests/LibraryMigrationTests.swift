import Foundation
import Testing
@testable import ResearchCore

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

@Suite struct LibraryMigrationTests {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent("Migration-" + UUID().uuidString)
  var source: URL { base.appendingPathComponent("iCloud Library") }
  var destination: URL { base.appendingPathComponent("Local Library") }

  /// A small library: one item with a PDF, a recovery copy, a nested metadata file,
  /// and hidden temporary files that must not be copied.
  func makeSource(recordedHash: String? = nil) throws -> (item: LibraryItem, pdf: Data) {
    let sidecars = try SidecarService(root: source)
    let pdf = Data("%PDF-1.7 fixture \(UUID())".utf8)
    try pdf.write(to: source.appendingPathComponent("PDFs/2021 - Lovelace - Engines.pdf"))
    var item = LibraryItem(title: "Engines")
    var resource = Resource(itemID: item.id, type: .pdf, path: "PDFs/2021 - Lovelace - Engines.pdf", availability: .local)
    let actualHash = try Files.hash(source.appendingPathComponent("PDFs/2021 - Lovelace - Engines.pdf"))
    resource.sha256 = recordedHash ?? actualHash
    item.resources = [resource]
    try sidecars.save(item)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Metadata/OpenAlex"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: source.appendingPathComponent("Metadata/OpenAlex/dashboard.json"))
    try Data("old".utf8).write(to: source.appendingPathComponent("Recovery/old.json"))
    try Data("x".utf8).write(to: source.appendingPathComponent("Inbox/.upload.partial"))
    try Data("x".utf8).write(to: source.appendingPathComponent(".DS_Store"))
    return (item, pdf)
  }

  @Test func copiesEveryFileVerifiedAndLeavesSourceUntouched() async throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let (item, pdf) = try makeSource()
    let before = try LibraryMigration.enumerateFiles(source).map(\.relative)
    let report = try await LibraryMigration.copyLibrary(from: source, to: destination, reserveBytes: 0)
    #expect(report.isComplete)
    #expect(report.filesCopied == before.count)
    #expect(report.preexistingHashDifferences.isEmpty)
    #expect(report.attachmentsChecked == 1)
    #expect(try Data(contentsOf: destination.appendingPathComponent("PDFs/2021 - Lovelace - Engines.pdf")) == pdf)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Metadata/OpenAlex/dashboard.json").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Inbox/.upload.partial").path))
    #expect(try SidecarService(root: destination).read(destination.appendingPathComponent("Metadata/\(item.id.uuidString).json")).title == "Engines")
    // Source is unchanged.
    #expect(try LibraryMigration.enumerateFiles(source).map(\.relative) == before)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("Inbox/.upload.partial").path))
  }

  @Test func lowDiskSpaceStopsSafelyAndRerunResumes() async throws {
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try makeSource()
    let total = try LibraryMigration.enumerateFiles(source).count
    let calls = Counter()
    await #expect(throws: LibraryError.self) {
      _ = try await LibraryMigration.copyLibrary(from: source, to: destination, reserveBytes: 1_000,
        availableBytes: { _ in calls.next() <= 2 ? 1_000_000 : 10 })
    }
    let resumed = try await LibraryMigration.copyLibrary(from: source, to: destination, reserveBytes: 0)
    #expect(resumed.isComplete)
    #expect(resumed.filesAlreadyCopied == 2)
    #expect(resumed.filesCopied == total - 2)
  }

  @Test func refusesUnsafeDestinations() async throws {
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try makeSource()
    await #expect(throws: LibraryError.self) {
      _ = try await LibraryMigration.copyLibrary(from: source, to: source.appendingPathComponent("Nested"))
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: destination.appendingPathComponent("unrelated.txt"))
    await #expect(throws: LibraryError.self) {
      _ = try await LibraryMigration.copyLibrary(from: source, to: destination, reserveBytes: 0)
    }
    #expect(try Data(contentsOf: destination.appendingPathComponent("unrelated.txt")) == Data("mine".utf8))
  }

  @Test func preexistingChecksumDifferencesAreReportedNotBlocking() async throws {
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try makeSource(recordedHash: "0000")
    let report = try await LibraryMigration.copyLibrary(from: source, to: destination, reserveBytes: 0)
    #expect(report.isComplete)
    #expect(report.preexistingHashDifferences == ["PDFs/2021 - Lovelace - Engines.pdf"])
  }

  // MARK: iPhone capture Inbox

  @Test func captureInboxMovesRequestsAndFilesIntoLibrary() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let inbox = base.appendingPathComponent("Capture Inbox")
    let library = base.appendingPathComponent("Library")
    let capture = try SidecarService(root: inbox)
    var request = IngestionRequest(source: "iOS", text: nil)
    let fileName = "\(request.id)-paper.pdf"
    try Data("%PDF-1.7 phone".utf8).write(to: inbox.appendingPathComponent("Inbox/" + fileName))
    request.inputFile = "Inbox/" + fileName
    try capture.saveRequest(request)
    let urlOnly = IngestionRequest(source: "iOS", text: "https://doi.org/10.1000/xyz")
    try capture.saveRequest(urlOnly)
    try Data("%PDF-1.7 loose".utf8).write(to: inbox.appendingPathComponent("Inbox/loose.pdf"))

    #expect(try CaptureInbox.importPending(from: inbox, into: library) == 3)
    let moved = try SidecarService(root: library).requests()
    #expect(Set(moved.map(\.id)) == [request.id, urlOnly.id])
    #expect(try Data(contentsOf: library.appendingPathComponent("Inbox/" + fileName)) == Data("%PDF-1.7 phone".utf8))
    #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("Inbox/loose.pdf").path))
    #expect(try capture.requests().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Inbox/" + fileName).path))
    // Nothing left: a second pass is a no-op.
    #expect(try CaptureInbox.importPending(from: inbox, into: library) == 0)
  }

  @Test func captureFileWaitsForItsRequestToSync() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let inbox = base.appendingPathComponent("Capture Inbox")
    let library = base.appendingPathComponent("Library")
    _ = try SidecarService(root: inbox)
    let early = inbox.appendingPathComponent("Inbox/\(UUID())-early.pdf")
    try Data("%PDF".utf8).write(to: early)
    #expect(try CaptureInbox.importPending(from: inbox, into: library) == 0)
    #expect(FileManager.default.fileExists(atPath: early.path))
    // After an hour with no request, it is collected as a loose file.
    #expect(try CaptureInbox.importPending(from: inbox, into: library, now: Date().addingTimeInterval(7200)) == 1)
  }

  @Test func captureRequestWithUnsafePathIsRejected() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let inbox = base.appendingPathComponent("Capture Inbox")
    let library = base.appendingPathComponent("Library")
    var request = IngestionRequest(source: "iOS", text: nil)
    request.inputFile = "Inbox/../../escape.pdf"
    try SidecarService(root: inbox).saveRequest(request)
    let good = IngestionRequest(source: "iOS", text: "10.1000/fine")
    try SidecarService(root: inbox).saveRequest(good)
    #expect(try CaptureInbox.importPending(from: inbox, into: library) == 1)
    #expect(try SidecarService(root: library).requests().map(\.id) == [good.id])
    #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("Inbox/Rejected/\(request.id.uuidString).json").path))
  }
}

extension LibraryMigrationTests {
  @Test func filesArrivingDuringTheCopyAreIncluded() async throws {
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try makeSource()
    let late = source.appendingPathComponent("Inbox/arrived-during-move.pdf")
    let calls = Counter()
    let report = try await LibraryMigration.copyLibrary(from: source, to: destination, reserveBytes: 0,
      availableBytes: { _ in
        // Simulate a capture landing in the old Inbox partway through the copy.
        if calls.next() == 2 { try? Data("%PDF late".utf8).write(to: late) }
        return 1 << 40
      })
    #expect(report.isComplete)
    #expect(try Data(contentsOf: destination.appendingPathComponent("Inbox/arrived-during-move.pdf")) == Data("%PDF late".utf8))
  }
}

extension LibraryMigrationTests {
  @Test func otherIndexFoldersExcludeCurrentLibraryAndCaches() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let support = base.appendingPathComponent("Support")
    let current = LibraryService.indexFolder(for: destination, support: support)
    let old = LibraryService.indexFolder(for: source, support: support)
    for folder in [current, old, support.appendingPathComponent("ResearchLibrary/Thumbnails")] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(count: 10).write(to: folder.appendingPathComponent("index.sqlite"))
    }
    let stale = LibraryService.otherIndexFolders(keeping: destination, support: support)
    #expect(stale.map(\.url.standardizedFileURL.path) == [old.standardizedFileURL.path])
    #expect(stale.first?.bytes == 10)
  }
}
