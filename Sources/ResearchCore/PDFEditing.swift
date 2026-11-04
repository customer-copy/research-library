import Foundation
import PDFKit
import CryptoKit

public struct PDFReadSnapshot: Sendable {
  public let data: Data
  public let sha256: String
}
public protocol PDFSnapshotLoader: Sendable {
  func read(_ url: URL) throws -> PDFReadSnapshot
}
public struct NativePDFSnapshotLoader: PDFSnapshotLoader {
  public init() {}
  public func read(_ url: URL) throws -> PDFReadSnapshot { try PDFEditing.read(url) }
}
public enum PDFEditing {
  public static func read(_ url: URL) throws -> PDFReadSnapshot {
    try Files.materialize(url)
    return try Files.coordinatedRead(url) { file in
      let data = try Data(contentsOf: file)
      guard data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data),
        !pdf.isLocked, pdf.pageCount > 0 else {
        throw LibraryError.invalid("This attachment is not a readable, unlocked PDF")
      }
      return PDFReadSnapshot(data: data,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
  }
  public static func save(_ data: Data, to url: URL, expectedHash: String, recovery: URL) throws
    -> String
  {
    guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
      throw LibraryError.invalid("Cannot save an invalid or locked PDF")
    }
    let replacementHash = Files.digest(data)
    var error: NSError?
    var result: Result<String, Error>?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) {
      file in
      result = Result {
        let backup = recovery.appendingPathComponent(expectedHash + ".pdf")
        let currentHash = try Files.hash(file)
        if currentHash != expectedHash {
          // The bytes may have committed before a metadata write failed or the app stopped.
          // Retry only the identical save, backed by the verified pre-edit original.
          if currentHash == replacementHash, FileManager.default.fileExists(atPath: backup.path),
            try Files.hash(backup) == expectedHash { return currentHash }
          throw LibraryError.conflict(
            "This PDF changed outside the reader. Reload it before making more highlights.")
        }
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: backup.path) {
          try Data(contentsOf: file).write(to: backup, options: .atomic)
        }
        guard try Files.hash(backup) == expectedHash else {
          throw LibraryError.invalid("PDF recovery copy could not be verified")
        }
        try data.write(to: file, options: .atomic)
        return try Files.hash(file)
      }
    }
    if let error { throw error }
    guard let result else { throw LibraryError.invalid("PDF file coordination failed") }
    return try result.get()
  }
}

public struct ReaderPosition: Codable, Equatable, Sendable {
  public var page = 1
  public var scale = 1.0
  public var zoomMode = "width"
  public var sidebar = "pages"
  public var sidebarVisible = true
  public init() {}
}
