import Foundation
import PDFKit
import CryptoKit

// A small, unsandboxed native messaging host. The app's existing bookmark is the
// only production destination; browser messages cannot supply filesystem paths.
enum HostError: Error, LocalizedError {
  case invalid(String)
  var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

struct PDFUpload {
  var id: String
  var temporary: URL
  var handle: FileHandle
  var size = 0
  var hasher = SHA256()
}
var upload: PDFUpload?
func cancelUpload() {
  if let value = upload {
    try? value.handle.close()
    try? FileManager.default.removeItem(at: value.temporary)
  }
  upload = nil
}

func readExactly(_ count: Int) throws -> Data {
  var result = Data()
  while result.count < count {
    guard let part = try FileHandle.standardInput.read(upToCount: count - result.count), !part.isEmpty else {
      throw HostError.invalid("Incomplete native message.")
    }
    result.append(part)
  }
  return result
}

func libraryRoot() throws -> URL {
  // Disposable fixture support is CLI-only; it is never read from a web message.
  if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--test-root" {
    return URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
  }
  guard let bookmark = UserDefaults.standard.persistentDomain(forName: "org.researchlibrary.mac")?["libraryBookmark"] as? Data else {
    throw HostError.invalid("Open Research Library and select your library folder first.")
  }
  var stale = false
  // App-scoped security access belongs to the creating app. This unsandboxed
  // helper resolves the bookmark's location without claiming that app's scope.
  return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
    relativeTo: nil, bookmarkDataIsStale: &stale)
}

func webURL(_ value: String) throws -> URL {
  guard value.utf8.count <= 8000, let parts = URLComponents(string: value),
    ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
    parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(), !host.isEmpty,
    let url = parts.url else { throw HostError.invalid("Open an HTTP or HTTPS PDF or article first.") }
  return url
}

func openApp(_ capture: URL? = nil) -> Bool {
  if CommandLine.arguments.contains("--test-root") { return true }
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  task.arguments = ["-g", "-b", "org.researchlibrary.mac"] + (capture.map { [$0.absoluteString] } ?? [])
  task.standardOutput = FileHandle.standardError
  task.standardError = FileHandle.standardError
  do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
  catch { return false }
}

func envelopeURL(root: URL, id: String) throws -> URL {
  let relative = "Inbox/BrowserCaptures/\(id.lowercased()).json"
  let base = root.resolvingSymlinksInPath().standardizedFileURL.path
  let url = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(relative)
  guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/") else {
    throw HostError.invalid("Browser captures must stay inside the selected library.")
  }
  return url
}

func coordinatedWrite(_ data: Data, to target: URL) throws {
  try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
  var coordinationError: NSError?
  var writeError: Error?
  NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
    do { try data.write(to: url, options: .atomic) } catch { writeError = error }
  }
  if let error = coordinationError ?? writeError as NSError? { throw error }
}

func notifyCapture(_ id: String) -> Bool {
  var link = URLComponents()
  link.scheme = "researchlibrary"; link.host = "chrome-capture"
  link.queryItems = [URLQueryItem(name: "id", value: id)]
  return openApp(link.url)
}

func updateEnvelope(root: URL, id: String, phase: String, error: String? = nil) throws {
  let target = try envelopeURL(root: root, id: id)
  let data = try Data(contentsOf: target)
  guard data.count <= 128 * 1024, var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    (payload["id"] as? String)?.lowercased() == id.lowercased(), payload["version"] as? Int == 2 else {
    throw HostError.invalid("Begin the article capture before sending the PDF.")
  }
  payload["phase"] = phase
  payload["error"] = error
  try coordinatedWrite(JSONSerialization.data(withJSONObject: payload), to: target)
}

