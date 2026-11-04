import AppKit
import PDFKit
import ResearchCore
import SwiftUI
import UniformTypeIdentifiers

/// Exclusive ownership transfers from a worker to the main actor after parsing completes.
/// The worker never touches this PDFDocument again; PDFView remains on the main actor.
private final class PreparedReaderPDF: @unchecked Sendable {
  let document: PDFDocument
  let hash: String
  init(_ snapshot: PDFReadSnapshot) throws {
    guard let document = PDFDocument(data: snapshot.data), !document.isLocked, document.pageCount > 0
    else { throw LibraryError.invalid("This PDF is locked or cannot be opened") }
    self.document = document
    hash = snapshot.sha256
  }
  static func load(_ snapshot: PDFReadSnapshot) async throws -> PreparedReaderPDF {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try PreparedReaderPDF(snapshot)
    }
    let prepared = try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
    try Task.checkCancellation()
    return prepared
  }
}

@MainActor final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { LibraryModel.shared.receiveBrowserCapture(url) }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let workspace = ReaderWorkspace.shared
    guard workspace.documents.contains(where: \.hasUnsavedWork) else {
      return .terminateNow
    }
    Task {
      let proceed = await workspace.resolveUnsaved(workspace.documents, action: "Quit")
      sender.reply(toApplicationShouldTerminate: proceed)
    }
    return .terminateLater
  }
}

struct ReaderDownload: Identifiable {
  let id: UUID
  let itemID: UUID
  let title: String
}

@MainActor final class ReaderWorkspace: NSObject, ObservableObject {
  static let shared = ReaderWorkspace()
  @Published var documents: [ReaderDocument] = []
  @Published var selectedID: UUID?
  @Published var toolbarReaderID: UUID?
  @Published var readerSidebarSection = "metadata"
  var toolbarReader: ReaderDocument? {
    selected
  }
  @Published var isPresented = false
  @Published var metadataVisible = false
  @Published var downloads: [UUID: ReaderDownload] = [:]
  #if DEBUG
    var metadataDisplayedItemID: UUID?
    var simulatedDownloads: [URL: Int] = [:]
    var lastMiddleHit: UUID?
  #endif
  private var windowDelegate: ReaderWindowDelegate?
  private var openGeneration = 0
  var selectionGeneration: Int { openGeneration }
  func prepareForLookup() { openGeneration += 1 }
  private var deletingItems = Set<UUID>()
  fileprivate var window: NSWindow?
  var selected: ReaderDocument? { documents.first { $0.id == selectedID } }
  func open(
    url: URL, title: String, itemID: UUID, resourceID: UUID, root: URL, library: LibraryService,
    initialPage: Int?, inNewTab: Bool = false
  ) async throws {
    guard !deletingItems.contains(itemID) else { return }
    openGeneration += 1
    let generation = openGeneration
    if let existing = documents.first(where: { $0.id == resourceID && $0.url == url }) {
      select(existing.id)
      if let initialPage { existing.go(page: initialPage) }
    } else {
      let requestID = UUID()
      let accessing = root.startAccessingSecurityScopedResource()
      defer {
        downloads[requestID] = nil
        if accessing { root.stopAccessingSecurityScopedResource() }
      }
      let started = ContinuousClock.now
      var loaded: ReaderDocument?
      while loaded == nil {
        guard !deletingItems.contains(itemID) else { return }
        guard inNewTab || generation == openGeneration else { return }
        try Task.checkCancellation()
        do {
          #if DEBUG
            if let remaining = simulatedDownloads[url], remaining > 0 {
              simulatedDownloads[url] = remaining - 1
              throw ResourceDownloadPending()
            }
          #endif
          let snapshot = try await library.readPDFForReader(itemID: itemID, resourceID: resourceID)
          let prepared = try await PreparedReaderPDF.load(snapshot)
          guard inNewTab || generation == openGeneration else { return }
          guard !deletingItems.contains(itemID) else { return }
          loaded = try ReaderDocument(
            url: url, title: title, itemID: itemID, resourceID: resourceID, root: root,
            library: library, initialPage: initialPage, prepared: prepared)
        } catch is ResourceDownloadPending {
          downloads[requestID] = ReaderDownload(id: requestID, itemID: itemID, title: title)
          guard started.duration(to: .now) < .seconds(300) else {
            throw LibraryError.invalid(
              "This PDF is still downloading from iCloud. Check your connection and try again.")
          }
          try await Task.sleep(for: .milliseconds(300))
        }
      }
      let document = loaded!
      if let existing = documents.first(where: { $0.id == resourceID && $0.url == url }) {
        let activate = !inNewTab || generation == openGeneration || selected == nil
        if activate { select(existing.id) }
        if let initialPage, activate { existing.go(page: initialPage) }
        showWindow()
        return
      }
      if !inNewTab, let current = selected {
        guard await current.flush() else {
          showWindow()
          throw LibraryError.invalid(
            "The current PDF has unsaved highlights. Save or reload it before opening another paper."
          )
        }
        // A newer selection wins while a save is in progress.
        guard generation == openGeneration else { return }
        current.remember()
        if let index = documents.firstIndex(where: { $0 === current }) {
          documents[index] = document
        } else {
          documents.append(document)
        }
      } else {
        documents.append(document)
      }
      if !inNewTab || generation == openGeneration || selected == nil { select(document.id) }
    }
    showWindow()
  }
  func select(_ id: UUID) {
    openGeneration += 1
    selectedID = id
    toolbarReaderID = id
    updateWindowIdentity()
  }
  func close(_ requested: ReaderDocument) {
    guard
      let document = documents.first(where: { $0.id == requested.id && $0.url == requested.url })
    else { return }
    openGeneration += 1
    Task {
      guard await resolveUnsaved([document], action: "Close") else { return }
      document.remember()
      documents.removeAll { $0.id == document.id }
      if selectedID == document.id { selectedID = documents.first?.id }
      self.updateWindowIdentity()
      if documents.isEmpty { isPresented = false }
    }
  }
  func flush() async -> Bool {
    var success = true
    for document in documents {
      document.remember()
      if !(await document.flush()) { success = false }
    }
    return success
  }
  /// Like `flush()`, but gives up waiting after `timeout` (for example an iCloud write
  /// that never completes) so quitting and closing can never hang indefinitely.
  func flush(timeout: Duration) async -> Bool {
    await Self.waitAtMost(timeout) { await self.flush() }
  }
  static func waitAtMost(_ timeout: Duration, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
    final class Once { var done = false }
    let once = Once()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      Task { @MainActor in
        let result = await work()
        if !once.done { once.done = true; continuation.resume(returning: result) }
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        if !once.done { once.done = true; continuation.resume(returning: false) }
      }
    }
  }
  enum UnsavedChoice { case keepOpen, saveCopyThenContinue, discard }
  /// Asks what to do when highlights could not be saved. Never leaves the user stuck.
  func askAboutUnsaved(_ unsaved: [ReaderDocument], action: String) -> UnsavedChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    let names = unsaved.map { "“\($0.title)”" }.prefix(3).joined(separator: ", ")
    alert.messageText = "Highlights in \(names) could not be saved."
    let reason = unsaved.compactMap(\.error).first.map { "\n\nReason: " + $0 } ?? ""
    alert.informativeText =
      "You can keep the reader open and try again, save a copy of the highlighted PDF elsewhere, or \(action.lowercased()) without these highlights.\(reason)"
    alert.addButton(withTitle: "Keep Open")
    alert.addButton(withTitle: "Save a Copy…")
    alert.addButton(withTitle: "\(action) Without Saving")
    alert.buttons.last?.hasDestructiveAction = true
    switch alert.runModal() {
    case .alertSecondButtonReturn: return .saveCopyThenContinue
    case .alertThirdButtonReturn: return .discard
    default: return .keepOpen
    }
  }
  /// Flushes `targets`; if that fails, lets the user decide. Returns true when it is safe
  /// to proceed with closing/quitting.
  func resolveUnsaved(_ targets: [ReaderDocument], action: String) async -> Bool {
    let saved = await Self.waitAtMost(.seconds(20)) {
      var ok = true
      for document in targets {
        if !(await document.flush()) { ok = false }
      }
      return ok
    }
    if saved { return true }
    showWindow()
    let unsaved = targets.filter(\.hasUnsavedWork)
    guard !unsaved.isEmpty else { return true }
    switch askAboutUnsaved(unsaved, action: action) {
    case .keepOpen: return false
    case .saveCopyThenContinue:
      for document in unsaved { guard document.exportCopy() else { return false } }
      fallthrough
    case .discard:
      for document in unsaved { document.abandonUnsavedChanges() }
      return true
    }
  }
  func discardForDeletion(_ itemID: UUID) async {
    deletingItems.insert(itemID)
    openGeneration += 1
    for document in documents where document.itemID == itemID {
      await document.discardForDeletion()
    }
    documents.removeAll { $0.itemID == itemID }
    if !documents.contains(where: { $0.id == selectedID }) { selectedID = documents.first?.id }
    if documents.isEmpty { isPresented = false }
  }
  func deletionFailed(_ itemID: UUID) { deletingItems.remove(itemID) }
  func attach(to window: NSWindow) {
    guard self.window !== window else { return }
    self.window = window
    // Let AppKit own the titlebar material and active/inactive appearance.
    // A clear nonopaque window bypasses the normal unified-window backdrop.
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = false
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.toolbar?.showsBaselineSeparator = false
    window.backgroundColor = .windowBackgroundColor
    window.isOpaque = true
    updateWindowIdentity()
    let delegate = ReaderWindowDelegate(workspace: self, original: window.delegate)
    windowDelegate = delegate
    window.delegate = delegate
  }
  func showWindow() {
    isPresented = true
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func updateWindowIdentity() {
    window?.title = selected?.title ?? "Research Library"
  }

}

