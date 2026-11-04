# Save to Research Library for Chrome

Click the toolbar book icon while viewing an article page or web PDF to save the PDF’s actual bytes to the **Inbox** hot folder of the library selected in the Mac app. There is no collection picker. The extension reads citation tags, Dublin Core and structured article metadata, finds the main PDF link, and sends the metadata immediately. The helper opens Research Library in the background. The updated app publishes the record without waiting for the publisher, then attaches the streamed PDF using its durable import checkpoints. Text extraction is deferred. This version requires the updated Mac app as well as the helper.

## One-time setup on this Mac

1. Open Research Library and select your library folder if you have not already.
2. Double-click **Install Chrome Helper.command** in this folder. It builds a small Swift helper using the installed Xcode tools and registers it for Chrome under your user account.
3. Open `chrome://extensions`, enable **Developer mode**, click **Load unpacked**, and choose this **ChromeExtension** folder (the one containing `manifest.json`).
4. Pin **Save to Research Library** from Chrome's Extensions menu. Its Options page shows the selected Inbox path and the most recent save result.

After setup, open an article page or PDF and click the book icon once. No Save dialog appears. Changing the library in the Mac app changes the destination automatically; no hard-coded library path is stored in Chrome.

## What the toolbar means

- **↓:** the page metadata has been handed to the app and the PDF is downloading.
- **✓:** a validated PDF has reached Inbox and the app has been notified to attach it immediately.
- **PDF?:** the metadata was retained, but the browser could not download a readable PDF. The app shows the issue and allows another PDF lookup.
- **!:** the local handoff failed. The Options page opens with the error.

The extension discovers PDF links from citation metadata, PDF alternate links, structured article encodings, and main “Download PDF” links. It excludes supplementary/reporting PDFs from the main-link fallback. It captures the title, ordered authors, available ORCIDs, DOI/PMID, journal, publication date, abstract, volume/issue/pages, publisher, language, ISSNs and keywords.

For the Nature example `https://www.nature.com/articles/s41586-026-11114-1`, the observed page exposes `citation_pdf_url`, 39 Dublin Core creators, citation fields and structured article data. Its main PDF is about 88 MB, so the transfer streams through a persistent native connection in bounded chunks, with a 512 MB limit. It uses the browser session when Chrome permits it. Publisher access restrictions still apply. Local files, `blob:` viewers and Chrome settings pages remain unsupported.

The sub-second target applies to publishing the metadata record and to the local attachment step after bytes arrive, not to an arbitrary publisher download. Local tests registered metadata in approximately 20–60 ms and attached an 88 MB fixture in approximately 0.92 seconds; they exclude real iCloud latency, publisher transfer time, app launch and full UI rendering. The app’s library list reveals and selects the capture as soon as it is registered. Cold launches, cloud-only metadata conflicts and website response times can take longer.

## Capture durability and recovery

The helper writes a small versioned payload to `Inbox/BrowserCaptures/<UUID>.json` before downloading. It signals the running app directly using a UUID-only `researchlibrary://chrome-capture` URL. The app reserves `Inbox/Chrome-<UUID>.pdf` in its ingestion journal so the ordinary watcher cannot race the transfer. Partial downloads stay in a temporary file and appear in Inbox only after complete validation. The ready signal bypasses Inbox stability polling and external metadata lookups. Duplicate identifiers, human metadata edits and interrupted import commits retain the app’s existing protections. A periodic reconciliation recovers missed notifications; it processes only changed capture payloads.

## Local integration and privacy

Chrome extensions cannot directly write arbitrary Mac folders. This extension uses Chrome's [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) API and a local Swift executable. There is no extension server. `activeTab` and `scripting` read the selected page only on a click; no persistent website permissions are requested. `nativeMessaging` contacts the local helper, and `storage` retains only the most recent result and its timing. The Options page updates live while a capture runs. Cookies are used by Chrome for the selected PDF fetch, not extracted or sent to the helper. The native host accepts PDF bytes or a bounded article handoff, never a browser-supplied destination path.

The helper reads the Mac app's existing `org.researchlibrary.mac` library bookmark. It validates PDF structure and stream ordering, checks that Inbox stays inside the selected library, and installs complete files with file coordination and atomic visibility. Existing unrelated bytes are never overwritten. The extension's public manifest key keeps its ID stable when loaded unpacked, and the native host registration permits only that ID.

Installed files:

- `~/Library/Application Support/ResearchLibrary/ChromeExtension/research-library-chrome-host`
- `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/org.researchlibrary.chrome.json`

Remove the extension in Chrome and delete those helper files to uninstall. The source folder must remain available while the unpacked extension is installed. This is a local macOS build, not a Chrome Web Store publication.

## Development checks

```sh
python3 Scripts/install-chrome-extension.py --stage-only
node Scripts/test-chrome-extension.cjs
python3 Scripts/test-chrome-host.py
```

Run those commands from the repository root. Host tests write only to temporary fixture folders and never open the app or modify the selected library. macOS file coordination requires access to its coordination service; a restricted test environment can block it even when ordinary file writes work. `--install-root <temporary-folder>` tests installer output without registering it in your real Chrome profile. Live Chrome toolbar activation and publisher-specific login behavior require a browser check after reloading the extension. After updating, restart the Mac app and click Reload for the extension at chrome://extensions.