func handle(_ message: [String: Any]) throws -> [String: Any] {
  guard let token = message["id"] as? String, UUID(uuidString: token) != nil else {
    throw HostError.invalid("Invalid capture identifier.")
  }
  let root = try libraryRoot()
  let access = root.startAccessingSecurityScopedResource()
  defer { if access { root.stopAccessingSecurityScopedResource() } }
  var directory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
    throw HostError.invalid("Your selected library is unavailable. Open Research Library and select it again.")
  }
  switch message["action"] as? String {
  case "status":
    return ["ok": true, "status": "ready", "helperVersion": 2, "inbox": root.appendingPathComponent("Inbox").path]
  case "beginCapture":
    guard let value = message["url"] as? String, let metadata = message["metadata"] as? [String: Any] else {
      throw HostError.invalid("Missing article page metadata.")
    }
    let page = try webURL(value)
    var payload: [String: Any] = ["version": 2, "id": token.lowercased(), "url": page.absoluteString,
      "metadata": metadata, "phase": "pending"]
    if let pdf = message["pdfURL"] as? String { payload["pdfURL"] = try webURL(pdf).absoluteString }
    if let clickedAt = message["clickedAt"] as? Double { payload["clickedAt"] = clickedAt }
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard data.count <= 128 * 1024 else { throw HostError.invalid("Article metadata exceeds the capture limit.") }
    let target = try envelopeURL(root: root, id: token)
    if !FileManager.default.fileExists(atPath: target.path) { try coordinatedWrite(data, to: target) }
    let launched = notifyCapture(token)
    return ["ok": true, "status": "added", "appOpened": launched]
  case "captureFailed":
    try updateEnvelope(root: root, id: token, phase: "failed", error: String((message["error"] as? String ?? "PDF download failed.").prefix(1000)))
    let launched = notifyCapture(token)
    return ["ok": true, "status": "metadataOnly", "appOpened": launched]
  case "pdfStart":
    guard upload == nil, FileManager.default.fileExists(atPath: try envelopeURL(root: root, id: token).path) else {
      throw HostError.invalid("Begin the article capture before transferring its PDF.")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchChrome-\(UUID()).part")
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
      throw HostError.invalid("Could not create the temporary PDF transfer.")
    }
    upload = PDFUpload(id: token.lowercased(), temporary: temporary, handle: try FileHandle(forWritingTo: temporary))
    return ["ok": true, "status": "streaming", "offset": 0]
  case "pdfChunk":
    guard var value = upload, value.id == token.lowercased(), message["offset"] as? Int == value.size,
      let encoded = message["data"] as? String, encoded.utf8.count <= 1_048_576,
      let chunk = Data(base64Encoded: encoded), !chunk.isEmpty, chunk.count <= 768 * 1024,
      value.size + chunk.count <= 512 * 1024 * 1024 else {
      throw HostError.invalid("Invalid, out-of-order or oversized PDF transfer.")
    }
    try value.handle.write(contentsOf: chunk)
    value.hasher.update(data: chunk); value.size += chunk.count
    upload = value
    return ["ok": true, "offset": value.size]
  case "pdfFinish":
    guard let value = upload, value.id == token.lowercased(), value.size > 0 else {
      throw HostError.invalid("The PDF transfer is incomplete.")
    }
    try value.handle.synchronize(); try value.handle.close()
    guard let document = PDFDocument(url: value.temporary), document.pageCount > 0 else {
      throw HostError.invalid("The website did not return a readable PDF.")
    }
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let inbox = URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent("Inbox", isDirectory: true)
    guard inbox.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath + "/") else {
      throw HostError.invalid("Inbox must stay inside your selected library.")
    }
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let target = inbox.appendingPathComponent("Chrome-\(token.lowercased()).pdf")
    let stage = inbox.appendingPathComponent(".Chrome-\(UUID()).part")
    defer { try? FileManager.default.removeItem(at: stage) }
    try FileManager.default.copyItem(at: value.temporary, to: stage)
    var coordinationError: NSError?
    var moveError: Error?
    NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
      do {
        // A new capture has a fresh UUID. Existing bytes are never replaced on retry.
        if FileManager.default.fileExists(atPath: url.path) {
          throw HostError.invalid("This capture already has a PDF. Retry with a fresh toolbar click.")
        }
        try FileManager.default.moveItem(at: stage, to: url)
      } catch { moveError = error }
    }
    if let error = coordinationError ?? moveError as NSError? { throw error }
    try updateEnvelope(root: root, id: token, phase: "ready")
    cancelUpload()
    let launched = notifyCapture(token)
    return ["ok": true, "status": "saved", "bytes": value.size, "appOpened": launched]
  case "pdfCancel":
    guard upload?.id == token.lowercased() else { throw HostError.invalid("No matching PDF transfer.") }
    cancelUpload()
    return ["ok": true, "status": "cancelled"]
  case "savePDF":
    guard let encoded = message["data"] as? String, encoded.utf8.count <= 44_739_244,
      let bytes = Data(base64Encoded: encoded), bytes.count <= 32 * 1024 * 1024,
      bytes.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: bytes), pdf.pageCount > 0 else {
      throw HostError.invalid("The website did not return a readable PDF of 32 MB or less.")
    }
    let title = String((message["title"] as? String ?? "Article").prefix(100))
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    let clean = title.components(separatedBy: bad).joined(separator: " ")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    // Do not allow an Inbox symlink to redirect writes outside the selected library.
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let inbox = URL(fileURLWithPath: resolvedRoot, isDirectory: true).appendingPathComponent("Inbox", isDirectory: true)
    guard inbox.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot + "/") else {
      throw HostError.invalid("Inbox must be inside your selected library.")
    }
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let isV2 = message["captureV2"] as? Bool == true
    if isV2 {
      let envelope = try envelopeURL(root: root, id: token)
      guard FileManager.default.fileExists(atPath: envelope.path) else { throw HostError.invalid("Article capture is missing. Retry the save.") }
    }
    let name = isV2 ? "Chrome-\(token.lowercased()).pdf" : (clean.isEmpty ? "Article" : clean) + "-" + String(hash.prefix(16)) + ".pdf"
    let target = inbox.appendingPathComponent(name)
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
      do {
        if FileManager.default.fileExists(atPath: url.path) {
          guard try Data(contentsOf: url) == bytes else { throw HostError.invalid("An unrelated file already uses this name.") }
        } else {
          try bytes.write(to: url, options: .atomic)
        }
      } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError as NSError? { throw error }
    if isV2 { try updateEnvelope(root: root, id: token, phase: "ready") }
    let launched = isV2 ? notifyCapture(token) : openApp()
    return ["ok": true, "status": "saved", "appOpened": launched]
  case "capture":
    guard let value = message["url"] as? String else { throw HostError.invalid("Missing article URL.") }
    let url = try webURL(value)
    var query = [URLQueryItem(name: "version", value: "1"), URLQueryItem(name: "id", value: token),
      URLQueryItem(name: "url", value: url.absoluteString)]
    if let title = message["title"] as? String { query.append(URLQueryItem(name: "title", value: String(title.prefix(500)))) }
    if let pdf = message["pdfURL"] as? String { query.append(URLQueryItem(name: "pdfURL", value: try webURL(pdf).absoluteString)) }
    if let doi = message["doi"] as? String, doi.count <= 200,
      doi.range(of: "^10\\.[0-9]{4,9}/[-._;()/:A-Z0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil {
      query.append(URLQueryItem(name: "doi", value: doi))
    }
    if let pmid = message["pmid"] as? String, pmid.range(of: "^[0-9]{1,9}$", options: .regularExpression) != nil {
      query.append(URLQueryItem(name: "pmid", value: pmid))
    }
    var link = URLComponents()
    link.scheme = "researchlibrary"; link.host = "capture"; link.queryItems = query
    guard let capture = link.url, capture.absoluteString.utf8.count <= 24_000, openApp(capture) else {
      throw HostError.invalid("Could not reach Research Library. Open the app and try again.")
    }
    return ["ok": true, "status": "sent"]
  default: throw HostError.invalid("Unsupported native message.")
  }
}

// connectNative uses several bounded messages in one process. sendNativeMessage
// remains compatible: Chrome closes stdin after receiving the first reply.
while true {
  let response: [String: Any]
  do {
    var header = try FileHandle.standardInput.read(upToCount: 4) ?? Data()
    if header.isEmpty { break }
    if header.count < 4 { header.append(try readExactly(4 - header.count)) }
    let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    guard length > 0, length <= 48 * 1024 * 1024,
      let message = try JSONSerialization.jsonObject(with: readExactly(Int(length))) as? [String: Any] else {
      throw HostError.invalid("Invalid or oversized native message.")
    }
    response = try handle(message)
  } catch {
    cancelUpload()
    response = ["ok": false, "error": error.localizedDescription]
  }
  let output = try JSONSerialization.data(withJSONObject: response)
  var length = UInt32(output.count).littleEndian
  try FileHandle.standardOutput.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
  try FileHandle.standardOutput.write(contentsOf: output)
}
cancelUpload()
