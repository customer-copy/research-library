import AppIntents
import AppKit
import CoreSpotlight
import PDFKit
import ResearchCore
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor final class LibraryModel: ObservableObject {
  static let shared = LibraryModel()
  @Published var results: [RetrievalResult] = []
  @Published var selection: String?
  @Published var query = ""
  @Published var scope = "Overview"
  @Published var tags: [String] = []
  @Published var collections: [String] = []
  @Published var requests: [IngestionRequest] = []
  @Published var message: String?
  @Published var busy = false
  @Published var root: URL?
  @Published var showCapture = false
  @Published var editor: ResearchCore.LibraryItem?
  @Published var permanentDeletion: ResearchCore.LibraryItem?
  @Published var issues: [IntegrityIssue] = []
  @Published var showIssues = false
  @Published var canLoadMore = false
  @Published var isSearching = false
  @Published var searchingPDFText = false
  @Published var sort = "Relevance"
  @Published var input = ""
  @Published var captureCollection = ""
  @Published var captureTags = ""
  @Published var captureNote = ""
  var library: LibraryService?
  var worker: Task<Void, Never>?
  var processor: Task<Void, Never>?
  var searchTask: Task<Void, Never>?
  private var searchGeneration = 0
  private var organizationTask: Task<Void, Never>?
  var accessing = false
  @Published var locatingPDFs = Set<UUID>()
  @Published var pdfLookupMessages: [UUID: String] = [:]
  var currentPDFRequest = UUID()
  private var suppressedSelectionItem: UUID?
  func suppressSelectionOpening(_ id: UUID) { suppressedSelectionItem = id }
  var handledLaunchImport = false
  var handledArchiveImport = false
  var pendingBrowserCaptures: [URL] = []
  @Published var browserCaptureStatus: String?
  @Published var browserCaptureSequence = 0
  @Published var dashboardItems: [ResearchCore.LibraryItem] = []
  @Published var dashboardSnapshot = OpenAlexDashboardSnapshot()
  @Published var dashboardSummary = DashboardSummary()
  @Published var dashboardBusy = false
  @Published var dashboardStatus: String?
  private var dashboardTask: Task<Void, Never>?
  var selected: RetrievalResult? { results.first { $0.id == selection } }
  var pendingCaptureCount: Int {
    requests.filter { $0.state != .complete && $0.state != .failed && $0.state != .awaitingReview }
      .count
  }
  init() {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment["RESEARCH_LIBRARY_TEST_ROOT"] {
        open(URL(fileURLWithPath: path, isDirectory: true))
        return
      }
    #endif
    do { if let url = try LibraryAccess.restore() { open(url) } } catch {
      message = error.localizedDescription
    }
  }
  func importLaunchBibliography() async {
    guard !handledLaunchImport else { return }
    handledLaunchImport = true
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--import-bibliography"), index + 1 < arguments.count else { return }
    var report: [String: Any] = [:]
    busy = true
    defer { busy = false }
    do {
      guard let library else { throw LibraryError.invalid("Choose a library folder before importing.") }
      let resume = arguments.contains("--resume-import")
      if !resume { try await library.synchronizeSidecars() }
      report["before"] = try await library.libraryCounts()
      if resume {
        guard let reportIndex = arguments.firstIndex(of: "--import-report"), reportIndex + 1 < arguments.count else {
          throw LibraryError.invalid("A report path is required for a resumed import backup.")
        }
        let backup = URL(fileURLWithPath: arguments[reportIndex + 1]).deletingLastPathComponent()
          .appendingPathComponent("Library before resumed import-\(Int(Date().timeIntervalSince1970)).json")
        try await library.exportCachedSnapshot(to: backup)
        report["backup"] = backup.path
        report["backupSource"] = "Last synchronized local index"
      } else {
        let deadline = Date().addingTimeInterval(300)
        while true {
        do { report["backup"] = try await library.export(format: .json).path; break }
        catch is ResourceDownloadPending {
          guard Date() < deadline else { throw LibraryError.invalid("Existing library metadata is still downloading from iCloud. Retry the import when the download finishes.") }
          try await Task.sleep(for: .seconds(1))
        }
        }
      }
      report["importedReferences"] = try await library.importRecords(URL(fileURLWithPath: arguments[index + 1]), resume: resume)
      report["after"] = try await library.libraryCounts()
      report["success"] = true
      refresh()
    } catch { report["success"] = false; report["error"] = error.localizedDescription; message = error.localizedDescription }
    if let index = arguments.firstIndex(of: "--import-report"), index + 1 < arguments.count,
      let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
    }
  }
  func processLaunchArchives() async {
    guard !handledArchiveImport else { return }
    handledArchiveImport = true
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("--process-inbox-zips") else { return }
    var output: [String: Any] = [:]
    busy = true
    defer { busy = false }
    do {
      guard let library else { throw LibraryError.invalid("Choose a library folder before processing ZIPs.") }
      let report = try await library.processInboxArchives()
      output = try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(report)) as? [String: Any] ?? [:]
      output["success"] = true
      refresh()
    } catch {
      output["success"] = false; output["error"] = error.localizedDescription; message = error.localizedDescription
    }
    if let index = arguments.firstIndex(of: "--zip-report"), index + 1 < arguments.count,
      let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
    }
  }
  func chooseLibrary() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.message = "Choose a Research Library folder in iCloud Drive or another location."
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try LibraryAccess.store(url)
        open(url)
      } catch { message = error.localizedDescription }
    }
  }
  func open(_ url: URL) {
    worker?.cancel()
    processor?.cancel()
    searchTask?.cancel()
    dashboardTask?.cancel()
    organizationTask?.cancel()
    if accessing { root?.stopAccessingSecurityScopedResource() }
    accessing = url.startAccessingSecurityScopedResource()
    root = url
    do {
      let service = try LibraryService(root: url)
      library = service
      let pendingCaptures = pendingBrowserCaptures
      pendingBrowserCaptures.removeAll()
      for capture in pendingCaptures { receiveBrowserCapture(capture) }
      worker = Task { [weak self] in
        if ProcessInfo.processInfo.arguments.contains("--diagnose-pdf") { return }
        let launchImport = ProcessInfo.processInfo.arguments.contains("--import-bibliography")
        let launchArchives = ProcessInfo.processInfo.arguments.contains("--process-inbox-zips")
        if launchImport || launchArchives {
          while (launchImport && self?.handledLaunchImport == false)
            || (launchArchives && self?.handledArchiveImport == false) || self?.busy == true {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(250))
          }
        }
        do {
          try await service.prepareCachedLibrary()
          self?.refresh()
          self?.refreshDashboard()
          self?.refreshOrganization()
          try await service.synchronizeSidecars()
          self?.refresh()
        } catch is CancellationError { return }
        catch { self?.message = error.localizedDescription }
        var lastGeneration = -1
        while !Task.isCancelled {
          do {
            await service.consumePendingChromeCaptures()
            try await service.pollInbox()
            try await service.synchronizeSidecars()
            if !(await service.isProcessing()) {
              self?.processor = Task { await service.processPending() }
            }
            await service.indexPendingAttachments(limit: 3)
            self?.requests = try await service.requests()
            let generation = await service.generation()
            if generation != lastGeneration {
              lastGeneration = generation
              self?.refresh()
              self?.refreshOrganization()
            }
          } catch is CancellationError { return }
          catch { self?.message = error.localizedDescription }
          try? await Task.sleep(for: .seconds(4))
        }
      }
    } catch { message = error.localizedDescription }
  }
  func refreshDashboard(forceOpenAlex: Bool = false) {
    dashboardTask?.cancel()
    guard let library, let root else { return }
    dashboardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let cacheURL = root.appendingPathComponent("Metadata/OpenAlex/dashboard.json")
        if let data = try? Files.coordinatedRead(cacheURL, { try Data(contentsOf: $0) }),
           let cached = try? PortableJSON.decoder().decode(OpenAlexDashboardSnapshot.self, from: data) {
          self.dashboardSnapshot = cached
          self.dashboardSummary = cached.summary ?? DashboardSummary(counts: cached.localCounts)
        }
        let items = try await library.dashboardItems()
        guard !Task.isCancelled else { return }
        self.dashboardItems = items
        let summary = Self.makeDashboardSummary(items)
        self.dashboardSummary = summary
        let counts = summary.counts
        let shouldFetchFeed = forceOpenAlex || self.dashboardSnapshot.feed.isEmpty || Date().timeIntervalSince(self.dashboardSnapshot.generatedAt) > 86_400
        guard shouldFetchFeed, let apiKey = OpenAlexCredentialStore.read(), !apiKey.isEmpty else {
          self.dashboardStatus = OpenAlexCredentialStore.read() == nil ? "Connect OpenAlex in Settings for publication recommendations." : "Showing cached OpenAlex data."
          var snapshot = self.dashboardSnapshot
          snapshot.localCounts = counts; snapshot.summary = summary
          try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? PortableJSON.encoder().encode(snapshot).write(to: cacheURL, options: .atomic)
          return
        }
        self.dashboardBusy = true
        self.dashboardStatus = "Updating publication feed…"
        defer { self.dashboardBusy = false }
        let keywords = items.flatMap { $0.keywords ?? [] }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let search = keywords.sorted { $0.value > $1.value }.prefix(3).map(\.key).joined(separator: " ")
        let from = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90 * 86_400)).prefix(10)
        let feed = try await OpenAlexClient(apiKey: apiKey).recentWorks(search: search.isEmpty ? nil : search, from: String(from), limit: 24)
        guard !Task.isCancelled else { return }
        self.dashboardSnapshot = OpenAlexDashboardSnapshot(generatedAt: Date(), syncedCount: self.dashboardSnapshot.syncedCount, matchedCount: self.dashboardSnapshot.matchedCount, feed: feed, matched: self.dashboardSnapshot.matched, localCounts: counts, summary: summary)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PortableJSON.encoder().encode(self.dashboardSnapshot).write(to: cacheURL, options: .atomic)
        self.dashboardStatus = "Updated \(feed.count) recommendations from OpenAlex."
      } catch is CancellationError {} catch { self.dashboardStatus = "OpenAlex update failed: \(error.localizedDescription)" }
    }
  }
  func syncOpenAlexMetadata() {
    guard let library, let root, let key = OpenAlexCredentialStore.read(), !key.isEmpty else {
      message = "Add an OpenAlex API key in Settings before syncing metadata."; return
    }
    dashboardTask?.cancel(); dashboardBusy = true; dashboardStatus = "Syncing OpenAlex metadata…"
    dashboardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let items = try await library.dashboardItems()
        var matched: [OpenAlexWorkRecord] = []
        var failed = 0, consecutiveFailures = 0, updated = 0
        var lastError: Error?
        let client = OpenAlexClient(apiKey: key)
        for (index, item) in items.enumerated() {
          try Task.checkCancellation()
          // One bad record must not stop the whole sync. Repeated consecutive failures
          // (offline, invalid key, provider outage) do stop it, so it doesn't grind on.
          do {
            if let record = try await client.work(for: item) {
              if try await library.mergeOpenAlex(record, into: item.id) { updated += 1 }
              matched.append(record)
            }
            consecutiveFailures = 0
          } catch is CancellationError { throw CancellationError() }
          catch {
            failed += 1; consecutiveFailures += 1; lastError = error
            if consecutiveFailures >= 5 {
              throw LibraryError.invalid("Stopped after 5 failures in a row (\(error.localizedDescription)). \(matched.count) matched so far.")
            }
          }
          if index % 10 == 0 { dashboardStatus = "Syncing metadata… \(index)/\(items.count)" }
        }
        let summary = Self.makeDashboardSummary(items)
        let snapshot = OpenAlexDashboardSnapshot(generatedAt: Date(), syncedCount: items.filter { $0.doi != nil }.count, matchedCount: matched.count, feed: dashboardSnapshot.feed, matched: matched, localCounts: summary.counts, summary: summary)
        let url = root.appendingPathComponent("Metadata/OpenAlex/dashboard.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PortableJSON.encoder().encode(snapshot).write(to: url, options: .atomic)
        dashboardSnapshot = snapshot; dashboardSummary = summary; dashboardItems = try await library.dashboardItems(); dashboardStatus = "Synced \(matched.count) OpenAlex records (\(updated) updated)."
          + (failed > 0 ? " \(failed) could not be checked\(lastError.map { ": " + $0.localizedDescription } ?? "")." : "")
      } catch is CancellationError { dashboardStatus = "OpenAlex sync paused." }
      catch { dashboardStatus = "OpenAlex sync failed: \(error.localizedDescription)" }
      dashboardBusy = false
    }
  }
  private static func makeDashboardSummary(_ items: [ResearchCore.LibraryItem]) -> DashboardSummary {
    let counts = ["total": items.count, "unread": items.filter { !$0.read }.count,
      "withPDF": items.filter(\.hasPDF).count, "favorites": items.filter(\.favorite).count]
    let queue = items.filter { !$0.read }.prefix(6).map {
      DashboardReadingItem(id: $0.id, title: $0.title, journal: $0.journal, year: $0.year)
    }
    let topics = items.flatMap { $0.keywords ?? [] }.reduce(into: [String: Int]()) {
      $0[$1, default: 0] += 1
    }.sorted { $0.value > $1.value }.prefix(12).map { DashboardTopic(name: $0.key, count: $0.value) }
    return DashboardSummary(counts: counts, continueReading: Array(queue), topics: topics)
  }
  func openDashboardItem(_ id: UUID) {
    guard let library else { return }
    Task {
      if let item = try? await library.item(id) { openPDF(item) }
    }
  }
  func refreshOrganization() {
    organizationTask?.cancel()
    guard let library else { return }
    organizationTask = Task {
      do {
        let organization = try await library.organization()
        guard !Task.isCancelled else { return }
        tags = organization.tags
        collections = organization.collections
      } catch is CancellationError {} catch { message = error.localizedDescription }
    }
  }
  func refresh(append: Bool = false, debounce: Bool = false) {
    searchTask?.cancel()
    searchGeneration += 1
    let generation = searchGeneration
    guard let library else { return }
    let query = query
    var f = SearchFilters()
    switch sort {
    case "Title": f.sort = .title
    case "Year": f.sort = .year
    case "Newest": f.sort = .publicationDate
    case "Recently added": f.sort = .dateAdded
    default: f.sort = .relevance
    }
    switch scope {
    case "Favorites": f.favorite = true
    case "Unread": f.read = false
    case "PDF Available": f.hasPDF = true
    case "PDF Unavailable": f.hasPDF = false
    case "Needs Review": f.needsReview = true
    case "Recently Added": f.recentlyAdded = true
    default:
      if scope.hasPrefix("tag:") { f.tag = String(scope.dropFirst(4)) }
      if scope.hasPrefix("collection:") { f.collection = String(scope.dropFirst(11)) }
    }
    let offset = append ? results.count : 0
    let limit = 100
    isSearching = true
    searchingPDFText = false
    canLoadMore = false
    searchTask = Task {
      defer {
        if generation == searchGeneration { isSearching = false; searchingPDFText = false }
      }
      do {
        if debounce { try await Task.sleep(for: .milliseconds(180)) }
        try Task.checkCancellation()
        // A metadata preview gives quick feedback; custom sorts wait for the final global order.
        if !append && f.sort == .relevance && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let preview = try await library.searchMetadata(query, filters: f, limit: limit)
          guard !Task.isCancelled && generation == searchGeneration else { return }
          results = preview
          if preview.count == limit { canLoadMore = true; return }
          searchingPDFText = true
        }
        let values = try await library.search(query, filters: f, limit: limit, offset: offset)
        guard !Task.isCancelled && generation == searchGeneration else { return }
        if append {
          let existing = Set(results.map { $0.item.id })
          results += values.filter { !existing.contains($0.item.id) }
        } else { results = values }
        canLoadMore = values.count == limit
      } catch is CancellationError {} catch {
        guard generation == searchGeneration else { return }
        message = error.localizedDescription
      }
    }
  }
  func importPDF(attach: UUID? = nil) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = attach == nil
    if panel.runModal() == .OK {
      let urls = panel.urls
      run { service in
        for url in urls { _ = try await service.captureFile(url, attachTo: attach) }
        await service.processPending()
      }
    }
  }
  func attachSupplement(_ id: UUID) {
    let panel = NSOpenPanel()
    if panel.runModal() == .OK, let url = panel.url {
      run { try await $0.attachSupplement(url, to: id) }
    }
  }
  func drop(_ urls: [URL]) {
    run { service in
      for url in urls {
        if url.isFileURL {
          _ = try await service.captureFile(url)
        } else {
          var r = IngestionRequest(source: "dragDrop")
          r.inputURL = url.absoluteString
          try await service.submit(r)
        }
      }
      await service.processPending()
    }
  }
  func capture() {
    let value = input
    let col = captureCollection
    let tags = captureTags
    let note = captureNote
    run { service in
      var r = IngestionRequest(source: "pasted", text: value)
      r.suggestedCollection = col.isEmpty ? nil : col
      r.suggestedTags = tags.split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
      r.note = note
      try await service.submit(r)
      await service.processPending()
    }
    showCapture = false
    input = ""
    captureNote = ""
  }
  func run(_ operation: @escaping @Sendable (LibraryService) async throws -> Void) {
    guard let library else {
      message = "Choose a library folder first."
      return
    }
    busy = true
    Task {
      do {
        try await operation(library)
        requests = try await library.requests()
        refresh()
      } catch { message = error.localizedDescription }
      busy = false
    }
  }
  func refreshInbox() {
    run { service in
      try await service.pollInbox()
      // Recheck file stability without blocking the UI or importing an unfinished copy.
      try await Task.sleep(for: .seconds(2.2))
      try await service.pollInbox()
      try await service.synchronizeSidecars()
      await service.processPending()
    }
  }
  func receiveBrowserCapture(_ url: URL) {
    if url.host == "chrome-capture" {
      do { _ = try BrowserCapture.chromeID(from: url) }
      catch { message = error.localizedDescription; return }
      guard let library else { pendingBrowserCaptures.append(url); chooseLibrary(); return }
      Task {
        do {
          let started = ContinuousClock.now
          let id = try BrowserCapture.chromeID(from: url)
          let item = try await library.consumeChromeCapture(id)
          browserCaptureStatus = item.hasPDF ? "PDF saved from Chrome"
            : item.pdfLookup?.status == .retry ? "Article added; PDF download needs attention" : "Article added; downloading PDF…"
          // Show the new capture immediately, even when the dashboard or a filter was selected.
          scope = "Recently Added"; query = ""
          suppressSelectionOpening(item.id)
          results.removeAll { $0.item.id == item.id }
          results.insert(RetrievalResult(item: item), at: 0)
          selection = item.id.uuidString
          browserCaptureSequence += 1
          refresh()
          let arguments = ProcessInfo.processInfo.arguments
          if let index = arguments.firstIndex(of: "--browser-capture-report"), index + 1 < arguments.count {
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let report: [String: Any] = ["queued": true, "itemID": item.id.uuidString, "hasPDF": item.hasPDF,
              "title": item.title, "authors": item.orderedAuthors.count, "seconds": seconds]
            try JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
          }
        } catch { message = "Chrome capture could not be saved: " + error.localizedDescription }
      }
      return
    }
    do { _ = try BrowserCapture.request(from: url) }
    catch { message = error.localizedDescription; return }
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--browser-capture-report"), index + 1 < arguments.count {
      try? JSONSerialization.data(withJSONObject: ["received": true, "queued": false])
        .write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
    }
    guard let library else {
      pendingBrowserCaptures.append(url)
      chooseLibrary()
      return
    }
    Task {
      do {
        _ = try await library.submitBrowserCapture(url)
        browserCaptureStatus = "Safari capture added to Inbox"
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--browser-capture-report"), index + 1 < arguments.count {
          let request = try BrowserCapture.request(from: url)
          let output: [String: Any] = ["queued": true, "root": root?.path ?? "",
            "request": try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(request))]
          try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
        }
        requests = try await library.requests()
        // The regular worker handles in-flight captures. A newly opened app can begin now.
        await library.processPending()
        refresh()
      } catch { message = "Safari capture could not be saved: " + error.localizedDescription }
    }
  }
  func save(_ item: ResearchCore.LibraryItem) {
    run { try await $0.edit(item) }
    editor = nil
  }
  func toggleFavorite(_ item: ResearchCore.LibraryItem) {
    var item = item
    item.favorite.toggle()
    save(item)
  }
  func toggleRead(_ item: ResearchCore.LibraryItem) {
    var item = item
    item.read.toggle()
    save(item)
  }
  func permanentlyDelete(_ item: ResearchCore.LibraryItem) {
    guard let library else { return }
    busy = true
    Task {
      defer { busy = false }
      await ReaderWorkspace.shared.discardForDeletion(item.id)
      do {
        try await library.permanentlyRemove(item.id)
        results.removeAll { $0.item.id == item.id }
        if editor?.id == item.id { editor = nil }
        selection = nil
        refresh()
      } catch {
        ReaderWorkspace.shared.deletionFailed(item.id)
        message = "Permanent deletion could not finish: " + error.localizedDescription
      }
    }
  }
  func openPDF(
    _ item: ResearchCore.LibraryItem, resourceID: UUID? = nil, page: Int? = nil,
    inNewTab: Bool = false, retry: Bool = false
  ) {
    guard let root, let library else { return }
    let request = UUID()
    if !inNewTab {
      currentPDFRequest = request
      ReaderWorkspace.shared.prepareForLookup()
    }
    let readerGeneration = ReaderWorkspace.shared.selectionGeneration
    let hasLocal = item.resources.contains { $0.type == .pdf && $0.relativePath != nil }
    if !inNewTab && (!hasLocal || ReaderWorkspace.shared.selected?.itemID != item.id) {
      ReaderWorkspace.shared.isPresented = false
    }
    locatingPDFs.insert(item.id)
    Task {
      defer { locatingPDFs.remove(item.id) }
      do {
        let resolved = try await library.resolvePDF(item.id, retry: retry)
        pdfLookupMessages[item.id] = resolved.pdfLookup?.detail
        refresh()
        guard inNewTab || (currentPDFRequest == request
          && ReaderWorkspace.shared.selectionGeneration == readerGeneration) else { return }
        let r = resolved.resources.first(where: {
          $0.type == .pdf && $0.relativePath != nil && $0.availability == .local
            && (resourceID == nil || $0.id == resourceID)
        }) ?? resolved.resources.first(where: { $0.type == .pdf && $0.relativePath != nil && $0.availability == .local })
        guard let r, let path = r.relativePath, r.availability == .local else { return }
        let url = try Files.safeURL(root: root, relative: path)
        try await ReaderWorkspace.shared.open(
          url: url, title: resolved.title, itemID: item.id, resourceID: r.id,
          root: root, library: library, initialPage: page, inNewTab: inNewTab)
      } catch is CancellationError { return }
      catch {
        pdfLookupMessages[item.id] = error.localizedDescription
        if !inNewTab && currentPDFRequest == request { ReaderWorkspace.shared.isPresented = false }
      }
    }
  }

  func readSelection() {
    guard let result = selected else { currentPDFRequest = UUID(); return }
    let suppressed = suppressedSelectionItem
    suppressedSelectionItem = nil
    if suppressed == result.item.id { return }
    openPDF(result.item, resourceID: result.resourceID, page: result.pageStart)
  }

  func reveal(_ item: ResearchCore.LibraryItem) {
    guard let root,
      let path = item.resources.first(where: { $0.relativePath != nil })?.relativePath,
      let url = try? Files.safeURL(root: root, relative: path)
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
  func website(_ item: ResearchCore.LibraryItem) {
    if let value = item.canonicalURL ?? item.resources.compactMap(\.remoteURL).first,
      let url = try? Identifiers.canonicalURL(value)
    {
      NSWorkspace.shared.open(url)
    }
  }
  func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
  func rebuild() {
    run { service in
      let issues = try await service.rebuild()
      await MainActor.run {
        self.issues = issues
        self.showIssues = true
      }
    }
  }
  func integrity() {
    run { service in
      let issues = try await service.integrity()
      await MainActor.run {
        self.issues = issues
        self.showIssues = true
      }
    }
  }
  func export(_ format: ExportFormat) {
    run { service in
      let url = try await service.export(format: format)
      await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
  }
  func diagnostics() {
    run { service in
      let url = try await service.diagnostics()
      await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
  }
  func enableSafariExtension() {
    SFSafariApplication.showPreferencesForExtension(withIdentifier: "org.researchlibrary.mac.safari") { error in
      if let error {
        Task { @MainActor in
          self.message = "Safari extension settings could not open: " + error.localizedDescription
            + " Enable Allow unsigned extensions in Safari Settings → Developer, then go straight to Extensions without quitting Safari. Safari resets the unsigned setting when it quits."
        }
      }
    }
  }
  func reportSafariExtension(to url: URL) {
    SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: "org.researchlibrary.mac.safari") { state, error in
      var report: [String: Any] = ["identifier": "org.researchlibrary.mac.safari",
        "app": Bundle.main.bundleURL.path, "recognizedBySafari": state != nil]
      if let state { report["enabled"] = state.isEnabled }
      if let error = error as NSError? {
        report["errorDomain"] = error.domain; report["errorCode"] = error.code
        report["error"] = error.localizedDescription
      }
      try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
    }
  }
  func focusItem(_ id: UUID) {
    guard let library else { return }
    Task {
      do {
        if let item = try await library.item(id) {
          let result = RetrievalResult(item: item)
          if !results.contains(where: { $0.id == result.id }) { results.insert(result, at: 0) }
          selection = result.id
        }
      } catch { message = error.localizedDescription }
    }
  }
  func migrate() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json, UTType(filenameExtension: "bib") ?? .plainText]
    if panel.runModal() == .OK, let url = panel.url { run { _ = try await $0.importRecords(url) } }
  }
}
@main struct ResearchLibraryApp: App {
  @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) private var appDelegate
  @StateObject private var model = LibraryModel.shared
  init() {
    let launchModel = LibraryModel.shared
    _model = StateObject(wrappedValue: launchModel)
    let safariArguments = ProcessInfo.processInfo.arguments
    if let index = safariArguments.firstIndex(of: "--safari-extension-report"), index + 1 < safariArguments.count {
      launchModel.reportSafariExtension(to: URL(fileURLWithPath: safariArguments[index + 1]))
    }
    if ProcessInfo.processInfo.arguments.contains("--show-safari-extension-settings") {
      launchModel.enableSafariExtension()
    }
    if ProcessInfo.processInfo.arguments.contains("--import-bibliography") {
      Task { await launchModel.importLaunchBibliography() }
    }
    if ProcessInfo.processInfo.arguments.contains("--process-inbox-zips") {
      Task { await launchModel.processLaunchArchives() }
    }
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--diagnose-pdf"), index + 1 < arguments.count,
      let id = UUID(uuidString: arguments[index + 1]),
      let reportIndex = arguments.firstIndex(of: "--pdf-report"), reportIndex + 1 < arguments.count {
      Task {
        do {
          guard let library = launchModel.library else { throw LibraryError.invalid("Library folder unavailable") }
          let data: Data
          if arguments.contains("--resolve-pdf") {
            let item = try await library.resolvePDF(id, retry: true)
            guard let root = launchModel.root,
              let resource = item.resources.first(where: { $0.type == .pdf && $0.relativePath != nil && $0.availability == .local }),
              let path = resource.relativePath else { throw LibraryError.invalid(item.pdfLookup?.detail ?? "PDF unavailable") }
            let url = try Files.safeURL(root: root, relative: path)
            try await ReaderWorkspace.shared.open(url: url, title: item.title, itemID: id,
              resourceID: resource.id, root: root, library: library, initialPage: nil)
            guard let document = ReaderWorkspace.shared.documents.first(where: { $0.id == resource.id }) else { throw LibraryError.invalid("Reader did not open the PDF") }
            data = try JSONSerialization.data(withJSONObject: ["readerOpened": true,
              "readerPages": document.document.pageCount, "path": path,
              "item": try JSONSerialization.jsonObject(with: PortableJSON.encoder().encode(item))], options: [.prettyPrinted, .sortedKeys])
          } else { data = try await library.pdfDiagnostic(id) }
          try data.write(to: URL(fileURLWithPath: arguments[reportIndex + 1]), options: .atomic)
        } catch {
          let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
          try? data?.write(to: URL(fileURLWithPath: arguments[reportIndex + 1]), options: .atomic)
        }
      }
    }
  }
  var body: some Scene {
    WindowGroup("Research Library") {
      LibraryView().environmentObject(model).frame(minWidth: 1000, minHeight: 640)
        .task {
          await model.importLaunchBibliography()
          #if DEBUG
            if let report = ProcessInfo.processInfo.environment["RESEARCH_LIBRARY_SEARCH_TEST_REPORT"] {
              await SearchSmokeTest.run(report: URL(fileURLWithPath: report), model: model)
              return
            }
            if let report = ProcessInfo.processInfo.environment[
              "RESEARCH_LIBRARY_READER_TEST_REPORT"]
            {
              await ReaderSmokeTest.run(report: URL(fileURLWithPath: report), model: model)
              return
            }
            if let path = ProcessInfo.processInfo.environment["RESEARCH_LIBRARY_SNAPSHOT"] {
              try? await Task.sleep(for: .seconds(8))
              if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
              {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                  try? data.write(to: URL(fileURLWithPath: path))
                }
              }
              NSApp.terminate(nil)
            }
          #endif
        }
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(after: .newItem) {
        Button("Select Library…", action: model.chooseLibrary)
        Button("Import PDFs…") { model.importPDF() }.keyboardShortcut("i")
        Button("Add URL or Identifier…") { model.showCapture = true }.keyboardShortcut("n")
      }
      CommandMenu("Library") {
        Button("Refresh Inbox", action: model.refreshInbox).keyboardShortcut("r")
          .disabled(model.root == nil || model.busy)
        Button("Enable Safari Extension…", action: model.enableSafariExtension)
        Button("Rebuild Local Index", action: model.rebuild)
        Button("Check Integrity", action: model.integrity)
        Button("Export Diagnostics", action: model.diagnostics)
        Button("Import Paperpile JSON / BibTeX…", action: model.migrate)
        Menu("Export") {
          ForEach(ExportFormat.allCases, id: \.self) { f in
            Button(f.rawValue.uppercased()) { model.export(f) }
          }
        }
        Button("Show Library in Finder") {
          if let root = model.root { NSWorkspace.shared.open(root) }
        }
      }
    }
    Settings { SettingsView() }
  }
}
struct SettingsView: View {
  @State private var openAlexKey = ""
  var body: some View {
    Form {
      Section("OpenAlex") {
        SecureField("API key", text: $openAlexKey)
        HStack {
          Button("Save key") { try? OpenAlexCredentialStore.save(openAlexKey) }
          Button("Remove key", role: .destructive) { OpenAlexCredentialStore.remove(); openAlexKey = "" }
        }
        Text("The key is stored in macOS Keychain and is only sent to api.openalex.org.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("PDF naming pattern") {
        TextField("Pattern", text: Binding(get: { UserDefaults.standard.string(forKey: "filenamePattern") ?? "{year} - {author} - {title}" }, set: { UserDefaults.standard.set($0, forKey: "filenamePattern") }))
        Text("Tokens: {year}, {author}, {title}").foregroundStyle(.secondary)
      }
    }.padding().frame(width: 480).task { openAlexKey = OpenAlexCredentialStore.read() ?? "" }
  }
}
struct ResearchDashboardView: View {
  @EnvironmentObject var model: LibraryModel
  private var continueItems: [ResearchCore.LibraryItem] { Array(model.dashboardItems.filter { !$0.read }.prefix(6)) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("Research overview").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Reading, activity, and new work in one place.").foregroundStyle(.secondary)
          }
          Spacer()
          Button { model.refreshDashboard(forceOpenAlex: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .buttonStyle(.bordered).disabled(model.dashboardBusy)
          Button { model.syncOpenAlexMetadata() } label: { Label("Sync OpenAlex", systemImage: "cloud.and.arrow.down") }
            .buttonStyle(.borderedProminent).tint(.indigo).disabled(model.dashboardBusy)
        }
        if let status = model.dashboardStatus {
          Label(status, systemImage: model.dashboardBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle")
            .font(.caption).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
          DashboardMetric(title: "In library", value: model.dashboardSummary.counts["total", default: 0], icon: "books.vertical", tint: .indigo)
          DashboardMetric(title: "Unread", value: model.dashboardSummary.counts["unread", default: 0], icon: "book.closed", tint: .blue)
          DashboardMetric(title: "PDFs", value: model.dashboardSummary.counts["withPDF", default: 0], icon: "doc.richtext", tint: .teal)
          DashboardMetric(title: "Favorites", value: model.dashboardSummary.counts["favorites", default: 0], icon: "star.fill", tint: .orange)
        }
        DashboardCard(title: "Continue reading", subtitle: "Your unread library") {
          if continueItems.isEmpty && model.dashboardSummary.continueReading.isEmpty { Text("Your unread papers will appear here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
          else {
            if continueItems.isEmpty {
              ForEach(model.dashboardSummary.continueReading) { item in
                DashboardCachedPaperRow(item: item, action: { model.openDashboardItem(item.id) })
                if item.id != model.dashboardSummary.continueReading.last?.id { Divider().padding(.leading, 2) }
              }
            } else {
              ForEach(continueItems) { item in
                DashboardPaperRow(item: item, action: { model.openPDF(item) })
                if item.id != continueItems.last?.id { Divider().padding(.leading, 2) }
              }
            }
          }
        }
        DashboardCard(title: "New publications", subtitle: "Based on your library") {
          if model.dashboardSnapshot.feed.isEmpty { Text("Add an OpenAlex key in Settings to personalize this feed.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
          else {
            ForEach(model.dashboardSnapshot.feed) { work in
              DashboardWorkRow(work: work, action: { if let url = work.openAccessURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) } })
              if work.id != model.dashboardSnapshot.feed.last?.id { Divider().padding(.horizontal, 4) }
            }
          }
        }
        DashboardCard(title: "Research pulse", subtitle: "Topics across your library") {
          if model.dashboardSummary.topics.isEmpty { Text("Keywords will appear as metadata is enriched.").foregroundStyle(.secondary) }
          else {
            FlowLayout(spacing: 8) {
              ForEach(model.dashboardSummary.topics) { topic in
                Text("\(topic.name)  \(topic.count)")
                  .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                  .background(.indigo.opacity(0.12), in: Capsule())
                  .foregroundStyle(.indigo)
              }
            }
          }
          Text("OpenAlex matched \(model.dashboardSnapshot.matchedCount) of \(model.dashboardSummary.counts["total", default: 0]) local publications.")
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
      }.padding(28).frame(maxWidth: 1100, alignment: .leading)
    }
    .background(Color(nsColor: .underPageBackgroundColor))
  }
}
struct DashboardMetric: View {
  let title: String; let value: Int; let icon: String; let tint: Color
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Image(systemName: icon).font(.headline).foregroundStyle(tint)
      Text(value, format: .number).font(.system(.title, design: .rounded, weight: .bold))
      Text(title).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, minHeight: 104, alignment: .leading).padding(16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.16)) }
  }
}
struct DashboardCard<Content: View>: View {
  let title: String; let subtitle: String; @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title3.weight(.semibold))
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      content
    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
  }
}
struct DashboardSidebarSummary: View {
  @EnvironmentObject var model: LibraryModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Dashboard", systemImage: "chart.bar.xaxis").font(.headline)
      Divider()
      Label("\(model.dashboardSummary.counts["unread", default: 0]) unread", systemImage: "book.closed")
      Label("\(model.dashboardSummary.counts["withPDF", default: 0]) PDFs", systemImage: "doc.richtext")
      Spacer()
      Text("Select a library section to browse papers.").font(.caption).foregroundStyle(.secondary)
    }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
  }
}
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .greatestFiniteMagnitude
    var cursor = CGPoint.zero; var height: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if cursor.x > 0, cursor.x + size.width > width { cursor.x = 0; cursor.y += height + spacing; height = 0 }
      cursor.x += size.width + spacing; height = max(height, size.height)
    }
    return CGSize(width: proposal.width ?? cursor.x, height: cursor.y + height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var point = bounds.origin; var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if point.x > bounds.minX, point.x + size.width > bounds.maxX { point.x = bounds.minX; point.y += rowHeight + spacing; rowHeight = 0 }
      subview.place(at: point, proposal: ProposedViewSize(size))
      point.x += size.width + spacing; rowHeight = max(rowHeight, size.height)
    }
  }
}
struct DashboardPaperRow: View {
  let item: ResearchCore.LibraryItem; let action: () -> Void
  var body: some View { Button(action: action) { VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.headline).lineLimit(2); Text([item.journal, item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }
}
struct DashboardCachedPaperRow: View {
  let item: DashboardReadingItem; let action: () -> Void
  var body: some View { Button(action: action) { VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.headline).lineLimit(2); Text([item.journal, item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " • ")).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }
}
struct DashboardWorkRow: View {
  let work: OpenAlexWorkRecord; let action: () -> Void
  @State private var hovering = false
  private var metadata: String {
    [work.journal ?? "", work.publicationDate ?? "", work.authors.prefix(2).joined(separator: ", ")]
      .filter { !$0.isEmpty }.joined(separator: "  •  ")
  }
  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: work.openAccessURL == nil ? "doc.text" : "lock.open")
          .font(.subheadline.weight(.medium)).foregroundStyle(.indigo)
          .frame(width: 24, height: 24)
          .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        VStack(alignment: .leading, spacing: 6) {
          Text(work.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
          if !metadata.isEmpty { Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        Spacer(minLength: 8)
        Text(work.openAccessURL == nil ? "OpenAlex" : "Open access")
          .font(.caption2.weight(.semibold)).foregroundStyle(.indigo)
          .padding(.horizontal, 8).padding(.vertical, 5)
          .background(.indigo.opacity(0.12), in: Capsule())
      }.padding(.vertical, 10).padding(.horizontal, 12)
        .background(hovering ? Color.indigo.opacity(0.10) : Color.clear,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
      .onHover { hovering = $0 }
      .accessibilityHint(work.openAccessURL == nil ? "Open the OpenAlex record" : "Open the available publication")
  }
}
struct LibraryPanePresenceProbe: ViewModifier {
  let name: String
  func body(content: Content) -> some View {
    #if DEBUG
      content.onAppear { LibraryPanePresence.mounted.insert(name) }
        .onDisappear { LibraryPanePresence.mounted.remove(name) }
    #else
      content
    #endif
  }
}
#if DEBUG
@MainActor enum LibraryPanePresence {
  static var mounted = Set<String>()
}
#endif

struct LibraryNavigationRail: View {
  @EnvironmentObject var model: LibraryModel
  @Binding var selection: String
  let collections: [String]
  let tags: [String]
  private let destinations: [(String, String)] = [
    ("Overview", "house"), ("All Items", "books.vertical"),
    ("Recently Added", "clock"), ("Favorites", "star"), ("Unread", "book.closed"),
    ("PDF Available", "doc.richtext"), ("PDF Unavailable", "doc.badge.ellipsis"),
    ("Needs Review", "exclamationmark.bubble"),
  ]
  var body: some View {
    VStack(spacing: 4) {
      ForEach(destinations, id: \.0) { title, icon in
        NavigationRailControl(title: title, selected: selection == title) {
          Button { selection = title } label: {
            Image(systemName: icon).frame(width: 40, height: 40)
          }.buttonStyle(.plain).accessibilityLabel(title)
        }
      }
      Divider().padding(.horizontal, 14).padding(.vertical, 6)
      NavigationRailControl(title: "Collections", selected: selection.hasPrefix("collection:")) {
        Menu {
          if collections.isEmpty { Text("No collections") }
          ForEach(collections, id: \.self) { name in
            Button(name) { selection = "collection:" + name }
          }
        } label: { Image(systemName: "folder").frame(width: 40, height: 40) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Collections")
      }
      NavigationRailControl(title: "Tags", selected: selection.hasPrefix("tag:")) {
        Menu {
          if tags.isEmpty { Text("No tags") }
          ForEach(tags, id: \.self) { name in
            Button(name) { selection = "tag:" + name }
          }
        } label: { Image(systemName: "tag").frame(width: 40, height: 40) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("Tags")
      }
      Spacer(minLength: 0)
      Divider().padding(.horizontal, 14).padding(.vertical, 4)
      NavigationRailControl(title: "Refresh Inbox", selected: false) {
        Button(action: model.refreshInbox) {
          Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
        }.buttonStyle(.plain)
          .disabled(model.root == nil || model.busy)
          .accessibilityLabel("Refresh Inbox")
          .help("Check the Inbox hot folder and refresh the library")
      }
      NavigationRailControl(title: "Settings", selected: false) {
        SettingsLink {
          Image(systemName: "gearshape").frame(width: 40, height: 40)
        }.buttonStyle(.plain).accessibilityLabel("Settings")
      }
    }
    .font(.system(size: 21, weight: .regular))
    .padding(.top, 12).padding(.bottom, 8)
    .frame(maxHeight: .infinity)
    .liquidGlass(in: Rectangle())
  }
}

struct NavigationRailControl<Content: View>: View {
  let title: String
  let selected: Bool
  let content: Content
  @State private var hovering = false
  init(title: String, selected: Bool, @ViewBuilder content: () -> Content) {
    self.title = title; self.selected = selected; self.content = content()
  }
  var body: some View {
    content
      .foregroundStyle(selected ? Color.primary : Color.secondary)
      .background(selected ? Color.accentColor.opacity(0.18)
        : hovering ? Color.primary.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: 12))
      .onHover { hovering = $0 }
      .overlay(alignment: .leading) {
        if hovering {
          Text(title).font(.system(size: 14, weight: .medium)).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .offset(x: 54).allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .zIndex(hovering ? 100 : 0)
  }
}

struct LibraryView: View {
  @EnvironmentObject var model: LibraryModel
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var readerWorkspace = ReaderWorkspace.shared
  @AppStorage("libraryListVisible") private var libraryListVisible = true
  private var readerView: some View {
    ReaderWorkspaceView(workspace: readerWorkspace)
      .frame(minWidth: 420).background(Color(nsColor: .windowBackgroundColor))
  }
  private var scopeTitle: String {
    model.scope.hasPrefix("tag:") ? String(model.scope.dropFirst(4))
      : model.scope.hasPrefix("collection:") ? String(model.scope.dropFirst(11)) : model.scope
  }
  private var libraryListPane: some View {
    VStack(spacing: 0) {
      if model.root == nil {
        ContentUnavailableView {
          Label("Your research, your files", systemImage: "books.vertical")
        } description: {
          Text("Choose a folder to create or open your portable research archive.")
        } actions: {
          Button("Choose Library…", action: model.chooseLibrary).buttonStyle(
            .borderedProminent)
        }
      } else {
        if model.scope == "Overview" {
          DashboardSidebarSummary()
        } else {
        HStack {
          Text(scopeTitle).font(.headline).lineLimit(1)
          Spacer()
          Picker("Sort", selection: $model.sort) {
            Text("Relevance").tag("Relevance")
            Text("Newest publication").tag("Newest")
            Text("Recently added").tag("Recently added")
            Text("Title").tag("Title")
            Text("Year").tag("Year")
          }
          .labelsHidden().frame(maxWidth: 165)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .liquidGlass(in: Rectangle())
        List(selection: $model.selection) {
          ForEach(model.results) { result in
            LibraryRow(result: result).tag(result.id).contextMenu {
              Button("Open PDF in Tab") {
                model.openPDF(
                  result.item, resourceID: result.resourceID, page: result.pageStart,
                  inNewTab: true)
              }
              Divider()
              ItemActions(item: result.item)
            }.background(
              PDFRowMouseHandler(
                itemID: result.item.id,
                openCurrent: {
                  model.openPDF(
                    result.item, resourceID: result.resourceID, page: result.pageStart)
                },
                openInTab: {
                  model.openPDF(
                    result.item, resourceID: result.resourceID, page: result.pageStart,
                    inNewTab: true)
                }, controlHit: { model.suppressSelectionOpening(result.item.id) })
            )
          }
          if model.canLoadMore { Button("Load More") { model.refresh(append: true) }.disabled(model.isSearching) }

        }
        .scrollContentBackground(.hidden)
        .overlay {
          if model.results.isEmpty && !model.isSearching { ContentUnavailableView.search(text: model.query) }
        }
        HStack {
          Text("\(model.results.count) results")
          Spacer()
          if model.isSearching {
            Text(model.searchingPDFText ? "Searching PDF text…" : "Searching…")
              .font(.caption).foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
          }
          if model.busy { ProgressView().controlSize(.small) }
          let count = model.pendingCaptureCount
          Text(count > 0 ? "Processing \(count) captures" : "Up to date")
          if let status = model.browserCaptureStatus {
            Text(status).lineLimit(1).help(status)
          }
        }
        .font(.caption).foregroundStyle(.secondary).padding(10)
        .liquidGlass(in: Rectangle())
        CaptureQueueView()
        }
      }
    }
  }
  @ViewBuilder private var detailPane: some View {
    if model.scope == "Overview" {
      ResearchDashboardView()
    } else if readerWorkspace.isPresented, !readerWorkspace.documents.isEmpty {
      readerView
    } else if let result = model.selected {
      PDFUnavailableView(result: result)
    } else {
      ContentUnavailableView(
        "Select an item", systemImage: "doc.text.magnifyingglass",
        description: Text(
          "Select a paper to read its PDF. Use Metadata to show article details."))
    }

  }
  var body: some View {
    HStack(spacing: 0) {
      LibraryNavigationRail(selection: $model.scope, collections: model.collections, tags: model.tags)
        .frame(width: 64)
        .accessibilityIdentifier("navigation-rail")
        .modifier(LibraryPanePresenceProbe(name: "navigation"))
        .zIndex(10)
      Divider()
      HSplitView {
        if libraryListVisible {
          libraryListPane.frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
            .accessibilityIdentifier("library-list-pane")
            .modifier(LibraryPanePresenceProbe(name: "library"))
        }
        detailPane.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if !readerWorkspace.downloads.isEmpty {
        HStack {
          ProgressView().controlSize(.small)
          Text(
            "Downloading from iCloud: "
              + Set(readerWorkspace.downloads.values.map(\.title)).sorted().joined(separator: ", ")
          )
          .lineLimit(2)
          Spacer()
        }.font(.caption).padding(10).background(Color(nsColor: .windowBackgroundColor))
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .background(ReaderWindowAttachment(workspace: readerWorkspace).frame(width: 0, height: 0))
    .onChange(of: readerWorkspace.isPresented) {
      if !readerWorkspace.isPresented {
        libraryListVisible = true
      }
    }
    .onChange(of: model.selection) { model.readSelection() }
    .onChange(of: model.browserCaptureSequence) { libraryListVisible = true }
    .inspector(isPresented: $readerWorkspace.metadataVisible) {
      VStack(spacing: 0) {
        HStack {
          Text("Reader Sidebar").font(.headline)
          Spacer()
          Button {
            readerWorkspace.metadataVisible = false
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain).help("Close metadata sidebar")
        }.padding(14)
        Divider()
        if model.scope == "Overview" {
          ContentUnavailableView("Dashboard", systemImage: "chart.bar.xaxis")
        } else if readerWorkspace.isPresented, let reader = readerWorkspace.selected {
          UnifiedReaderSidebar(reader: reader).id(reader.id)
        } else if let result = model.selected {
          Inspector(result: result)
        } else {
          ContentUnavailableView("No paper selected", systemImage: "info.circle")
        }
      }.environment(\.colorScheme, colorScheme)
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .foregroundStyle(Color(nsColor: .labelColor))
        .background(Color.clear)
        .liquidGlass(in: Rectangle())
        .inspectorColumnWidth(min: 280, ideal: 340, max: 450)
    }
    .searchable(text: $model.query, prompt: "Search")
    .toolbar(removing: .sidebarToggle)
    .toolbar {
      if model.scope != "Overview", readerWorkspace.isPresented, let reader = readerWorkspace.toolbarReader {
        ReaderToolbar(
          reader: reader,
          showLibrary: { libraryListVisible.toggle() },
          toggleInspector: {
            if readerWorkspace.metadataVisible && readerWorkspace.readerSidebarSection == "metadata" {
              readerWorkspace.metadataVisible = false
            } else {
              readerWorkspace.readerSidebarSection = "metadata"
              readerWorkspace.metadataVisible = true
            }
          })
      } else {
        ToolbarItem(placement: .navigation) {
          Button {
            libraryListVisible.toggle()
          } label: {
            Label("Library", systemImage: "sidebar.left")
          }.help("Show or hide the publication list")
        }
        ToolbarItemGroup(placement: .automatic) {
        Button(action: model.refreshInbox) {
          Label("Refresh Inbox", systemImage: "arrow.clockwise")
        }
        .help("Check the Inbox hot folder and process new captures")
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.root == nil || model.busy)
        Button {
          readerWorkspace.metadataVisible.toggle()
        } label: {
          Label("Reader Sidebar", systemImage: "sidebar.right")
        }.help("Show or hide metadata and PDF navigation")
          .disabled(model.scope == "Overview" || (model.selected == nil && readerWorkspace.selected == nil))
        if !readerWorkspace.documents.isEmpty, !readerWorkspace.isPresented {
          Button {
            readerWorkspace.showWindow()
          } label: {
            Label("Reader", systemImage: "doc.richtext")
          }
        }
        Menu {
          Button("Import PDFs…") { model.importPDF() }
          Button("Add URL or Identifier…") { model.showCapture = true }
        } label: {
          Label("Add to Library", systemImage: "plus")
        }.help("Import PDFs or add a link or identifier").disabled(model.root == nil)
        }
      }
    }
    .onContinueUserActivity(CSSearchableItemActionType) { activity in
      if let value = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
        let id = UUID(uuidString: value)
      {
        model.focusItem(id)
      }
    }
    .onSubmit(of: .search) { model.refresh() }
    .onChange(of: model.query) { if model.scope != "Overview" { model.refresh(debounce: true) } }.onChange(of: model.scope) {
      if model.scope == "Overview" {
        readerWorkspace.metadataVisible = false
        libraryListVisible = true
        model.refreshDashboard()
      } else { model.refresh() }
    }.onChange(of: model.sort) { model.refresh() }
    .dropDestination(for: URL.self) { urls, _ in
      model.drop(urls)
      return true
    }
    .sheet(isPresented: $model.showCapture) { CaptureView() }
    .sheet(item: $model.editor) { item in MetadataEditor(item: item) }
    .sheet(isPresented: $model.showIssues) {
      VStack(alignment: .leading) {
        Text("Library integrity").font(.title2)
        if model.issues.isEmpty {
          Text("No issues detected.")
        } else {
          List(model.issues) { issue in
            VStack(alignment: .leading) {
              Text(issue.path).font(.headline)
              Text(issue.message).foregroundStyle(.secondary)
            }
          }
          Text(
            "Files are retained. Use Attach PDF to reconcile orphan attachments, or reimport JSON from Recovery."
          ).font(.caption)
        }
        Button("Done") { model.showIssues = false }
      }.padding().frame(width: 650, height: 400)
    }
    .modifier(PermanentDeletionConfirmation(model: model))
    .alert(
      "Research Library",
      isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    ) {
      Button("OK") { model.message = nil }
    } message: {
      Text(model.message ?? "")
    }
  }
}
struct PermanentDeletionConfirmation: ViewModifier {
  @ObservedObject var model: LibraryModel
  func body(content: Content) -> some View {
    content.alert(
      "Permanently delete this article?",
      isPresented: Binding(
        get: { model.permanentDeletion != nil },
        set: { if !$0 { model.permanentDeletion = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { model.permanentDeletion = nil }
      Button("Delete Permanently", role: .destructive) {
        if let item = model.permanentDeletion { model.permanentlyDelete(item) }
        model.permanentDeletion = nil
      }
    } message: {
      Text(
        "“" + (model.permanentDeletion?.title ?? "")
          + "” and its managed attachments, notes, highlights, and app recovery copies will be deleted from this library and iCloud. This cannot be undone. Attachments used by other articles and files outside the library are kept."
      )
    }
  }
}
struct LibraryRow: View {
  @EnvironmentObject var model: LibraryModel
  let result: RetrievalResult
  @ViewState private var showPages = false
  @ViewState private var pageMatches: [RetrievalResult] = []
  @ViewState private var pageLimit = 5
  @ViewState private var loadingPages = false
  @ViewState private var pageError: String?
  private struct PageRequest: Hashable {
    let itemID: UUID
    let query: String
    let expanded: Bool
    let limit: Int
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        if result.item.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
        Text(result.item.title).font(.headline).lineLimit(2)
        Spacer()
        Image(systemName: result.item.hasPDF ? "doc.richtext" : "link").accessibilityLabel(
          result.item.hasPDF ? "PDF available" : "PDF unavailable")
      }
      Text(
        [
          result.item.orderedAuthors.first?.familyName ?? "Unknown author",
          result.item.year.map(String.init) ?? "undated", result.item.journal,
        ].filter { !$0.isEmpty }.joined(separator: " · ")
      ).font(.subheadline).foregroundStyle(.secondary)
      if !result.item.hasPDF, let lookup = result.item.pdfLookup, lookup.status != .pending {
        Text(lookup.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      if !result.snippet.isEmpty && result.pageStart != nil {
        Text("Page \(result.pageStart!): \(result.snippet)").font(.caption).lineLimit(3)
      }
      if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.item.hasPDF {
        VStack(alignment: .leading, spacing: 5) {
          PDFMatchingPagesToggle(expanded: $showPages).frame(height: 20)
          if showPages {
          if loadingPages { ProgressView().controlSize(.small) }
          ForEach(pageMatches, id: \.pageMatchID) { match in
            Button {
              model.openPDF(match.item, resourceID: match.resourceID, page: match.pageStart)
            } label: {
              Text("Page \(match.pageStart ?? 1): \(match.snippet)")
                .font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(.vertical, 3)
          }
          if let pageError { Text(pageError).font(.caption).foregroundStyle(.secondary) }
          if !loadingPages && pageMatches.isEmpty && pageError == nil {
            Text("No matching indexed PDF pages.").font(.caption).foregroundStyle(.secondary)
          }
          if !loadingPages && pageMatches.count == pageLimit && pageLimit < 20 {
            Button("Show more pages") { pageLimit = min(20, pageLimit + 5) }.font(.caption)
          }
          }
        }.font(.caption).background(PDFRowControlsRegion())
      }
      if !result.item.tags.isEmpty {
        Text(result.item.tags.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.tint)
      }
    }.padding(.vertical, 7)
      .onChange(of: model.query) { showPages = false; pageMatches = []; pageLimit = 5 }
      .task(id: PageRequest(itemID: result.item.id, query: model.query, expanded: showPages, limit: pageLimit)) {
        guard showPages, let library = model.library else { return }
        loadingPages = true
        pageError = nil
        do {
          let values = try await library.matchingPages(model.query, itemID: result.item.id, limit: pageLimit)
          guard !Task.isCancelled else { return }
          pageMatches = values
          loadingPages = false
        } catch is CancellationError {} catch {
          guard !Task.isCancelled else { return }
          pageError = error.localizedDescription
          loadingPages = false
        }
      }
  }
}
struct ItemActions: View {
  @EnvironmentObject var model: LibraryModel
  let item: ResearchCore.LibraryItem
  var body: some View {
    Button("Open PDF") { model.openPDF(item) }
    Button("Open Website") { model.website(item) }
    Button("Show in Finder") { model.reveal(item) }
    Button("Attach PDF…") { model.importPDF(attach: item.id) }
    Button("Attach Supplement…") { model.attachSupplement(item.id) }
    Button("Organize PDF Filenames") { model.run { try await $0.organizeFiles(item.id) } }
    Button("Edit Metadata…") { model.editor = item }
    Button("Refresh Web Metadata") { model.run { try await $0.refreshMetadata(item.id) } }
    Button("Copy DOI") { model.copy(item.doi ?? "") }.disabled(item.doi == nil)
    Button("Copy Citation") { model.copy(item.citation) }
    Button(item.favorite ? "Remove Favorite" : "Favorite") { model.toggleFavorite(item) }
    Button(item.read ? "Mark Unread" : "Mark Read") { model.toggleRead(item) }
    Divider()
    Button("Delete (Keep Recovery Copy)", role: .destructive) {
      model.run { try await $0.remove(item.id) }
    }
    Button("Delete Permanently…", role: .destructive) { model.permanentDeletion = item }
  }
}
struct PDFUnavailableView: View {
  @EnvironmentObject var model: LibraryModel
  @ObservedObject private var workspace = ReaderWorkspace.shared
  let result: RetrievalResult
  var body: some View {
    ContentUnavailableView {
      if model.locatingPDFs.contains(result.item.id) {
        Label("Finding PDF…", systemImage: "doc.text.magnifyingglass")
      } else if workspace.downloads.values.contains(where: { $0.itemID == result.item.id }) {
        Label("Downloading PDF…", systemImage: "icloud.and.arrow.down")
      } else {
        Label("PDF unavailable", systemImage: "doc.richtext")
      }
    } description: {
      if model.locatingPDFs.contains(result.item.id) {
        Text("Searching your library folder and online sources. The PDF will open automatically when found.")
        ProgressView().controlSize(.small)
      } else if workspace.downloads.values.contains(where: { $0.itemID == result.item.id }) {
        Text("The reader will open this paper automatically when its iCloud download finishes.")
      } else {
        Text(model.pdfLookupMessages[result.item.id] ?? result.item.pdfLookup?.detail
          ?? "Attach a PDF or open the article website.")
      }
    } actions: {
      Button("Find PDF Again") {
        model.openPDF(result.item, resourceID: result.resourceID, page: result.pageStart, retry: true)
      }.disabled(model.locatingPDFs.contains(result.item.id))
      Button("Attach PDF…") { model.importPDF(attach: result.item.id) }
      Button("Website") { model.website(result.item) }
      Button("Show Metadata") { ReaderWorkspace.shared.metadataVisible = true }
    }
  }
}
struct UnifiedReaderSidebar: View {
  @ObservedObject var reader: ReaderDocument
  @ObservedObject private var workspace = ReaderWorkspace.shared
  var body: some View {
    VStack(spacing: 0) {
      Picker("Reader sidebar", selection: $workspace.readerSidebarSection) {
        Text("Metadata").tag("metadata")
        Text("PDF navigation").tag("pdf")
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      Divider()
      if workspace.readerSidebarSection == "pdf" {
        ReaderPDFNavigationView(reader: reader)
      } else {
        ReaderMetadataSidebar(reader: reader)
      }
    }
  }
}

struct ReaderPDFNavigationView: View {
  @ObservedObject var reader: ReaderDocument
  var body: some View {
    VStack(spacing: 8) {
      Picker("PDF navigation", selection: $reader.sidebar) {
        Image(systemName: "rectangle.grid.1x2").tag("pages")
        Image(systemName: "list.bullet.indent").tag("outline")
        Image(systemName: "magnifyingglass").tag("search")
        Image(systemName: "highlighter").tag("annotations")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 10)
      .padding(.top, 10)
      ReaderPane(reader: reader).sidebar
    }
  }
}

struct ReaderMetadataSidebar: View {
  @EnvironmentObject var model: LibraryModel
  let reader: ReaderDocument
  @State private var result: RetrievalResult?
  @State private var error: String?
  private var refreshKey: String {
    reader.id.uuidString
      + String(
        model.results.first { $0.item.id == reader.itemID }?.item.dateModified.timeIntervalSince1970
          ?? 0)
  }
  var body: some View {
    Group {
      if let result {
        Inspector(result: result)
      } else if let error {
        Text(error).foregroundStyle(.secondary).padding()
      } else {
        ProgressView("Loading metadata…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.task(id: refreshKey) {
      do {
        guard let item = try await reader.library.item(reader.itemID) else {
          error = "Metadata is no longer available for this paper."
          return
        }
        guard !Task.isCancelled else { return }
        result = RetrievalResult(item: item, resourceID: reader.id)
        #if DEBUG
          ReaderWorkspace.shared.metadataDisplayedItemID = item.id
        #endif
      } catch { self.error = error.localizedDescription }
    }
  }
}
struct Inspector: View {
  @EnvironmentObject var model: LibraryModel
  let result: RetrievalResult
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(result.item.title).font(.title2).textSelection(.enabled)
        Text(result.item.authorText).foregroundStyle(.secondary).textSelection(.enabled)
        Text(result.item.citation).font(.caption).textSelection(.enabled)
        HStack {
          Button("Open PDF") {
            model.openPDF(result.item, resourceID: result.resourceID, page: result.pageStart)
          }.disabled(!result.item.hasPDF)
          Button("Website") { model.website(result.item) }
        }
        if !result.item.hasPDF {
          Label("PDF unavailable", systemImage: "doc.badge.ellipsis")
          Button("Attach PDF…") { model.importPDF(attach: result.item.id) }
        }
        LabeledContent("DOI", value: result.item.doi ?? "—")
        LabeledContent("PMID", value: result.item.pmid ?? "—")
        if let date = result.item.publicationDate { LabeledContent("Published", value: date) }
        if let publisher = result.item.publisher, !publisher.isEmpty {
          LabeledContent("Publisher", value: publisher)
        }
        if let language = result.item.language, !language.isEmpty {
          LabeledContent("Language", value: language)
        }
        if let issn = result.item.issn, !issn.isEmpty {
          LabeledContent("ISSN", value: issn.joined(separator: ", "))
        }
        if let keywords = result.item.keywords, !keywords.isEmpty {
          LabeledContent("Keywords", value: keywords.joined(separator: ", "))
        }
        Button("Refresh Web Metadata") {
          model.run { try await $0.refreshMetadata(result.item.id) }
        }
        Text("Abstract").font(.headline)
        Text(result.item.abstract.isEmpty ? "No abstract available" : result.item.abstract)
          .textSelection(.enabled)
        Text("Tags & collections").font(.headline)
        Text(result.item.tags.joined(separator: ", "))
        Text(result.item.collections.joined(separator: ", "))
        Text("Notes").font(.headline)
        Text(result.item.notes.isEmpty ? "No notes yet" : result.item.notes).textSelection(.enabled)
        Button("Edit Metadata, Tags & Notes…") { model.editor = result.item }
        Text("Attachments").font(.headline)
        ForEach(result.item.resources) { r in
          VStack(alignment: .leading) {
            Text(r.relativePath ?? r.remoteURL ?? r.type.rawValue).font(.caption).textSelection(
              .enabled)
            Text(r.availability.rawValue).font(.caption2).foregroundStyle(.secondary)
            if r.type == .pdf, r.relativePath != nil {
              Button("Open Attachment") { model.openPDF(result.item, resourceID: r.id) }
            }
          }
        }
        Text("Metadata confidence: \(Int(result.item.confidence*100))%").font(.caption)
        ForEach(Array(result.item.provenance.enumerated()), id: \.offset) { _, p in
          Text("\(p.source): \(p.explanation)").font(.caption2).foregroundStyle(.secondary)
        }
        Menu("Actions") { ItemActions(item: result.item) }
      }.padding(22)
    }.navigationSplitViewColumnWidth(min: 300, ideal: 360)
  }
}
struct CaptureView: View {
  @EnvironmentObject var model: LibraryModel
  var body: some View {
    Form {
      Text("Add to Research Library").font(.title2)
      TextField("URL, DOI, PMID, arXiv ID, or text", text: $model.input)
      TextField("Collection (optional)", text: $model.captureCollection)
      TextField("Tags (comma separated)", text: $model.captureTags)
      TextField("Note", text: $model.captureNote, axis: .vertical)
      HStack {
        Button("Cancel") { model.showCapture = false }
        Spacer()
        Button("Save to Inbox", action: model.capture).buttonStyle(.borderedProminent).disabled(
          model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 560)
  }
}
struct MetadataEditor: View {
  @EnvironmentObject var model: LibraryModel
  @ViewState<ResearchCore.LibraryItem> var item: ResearchCore.LibraryItem
  @ViewState<String> private var authors = ""
  @ViewState<String> private var tags = ""
  @ViewState<String> private var collections = ""
  @ViewState<String> private var year = ""
  var body: some View {
    VStack {
      Text("Edit Metadata").font(.title2)
      ScrollView {
        Form {
          TextField("Title", text: $item.title)
          Picker("Type", selection: $item.type) {
            ForEach(ItemType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          TextField("Authors (Family, Given; Family, Given)", text: $authors)
          TextField("Year", text: $year)
          TextField("Journal", text: $item.journal)
          TextField("Volume", text: $item.volume)
          TextField("Issue", text: $item.issue)
          TextField("Pages", text: $item.pages)
          TextField(
            "DOI", text: Binding(get: { item.doi ?? "" }, set: { item.doi = $0.isEmpty ? nil : $0 })
          )
          TextField(
            "PMID",
            text: Binding(get: { item.pmid ?? "" }, set: { item.pmid = $0.isEmpty ? nil : $0 }))
          TextField(
            "PMCID",
            text: Binding(get: { item.pmcid ?? "" }, set: { item.pmcid = $0.isEmpty ? nil : $0 }))
          TextField(
            "arXiv ID",
            text: Binding(
              get: { item.arxivID ?? "" }, set: { item.arxivID = $0.isEmpty ? nil : $0 }))
          TextField(
            "Website",
            text: Binding(
              get: { item.canonicalURL ?? "" }, set: { item.canonicalURL = $0.isEmpty ? nil : $0 }))
          TextField("Tags (comma separated)", text: $tags)
          TextField("Collections (comma separated)", text: $collections)
          Text("Abstract")
          TextEditor(text: $item.abstract).frame(height: 120)
          Text("Notes")
          TextEditor(text: $item.notes).frame(height: 160)
          Toggle("Favorite", isOn: $item.favorite)
          Toggle("Read", isOn: $item.read)
        }
      }
      HStack {
        Button("Cancel") { model.editor = nil }
        Spacer()
        Button("Save") {
          item.year = Int(year)
          item.tags = tags.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
          }
          item.collections = collections.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
          }
          if authors
            != item.orderedAuthors.map({ $0.familyName + ", " + $0.givenName }).joined(
              separator: "; ")
          {
            item.setAuthors(
              authors.split(separator: ";").map {
                let parts = $0.split(separator: ",", maxSplits: 1).map {
                  String($0).trimmingCharacters(in: .whitespaces)
                }
                return Author(
                  givenName: parts.count > 1 ? parts[1] : "", familyName: parts.first ?? "")
              })
          }
          model.save(item)
        }.buttonStyle(.borderedProminent)
      }
    }.padding(24).frame(width: 650, height: 680).onAppear {
      authors = item.orderedAuthors.map { $0.familyName + ", " + $0.givenName }.joined(
        separator: "; ")
      year = item.year.map(String.init) ?? ""
      tags = item.tags.joined(separator: ", ")
      collections = item.collections.joined(separator: ", ")
    }
  }
}
struct CaptureQueueView: View {
  @EnvironmentObject var model: LibraryModel
  var attention: Bool {
    model.requests.contains { $0.state != .complete }
  }
  var body: some View {
    if attention {
      DisclosureGroup("Capture queue") {
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(model.requests.filter { $0.state != .complete }) { request in
              CaptureQueueRow(request: request)
            }
          }
        }.frame(maxHeight: 180)
      }.padding(10)
    }
  }
}
struct CaptureQueueRow: View {
  @EnvironmentObject var model: LibraryModel
  let request: IngestionRequest
  var body: some View {
    VStack(alignment: .leading) {
      Text(request.suggestedTitle ?? request.inputText ?? request.inputFile ?? "Capture").lineLimit(
        1)
      Text(request.error ?? request.state.rawValue).font(.caption).foregroundStyle(.secondary)
      HStack {
        if request.state == .awaitingReview {
          Button("Show Existing") { showExisting() }
          Button("Attach to Existing") { resolve(.attach) }
          Button("Keep Both") { resolve(.keepBoth) }
          Button("Cancel") { resolve(.cancel) }
        } else if request.state == .failed || request.state == .waitingForResource {
          Button("Retry") {
            model.run { service in
              try await service.retry(request.id)
              await service.processPending()
            }
          }
        }
      }
    }.padding(.vertical, 4)
  }
  func resolve(_ choice: DuplicateChoice) {
    let id = request.id
    model.run { service in
      try await service.resolveReview(id, choice: choice)
      await service.processPending()
    }
  }
  func showExisting() {
    guard let id = request.candidateID, let library = model.library else { return }
    Task { if let item = try? await library.item(id) { model.editor = item } }
  }
}

struct AppIntentRegistration: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [ResearchLibraryIntentPackage.self] }
}

struct ResearchLibraryAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddToResearchLibraryIntent(),
      phrases: ["Save to \(.applicationName)", "Add to \(.applicationName)"],
      shortTitle: "Save to Library", systemImageName: "books.vertical")
  }
}

#if DEBUG
@MainActor enum SearchSmokeTest {
  static func run(report: URL, model: LibraryModel) async {
    var checks: [String] = []
    do {
      func check(_ passed: Bool, _ description: String) throws {
        guard passed else { throw LibraryError.invalid("Search check failed: " + description) }
        checks.append(description)
      }
      func settle() async throws {
        for _ in 0..<150 {
          if !model.isSearching { return }
          try await Task.sleep(for: .milliseconds(20))
        }
        throw LibraryError.invalid("Search did not finish")
      }
      guard let library = model.library, let root = model.root else {
        throw LibraryError.missingLibrary
      }
      model.worker?.cancel()
      model.processor?.cancel()
      model.searchTask?.cancel()
      for (title, word) in [("Alpha microscopy", "alpha"), ("Beta neuroscience", "beta"), ("Gamma methods", "alpha beta")] {
        var item = ResearchCore.LibraryItem(title: title)
        let path = "PDFs/\(item.id).pdf"
        let file = root.appendingPathComponent(path)
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
          throw LibraryError.invalid("Cannot build search PDF fixture")
        }
        for page in 1...7 {
          context.beginPDFPage(nil)
          NSGraphicsContext.saveGraphicsState()
          NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
          NSAttributedString(string: "\(title)\n\(word) microglia evidence. Page \(page)",
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            .draw(in: CGRect(x: 40, y: 600, width: 530, height: 150))
          NSGraphicsContext.restoreGraphicsState()
          context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: file, options: .atomic)
        var resource = Resource(itemID: item.id, type: .pdf, path: path, availability: .local)
        resource.sha256 = try Files.hash(file)
        item.resources = [resource]
        try await library.edit(item)
      }
      _ = try await library.rebuild()
      model.query = "alpha"
      model.refresh(debounce: true)
      try await Task.sleep(for: .milliseconds(45))
      model.query = "beta"
      model.refresh(debounce: true)
      try check(model.isSearching, "Typing reports pending search")
      try await Task.sleep(for: .milliseconds(240))
      try await settle()
      try check(model.results.count == 2 && !model.results.contains { $0.item.title == "Alpha microscopy" },
        "Rapid typing displays only the latest query")
      try check(!model.isSearching && !model.searchingPDFText && model.message == nil,
        "Search completion clears progress without cancellation errors")
      model.query = "alpha"
      try await Task.sleep(for: .milliseconds(45))
      let submitted = ContinuousClock.now
      model.refresh()
      try await settle()
      try check(submitted.duration(to: .now) < .milliseconds(170), "Submit bypasses the typing debounce")
      try check(model.results.count == 2 && Set(model.results.map { $0.item.id }).count == 2,
        "Multiple matching pages appear as one article row")
      let preview = try await library.searchMetadata("alpha")
      try check(preview.first?.id == model.results.first?.id, "Article identity survives PDF result refinement")
      let body = try model.results.first { $0.item.title == "Gamma methods" }
        .unwrap("Body match missing")
      let pageMatches = try await library.matchingPages("alpha", itemID: body.item.id)
      try check(pageMatches.count == 5 && Set(pageMatches.map { $0.pageMatchID }).count == 5,
        "Expanded page lookup returns distinct, navigable pages")
      model.refresh(debounce: true)
      model.query = "no-such-fixture"
      model.refresh(debounce: true)
      model.searchTask?.cancel()
      model.query = "beta"
      model.refresh()
      try await Task.sleep(for: .milliseconds(240))
      try await settle()
      try check(model.results.count == 2 && model.message == nil, "Cancelled search does not overwrite the next search")
      for number in 0..<120 { try await library.edit(ResearchCore.LibraryItem(title: "Paginationfixture \(number)")) }
      model.query = "paginationfixture"
      model.refresh()
      try await Task.sleep(for: .milliseconds(240))
      try await settle()
      try check(model.results.count == 100 && model.canLoadMore, "Metadata preview supports pagination")
      model.refresh(append: true)
      try await settle()
      try check(model.results.count == 120 && Set(model.results.map { $0.item.id }).count == 120 && !model.canLoadMore,
        "Load More appends unique articles")
      model.query = "alpha"
      model.refresh()
      try await Task.sleep(for: .milliseconds(260))
      try await settle()
      if let content = NSApp.windows.first(where: { $0.isVisible })?.contentView {
        func regions(_ view: NSView) -> [PDFRowControlsView] {
          (view as? PDFRowControlsView).map { [$0] } ?? view.subviews.flatMap(regions)
        }
        if let region = regions(content).first(where: { !$0.visibleRect.isEmpty }) {
          let point = region.convert(NSPoint(x: region.visibleRect.midX, y: region.visibleRect.midY), to: nil)
          try check(PDFRowMouseView.isControlRegion(point, in: content), "Page controls are excluded from row-wide PDF opening")
          let initialHeight = region.bounds.height
          let documents = ReaderWorkspace.shared.documents.count
          func pageButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Matching PDF pages" { return button }
            return view.subviews.lazy.compactMap(pageButton).first
          }
          guard let button = pageButton(content) else {
            throw LibraryError.invalid("Matching-page native button did not render")
          }
          button.performClick(nil)
          try await Task.sleep(for: .milliseconds(300))
          let expandedHeight = regions(content).map { $0.bounds.height }.max() ?? 0
          try check(expandedHeight > initialHeight, "Matching-page controls expand after activation")
          try check(ReaderWorkspace.shared.documents.count == documents, "Expanding page matches does not open a PDF")
        } else { throw LibraryError.invalid("Matching-page controls did not render") }
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
          content.cacheDisplay(in: content.bounds, to: bitmap)
          try bitmap.representation(using: .png, properties: [:])?.write(to: report.deletingPathExtension().appendingPathExtension("png"))
        }
      }
      try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: .prettyPrinted)
        .write(to: report, options: .atomic)
    } catch {
      try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "error": error.localizedDescription,
        "message": model.message ?? "", "isSearching": model.isSearching, "searchingPDFText": model.searchingPDFText], options: .prettyPrinted)
        .write(to: report, options: .atomic)
    }
    NSApp.terminate(nil)
  }
}

private extension Optional {
  func unwrap(_ message: String) throws -> Wrapped {
    guard let value = self else { throw LibraryError.invalid(message) }
    return value
  }
}
#endif