/// Preserve SwiftUI's window delegate behavior while waiting for pending PDF saves.
@MainActor private final class ReaderWindowDelegate: NSObject, NSWindowDelegate {
  weak var workspace: ReaderWorkspace?
  weak var original: NSWindowDelegate?
  init(workspace: ReaderWorkspace, original: NSWindowDelegate?) {
    self.workspace = workspace
    self.original = original
  }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || (original?.responds(to: selector) ?? false)
  }
  override func forwardingTarget(for selector: Selector!) -> Any? { original }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let workspace else { return original?.windowShouldClose?(sender) ?? true }
    if workspace.documents.contains(where: \.hasUnsavedWork) {
      Task {
        if await workspace.resolveUnsaved(workspace.documents, action: "Close") {
          for document in workspace.documents { document.remember() }
          sender.performClose(nil)
        }
      }
      return false
    }
    for document in workspace.documents { document.remember() }
    return original?.windowShouldClose?(sender) ?? true
  }
}

struct ReaderWindowAttachment: NSViewRepresentable {
  let workspace: ReaderWorkspace
  func makeNSView(context: Context) -> NSView {
    let view = ReaderWindowAnchor()
    view.workspace = workspace
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
}
@MainActor private final class ReaderWindowAnchor: NSView {
  weak var workspace: ReaderWorkspace?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { workspace?.attach(to: window) }
  }
}

struct ReaderOutline: Identifiable {
  let id = UUID()
  let label: String
  let destination: PDFDestination?
  let children: [ReaderOutline]?
}
struct ReaderAnnotation: Identifiable {
  let id: String
  let annotation: PDFAnnotation
  let page: PDFPage
  let pageNumber: Int
  let text: String
  let kind: String
}

