import AppIntents
import ResearchCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

typealias ViewState<Value> = SwiftUI.State<Value>

final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(
      rootView: ShareCaptureView(
        save: { [weak self] collection, tags, note in
          await self?.save(collection: collection, tags: tags, note: note)
        },
        cancel: { [weak self] in
          self?.extensionContext?.cancelRequest(withError: LibraryError.invalid("Cancelled"))
        }))
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
  }
  @MainActor func save(collection: String, tags: String, note: String) async {
    do {
      guard let root = try LibraryAccess.restore() else { throw LibraryError.missingLibrary }
      let access = root.startAccessingSecurityScopedResource()
      defer { if access { root.stopAccessingSecurityScopedResource() } }
      let service = try SidecarService(root: root)
      let inputs = extensionContext?.inputItems as? [NSExtensionItem] ?? []
      var captured = false
      for input in inputs {
        for provider in input.attachments ?? [] {
          var r = IngestionRequest(source: "shareSheet")
          r.suggestedCollection = collection.isEmpty ? nil : collection
          r.suggestedTags = tags.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
          }
          r.note = note
          if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            let target = root.appendingPathComponent("Inbox/\(r.id).pdf")
            try await withCheckedThrowingContinuation {
              (continuation: CheckedContinuation<Void, Error>) in
              provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) {
                url, error in
                do {
                  if let error { throw error }
                  guard let url else { throw LibraryError.invalid("Shared PDF unavailable") }
                  try Files.coordinatedRead(url) {
                    try Files.atomicWrite(Data(contentsOf: $0), to: target)
                  }
                  continuation.resume()
                } catch { continuation.resume(throwing: error) }
              }
            }
            r.inputFile = "Inbox/" + target.lastPathComponent
          } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let value = try await provider.loadItem(
              forTypeIdentifier: UTType.url.identifier, options: nil)
            if let url = value as? URL {
              r.inputURL = url.absoluteString
            } else if let string = value as? String {
              r.inputURL = string
            }
          } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let value = try await provider.loadItem(
              forTypeIdentifier: UTType.plainText.identifier, options: nil)
            r.inputText =
              value as? String ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
          } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            let target = root.appendingPathComponent("Inbox/\(r.id)-attachment")
            let name = try await withCheckedThrowingContinuation {
              (continuation: CheckedContinuation<String, Error>) in
              provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) {
                url, error in
                do {
                  if let error { throw error }
                  guard let url else { throw LibraryError.invalid("Shared file unavailable") }
                  let name = Files.sanitized(url.lastPathComponent)
                  let final = target.appendingPathExtension(url.pathExtension)
                  try Files.coordinatedRead(url) {
                    try Files.atomicWrite(Data(contentsOf: $0), to: final)
                  }
                  continuation.resume(returning: name)
                } catch { continuation.resume(throwing: error) }
              }
            }
            r.inputFile =
              "Inbox/"
              + target.appendingPathExtension(URL(fileURLWithPath: name).pathExtension)
              .lastPathComponent
            r.suggestedTitle = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
          } else {
            continue
          }
          try service.saveRequest(r)
          captured = true
        }
      }
      guard captured else { throw LibraryError.invalid("Share a URL, PDF, or plain text.") }
      extensionContext?.completeRequest(returningItems: nil)
    } catch {
      let alert = UIAlertController(
        title: "Capture failed", message: error.localizedDescription, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
    }
  }
}
struct ShareCaptureView: View {
  var save: (String, String, String) async -> Void
  var cancel: () -> Void
  @ViewState<String> private var collection = ""
  @ViewState<String> private var tags = ""
  @ViewState<String> private var note = ""
  @ViewState<Bool> private var saving = false
  var body: some View {
    NavigationStack {
      Form {
        TextField("Collection", text: $collection)
        TextField("Tags (comma separated)", text: $tags)
        TextField("Note", text: $note, axis: .vertical)
        if saving { ProgressView("Saving…") }
      }.navigationTitle("Research Library").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            saving = true
            Task {
              await save(collection, tags, note)
              saving = false
            }
          }.disabled(saving)
        }
      }
    }
  }
}

struct AppIntentRegistration: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [ResearchLibraryIntentPackage.self] }
}
