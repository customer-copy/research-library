import AppKit
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  func beginRequest(with context: NSExtensionContext) {
    guard let item = context.inputItems.first as? NSExtensionItem,
      let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
      message["action"] as? String == "capture", let id = message["id"] as? String,
      UUID(uuidString: id) != nil, let value = message["url"] as? String,
      Self.validURL(value)
    else { complete(context, error: "This page does not have a supported web link."); return }
    var query = [URLQueryItem(name: "version", value: "1"),
      URLQueryItem(name: "id", value: id), URLQueryItem(name: "url", value: value)]
    for key in ["title", "doi", "pmid", "pdfURL"] {
      guard let value = message[key] as? String, !value.isEmpty else { continue }
      if key == "pdfURL", !Self.validURL(value) {
        complete(context, error: "The PDF link is not a supported web link."); return
      }
      let limit = key == "title" ? 2_000 : key == "pdfURL" ? 8_000 : 200
      guard value.utf8.count <= limit else { complete(context, error: "The capture is too large."); return }
      query.append(URLQueryItem(name: key, value: value))
    }
    var link = URLComponents()
    link.scheme = "researchlibrary"; link.host = "capture"; link.queryItems = query
    guard let url = link.url else { complete(context, error: "Could not create the capture."); return }
    DispatchQueue.main.async {
      // The containing app owns the selected library and performs durable queuing and ingestion.
      // Success here means handed off, not that PDF download/metadata processing has finished.
      let opened = NSWorkspace.shared.open(url)
      self.complete(context, error: opened ? nil : "Open Research Library once, then try again.")
    }
  }
  private static func validURL(_ value: String) -> Bool {
    guard value.utf8.count <= 8_000, let url = URLComponents(string: value),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
    return true
  }
  private func complete(_ context: NSExtensionContext, error: String?) {
    let reply = NSExtensionItem()
    reply.userInfo = [SFExtensionMessageKey: error.map { ["ok": false, "error": $0] }
      ?? ["ok": true, "status": "sent"]]
    context.completeRequest(returningItems: [reply])
  }
}