@MainActor final class ReaderDocument: ObservableObject, Identifiable {
  let id: UUID
  let itemID: UUID
  let url: URL
  let title: String
  let library: LibraryService
  let pdfView = ReaderPDFView()
  let edits = UndoManager()
  @Published var page = 1
  @Published var scale = 1.0
  @Published var sidebar = "pages"
  @Published var sidebarVisible = true
  @Published var searchText = ""
  @Published var searchFocusRequest = 0
  @Published var matches: [PDFSelection] = []
  @Published var matchIndex = -1
  @Published var searching = false
  @Published var annotationSearch = ""
  @Published var annotationColor = "All"
  @Published var annotations: [ReaderAnnotation] = []
  @Published var selectedAnnotationID: String?
  @Published var highlightColor = "Yellow"
  @Published var hasSelection = false
  @Published var dirty = false
  @Published var saving = false
  @Published var error: String?
  @Published var canUndo = false
  @Published var canRedo = false
  private(set) var document: PDFDocument
  private(set) var outline: [ReaderOutline] = []
  private(set) var hash: String
  private var zoomMode = "width"
  private var appliedScale = 1.0
  private var observers: [NSObjectProtocol] = []
  private var searchTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var revision = 0
  private var restoring = true
  private var retired = false
  private var initialPage: Int?
  private let memoryKey: String
  private let root: URL
  private let accessing: Bool
  /// Coalesces bursts of highlight edits so the whole PDF is serialized once per burst
  /// rather than on every keystroke.
  private var changeTask: Task<Void, Never>?
  static let colors: [(String, NSColor)] = [
    ("Yellow", .systemYellow), ("Green", .systemGreen), ("Blue", .systemBlue),
    ("Pink", .systemPink), ("Orange", .systemOrange), ("Purple", .systemPurple),
  ]
  var pageCount: Int { document.pageCount }
  var filteredAnnotations: [ReaderAnnotation] {
    annotations.filter {
      (annotationSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(annotationSearch))
        && (annotationColor == "All" || Self.colorName($0.annotation.color) == annotationColor)
    }
  }
  fileprivate init(
    url: URL, title: String, itemID: UUID, resourceID: UUID, root: URL, library: LibraryService,
    initialPage: Int?, prepared: PreparedReaderPDF? = nil
  ) throws {
    let prepared = try prepared ?? PreparedReaderPDF(PDFEditing.read(url))
    let document = prepared.document
    self.id = resourceID
    self.itemID = itemID
    self.url = url
    self.title = title
    self.library = library
    self.document = document
    self.hash = prepared.hash
    self.root = root
    self.accessing = root.startAccessingSecurityScopedResource()
    self.initialPage = initialPage
    self.memoryKey =
      "reader." + Files.stableID(root.path).uuidString + "." + resourceID.uuidString
    if let data = UserDefaults.standard.data(forKey: memoryKey),
      let remembered = try? PortableJSON.decoder().decode(ReaderPosition.self, from: data)
    {
      page = min(max(1, remembered.page), document.pageCount)
      scale = remembered.scale
      zoomMode = remembered.zoomMode
      sidebar = remembered.sidebar
      sidebarVisible = remembered.sidebarVisible
    }
    edits.groupsByEvent = false
    pdfView.reader = self
    pdfView.document = document
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.displaysPageBreaks = true
    pdfView.minScaleFactor = 0.1
    pdfView.maxScaleFactor = 16
    buildOutline()
    refreshAnnotations()
    for name in [
      Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewSelectionChanged,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: pdfView, queue: .main) {
          [weak self] notification in
          let selectionChanged = notification.name == .PDFViewSelectionChanged
          Task { @MainActor in
            guard let self else { return }
            self.viewChanged()
            if selectionChanged && self.hasSelection {
              ReaderWorkspace.shared.toolbarReaderID = self.id
            }
          }
        })
    }
  }
  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    if accessing { root.stopAccessingSecurityScopedResource() }
  }
  func mount() {
    guard restoring else { return }
    restoring = false
    applyZoom()
    go(page: initialPage ?? page)
  }
  func viewChanged() {
    guard !restoring else { return }
    if let current = pdfView.currentPage { page = document.index(for: current) + 1 }
    if abs(appliedScale - pdfView.scaleFactor) > 0.01 {
      zoomMode = "manual"
      appliedScale = pdfView.scaleFactor
    }
    if abs(scale - pdfView.scaleFactor) > 0.001 { scale = pdfView.scaleFactor }
    hasSelection = !(pdfView.currentSelection?.string?.isEmpty ?? true)
    remember()
  }
  func remember() {
    guard !restoring, !retired else { return }
    var position = ReaderPosition()
    position.page = page
    position.scale = scale
    position.zoomMode = zoomMode
    position.sidebar = sidebar
    position.sidebarVisible = sidebarVisible
    if let data = try? PortableJSON.encoder().encode(position) {
      UserDefaults.standard.set(data, forKey: memoryKey)
    }
  }
  func go(page number: Int) {
    let index = min(max(1, number), pageCount) - 1
    if let target = document.page(at: index) {
      pdfView.go(to: target)
      page = index + 1
    }
    remember()
  }
  func showNavigation(_ section: String) {
    sidebar = section
    sidebarVisible = true
    ReaderWorkspace.shared.readerSidebarSection = "pdf"
    ReaderWorkspace.shared.metadataVisible = true
    if section == "search" { searchFocusRequest += 1 }
    remember()
  }
  func go(_ destination: PDFDestination?) {
    if let destination { pdfView.go(to: destination) }
  }
  func zoom(_ factor: Double) {
    zoomMode = "manual"
    pdfView.autoScales = false
    appliedScale = min(16, max(0.1, factor))
    pdfView.scaleFactor = appliedScale
    scale = pdfView.scaleFactor
    remember()
  }
  func rotateCurrentPage() {
    guard let page = pdfView.currentPage else { return }
    setRotation(page, to: (page.rotation + 270) % 360)
  }
  private func setRotation(_ page: PDFPage, to rotation: Int) {
    let previous = page.rotation
    page.rotation = rotation
    let group = !edits.isUndoing && !edits.isRedoing
    if group { edits.beginUndoGrouping() }
    edits.registerUndo(withTarget: self) { target in target.setRotation(page, to: previous) }
    edits.setActionName("Rotate Page")
    if group { edits.endUndoGrouping() }
    pdfView.layoutDocumentView()
    applyZoom()
    changed()
  }
  func fit(_ mode: String) {
    zoomMode = mode
    applyZoom()
    remember()
  }
  func applyZoom() {
    guard pdfView.bounds.width > 0, let current = pdfView.currentPage ?? document.page(at: 0) else {
      return
    }
    pdfView.autoScales = false
    let bounds = current.bounds(for: .cropBox)
    let width = max(0.1, (pdfView.bounds.width - 24) / max(1, bounds.width))
    let height = max(0.1, (pdfView.bounds.height - 24) / max(1, bounds.height))
    let target = zoomMode == "width" ? width : zoomMode == "page" ? min(width, height) : scale
    appliedScale = min(16, max(0.1, target))
    if abs(pdfView.scaleFactor - appliedScale) > 0.005 { pdfView.scaleFactor = appliedScale }
    if abs(scale - pdfView.scaleFactor) > 0.001 { scale = pdfView.scaleFactor }
  }
  func buildOutline() {
    func node(_ value: PDFOutline) -> ReaderOutline {
      let children = (0..<value.numberOfChildren).compactMap { value.child(at: $0) }.map(node)
      return ReaderOutline(
        label: value.label ?? "Section",
        destination: value.destination ?? (value.action as? PDFActionGoTo)?.destination,
        children: children.isEmpty ? nil : children)
    }
    outline = (0..<(document.outlineRoot?.numberOfChildren ?? 0)).compactMap {
      document.outlineRoot?.child(at: $0)
    }.map(node)
  }
  func search() {
    searchTask?.cancel()
    matches = []
    matchIndex = -1
    pdfView.highlightedSelections = nil
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searching = false
      return
    }
    searching = true
    // Search one page at a time so large documents do not freeze the reader.
    searchTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard let self, !Task.isCancelled else { return }
      var found: [PDFSelection] = []
      for index in 0..<self.document.pageCount {
        if Task.isCancelled { return }
        if let page = self.document.page(at: index), let text = page.string {
          let string = text as NSString
          var range = NSRange(location: 0, length: string.length)
          while range.length > 0 {
            let match = string.range(of: query, options: .caseInsensitive, range: range)
            if match.location == NSNotFound { break }
            if let selection = page.selection(for: match) {
              selection.color = .systemOrange.withAlphaComponent(0.35)
              found.append(selection)
            }
            let end = NSMaxRange(match)
            range = NSRange(location: end, length: string.length - end)
          }
        }
        if index % 8 == 0 { await Task.yield() }
      }
      self.matches = found
      self.searching = false
      self.pdfView.highlightedSelections = found
      if !found.isEmpty { self.showMatch(0) }
    }
  }
  func showMatch(_ index: Int) {
    guard !matches.isEmpty else { return }
    matchIndex = (index + matches.count) % matches.count
    pdfView.go(to: matches[matchIndex])
    pdfView.setCurrentSelection(matches[matchIndex], animate: true)
  }
  func highlight() {
    guard let selection = pdfView.currentSelection, !(selection.string?.isEmpty ?? true) else {
      return
    }
    var added: [(PDFPage, PDFAnnotation)] = []
    for page in selection.pages {
      let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
      let rectangles = lines.map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
      guard let first = rectangles.first else { continue }
      let bounds = rectangles.dropFirst().reduce(first) { $0.union($1) }
      let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
      annotation.quadrilateralPoints = rectangles.flatMap { rect in
        [
          CGPoint(x: rect.minX - bounds.minX, y: rect.maxY - bounds.minY),
          CGPoint(x: rect.maxX - bounds.minX, y: rect.maxY - bounds.minY),
          CGPoint(x: rect.minX - bounds.minX, y: rect.minY - bounds.minY),
          CGPoint(x: rect.maxX - bounds.minX, y: rect.minY - bounds.minY),
        ].map { NSValue(point: $0) }
      }
      annotation.color = Self.colors.first { $0.0 == highlightColor }!.1.withAlphaComponent(0.45)
      annotation.contents = lines.compactMap(\.string).joined(separator: "\n")
      annotation.modificationDate = Date()
      annotation.setValue(UUID().uuidString, forAnnotationKey: .name)
      added.append((page, annotation))
    }
    mutate(added, add: true)
    pdfView.clearSelection()
    sidebar = "annotations"
    sidebarVisible = true
  }
  func mutate(_ entries: [(PDFPage, PDFAnnotation)], add: Bool) {
    guard !entries.isEmpty else { return }
    for (page, annotation) in entries {
      if add { page.addAnnotation(annotation) } else { page.removeAnnotation(annotation) }
    }
    let group = !edits.isUndoing && !edits.isRedoing
    if group { edits.beginUndoGrouping() }
    edits.registerUndo(withTarget: self) { target in target.mutate(entries, add: !add) }
    edits.setActionName(add ? "Highlight" : "Remove Highlight")
    if group { edits.endUndoGrouping() }
    changed()
  }
  func delete(_ entry: ReaderAnnotation) {
    guard entry.kind == "Highlight" else { return }
    mutate([(entry.page, entry.annotation)], add: false)
  }
  func recolor(_ entry: ReaderAnnotation, to name: String) {
    guard entry.kind == "Highlight", let color = Self.colors.first(where: { $0.0 == name })?.1
    else { return }
    setColor(entry.annotation, color: color.withAlphaComponent(0.45))
  }
  private func setColor(_ annotation: PDFAnnotation, color: NSColor) {
    let previous = annotation.color
    annotation.color = color
    let group = !edits.isUndoing && !edits.isRedoing
    if group { edits.beginUndoGrouping() }
    edits.registerUndo(withTarget: self) { target in target.setColor(annotation, color: previous) }
    edits.setActionName("Highlight Color")
    if group { edits.endUndoGrouping() }
    changed()
  }
  func undo() {
    edits.undo()
    updateUndo()
  }
  func redo() {
    edits.redo()
    updateUndo()
  }
  private func updateUndo() {
    canUndo = edits.canUndo
    canRedo = edits.canRedo
  }
  func jump(_ entry: ReaderAnnotation) {
    selectedAnnotationID = entry.id
    pdfView.go(to: entry.annotation.bounds, on: entry.page)
  }
  func refreshAnnotations() {
    var entries: [ReaderAnnotation] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      for (offset, annotation) in page.annotations.enumerated() {
        let kind = annotation.type ?? "Annotation"
        if ["Link", "Widget", "Popup"].contains(kind) { continue }
        let id =
          annotation.value(forAnnotationKey: .name) as? String
          ?? "\(index)-\(offset)-\(annotation.bounds)"
        let text =
          annotation.contents?.isEmpty == false
          ? annotation.contents! : page.selection(for: annotation.bounds)?.string ?? kind
        entries.append(
          ReaderAnnotation(
            id: id, annotation: annotation, page: page, pageNumber: index + 1, text: text,
            kind: kind))
      }
    }
    annotations = entries
    updateUndo()
  }
  static func colorName(_ color: NSColor) -> String {
    guard let color = color.usingColorSpace(.deviceRGB) else { return "Yellow" }
    return colors.min { a, b in
      func distance(_ value: NSColor) -> Double {
        let value = value.usingColorSpace(.deviceRGB)!
        return pow(value.redComponent - color.redComponent, 2)
          + pow(value.greenComponent - color.greenComponent, 2)
          + pow(value.blueComponent - color.blueComponent, 2)
      }
      return distance(a.1) < distance(b.1)
    }!.0
  }
  func changed() {
    revision += 1
    dirty = true
    for page in (0..<document.pageCount).compactMap({ document.page(at: $0) })
    where !page.annotations.isEmpty {
      pdfView.annotationsChanged(on: page)
    }
    pdfView.documentView?.needsDisplay = true
    refreshAnnotations()
    // Serializing the whole PDF is the expensive part; do it once per burst of edits.
    changeTask?.cancel()
    changeTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard let self, !Task.isCancelled else { return }
      self.changeTask = nil
      self.startSave()
    }
  }
  /// True while highlights still need saving (false once the user abandoned them).
  var hasUnsavedWork: Bool { !retired && (dirty || saving) }
  /// Runs any debounced work now (used before flushing).
  private func settlePendingChange() {
    changeTask?.cancel()
    changeTask = nil
  }
  private func startSave() {
    guard saveTask == nil, dirty, !retired else { return }
    saving = true
    saveTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while self.dirty && !self.retired {
        let version = self.revision
        // Serialize at save time, once per pass, instead of on every edit.
        guard let data = self.document.dataRepresentation() else {
          self.error = "PDF could not be serialized"
          break
        }
        do {
          self.hash = try await self.library.savePDFAnnotations(
            itemID: self.itemID, resourceID: self.id, data: data, expectedHash: self.hash)
          if version == self.revision { self.dirty = false }
          self.error = nil
        } catch {
          self.error = error.localizedDescription
          break
        }
      }
      self.saving = false
      self.saveTask = nil
    }
  }
  func flush() async -> Bool {
    if retired { return true }
    settlePendingChange()
    if saveTask == nil && dirty { startSave() }
    await saveTask?.value
    return !dirty
  }
  func discardForDeletion() async {
    retired = true
    changeTask?.cancel(); changeTask = nil
    searchTask?.cancel()
    await saveTask?.value
    dirty = false
    edits.removeAllActions()
    UserDefaults.standard.removeObject(forKey: memoryKey)
  }
  /// The user chose to close or quit without the unsaved highlights. Any save still in
  /// flight is left to finish or fail on its own; nothing new is started.
  func abandonUnsavedChanges() {
    retired = true
    changeTask?.cancel(); changeTask = nil
    dirty = false
    edits.removeAllActions()
    remember()
  }
  /// Writes the current highlighted PDF to a location the user picks. Returns true if saved.
  func exportCopy() -> Bool {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = (title.isEmpty ? "Highlighted" : title) + " (highlighted).pdf"
    panel.message = "Save a copy of this PDF with your unsaved highlights."
    guard panel.runModal() == .OK, let destination = panel.url,
      let data = document.dataRepresentation() else { return false }
    do { try data.write(to: destination, options: .atomic); return true } catch {
      self.error = "Could not save a copy: " + error.localizedDescription
      return false
    }
  }
  func reload() {
    guard !saving else { return }
    saving = true
    Task { @MainActor in
      defer { saving = false }
      do {
        let snapshot = try await library.readPDFForReader(itemID: itemID, resourceID: id)
        let prepared = try await PreparedReaderPDF.load(snapshot)
        guard !retired else { return }
        let fresh = prepared.document
        let previousPage = page
        searchTask?.cancel()
        restoring = true
        document = fresh
        hash = snapshot.sha256
        pdfView.document = fresh
        changeTask?.cancel(); changeTask = nil
        edits.removeAllActions()
        dirty = false
        error = nil
        buildOutline()
        refreshAnnotations()
        restoring = false
        go(page: previousPage)
        applyZoom()
        if !searchText.isEmpty { search() }
      } catch { self.error = error.localizedDescription }
    }
  }

}

