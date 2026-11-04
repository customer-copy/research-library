import CoreML
import Foundation
import PDFKit
import Vision

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

public protocol PDFTextExtractor: Sendable {
  func extract(url: URL, itemID: UUID, resourceID: UUID) throws -> [DocumentPage]
  func identifiers(url: URL) throws -> String
  func metadataSeed(url: URL) throws -> LibraryItem?
}
extension PDFTextExtractor {
  public func metadataSeed(url: URL) throws -> LibraryItem? { nil }
}
public struct PDFExtractionService: PDFTextExtractor {
  public init() {}
  public func extract(url: URL, itemID: UUID, resourceID: UUID) throws -> [DocumentPage] {
    try Files.materialize(url)
    return try Files.coordinatedRead(url) { u in
      guard let doc = PDFDocument(url: u), doc.pageCount > 0, !doc.isLocked else {
        throw LibraryError.invalid("Invalid, empty or locked PDF")
      }
      var pages: [DocumentPage] = []
      for number in 0..<doc.pageCount {
        try Task.checkCancellation()
        guard let page = doc.page(at: number) else { continue }
        let (text, method) = try pageText(page)
        pages.append(
          DocumentPage(
            id: Files.stableID("\(resourceID):page:\(number+1):v1"), itemID: itemID,
            resourceID: resourceID, pageNumber: number + 1, text: text, method: method))
      }
      return pages
    }
  }
  private func pageText(_ page: PDFPage) throws -> (String, String) {
    var text = page.string ?? ""
    var method = "PDFKit"
    if text.filter(\.isLetter).count < 30 {
      let image = page.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
      #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
      #else
        let cgImage = image.cgImage
      #endif
      if let cg = cgImage {
        let request = VNRecognizeTextRequest()
        if VNRecognizeTextRequest.supportedRevisions.contains(VNRecognizeTextRequestRevision3) {
          request.revision = VNRecognizeTextRequestRevision3
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
          try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        } catch {
          // Retry a supported CPU device when the accelerator cannot initialize.
          let devices = try request.supportedComputeStageDevices
          var configured = false
          for (stage, choices) in devices {
            if let cpu = choices.first(where: {
              if case .cpu = $0 { return true }
              return false
            }) {
              request.setComputeDevice(cpu, for: stage)
              configured = true
            }
          }
          do {
            guard configured else { throw error }
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
          } catch {
            // The fast recognizer also works when the accurate model is unavailable.
            request.recognitionLevel = .fast
            request.revision = VNRecognizeTextRequestRevision1
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
          }
        }
        text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
          separator: "\n")
        method = "VisionOCR"
      }
    }
    return (text, method)
  }
  public func identifiers(url: URL) throws -> String {
    try Files.coordinatedRead(url) { u in
      guard let doc = PDFDocument(url: u), !doc.isLocked, doc.pageCount > 0 else {
        throw LibraryError.invalid("Invalid or locked PDF")
      }
      let attrs = doc.documentAttributes ?? [:]
      return [
        attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "",
        try (0..<min(3, doc.pageCount)).compactMap { index -> String? in
          guard let page = doc.page(at: index) else { return nil }
          return try pageText(page).0
        }.joined(separator: "\n"),
      ].joined(separator: "\n")
    }
  }
  public func metadataSeed(url: URL) throws -> LibraryItem? {
    try Files.coordinatedRead(url) { file in
      guard let doc = PDFDocument(url: file), !doc.isLocked, doc.pageCount > 0 else { return nil }
      let attributes = doc.documentAttributes ?? [:]
      let embedded = attributes[PDFDocumentAttribute.titleAttribute] as? String
      let firstPage = doc.page(at: 0)?.string ?? ""
      let line = firstPage.components(separatedBy: .newlines).first(where: {
        MetadataResolutionService.searchableTitle($0) && Identifiers.doi($0) == nil
          && !$0.lowercased().hasPrefix("abstract")
      })
      let filename = file.deletingPathExtension().lastPathComponent.replacingOccurrences(
        of: "_", with: " ")
      let title = [embedded, line, filename].compactMap { $0 }.first(
        where: MetadataResolutionService.searchableTitle)
      guard let title else { return nil }
      var item = LibraryItem(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
      item.confidence = 0.3
      item.provenance.append(Provenance("PDF", "Embedded title or first-page title candidate"))
      return item
    }
  }

}
public enum TextDerivation {
  public static func sections(_ pages: [DocumentPage]) -> [Section] {
    let known = [
      "abstract", "introduction", "methods", "materials and methods", "results", "discussion",
      "conclusion", "conclusions", "references", "supplement",
    ]
    var output: [Section] = []
    var current: Section?
    for p in pages {
      for line in p.text.components(separatedBy: .newlines) {
        let heading = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = heading.lowercased().replacingOccurrences(
          of: "^[0-9.]+\\s*", with: "", options: .regularExpression)
        if known.contains(normalized) {
          if let c = current { output.append(c) }
          let type =
            normalized.contains("methods")
            ? "methods" : normalized == "conclusions" ? "conclusion" : normalized
          current = Section(
            id: Files.stableID("\(p.resourceID):section:\(output.count):v1"), itemID: p.itemID,
            heading: heading, type: type, startPage: p.pageNumber, endPage: p.pageNumber,
            sequence: output.count, text: "")
        }
        if current == nil {
          current = Section(
            id: Files.stableID("\(p.resourceID):section:0:v1"), itemID: p.itemID,
            heading: "Document", type: "unknown", startPage: p.pageNumber, endPage: p.pageNumber,
            sequence: 0, text: "")
        }
        current?.text += line + "\n"
        current?.endPage = p.pageNumber
      }
    }
    if let c = current { output.append(c) }
    return output
  }
  public static func chunks(
    _ pages: [DocumentPage], sections: [Section] = [], wordsPerChunk: Int = 650, overlap: Int = 80
  ) -> [Chunk] {
    guard wordsPerChunk > overlap, overlap >= 0 else { return [] }
    var words: [(String, Int)] = []
    for p in pages {
      words += p.text.split(whereSeparator: \.isWhitespace).map { (String($0), p.pageNumber) }
    }
    guard let first = pages.first else { return [] }
    var output: [Chunk] = []
    var start = 0
    while start < words.count {
      let end = min(words.count, start + wordsPerChunk)
      let part = Array(words[start..<end])
      let a = part.first!.1
      let b = part.last!.1
      output.append(
        Chunk(
          id: Files.stableID("\(first.resourceID):chunk:\(output.count):v1"), itemID: first.itemID,
          resourceID: first.resourceID,
          sectionID: sections.first { $0.startPage <= a && $0.endPage >= a }?.id, startPage: a,
          endPage: b, sequence: output.count, text: part.map { $0.0 }.joined(separator: " "),
          approximateTokens: Int(Double(part.count) * 1.33)))
      if end == words.count { break }
      start = end - overlap
    }
    return output
  }
}
