import AppIntents
import ResearchCore
import SwiftUI
import UniformTypeIdentifiers

typealias ViewState<Value> = SwiftUI.State<Value>

@main struct ResearchLibraryCaptureApp: App {
  var body: some Scene { WindowGroup { CaptureScreen() } }
}
struct CaptureScreen: View {
  @ViewState<String> private var input = ""
  @ViewState<String> private var collection = ""
  @ViewState<String> private var tags = ""
  @ViewState<String> private var note = ""
  @ViewState<String> private var status =
    "Choose the same iCloud Drive library folder used on your Mac."
  @ViewState<Bool> private var chooseFolder = false
  @ViewState<Bool> private var choosePDF = false
  @ViewState<Bool> private var configured = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Library") {
          Button("Choose Library Folder") { chooseFolder = true }
          Text(status).font(.caption)
        }
        Section("Capture") {
          TextField("URL, DOI, PMID, or text", text: $input, axis: .vertical)
            .textInputAutocapitalization(.never).accessibilityIdentifier("captureInput")
          TextField("Collection", text: $collection).accessibilityIdentifier("captureCollection")
          TextField("Tags (comma separated)", text: $tags).accessibilityIdentifier("captureTags")
          TextField("Note", text: $note, axis: .vertical)
          Button("Save to Inbox") { capture() }.disabled(!configured || input.isEmpty)
            .accessibilityIdentifier("captureSave")
          Button("Capture File") { choosePDF = true }.disabled(!configured)
        }
        Section {
          Text(
            "Capture stays in your portable Inbox. Your Mac enriches metadata and indexes documents. An article without a PDF is a valid library item."
          )
        }
      }.navigationTitle("Research Library")
    }
    .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        _ = try SidecarService(root: url)
        try LibraryAccess.store(url)
        configured = true
        status = "Library folder selected."
      } catch { status = error.localizedDescription }
    }
    .fileImporter(isPresented: $choosePDF, allowedContentTypes: [.data, .pdf]) { result in
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let root = try LibraryAccess.restore() else { throw LibraryError.missingLibrary }
        let rootAccess = root.startAccessingSecurityScopedResource()
        defer { if rootAccess { root.stopAccessingSecurityScopedResource() } }
        let service = try SidecarService(root: root)
        var request = makeRequest()
        request.suggestedTitle = url.deletingPathExtension().lastPathComponent
        let target = root.appendingPathComponent(
          "Inbox/\(request.id)-" + Files.sanitized(url.lastPathComponent))
        try Files.coordinatedRead(url) { try Files.atomicWrite(Data(contentsOf: $0), to: target) }
        request.inputFile = "Inbox/" + target.lastPathComponent
        try service.saveRequest(request)
        status = "File saved to Inbox."
      } catch { status = error.localizedDescription }
    }
    .task {
      #if DEBUG
        if ProcessInfo.processInfo.environment["RESEARCH_LIBRARY_UI_TEST"] == "1" {
          do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("UITestLibrary")
            _ = try SidecarService(root: root)
            try LibraryAccess.store(root)
          } catch { status = error.localizedDescription }
        }
      #endif
      configured = (try? LibraryAccess.restore()) != nil
      if configured { status = "Library folder selected." }
    }
  }
  func makeRequest() -> IngestionRequest {
    var r = IngestionRequest(source: "iOS", text: input.isEmpty ? nil : input)
    r.suggestedCollection = collection.isEmpty ? nil : collection
    r.suggestedTags = tags.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    r.note = note
    return r
  }
  func capture() {
    do {
      guard let root = try LibraryAccess.restore() else { throw LibraryError.missingLibrary }
      let access = root.startAccessingSecurityScopedResource()
      defer { if access { root.stopAccessingSecurityScopedResource() } }
      try SidecarService(root: root).saveRequest(makeRequest())
      status = "Saved to Inbox."
      input = ""
      note = ""
    } catch { status = error.localizedDescription }
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
