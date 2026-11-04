import AppIntents
import Foundation
import UniformTypeIdentifiers

public enum LibraryAccess {
  public static var defaults: UserDefaults {
    #if os(macOS)
      return .standard
    #else
      return UserDefaults(suiteName: "group.org.researchlibrary.app") ?? .standard
    #endif
  }
  public static func store(_ url: URL) throws {
    #if os(macOS)
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
      let bookmark = try url.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
    defaults.set(bookmark, forKey: "libraryBookmark")
  }
  public static func restore() throws -> URL? {
    guard let data = defaults.data(forKey: "libraryBookmark") else { return nil }
    var stale = false
    #if os(macOS)
      let url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &stale)
    #else
      let url = try URL(
        resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    #endif
    if stale { try store(url) }
    return url
  }
  public static func capture(
    text: String?, url: URL?, file: IntentFile?, doi: String?, pmid: String?, title: String?,
    collection: String?, tags: String?, note: String?, rootOverride: URL? = nil
  ) throws -> UUID {
    guard let root = try rootOverride ?? restore() else { throw LibraryError.missingLibrary }
    let access = root.startAccessingSecurityScopedResource()
    defer { if access { root.stopAccessingSecurityScopedResource() } }
    let sidecars = try SidecarService(root: root)
    var request = IngestionRequest(source: "appIntent", text: text)
    request.inputURL = url?.absoluteString
    request.doi = doi
    request.pmid = pmid
    request.suggestedTitle = title
    request.suggestedCollection = collection
    request.suggestedTags = (tags ?? "").split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    request.note = note ?? ""
    if let file {
      let data = file.data
      var filename = Files.sanitized(file.filename)
      if data.starts(with: Data("%PDF-".utf8)), !filename.lowercased().hasSuffix(".pdf") {
        filename += ".pdf"
      }
      request.suggestedTitle =
        title ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
      request.titleIsFilename = title == nil
      let target = root.appendingPathComponent("Inbox/\(request.id)-" + filename)
      try Files.atomicWrite(data, to: target)
      request.inputFile = "Inbox/" + target.lastPathComponent
    }
    guard
      request.inputText?.isEmpty == false || request.inputURL != nil || request.inputFile != nil
        || request.doi?.isEmpty == false || request.pmid?.isEmpty == false
        || request.suggestedTitle?.isEmpty == false
    else { throw LibraryError.invalid("Provide a URL, PDF, DOI, PMID, or text.") }
    try sidecars.saveRequest(request)
    return request.id
  }
}
public struct AddToResearchLibraryIntent: AppIntent {
  public static var title: LocalizedStringResource = "Add to Research Library"
  public static var description = IntentDescription(
    "Save a URL, DOI, PMID, text, or PDF to your portable library Inbox. Processing happens on the Mac."
  )
  public static var openAppWhenRun = false
  var rootOverride: URL?
  @Parameter(title: "URL") public var url: URL?
  @Parameter(title: "File") public var file: IntentFile?
  @Parameter(title: "Text") public var text: String?
  @Parameter(title: "DOI") public var doi: String?
  @Parameter(title: "PMID") public var pmid: String?
  @Parameter(title: "Title") public var itemTitle: String?
  @Parameter(title: "Collection") public var collection: String?
  @Parameter(title: "Tags (comma separated)") public var tags: String?
  @Parameter(title: "Note") public var note: String?
  public init() {}
  public func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try LibraryAccess.capture(
      text: text, url: url, file: file, doi: doi, pmid: pmid, title: itemTitle,
      collection: collection, tags: tags, note: note, rootOverride: rootOverride)
    return .result(dialog: "Saved to Research Library Inbox.")
  }
}
public struct LibraryItemEntity: AppEntity {
  public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Library Item")
  public static var defaultQuery = LibraryEntityQuery()
  public var id: UUID
  public var title: String
  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }
  public init(id: UUID, title: String) {
    self.id = id
    self.title = title
  }
}
public struct LibraryEntityQuery: EntityStringQuery {
  public init() {}
  public func entities(for identifiers: [UUID]) async throws -> [LibraryItemEntity] {
    guard let root = try LibraryAccess.restore() else { return [] }
    let access = root.startAccessingSecurityScopedResource()
    defer { if access { root.stopAccessingSecurityScopedResource() } }
    let sidecars = try SidecarService(root: root)
    return try identifiers.compactMap { id in
      let url = sidecars.url(id)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let item = try sidecars.read(url)
      return LibraryItemEntity(id: item.id, title: item.title)
    }
  }
  public func entities(matching string: String) async throws -> [LibraryItemEntity] {
    try await load(query: string)
  }
  public func suggestedEntities() async throws -> [LibraryItemEntity] { try await load(query: "") }
  private func load(query: String) async throws -> [LibraryItemEntity] {
    guard let root = try LibraryAccess.restore() else { return [] }
    let access = root.startAccessingSecurityScopedResource()
    defer { if access { root.stopAccessingSecurityScopedResource() } }
    let library = try LibraryService(root: root)
    try await library.synchronizeSidecars()
    return try await library.search(query, limit: 100).map {
      LibraryItemEntity(id: $0.item.id, title: $0.item.title)
    }
  }
}

public struct ResearchLibraryIntentPackage: AppIntentsPackage {}

@available(macOS 15.0, iOS 18.0, *)
extension LibraryItemEntity: IndexedEntity {}

// SyncableEntity ships with the macOS/iOS 27 SDKs (Swift 6.4 / Xcode 27).
// Guarded so the package still builds on CI runners with older Xcode.
#if compiler(>=6.4)
@available(macOS 27.0, iOS 27.0, *)
extension LibraryItemEntity: SyncableEntity {}
#endif