@MainActor final class ReaderPDFView: PDFView {
  weak var reader: ReaderDocument?
  override var undoManager: UndoManager? { reader?.edits }
  override func mouseDown(with event: NSEvent) {
    ReaderWorkspace.shared.toolbarReaderID = reader?.id
    super.mouseDown(with: event)
  }
  override func layout() {
    super.layout()
    DispatchQueue.main.async { [weak self] in self?.reader?.applyZoom() }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { reader?.mount() }
  }
  override func keyDown(with event: NSEvent) {
    let key = event.charactersIgnoringModifiers?.lowercased()
    if key == "h", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      reader?.highlight()
      return
    }
    if event.modifierFlags.contains(.command) {
      if key == "f" {
        reader?.showNavigation("search")
        return
      }
      if key == "+" || key == "=" {
        reader?.zoom((reader?.scale ?? 1) * 1.2)
        return
      }
      if key == "-" {
        reader?.zoom((reader?.scale ?? 1) / 1.2)
        return
      }
      if key == "0" {
        reader?.fit("width")
        return
      }
    }
    if key == "z", event.modifierFlags.contains(.command) {
      if event.modifierFlags.contains(.shift) { reader?.redo() } else { reader?.undo() }
      return
    }
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let highlight = NSMenuItem(
      title: "Highlight Selected Text", action: #selector(highlightText), keyEquivalent: "")
    highlight.target = self
    highlight.isEnabled = !(currentSelection?.string?.isEmpty ?? true)
    menu.addItem(highlight)
    let copy = NSMenuItem(title: "Copy", action: #selector(copyText), keyEquivalent: "")
    copy.target = self
    menu.addItem(copy)
    return menu
  }
  @objc private func highlightText() { reader?.highlight() }
  @objc private func copyText() {
    if let string = currentSelection?.string {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    }
  }
}

struct ReaderWorkspaceView: View {
  @ObservedObject var workspace: ReaderWorkspace
  var body: some View {
    VStack(spacing: 0) {
      if workspace.documents.count > 1 {
        HStack {
          ScrollView(.horizontal) {
            HStack(spacing: 6) {
              ForEach(workspace.documents) { document in
                ReaderTab(workspace: workspace, document: document).fixedSize()
              }
            }
          }
        }.padding(10)
        Divider()
      }
      if let primary = workspace.selected {
        ReaderPane(reader: primary).id(primary.id).frame(minWidth: 420)
      } else {
        ContentUnavailableView(
          "Open a paper", systemImage: "doc.richtext",
          description: Text("Open PDFs from your library to read them in tabs."))
      }
    }
  }
}

struct ReaderTab: NSViewRepresentable {
  @ObservedObject var workspace: ReaderWorkspace
  let document: ReaderDocument
  func makeNSView(context: Context) -> ReaderTabView {
    let view = ReaderTabView()
    configure(view)
    return view
  }
  func updateNSView(_ view: ReaderTabView, context: Context) { configure(view) }
  private func configure(_ view: ReaderTabView) {
    view.workspace = workspace
    view.document = document
    view.titleButton.title = document.title
    view.titleButton.toolTip = document.title
    view.closeButton.toolTip = "Close " + document.title + " (middle-click also closes)"
    view.layer?.backgroundColor =
      (workspace.selectedID == document.id
      ? NSColor.controlAccentColor.withAlphaComponent(0.18)
      : NSColor.secondaryLabelColor.withAlphaComponent(0.08)).cgColor
    view.invalidateIntrinsicContentSize()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReaderTabView, context: Context)
    -> CGSize?
  {
    nsView.intrinsicContentSize
  }
}
@MainActor final class ReaderTabView: NSView {
  weak var workspace: ReaderWorkspace?
  var document: ReaderDocument?
  let titleButton = ReaderTabButton(title: "", target: nil, action: nil)
  let closeButton = ReaderTabButton(title: "", target: nil, action: nil)
  #if DEBUG
    var middleClicks = 0
  #endif
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 7
    titleButton.isBordered = false
    titleButton.alignment = .left
    titleButton.font = .systemFont(ofSize: 13)
    titleButton.cell?.lineBreakMode = .byTruncatingTail
    titleButton.target = self
    titleButton.action = #selector(selectTab)
    closeButton.isBordered = false
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close paper")
    closeButton.imagePosition = .imageOnly
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(closeTab)
    for button in [titleButton, closeButton] {
      button.middleClick = { [weak self] in self?.middleClose() }
      addSubview(button)
    }
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  override var intrinsicContentSize: NSSize {
    NSSize(width: min(230, titleButton.intrinsicContentSize.width) + 44, height: 34)
  }
  override func layout() {
    super.layout()
    titleButton.frame = NSRect(x: 9, y: 6, width: max(0, bounds.width - 44), height: 22)
    closeButton.frame = NSRect(x: bounds.width - 26, y: 10, width: 16, height: 14)
  }
  @objc private func selectTab() { if let document { workspace?.select(document.id) } }
  @objc private func closeTab() { if let document { workspace?.close(document) } }
  func middleClose() {
    #if DEBUG
      middleClicks += 1
    #endif
    closeTab()
  }
  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { middleClose() } else { super.otherMouseDown(with: event) }
  }
}
@MainActor final class ReaderTabButton: NSButton {
  var middleClick: (() -> Void)?
  override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { middleClick?() } else { super.otherMouseDown(with: event) }
  }
}

/// Independent native toolbar items allow macOS to group controls, apply glass, and overflow
/// lower-priority actions without compressing the document identity into a custom command strip.
struct ReaderToolbar: ToolbarContent {
  @ObservedObject var reader: ReaderDocument
  let showLibrary: () -> Void
  let toggleInspector: () -> Void
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button(action: showLibrary) { Label("Publication List", systemImage: "sidebar.left") }
        .help("Show or hide the publication list")
    }
    ReaderTitleToolbarItem(reader: reader)
    ReaderToolbarFlexibleSpace()
    ToolbarItemGroup(placement: .primaryAction) {
      Button { reader.zoom(reader.scale / 1.2) } label: {
        Label("Zoom Out", systemImage: "minus.magnifyingglass")
      }.help("Zoom out")
      Button { reader.zoom(1) } label: {
        Label("Actual Size", systemImage: "1.magnifyingglass")
      }
      .contextMenu {
        Button("Actual Size") { reader.zoom(1) }
        Button("Fit Width") { reader.fit("width") }
        Button("Fit Page") { reader.fit("page") }
        Divider()
        ForEach([50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { percentage in
          Button("\(percentage)%") { reader.zoom(Double(percentage) / 100) }
        }
      }
        .help("Actual size (100%). Right-click for fit and zoom options. Current zoom: \(Int(reader.scale * 100))%")
      Button { reader.zoom(reader.scale * 1.2) } label: {
        Label("Zoom In", systemImage: "plus.magnifyingglass")
      }.help("Zoom in")
    }
    ReaderToolbarSpacer()
    ToolbarItemGroup(placement: .primaryAction) {
      Button { reader.highlight() } label: { Label("Highlight", systemImage: "highlighter") }
        .disabled(!reader.hasSelection).help("Highlight selected text (H)")
      Menu {
        ForEach(ReaderDocument.colors, id: \.0) { color in
          Button { reader.highlightColor = color.0 } label: {
            if reader.highlightColor == color.0 { Label(color.0, systemImage: "checkmark") }
            else { Text(color.0) }
          }
        }
        Divider()
        Button("Show Highlights") { reader.showNavigation("annotations") }
        Button("Undo") { reader.undo() }.disabled(!reader.canUndo)
        Button("Redo") { reader.redo() }.disabled(!reader.canRedo)
      } label: { Label("Highlight Color", systemImage: "chevron.down") }
        .menuIndicator(.hidden)
        .help("Highlight color: " + reader.highlightColor)
    }
    ReaderToolbarSpacer()
    ToolbarItem(placement: .primaryAction) {
      Button { reader.rotateCurrentPage() } label: { Label("Rotate", systemImage: "rotate.left") }
        .help("Rotate page left")
    }
    // Grouped so the builder stays within 10 children on SDKs before macOS 27.
    Group {
    ReaderToolbarSpacer()
    ToolbarItem(placement: .primaryAction) {
      Button { reader.showNavigation("annotations") } label: {
        Label("Annotations", systemImage: "pencil.tip.crop.circle")
      }.help("Show highlights and annotations")
    }
    ReaderToolbarSpacer()
    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: toggleInspector) { Label("Info", systemImage: "info.circle") }
        .help("Show or hide document information")
      ShareLink(item: reader.url) { Label("Share", systemImage: "square.and.arrow.up") }
        .help("Share PDF")
    }
    if #available(macOS 26.0, *) {
      ReaderToolbarSpacer()
      // Keep system Search in the same trailing region as the reader commands.
      // Its automatic placement inserts flexible space after those commands.
      DefaultToolbarItem(kind: .search, placement: .primaryAction)
    }
    }
  }
}

struct ReaderTitleToolbarItem: ToolbarContent {
  @ObservedObject var reader: ReaderDocument
  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .navigation) { ReaderDocumentIdentity(reader: reader) }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .navigation) { ReaderDocumentIdentity(reader: reader) }
    }
  }
}

struct ReaderToolbarFlexibleSpace: ToolbarContent {
  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarSpacer(.flexible, placement: .primaryAction)
    } else {
      ToolbarItem(placement: .principal) { Spacer() }
    }
  }
}

struct ReaderToolbarSpacer: ToolbarContent {
  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarSpacer(.fixed, placement: .primaryAction)
    } else {
      ToolbarItem(placement: .primaryAction) { Color.clear.frame(width: 8) }
    }
  }
}

struct ReaderDocumentIdentity: View {
  @ObservedObject var reader: ReaderDocument
  @State private var showingPages = false
  var body: some View {
    Button { showingPages.toggle() } label: {
      VStack(alignment: .leading, spacing: 1) {
        Text(reader.url.lastPathComponent).font(.system(size: 13, weight: .semibold))
          .lineLimit(1).truncationMode(.middle)
        Text("Page \(reader.page) of \(reader.pageCount)")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }.frame(width: 210, alignment: .leading)
    }.buttonStyle(.plain).help(reader.title + " — page navigation")
      .popover(isPresented: $showingPages) {
        VStack(alignment: .leading, spacing: 12) {
          Text(reader.title).font(.headline).lineLimit(3)
          HStack {
            Button { reader.go(page: reader.page - 1) } label: {
              Image(systemName: "chevron.left")
            }.disabled(reader.page == 1)
            ReaderPageField(reader: reader)
            Text("of \(reader.pageCount)").foregroundStyle(.secondary)
            Button { reader.go(page: reader.page + 1) } label: {
              Image(systemName: "chevron.right")
            }.disabled(reader.page == reader.pageCount)
          }
          HStack {
            Button("Back") { reader.pdfView.goBack(nil) }.disabled(!reader.pdfView.canGoBack)
            Button("Forward") { reader.pdfView.goForward(nil) }.disabled(!reader.pdfView.canGoForward)
          }
          HStack {
            Button("Pages") { reader.showNavigation("pages"); showingPages = false }
            Button("Contents") { reader.showNavigation("outline"); showingPages = false }
            Button("Find") { reader.showNavigation("search"); showingPages = false }
          }
          Text(reader.saving ? "Saving…" : reader.dirty ? "Unsaved changes" : "Saved")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 290)
      }
  }
}

struct ReaderPageField: View {
  @ObservedObject var reader: ReaderDocument
  @State private var value = ""
  var body: some View {
    TextField("Page", text: $value).frame(width: 34).textFieldStyle(.plain)
      .multilineTextAlignment(.trailing)
      .font(.caption.monospacedDigit())
      .onSubmit {
        if let page = Int(value) { reader.go(page: page) }
        value = String(reader.page)
      }
      .accessibilityLabel("Page number")
      .onAppear { value = String(reader.page) }
      .onChange(of: reader.page) { value = String(reader.page) }
  }
}

private struct LiquidGlassModifier<S: Shape>: ViewModifier {
  let shape: S
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content.background(.ultraThinMaterial, in: shape)
    }
  }
}

extension View {
  func liquidGlass<S: Shape>(in shape: S) -> some View {
    modifier(LiquidGlassModifier(shape: shape))
  }
}

struct ReaderPane: View {
  @ObservedObject var reader: ReaderDocument
  @State private var reloadConfirmation = false
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      if let error = reader.error {
        HStack {
          Text(error).font(.caption).foregroundStyle(.red)
          Button("Retry") { Task { _ = await reader.flush() } }
          Button("Reload") {
            reloadConfirmation = reader.dirty
            if !reader.dirty { reader.reload() }
          }
        }.padding(10)
      }
      ReaderPDFSurface(reader: reader).frame(maxWidth: .infinity, maxHeight: .infinity)
    }.simultaneousGesture(TapGesture().onEnded {
      ReaderWorkspace.shared.toolbarReaderID = reader.id
    })
      .onChange(of: reader.searchFocusRequest) { searchFocused = true }
      .onChange(of: reader.sidebar) { reader.remember() }
      .onChange(of: reader.searchText) { reader.search() }
      .confirmationDialog(
        "Reload and discard unsaved highlights?", isPresented: $reloadConfirmation
      ) {
        Button("Reload PDF", role: .destructive) { reader.reload() }
      } message: {
        Text("The saved PDF will be loaded. Highlights that could not be saved will be discarded.")
      }
  }
  @ViewBuilder var sidebar: some View {
    switch reader.sidebar {
    case "outline":
      if reader.outline.isEmpty {
        Text("This PDF has no table of contents.").font(.caption).foregroundStyle(.secondary)
          .padding()
        Spacer()
      } else {
        List {
          OutlineGroup(reader.outline, children: \.children) { node in
            Button(node.label) { reader.go(node.destination) }.buttonStyle(.plain)
          }
        }
      }
    case "search":
      TextField("Search this PDF", text: $reader.searchText).textFieldStyle(.roundedBorder).focused(
        $searchFocused
      ).padding(.horizontal, 8)
      HStack {
        Text(reader.searching ? "Searching…" : "\(reader.matches.count) matches").font(.caption)
        Spacer()
        Button {
          reader.showMatch(reader.matchIndex - 1)
        } label: {
          Image(systemName: "chevron.up")
        }
        Button {
          reader.showMatch(reader.matchIndex + 1)
        } label: {
          Image(systemName: "chevron.down")
        }
      }.padding(.horizontal, 8).disabled(reader.matches.isEmpty)
      List(Array(reader.matches.enumerated()), id: \.offset) { index, selection in
        Button {
          reader.showMatch(index)
        } label: {
          VStack(alignment: .leading) {
            Text("Page \((selection.pages.first.map { reader.document.index(for: $0) } ?? 0) + 1)")
              .font(.caption).foregroundStyle(.secondary)
            Text(
              selection.pages.first?.selection(
                for: selection.bounds(for: selection.pages[0]).insetBy(dx: 0, dy: -14))?.string
                ?? selection.string ?? "Match"
            ).font(.caption).lineLimit(4)
          }.padding(4).background(
            reader.matchIndex == index ? Color.accentColor.opacity(0.12) : Color.clear)
        }.buttonStyle(.plain)
      }
      if !reader.searching, reader.matches.isEmpty, !reader.searchText.isEmpty {
        Text("Scanned pages without selectable text can be searched from the library’s OCR index.")
          .font(.caption).foregroundStyle(.secondary).padding(8)
      }
    case "annotations":
      TextField("Search annotations", text: $reader.annotationSearch).textFieldStyle(.roundedBorder)
        .padding(.horizontal, 8)
      Picker("Color", selection: $reader.annotationColor) {
        Text("All colors").tag("All")
        ForEach(ReaderDocument.colors, id: \.0) { Text($0.0).tag($0.0) }
      }.padding(.horizontal, 8)
      if reader.filteredAnnotations.isEmpty {
        Text("Select text and press H to highlight it.").font(.caption).foregroundStyle(.secondary)
          .padding(8)
      }
      List(reader.filteredAnnotations) { entry in
        Button {
          reader.jump(entry)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Circle().fill(Color(nsColor: entry.annotation.color)).frame(width: 9, height: 9)
              Text("Page \(entry.pageNumber) · \(entry.kind)").font(.caption).foregroundStyle(
                .secondary)
            }
            Text(entry.text).font(.caption).lineLimit(6)
          }.padding(4).background(
            reader.selectedAnnotationID == entry.id ? Color.accentColor.opacity(0.1) : Color.clear)
        }.buttonStyle(.plain).contextMenu {
          if entry.kind == "Highlight" {
            Menu("Change color") {
              ForEach(ReaderDocument.colors, id: \.0) { color in
                Button(color.0) { reader.recolor(entry, to: color.0) }
              }
            }
            Button("Delete highlight", role: .destructive) { reader.delete(entry) }
          }
          Button("Copy text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
          }
        }
      }
    default:
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(0..<reader.pageCount, id: \.self) { index in
            ReaderPageThumbnail(reader: reader, index: index)
          }
        }.padding(10)
      }
    }
  }
}
struct ReaderPageThumbnail: View {
  @ObservedObject var reader: ReaderDocument
  let index: Int
  @State private var image: NSImage?
  var body: some View {
    Button {
      reader.go(page: index + 1)
    } label: {
      VStack {
        if let image {
          Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
        } else {
          ProgressView().frame(width: 130, height: 180)
        }
        Text("\(index + 1)").font(.caption)
      }.padding(5).background(
        reader.page == index + 1 ? Color.accentColor.opacity(0.15) : Color.clear,
        in: RoundedRectangle(cornerRadius: 5))
    }.buttonStyle(.plain).task {
      image = ReaderThumbnailCache.shared.image(for: reader, page: index)
    }
  }
}
@MainActor final class ReaderThumbnailCache {
  static let shared = ReaderThumbnailCache()
  private let maximumBytes = 250 * 1024 * 1024
  private let memory = NSCache<NSString, NSImage>()
  private let root: URL
  private init() {
    root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ResearchLibrary/Thumbnails", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    memory.countLimit = 160
  }
  func image(for reader: ReaderDocument, page index: Int) -> NSImage? {
    let key = reader.hash + "-" + String(index)
    if let image = memory.object(forKey: key as NSString) { return image }
    let file = root.appendingPathComponent(key).appendingPathExtension("png")
    if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
      memory.setObject(image, forKey: key as NSString)
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return image
    }
    guard let image = reader.document.page(at: index)?.thumbnail(
      of: NSSize(width: 170, height: 230), for: .cropBox) else { return nil }
    memory.setObject(image, forKey: key as NSString)
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) {
      try? png.write(to: file, options: .atomic)
      pruneIfNeeded()
    }
    return image
  }
  private func pruneIfNeeded() {
    let manager = FileManager.default
    guard let files = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
    let records = files.compactMap { file -> (URL, Int, Date)? in
      guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
      return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }
    var total = records.reduce(0) { $0 + $1.1 }
    for record in records.sorted(by: { $0.2 < $1.2 }) where total > maximumBytes {
      try? manager.removeItem(at: record.0)
      total -= record.1
    }
  }
}
struct ReaderPDFSurface: NSViewRepresentable {
  @ObservedObject var reader: ReaderDocument
  func makeNSView(context: Context) -> ReaderPDFView { reader.pdfView }
  func updateNSView(_ view: ReaderPDFView, context: Context) {}
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReaderPDFView, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
  }
}

#if DEBUG
  /// Runs against disposable fixtures only; never opens the user's archive.
  @MainActor enum ReaderSmokeTest {
    static func run(report: URL, model: LibraryModel) async {
      model.worker?.cancel()
      model.processor?.cancel()
      model.searchTask?.cancel()
      var checks: [String] = []
      do {
        func check(_ value: Bool, _ name: String) throws {
          guard value else { throw LibraryError.invalid("Reader check failed: " + name) }
          checks.append(name)
          try JSONSerialization.data(
            withJSONObject: ["running": true, "checks": checks], options: .prettyPrinted
          ).write(to: report)
        }
        let root = report.deletingLastPathComponent().appendingPathComponent(
          "ReaderFixtures-" + UUID().uuidString)
        model.open(root)
        model.scope = "All Items"
        model.worker?.cancel()
        model.processor?.cancel()
        model.searchTask?.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let library = model.library!
        func fixture(_ title: String) async throws -> ResearchCore.LibraryItem {
          var item = ResearchCore.LibraryItem(title: title)
          let path = "PDFs/" + item.id.uuidString + ".pdf"
          let url = root.appendingPathComponent(path)
          var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
          let data = NSMutableData()
          let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
          for number in 1...3 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(
              string:
                "\(title)\n\nSection \(number)\n\nMicroglia regulate lipid metabolism.\nThis selectable text tests highlights and search.\n\nPage \(number) of three.",
              attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]
            ).draw(in: CGRect(x: 48, y: 430, width: 516, height: 310))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
          }
          context.closePDF()
          let document = PDFDocument(data: data as Data)!
          let outline = PDFOutline()
          for number in 0..<3 {
            let section = PDFOutline()
            section.label = "Section \(number + 1)"
            section.destination = PDFDestination(
              page: document.page(at: number)!, at: CGPoint(x: 0, y: 792))
            outline.insertChild(section, at: number)
          }
          document.outlineRoot = outline
          guard document.write(to: url) else {
            throw LibraryError.invalid("Fixture PDF write failed")
          }
          var resource = Resource(itemID: item.id, type: .pdf, path: path, availability: .local)
          resource.sha256 = try Files.hash(url)
          item.resources = [resource]
          try await library.edit(item)
          return item
        }
        let first = try await fixture("Microglial lipid metabolism")
        let second = try await fixture("Comparative cellular response")
        let workspace = ReaderWorkspace.shared
        let mainWindow = NSApp.windows.first { $0.isVisible }
        let existingWindows = Set(
          NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.map {
            ObjectIdentifier($0)
          })
        model.results = [RetrievalResult(item: first), RetrievalResult(item: second)]
        let firstURL = root.appendingPathComponent(first.resources[0].relativePath!)
        if ProcessInfo.processInfo.environment["RESEARCH_LIBRARY_TOOLBAR_TEST"] == "1" {
          try await workspace.open(url: firstURL, title: first.title, itemID: first.id,
            resourceID: first.resources[0].id, root: root, library: library, initialPage: 1)
          workspace.window?.setContentSize(NSSize(width: 1400, height: 850))
          try await Task.sleep(for: .milliseconds(600))
          let reader = workspace.selected!
          try check(workspace.window?.toolbarStyle == .unified, "Full-size unified toolbar")
          try check(workspace.window?.titlebarAppearsTransparent == false, "System-managed titlebar backdrop")
          if let window = workspace.window {
            let pdfFrame = reader.pdfView.convert(reader.pdfView.bounds, to: nil)
            try check(pdfFrame.maxY <= window.contentLayoutRect.maxY + 2,
              "PDF stays below the toolbar content boundary")
          }
          let previousListVisibility = UserDefaults.standard.object(forKey: "libraryListVisible")
          defer { UserDefaults.standard.set(previousListVisibility, forKey: "libraryListVisible") }
          UserDefaults.standard.set(true, forKey: "libraryListVisible")
          try await Task.sleep(for: .milliseconds(250))
          try check(LibraryPanePresence.mounted.contains("navigation")
            && LibraryPanePresence.mounted.contains("library"), "Navigation rail and publication list visible")
          UserDefaults.standard.set(false, forKey: "libraryListVisible")
          try await Task.sleep(for: .milliseconds(250))
          try check(LibraryPanePresence.mounted.contains("navigation")
            && !LibraryPanePresence.mounted.contains("library"), "Hiding publication list keeps navigation rail")
          try check(workspace.selected?.id == reader.id, "Hiding publication list preserves active PDF")
          UserDefaults.standard.set(true, forKey: "libraryListVisible")
          try await Task.sleep(for: .milliseconds(250))
          try check(LibraryPanePresence.mounted.contains("library"), "Publication list reopens")
          let page = reader.document.page(at: 0)!
          let rotation = page.rotation
          reader.rotateCurrentPage()
          try check(page.rotation == (rotation + 270) % 360, "Rotate page")
          reader.undo()
          try check(page.rotation == rotation, "Undo rotation")
          try check(await reader.flush(), "Save rotation undo")
          reader.pdfView.setCurrentSelection(page.selection(for:
            (page.string! as NSString).range(of: "Microglia regulate lipid metabolism.")), animate: false)
          reader.highlight()
          try check(reader.annotations.count == 1, "Direct highlight action")
          try check(await reader.flush(), "Persist highlight")
          reader.undo()
          try check(await reader.flush(), "Persist highlight undo")
          reader.searchText = "lipid metabolism"
          reader.search()
          try await Task.sleep(for: .milliseconds(600))
          try check(!reader.matches.isEmpty, "Find in PDF")
          reader.searchText = ""
          reader.search()
          reader.fit("width")
          try await Task.sleep(for: .milliseconds(400))
          if let view = workspace.window?.contentView?.superview,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
              to: report.deletingPathExtension().appendingPathExtension("png"))
          }
          try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks],
            options: .prettyPrinted).write(to: report)
          NSApp.terminate(nil)
          return
        }
        workspace.simulatedDownloads[firstURL] = 2
        model.selection = model.results[0].id
        try await Task.sleep(for: .milliseconds(150))
        try check(
          !workspace.downloads.isEmpty && model.message == nil,
          "Cloud download shows progress without an alert")
        try await Task.sleep(for: .milliseconds(650))
        try check(
          workspace.downloads.isEmpty && model.message == nil,
          "Cloud download opens automatically after one selection")
        try check(
          workspace.isPresented && workspace.selected?.itemID == first.id,
          "Selecting a library row opens its PDF by default")
        try check(!workspace.metadataVisible, "Metadata sidebar is hidden by default")
        let secondURL = root.appendingPathComponent(second.resources[0].relativePath!)
        workspace.simulatedDownloads[secondURL] = 3
        model.selection = RetrievalResult(item: second).id
        try await Task.sleep(for: .milliseconds(100))
        model.selection = RetrievalResult(item: first).id
        try await Task.sleep(for: .milliseconds(400))
        try check(
          workspace.selected?.itemID == first.id && workspace.documents.count == 1
            && workspace.downloads.isEmpty,
          "An obsolete download cannot replace a newer selection")
        workspace.simulatedDownloads[secondURL] = nil
        model.selection = RetrievalResult(item: second).id
        try await Task.sleep(for: .milliseconds(250))
        try check(
          workspace.documents.count == 1 && workspace.selected?.itemID == second.id,
          "Normal selection replaces the current PDF")
        model.selection = RetrievalResult(item: first).id
        try await Task.sleep(for: .milliseconds(250))
        try check(
          workspace.documents.count == 1 && workspace.selected?.itemID == first.id,
          "Repeated normal selections keep one tab")
        func rowViews(_ view: NSView) -> [PDFRowMouseView] {
          (view as? PDFRowMouseView).map { [$0] } ?? view.subviews.flatMap(rowViews)
        }
        if let content = mainWindow?.contentView,
          let row = rowViews(content).first(where: {
            $0.itemID == second.id && !$0.visibleRect.isEmpty
          }),
          let window = mainWindow
        {
          let point = row.convert(
            NSPoint(x: row.visibleRect.midX, y: row.visibleRect.midY), to: nil)
          let event = NSEvent.mouseEvent(
            with: .otherMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: 1)!
          let cg = event.cgEvent!
          cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
          NSApp.postEvent(NSEvent(cgEvent: cg)!, atStart: true)
          try await Task.sleep(for: .milliseconds(350))
          try check(
            workspace.documents.count == 2 && workspace.selected?.itemID == second.id,
            "Middle mouse click opens a new tab without replacing the current PDF")
        } else {
          throw LibraryError.invalid("Middle-click fixture row is not visible")
        }
        if let content = mainWindow?.contentView,
          let row = rowViews(content).first(where: {
            $0.itemID == first.id && !$0.visibleRect.isEmpty
          }),
          let window = mainWindow
        {
          let point = row.convert(
            NSPoint(x: row.visibleRect.midX, y: row.visibleRect.midY), to: nil)
          for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(
              NSEvent.mouseEvent(
                with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1,
                pressure: 1)!, atStart: false)
          }
          try await Task.sleep(for: .milliseconds(300))
          try check(
            workspace.documents.count == 2 && workspace.selected?.itemID == first.id,
            "Normal click on the already-selected row reactivates its PDF")
        } else {
          throw LibraryError.invalid("Normal-click fixture row is not visible")
        }
        model.openPDF(first, inNewTab: true)
        try await Task.sleep(for: .milliseconds(200))
        try check(
          workspace.documents.count == 2 && workspace.selected?.itemID == first.id,
          "Explicit tab action reuses an already-open PDF")
        for item in [first, second] {
          let resource = item.resources[0]
          try await workspace.open(
            url: root.appendingPathComponent(resource.relativePath!), title: item.title,
            itemID: item.id, resourceID: resource.id, root: root, library: library,
            initialPage: nil, inNewTab: true
          )
        }
        try await Task.sleep(for: .milliseconds(500))
        let reader = workspace.documents[0]
        workspace.select(reader.id)
        reader.go(page: 3)
        try await Task.sleep(for: .milliseconds(150))
        try check(reader.page == 3, "Page navigation")
        if reader.outline.isEmpty {
          let rootOutline = PDFOutline()
          let section = PDFOutline()
          section.label = "Results"
          section.destination = PDFDestination(
            page: reader.document.page(at: 2)!, at: CGPoint(x: 0, y: 792))
          rootOutline.insertChild(section, at: 0)
          reader.document.outlineRoot = rootOutline
          reader.buildOutline()
        }
        try check(!reader.outline.isEmpty, "Outline navigation")
        reader.go(reader.outline.last?.destination)
        reader.zoom(1.5)
        try check(abs(reader.pdfView.scaleFactor - 1.5) < 0.01, "Manual zoom")
        let rotationPage = reader.pdfView.currentPage!
        let originalRotation = rotationPage.rotation
        reader.rotateCurrentPage()
        try check(rotationPage.rotation == (originalRotation + 270) % 360, "Toolbar page rotation")
        reader.undo()
        try check(rotationPage.rotation == originalRotation, "Undo page rotation")
        try check(await reader.flush(), "Save page rotation and undo")
        reader.fit("page")
        let fittedPage = reader.document.page(at: reader.page - 1)!.bounds(for: .cropBox)
        let horizontalSpace = reader.pdfView.bounds.width - fittedPage.width * reader.scale
        let verticalSpace = reader.pdfView.bounds.height - fittedPage.height * reader.scale
        try check(reader.scale > 0 && horizontalSpace >= 23 && verticalSpace >= 23
          && min(horizontalSpace, verticalSpace) < 25, "Fit page")
        reader.searchText = "lipid metabolism"
        reader.search()
        try await Task.sleep(for: .milliseconds(700))
        try check(reader.matches.count == 6, "Search matches across pages")
        reader.showMatch(3)
        try check(reader.matchIndex == 3, "Search result navigation")
        let page = reader.document.page(at: 2)!
        let selection = page.selection(
          for: (page.string! as NSString).range(
            of:
              "Microglia regulate lipid metabolism.\nThis selectable text tests highlights and search."
          ))!
        reader.pdfView.setCurrentSelection(selection, animate: false)
        reader.highlight()
        try check(reader.annotations.count == 1, "Create multiline highlight")
        try check(
          reader.annotations[0].annotation.quadrilateralPoints?.count == 8,
          "Highlight covers both text lines")
        try check(await reader.flush(), "Save highlight")
        try check(
          PDFDocument(url: reader.url)!.page(at: 2)!.annotations.contains {
            $0.type == "Highlight"
          }, "Highlight persisted in PDF")
        reader.annotationSearch = "microglia"
        try check(reader.filteredAnnotations.count == 1, "Search annotations")
        reader.recolor(reader.annotations[0], to: "Green")
        try check(await reader.flush(), "Save highlight color")
        reader.annotationColor = "Green"
        try check(reader.filteredAnnotations.count == 1, "Filter annotations by color")
        reader.undo()
        try check(await reader.flush(), "Undo persisted")
        try check(
          ReaderDocument.colorName(reader.annotations.first?.annotation.color ?? .clear)
            == "Yellow",
          "Undo restores color")
        reader.redo()
        try check(await reader.flush(), "Redo persisted")
        try check(
          ReaderDocument.colorName(reader.annotations.first?.annotation.color ?? .clear) == "Green",
          "Redo restores color")
        reader.reload()
        try await Task.sleep(for: .milliseconds(300))
        try check(
          reader.annotations.count == 1 && !reader.dirty && reader.error == nil,
          "Reload saved annotations")
        reader.delete(reader.annotations[0])
        try check(await reader.flush() && reader.annotations.isEmpty, "Delete highlight persisted")
        reader.undo()
        try check(await reader.flush() && reader.annotations.count == 1, "Undo deletion persisted")
        reader.go(page: 3)
        reader.zoom(1.25)
        reader.sidebar = "annotations"
        reader.remember()
        let restored = try ReaderDocument(
          url: reader.url, title: reader.title, itemID: reader.itemID,
          resourceID: reader.id, root: root, library: library, initialPage: nil)
        try check(
          restored.page == 3 && abs(restored.scale - 1.25) < 0.01
            && restored.sidebar == "annotations", "Reading memory restored")
        reader.fit("width")
        reader.annotationSearch = ""
        try await Task.sleep(for: .milliseconds(600))
        try check(
          workspace.documents.count == 2 && workspace.documents[1].pdfView !== reader.pdfView,
          "Independent PDFs remain separate tabs")
        try check(
          mainWindow != nil && workspace.window === mainWindow
            && reader.pdfView.window === mainWindow,
          "The active PDF uses the main app window")
        try check(
          Set(
            NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.map {
              ObjectIdentifier($0)
            }
          ).isSubset(of: existingWindows), "No separate reader window created")
        workspace.isPresented = false
        try await Task.sleep(for: .milliseconds(200))
        try check(
          workspace.documents.count == 2 && mainWindow?.isVisible == true,
          "Return to library retains reader tabs")
        workspace.showWindow()
        try await Task.sleep(for: .milliseconds(300))
        try check(reader.pdfView.window === mainWindow, "Return to reader in the same window")
        workspace.metadataVisible = true
        try await Task.sleep(for: .milliseconds(500))
        try check(
          workspace.metadataDisplayedItemID == first.id && reader.pdfView.window === mainWindow,
          "Metadata opens beside the PDF")
        workspace.select(workspace.documents[1].id)
        try await Task.sleep(for: .milliseconds(350))
        try check(
          workspace.metadataDisplayedItemID == second.id, "Metadata follows the active reader tab")
        workspace.metadataVisible = false
        try await Task.sleep(for: .milliseconds(150))
        try check(
          workspace.documents.count == 2 && workspace.selected?.itemID == second.id,
          "Closing metadata keeps the active PDF and tabs")
        var urlOnly = ResearchCore.LibraryItem(title: "Article without an attached PDF")
        urlOnly.canonicalURL = "https://example.com/article"
        try await library.edit(urlOnly)
        model.results.append(RetrievalResult(item: urlOnly))
        model.selection = RetrievalResult(item: urlOnly).id
        try await Task.sleep(for: .milliseconds(200))
        try check(
          !workspace.isPresented && model.selected?.item.id == urlOnly.id,
          "URL-only selection shows the PDF unavailable view")
        model.selection = RetrievalResult(item: first).id
        try await Task.sleep(for: .milliseconds(250))
        try check(
          workspace.isPresented && workspace.selected?.itemID == first.id,
          "Selecting another paper restores the reader")
        let replacement = try await fixture("Replacement paper")
        let active = workspace.selected!
        let markedPage = active.document.page(at: 0)!
        active.pdfView.setCurrentSelection(
          markedPage.selection(for: (markedPage.string! as NSString).range(of: "Microglia")),
          animate: false)
        active.highlight()
        let resource = replacement.resources[0]
        try await workspace.open(
          url: root.appendingPathComponent(resource.relativePath!), title: replacement.title,
          itemID: replacement.id, resourceID: resource.id, root: root, library: library,
          initialPage: nil)
        try check(
          workspace.documents.count == 2 && workspace.selected?.itemID == replacement.id,
          "Replacement preserves the other explicitly opened tab")
        try check(
          PDFDocument(url: active.url)!.page(at: 0)!.annotations.contains {
            $0.type == "Highlight"
          },
          "Pending highlight is saved before replacing the tab")
        model.openPDF(first)
        try await Task.sleep(for: .milliseconds(300))
        let cloudA = try await fixture("Cloud paper A")
        let cloudB = try await fixture("Cloud paper B")
        let cloudURLA = root.appendingPathComponent(cloudA.resources[0].relativePath!)
        let cloudURLB = root.appendingPathComponent(cloudB.resources[0].relativePath!)
        for item in [cloudA, cloudB] {
          workspace.simulatedDownloads[
            root.appendingPathComponent(item.resources[0].relativePath!)] = 2
          model.openPDF(item, inNewTab: true)
        }
        try await Task.sleep(for: .milliseconds(150))
        try check(workspace.downloads.count == 2, "Independent explicit tabs can download together")
        try await Task.sleep(for: .milliseconds(650))
        try check(
          workspace.documents.count == 4 && workspace.selected?.itemID == cloudB.id
            && workspace.downloads.isEmpty,
          "Concurrent cloud tabs both open without stealing later focus")
        func tabViews(_ view: NSView) -> [ReaderTabView] {
          (view as? ReaderTabView).map { [$0] } ?? view.subviews.flatMap(tabViews)
        }
        func middleClickTab(_ document: ReaderDocument) async throws {
          try await Task.sleep(for: .milliseconds(150))
          guard let content = mainWindow?.contentView,
            let tab = tabViews(content).first(where: {
              $0.document?.id == document.id && !$0.visibleRect.isEmpty
            }),
            let window = mainWindow
          else { throw LibraryError.invalid("Middle-close fixture tab is not visible") }
          let point = tab.convert(
            NSPoint(x: tab.visibleRect.midX, y: tab.visibleRect.midY), to: nil)
          let event = NSEvent.mouseEvent(
            with: .otherMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
          let cg = event.cgEvent!
          cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
          let before = tab.middleClicks
          workspace.lastMiddleHit = nil
          NSApp.postEvent(NSEvent(cgEvent: cg)!, atStart: true)
          for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if !workspace.documents.contains(where: { $0.id == document.id }) { break }
          }
          guard tab.middleClicks > before else {
            throw LibraryError.invalid(
              "Tab middle click was not delivered; hidden=\(tab.isHidden), ancestors=\(tab.superview?.isHiddenOrHasHiddenAncestor ?? false), window=\(tab.window === mainWindow), hit=\(workspace.lastMiddleHit?.uuidString ?? "none"), expected=\(document.id), frame=\(tab.frame), bounds=\(tab.bounds), point=\(point), remaining=\(workspace.documents.map(\.title))"
            )
          }
          if workspace.documents.contains(where: { $0.id == document.id }) {
            throw LibraryError.invalid("Tab did not close: " + (document.error ?? "no save error"))
          }
        }
        let closing = workspace.documents.first!
        workspace.select(closing.id)
        let closingPage = closing.document.page(at: 0)!
        closing.pdfView.setCurrentSelection(
          closingPage.selection(
            for: (closingPage.string! as NSString).range(of: "This selectable text")),
          animate: false)
        closing.highlight()
        try await middleClickTab(closing)
        try check(
          workspace.documents.count == 3 && !workspace.documents.contains { $0.id == closing.id },
          "Middle click closes the active tab")
        try check(
          PDFDocument(url: closing.url)!.page(at: 0)!.annotations.contains {
            $0.contents?.contains("This selectable text") == true
          },
          "Middle close saves pending highlights")
        let inactive = workspace.documents.first { $0.itemID == cloudA.id }!
        let selectedID = workspace.selectedID
        try await middleClickTab(inactive)
        try check(
          workspace.documents.count == 2 && workspace.selectedID == selectedID,
          "Middle click closes an inactive tab without changing the active PDF")
        if let other = workspace.documents.first(where: { $0.id != workspace.selectedID }) {
          workspace.close(other)
          try await Task.sleep(for: .milliseconds(200))
        }
        try await middleClickTab(workspace.selected!)
        try check(
          workspace.documents.isEmpty && !workspace.isPresented,
          "Middle click can close the last tab")
        try await workspace.open(
          url: cloudURLA, title: cloudA.title, itemID: cloudA.id,
          resourceID: cloudA.resources.first!.id, root: root, library: library,
          initialPage: nil, inNewTab: true)
        let deletingReader = workspace.selected!
        deletingReader.pdfView.setCurrentSelection(
          deletingReader.document.page(at: 0)!.selection(for: NSRange(location: 0, length: 10)),
          animate: false)
        deletingReader.highlight()
        model.permanentlyDelete(cloudA)
        for _ in 0..<20 {
          if !model.busy { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        try check(
          !model.busy && model.message == nil
            && !workspace.documents.contains { $0.itemID == cloudA.id },
          "Permanent deletion removes an open reader with pending highlights")
        let deletedCloudItem = try await library.item(cloudA.id)
        try check(
          !FileManager.default.fileExists(atPath: cloudURLA.path) && deletedCloudItem == nil,
          "Permanent deletion removes the PDF and library record")
        workspace.simulatedDownloads[cloudURLB] = 3
        let pendingDeletionOpen = Task { @MainActor in
          try await workspace.open(
            url: cloudURLB, title: cloudB.title, itemID: cloudB.id,
            resourceID: cloudB.resources.first!.id, root: root, library: library, initialPage: nil,
            inNewTab: true)
        }
        try await Task.sleep(for: .milliseconds(150))
        model.permanentlyDelete(cloudB)
        try await pendingDeletionOpen.value
        for _ in 0..<20 {
          if !model.busy { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        try check(
          !model.busy && model.message == nil && workspace.downloads.isEmpty
            && !workspace.documents.contains { $0.itemID == cloudB.id },
          "A pending cloud tab cannot reopen a permanently deleted article")
        model.openPDF(first)
        try await Task.sleep(for: .milliseconds(300))
        workspace.selected?.go(page: 3)
        let refreshInput = root.appendingPathComponent("Inbox/toolbar-refresh.pdf")
        try FileManager.default.copyItem(at: workspace.selected!.url, to: refreshInput)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5)], ofItemAtPath: refreshInput.path)
        let readingBeforeRefresh = workspace.selectedID
        model.refreshInbox()
        for _ in 0..<60 {
          if !model.busy { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        let refreshedRequests = try await library.requests()
        try check(!model.busy && model.message == nil && refreshedRequests.contains {
          $0.source == "hotFolder" && $0.inputFile == "Inbox/toolbar-refresh.pdf" && $0.state == .complete
        } && !FileManager.default.fileExists(atPath: refreshInput.path),
          "Toolbar refresh discovers and processes a hot-folder PDF")
        try check(workspace.selectedID == readingBeforeRefresh,
          "Refreshing the Inbox preserves the active reader")
        workspace.metadataVisible = true
        try await Task.sleep(for: .milliseconds(350))
        if let view = workspace.window?.contentView?.superview,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
          view.cacheDisplay(in: view.bounds, to: bitmap)
          try bitmap.representation(using: .png, properties: [:])!.write(
            to: report.deletingPathExtension().appendingPathExtension("png"))
        }
        let result: [String: Any] = ["passed": true, "checks": checks, "fixtures": root.path]
        try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(
          to: report)
      } catch {
        let result: [String: Any] = [
          "passed": false, "checks": checks, "error": error.localizedDescription,
        ]
        try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(
          to: report)
      }
      NSApp.terminate(nil)
    }
  }
#endif

/// Handle PDF row clicks while preserving native selection and context menus.
/// A native button remains independently actionable inside a selectable SwiftUI List row.
struct PDFMatchingPagesToggle: NSViewRepresentable {
  @Binding var expanded: Bool
  final class Coordinator: NSObject {
    var toggle: (() -> Void)?
    @objc func press() { toggle?() }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: "Matching PDF pages", target: context.coordinator, action: #selector(Coordinator.press))
    button.isBordered = false
    button.alignment = .left
    button.imagePosition = .imageLeading
    button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    button.setAccessibilityLabel("Matching PDF pages")
    return button
  }
  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.toggle = { expanded.toggle() }
    button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
  }
}

struct PDFRowControlsRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { PDFRowControlsView() }
  func updateNSView(_ view: NSView, context: Context) {}
}
final class PDFRowControlsView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct PDFRowMouseHandler: NSViewRepresentable {
  let itemID: UUID
  let openCurrent: () -> Void
  let openInTab: () -> Void
  var controlHit: (() -> Void)? = nil
  func makeNSView(context: Context) -> NSView {
    let view = PDFRowMouseView()
    view.itemID = itemID
    view.openCurrent = openCurrent
    view.openInTab = openInTab
    view.controlHit = controlHit
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    (view as? PDFRowMouseView)?.itemID = itemID
    (view as? PDFRowMouseView)?.openCurrent = openCurrent
    (view as? PDFRowMouseView)?.openInTab = openInTab
    (view as? PDFRowMouseView)?.controlHit = controlHit
  }
}
@MainActor final class PDFRowMouseView: NSView {
  var itemID: UUID?
  #if DEBUG
    var middleClicks = 0
  #endif
  var openCurrent: (() -> Void)?
  var openInTab: (() -> Void)?
  var controlHit: (() -> Void)?
  private var monitor: Any?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  static func isControlRegion(_ point: NSPoint, in view: NSView) -> Bool {
    if view.isHiddenOrHasHiddenAncestor { return false }
    if view is PDFRowControlsView && view.visibleRect.contains(view.convert(point, from: nil)) { return true }
    return view.subviews.contains { isControlRegion(point, in: $0) }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .leftMouseDown]) {
      [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, event.window === self.window,
          !self.isHiddenOrHasHiddenAncestor,
          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
        else { return false }
        if let content = self.window?.contentView,
          Self.isControlRegion(event.locationInWindow, in: content) {
          if event.type == .leftMouseDown { self.controlHit?() }
          return false
        }
        if event.type == .leftMouseDown, event.buttonNumber == 0,
          !event.modifierFlags.contains(.control)
        {
          self.openCurrent?()
          return false
        }
        guard event.buttonNumber == 2 else { return false }
        #if DEBUG
          self.middleClicks += 1
          ReaderWorkspace.shared.lastMiddleHit = self.itemID
        #endif
        self.openInTab?()
        return true
      }
      return handled ? nil : event
    }
  }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
