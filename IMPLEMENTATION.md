# Implementation and validation ledger

## Delivered implementation

The macOS app now embeds the Save to Research Library Safari web extension, with a toolbar popup for current-page/PDF capture and individual Google-result buttons. See `Apple/SafariExtension/README.md` for activation and local-signing requirements.

The shared ResearchCore package owns the portable archive, device-local SQLite/FTS index, persisted ingestion state machine, identifier/hash reconciliation, metadata providers, PDFKit/Vision extraction, sections/chunks, retrieval, migration, export and integrity checks. The macOS app provides library browsing, metadata editing, organization, capture, processing/review, PDF page navigation and recovery tools. The iOS app, Share Extension and App Intent write the same portable request format.

JSON sidecars and attachments are authoritative. Local databases, extracted pages, sections, chunks and Spotlight are derived. Database rebuild never requires a remote provider, and Spotlight service errors cannot stop a local rebuild. No embeddings or AI uploads are implemented. General captured attachments remain ordinary files.

## Verified on this machine

- Xcode 27.0 (27A266a), Swift 6.4, macOS 27.0.1, macOS/iOS/Simulator 27 SDKs.
- 37 deterministic Swift Testing tests passed. Tests use generated PDFs, raster scans, temporary archives and mock metadata transports; they do not depend on live providers.
- Native PDF body extraction and OCR, page/chunk provenance, metadata/body FTS ranking and phrase/filter search.
- Twenty thousand records: matching bibliographic search under two seconds, and correctly sorted pagination at offset 19,000. The unloaded run returned its match in about four milliseconds. This is a metadata/search benchmark, not a large scanned-PDF throughput benchmark.
- Search remains available while the actual ingestion pipeline awaits PDF extraction, using a controlled extractor to hold that stage open.
- Archive atomicity, unknown JSON preservation, clear optional fields, recovery snapshots, path safety, hashes and identifiers.
- Duplicate reconciliation, late PDF attachment, retained new notes/tags, ambiguous review choices, interrupted request recovery and hot-folder stability.
- URL-only and inaccessible articles, publisher-declared accessible PDFs, provider normalization and mock HTTP retry/response behavior.
- Actual App Intent perform, general file capture, malformed queue isolation, Paperpile/BibTeX migration including local PDF attachments, JSON/BibTeX/RIS export.
- Index rebuild, changed hashes, missing files, malformed sidecars and orphan reporting.
- Live public Crossref DOI capture resolved “Array programming with NumPy” (10.1038/s41586-020-2649-2), confidence 0.99, with exact-match provenance. No private documents were sent.
- macOS Xcode Debug clean build succeeded; iOS Simulator application and embedded Share Extension builds succeeded.
- Generated App Intents metadata contains the capture action, library entity, AppShortcutsProvider and localized phrases.

Final clean Release builds passed for macOS and iOS after the recovery changes, with no actionable compiler warnings. The macOS bundle passed strict signature verification and launched successfully. Both packaged apps contain one capture action, one stable library entity and one localized App Shortcut; the embedded Share Extension includes the action/entity package.

The final core suite passed all 37 tests, including OCR and rebuild. The 20,000-record search took 31 ms while Simulator startup was running. The native iOS 18.5 UI test also passed: enter DOI/collection/tags, save, terminate and relaunch with library access remembered. Host inspection confirmed one real portable request with the expected collection and both tags. Total: 38 passing tests. Debug test-bundle metadata/stripping notices are informational.

The macOS app was inspected against an isolated public-DOI archive. Its narrow-column search filters were corrected after that check. Simulator startup required a CoreSimulator service restart and a clean task-owned iOS 18.5 device. A visual check caught an opaque bitmap export failure in the iOS icon; the corrected asset was verified at 1024 × 1024 with no alpha channel.

## Genuine validation limits

A physical iOS installation requires a signing team and provisioned shared application group. A developer account is unnecessary for the local ad-hoc macOS build and Simulator development. Siri invocation, user-created Shortcuts, Safari Share Sheet interaction and system Spotlight launch have not been exercised end to end. Real iCloud propagation, coordinated writes by two Macs, OS-managed entity synchronization and other older supported OS versions have not been tested.

OCR uses native Vision, including a supported CPU/fast fallback when the accurate model cannot initialize. Recognition and section boundaries remain best-effort. A public publisher page without an accessible declared PDF remains URL-only. File-provider availability and authentication failures retain requests/items for retry. Renaming keeps the old original; integrity may consequently report it as an orphan. No distributed transaction guarantee is claimed for simultaneous cloud writers.

Debug-only UI harnesses use isolated test archives; Release builds exclude them. Automated test fixtures and native snapshots contain no user research documents. Generated apps, build caches and logs are excluded from source control.

The delivered macOS app is also installed under `~/Applications/Research Library.app` and passes strict signature verification there. The iCloud workspace reattached Finder attributes to its mirrored bundle after signing; the local installation avoids that file-provider behavior. Both packaged artifacts remain available in the project Build folder.

## Inbox cleanup update

Successful captures now remove their Inbox input only after completion, authoritative metadata persistence, and coordinated SHA-256 verification of both the input and the organized attachment. A nullable cleanup marker preserves compatibility with older requests; completed imports from earlier versions are also checked, and interrupted cleanup resumes after restart. Cancelled/review/failed captures and changed, missing, or corrupt organized copies retain the original. External import sources are retained. Downloaded PDFs persist their Inbox input path so the same cleanup applies.

All 41 core tests passed after this change (76.5 seconds), including normal and duplicate captures, hot-folder byte preservation, old-request cleanup/restart, changed originals, missing/corrupt organized copies, extraction failure/retry, downloaded PDFs, and cancelled duplicate review. The macOS Release build also passed. The previously delivered iOS UI test was not rerun for this Mac processing change.

## Automatic web metadata update

PDF ingestion now combines matching records from Crossref, DataCite (when Crossref has no record), Europe PMC, PubMed, arXiv, and accessible publisher citation/JSON-LD metadata. Newly discovered identifiers can trigger a second provider pass. Identifier conflicts are rejected; title fallback requires a unique exact normalized title and available author/year agreement. First-page OCR can reveal identifiers in scans. Embedded or first-page title candidates seed identifier-free imports. The importer no longer treats an automatically supplied filename as an authoritative title.

The main record retains publisher, publication date, language, ISSN/ISBN, keywords and licenses as well as the original bibliographic fields. Nullable fields keep old sidecars readable. Matching source records are retained under `sourceMetadata`, preserving extra source-supplied funding, affiliations, references and related-resource metadata. Keywords enter the rebuildable search index without changing personal tags. Missing provider fields cannot erase existing values; author enrichment preserves author order and IDs. Refresh Web Metadata enriches existing records and preserves human corrections, notes and organization, including edits made while a request is running. PubMed parsing excludes referenced papers' identifiers from the owning record.

All 49 core tests passed (76.4 seconds), including multi-provider import/refresh, identifier discovery, title lookup ambiguity, provider failures, conflicting identifiers, author ordering, publisher structured metadata, native PDF title extraction, portable metadata persistence, body-index rebuild, and Inbox cleanup. macOS Release and clean iOS Simulator/Share Extension Release builds passed. A live public DOI lookup for Array programming with NumPy combined Crossref, PubMed and Europe PMC records, with 26 authors, a 1,454-character abstract, DOI/PMID/PMCID and publication details. Publisher metadata was not returned for that paper; matching publisher metadata is covered by deterministic fixtures. No user PDF was sent to any service. The iOS system UI test was not rerun for this metadata change.


## Selected PDF reader upgrade

Implemented the selected macOS reader capabilities: navigation, zoom, in-document search, highlights, a searchable annotation sidebar, local reading memory, and tabs with side-by-side comparison. The reader is now embedded in the main window’s detail column, with a control to show or hide the library columns. Each pane owns a separate PDFView, search task, undo manager and selection. Page thumbnails load on demand; text search scans one page at a time and yields between batches. Outline navigation supports PDF destinations and GoTo actions.

Highlights use one standard PDF annotation per selected page with quadrilateral geometry for each text line. They support six colors, recoloring, deletion, and explicit undo groups. Autosave serializes successive revisions and flushes before closing or terminating. Coordinated checksum-guarded writes preserve recovery versions and report external edit conflicts. Reload reconciles the portable resource checksum before further editing. Original resource hashes enter an additive duplicate-alias table without changing schema-1 sidecar compatibility. Re-importing an unannotated original retains the organized annotated attachment; Inbox cleanup requires the matching original recovery file as well as a verified current attachment.

Validation: all 52 core tests passed in 82.6 seconds, including annotation persistence, invalid-PDF rejection, checksum conflict protection, recovery verification, external reload, hash aliases, re-import cleanup and reader-memory serialization. A disposable Debug native harness passed 22 checks covering navigation, outline traversal, zoom, multi-page search, multiline highlight geometry, disk persistence, annotation text/color filtering, independent undo/redo, reload, deletion/undo, reading memory and independent comparison views. The comparison layout and saved two-line highlight rendering were visually inspected. macOS Release and clean iOS Simulator/Share Extension Release builds passed. The reader upgrade is macOS-only; iOS remains the capture companion. Native integration fixtures do not access user PDFs. Pinch gestures, keyboard event delivery, real iCloud concurrent edits, and physical iOS UI were not exercised end to end in this update.


## Main-window reader integration

The PDF reader now occupies the main app’s detail area instead of creating a separate NSWindow. Library columns remain usable for opening further PDFs; comparison expands the detail area. Library/Reader controls switch between item details and retained PDF tabs. A delegate proxy preserves SwiftUI window handling while waiting for annotation saves on close. Opening a normal row also preserves its remembered reading page.

Validation: macOS Debug and Release builds passed without compiler warnings. All 26 disposable native reader checks passed, including both PDF panes sharing the original main window, no additional reader window, retaining tabs when returning to the library, and reopening the reader in that same window. The full-width comparison layout was visually inspected. No shared core or iOS code changed in this integration; their prior validations were not rerun.


## PDF-first library and right-hand metadata sidebar

Selecting a library row now opens or activates its PDF without requiring Open PDF or double-click. Search matches retain their explicit page navigation. The main detail area displays the reader or a PDF-unavailable placeholder with attachment/website actions. Metadata no longer replaces the viewer: the main toolbar toggles a native right-hand inspector containing the existing article details, notes, provenance and editing/attachment actions. Its content tracks the active reader tab and reloads when the library record changes. The reader’s Library control toggles the library columns while retaining the PDF view. URL-only selections retain open reader tabs and expose their own metadata through the sidebar.

Validation: macOS Debug and Release builds passed. All 33 native fixture checks passed, including single-row PDF selection, metadata hidden by default, metadata appearing beside the PDF, following the active tab, closing without losing PDFs, URL-only handling, and returning to reading by selecting another paper. The right-hand sidebar layout and dark appearance were visually inspected. PDF view sizing now follows the SwiftUI layout proposal instead of carrying oversized view bounds between layouts. Shared core and iOS code were unchanged.


## Explicit PDF tabs

Ordinary row selection, normal clicks, and Open PDF actions replace the active document in its existing tab. Middle mouse clicks are intercepted only over the visible matching library row, and the row context menu provides Open PDF in Tab. Those explicit actions add a tab; already-open attachments are activated without duplication. Re-clicking an already-selected row also displays its PDF. Replacement flushes pending highlights and remembers the previous reading position; a failed save keeps the old PDF open. Generation checks discard stale replacements when another selection, tab switch, or close occurs during a save. Comparison and other open tabs remain intact.

Validation: macOS Debug and Release builds passed without compiler warnings. All 40 native fixture checks passed, including one-tab normal selection/replacement, genuine posted middle-mouse events, re-clicking the already-selected row with native left-mouse events, explicit-tab reuse, preserving other tabs, and saving a pending highlight into the PDF before replacement. The right-click entry is bound to the same explicit-tab action. Shared core and iOS code were unchanged.


## Automatic iCloud reader opening and middle-click closing

File materialization distinguishes a pending download from a failure. Cached resource values are refreshed, and both current and downloaded iCloud versions count as locally available. The reader retries pending downloads asynchronously with visible progress instead of showing the capture-oriented alert; it opens the PDF without another click. A newer normal selection supersedes an obsolete pending replacement. Explicit new-tab downloads continue independently, reuse existing tabs on completion, and preserve the latest active tab. Requests retain scoped archive access during their wait. Genuine provider errors and a five-minute timeout remain reportable.

The center mouse button over a tab closes that tab through the existing save-and-close path. Closing resolves the live document instance before flushing, including when a tab view has been reused. Active, inactive and last-tab cases are covered by native mouse-event fixtures.

Validation: all 53 core tests passed (87.9 seconds), and all 49 native reader fixture checks passed, including automatic opening after simulated download delays, superseding an obsolete selection, concurrent explicit-tab downloads, native middle-click closing of active/inactive/last tabs, and flushing pending highlights before closing. macOS Debug and Release and iOS Simulator/Share Extension Release builds passed. Real iCloud delivery timing was not exercised; pending states use deterministic disposable fixtures.

## Permanent deletion and macOS capture shortcut

Added Delete Permanently alongside the recoverable delete action, with an explicit destructive confirmation. It removes managed attachments (including prior paths recovered from metadata versions), supplements, metadata/annotation recovery, linked Inbox inputs/requests, search data and orphan organization records. Current cross-article attachment references are checked before deletion and again during resumed deletion. External import files and independent exports/backups are preserved. Reader documents are retired before deletion, active save tasks finish, local reading memory is cleared, and pending downloads cannot reopen deleted articles. Coordinated path manifests resume interrupted deletion; completed UUID-only tombstones prevent stale metadata revival on updated clients. Pending manifests contain paths until completion, but completed markers contain no article content. Malformed/unavailable metadata and escaping paths fail safely.

Created the signed macOS Save to Research Library shortcut under Shortcuts, with a reproducible Python generator. It uses the native AddToResearchLibraryIntent, branches between PDF and URL input, accepts Safari/Share Sheet/Finder inputs, and uses the clipboard when launched without input. Empty/non-link input stops with an explanation. Native Shortcut import requires the user's Add Shortcut click. No shell-script action or hardcoded library path is used.

Validation: all 58 core tests passed (49.5 seconds), including removal of renamed/annotated PDFs and recovery, linked captures, preservation of shared/external files, unsafe-path rejection, stale-sidecar suppression after restart/rebuild, interrupted-manifest resumption, and actual App Intent URL/PDF capture through organization and Inbox cleanup. All 52 native fixture checks passed, including deleting an open reader with pending highlights and preventing a pending cloud tab from reopening a deleted article. macOS Debug/Release and iOS Simulator/Share Extension Release builds passed without compiler warnings. The shortcut property list was validated and Apple's shortcuts sign command produced the signed import artifact. Full Shortcuts/Share Sheet execution awaits the user's import; real cross-device iCloud deletion propagation was not exercised. No user article was deleted during development.

## Main-toolbar PDF controls and Inbox refresh

Moved navigation, reading history, editable page entry, zoom/fit, Find, highlight color, highlight/undo/redo and save status from the PDF pane into the native main toolbar alongside library search. Native toolbar groups support overflow. Controls follow the active document, including comparison-pane clicks and text selections. Find retains Command-F and focuses the PDF search sidebar. PDF panes retain their error/reload UI and gain the space previously occupied by the two control rows.

Added Refresh Inbox (Command-R), which polls the hot folder, waits asynchronously 2.2 seconds, checks stability again, reconciles portable metadata and processes pending captures. It updates requests/results without replacing the reader. The existing automatic monitor remains active.

Validation: macOS Debug and Release builds passed without compiler warnings, and all 55 native fixture checks passed. Added checks cover comparison toolbar targeting, discovering/processing/cleaning a hot-folder PDF through the refresh action, and preserving the active reader. The full window screenshot was visually inspected with controls in the title toolbar and the former reader control rows removed. The fit-page check now verifies viewport geometry, accommodating the larger PDF pane. Shared core/iOS code was unchanged; the previous 58 core tests and iOS build were not rerun.

## Toolbar consolidation

Replaced the split view's automatic sidebar control and the reader tab bar's Library button with one main-toolbar Library toggle. Import PDF and URL/identifier capture share an Add menu; Select Library remains in File. PDF sidebar modes and Find are consolidated under PDF Navigation. Reading history moved into the page-count menu alongside first/last-page actions, leaving the visible curved arrows exclusively for annotation undo/redo. Command-F remains available through the menu and PDF view. Refresh, Metadata, page stepping, zoom and highlighting remain directly accessible. The tab bar now contains tabs and Compare.

Validation: macOS Debug and Release builds passed without warnings; all 55 native reader checks passed. Visual inspection confirmed one Library toggle, one Add menu, one PDF Navigation menu, no duplicated reading-history/undo arrow buttons and a tab-only reader bar with Compare. The automatic sidebar button is suppressed on the split view and its sidebar where SwiftUI generates it. Shared core/iOS code was unchanged.

## Paperpile migration and on-demand PDF discovery

Imported the supplied October 7 Paperpile JSON export into the selected Papers archive. All 5,476 source identities and original JSON records are represented in 5,380 library entries after identifier reconciliation. Conflicting identifiers remain separate for review. Existing records, notes, manual edits, attachments and permanent-deletion markers are preserved. Publication dates, ordered authors/ORCIDs, citation keys, identifiers, URL arrays and attachment filename hints are mapped; unnamed folder UUIDs remain in source metadata.

Opening a PDF-less reference searches the selected archive, then exact-identifier Europe PMC/PMC Cloud Service/arXiv records and accessible publisher PDF links. Matches are validated, downloaded directly into organized storage, and indexed. Ambiguous matches, access restrictions, missing PDFs and temporary failures receive distinct review states; Find PDF Again explicitly retries. Normal selection and explicit tab behavior remain intact, including cancellation of stale cloud opens.

Large-library fixes add identifier expression indexes and an FTS rowid lookup, yield during sidecar reconciliation, and use resident-file metadata without unnecessary File Provider requests. An interrupted import can resume using the last synchronized local-index recovery snapshot and skip identical committed source records. Resume does not bypass sidecar conflict protection or deletion reconciliation. Native launch imports run independently of restored window visibility.

Validation: 74 core tests and all 55 native reader checks passed; macOS Debug/Release and iOS Simulator/Share Extension builds passed without compiler warnings. Migration verification found zero missing export identities, zero missing raw source records, zero missing preexisting entries and no lost preexisting notes. Backup, successful import report and verification report are retained in Build. PDF discovery uses deterministic mocked provider responses and generated local PDFs; live repository metadata was checked, while cross-device iCloud propagation and every publisher's access behavior were not exhaustively tested.

## Paperpile PDF ZIP ingestion

Inbox ZIP archives from a Paperpile/Google Drive export are processed through the app's iCloud security-scoped library access. Each archive is extracted into a temporary workspace, validated as a readable PDF, matched against Paperpile attachment filename hints and exact identifiers, and attached to the existing imported reference. Hashes prevent duplicate attachment copies. Ambiguous, unmatched, conflicting, unreadable, or non-PDF entries are copied into `Needs Review/Paperpile ZIPs/<archive>/` with their relative paths preserved. An archive is removed from Inbox only after every entry has been organized or preserved for review.

The completed Inbox run processed 5 ZIP archives and 1,522 PDFs: 1,194 newly attached, 227 already present, 101 sent to Needs Review, and one non-PDF preserved. The five source ZIPs were removed only after those outcomes were recorded. PDF text extraction is resumable through the background indexing queue and continues across app restarts.

Validation: the focused Paperpile suite passed 17 tests, the full core suite passed 75 tests, and macOS Release plus iOS Simulator/Share Extension builds passed. The report is retained at `Build/Paperpile ZIP Import Report.json`.

## bioRxiv and medRxiv metadata

Added dedicated bioRxiv and medRxiv providers ahead of general DOI metadata lookup. They use the official exact-DOI details endpoint, validate the returned DOI, parse the API's `collection` records, normalize dates, abstracts, authors, categories, licenses, and preprint provenance, and retain the raw provider record as source metadata. DOI URLs are also recognized when a record has a bioRxiv or medRxiv URL but no separate DOI field.

Validation: added a collection-response normalization test covering title, abstract cleanup, date/year, authors, category keywords, provenance, and exact endpoint routing. Source syntax checks pass; a fresh Xcode test/build invocation was blocked by the environment's approval-quota limit after the ZIP processing run.
## Verified Uhlmann PDF recovery (October 8)

The actual imported Uhlmann PDF was present twice in `Needs Review/Paperpile ZIPs`, with identical SHA-256 hashes. Its first-page DOI wraps after `annurev-cellbio-111524-`; the original parser interpreted that prefix as a conflicting DOI, so ZIP import rejected it. Local discovery also excluded Needs Review, preventing recovery.

DOI extraction now rejoins publisher suffixes wrapped before numeric continuations and after the registrant slash. Validation matches the complete expected DOI across layout line breaks and still rejects genuinely conflicting identifiers. Discovery includes review PDFs and content-validates them; identical validated files count as one candidate. Distinct versions still require review. Scoped launch diagnostics report capture state and matching evidence; an explicit resolve option exercises the real reader.

Validation: all 83 tests passed, including wrapped-DOI validation, rejection of a genuinely different suffix, and recovery of identical review copies without network access. Release macOS build and installed signature verification passed. The installed app recovered the actual file into the managed PDFs folder, saved the Uhlmann record with `pdfLookup.available`, and opened all 30 pages in ReaderWorkspace. Evidence: `Build/Uhlmann PDF trace 3.json` and `Build/Uhlmann PDF verified.json`.

## Safari capture extension (October 8)

Follow-up discovery check: the installed extension is registered at the expected path and its signatures verify. After refreshing registration, the containing app's `SFSafariExtensionManager` query returns `recognizedBySafari: true`, `enabled: false` without an API error. Safari logs also contain code-signing-dictionary warnings for the ad-hoc extension; registration alone must not be treated as proof of visibility or activation. Added `--safari-extension-report` to record Safari's own state. Clarified that quitting/restarting Safari after Allow unsigned extensions resets that option, so setup must proceed directly to Extensions without a restart. Requested Safari's extension settings through its native API; actual visible activation remains a user step.

Embedded a macOS Safari web extension in Research Library. Its active-tab popup collects the current URL, title, and available publisher DOI/PMID/PDF link. Google-only content scripts add per-result buttons, unwrap Google's outbound redirects, detect newly inserted/reused results, and show sending/error/retry state. Native messaging hands a bounded capture URL to the containing app, whose explicit macOS URL-event handler validates it and persists a Safari-source ingestion request. Retries reuse the request UUID and cannot reset a completed capture. The extension reports Sent rather than claiming metadata or PDF retrieval has finished. Capture processing uses the existing deduplication and organization pipeline.

The cold-launch handoff test exposed expensive rewrites of unchanged local index records during sidecar reconciliation. Reconciliation now compares the complete canonical record before updating author relations/FTS, while still detecting actual sidecar changes even if their article timestamp was not updated. Added Library → Enable Safari Extension to open Safari's extension preferences.

Validation: all 87 core tests passed; six disposable Chromium browser-fixture checks cover save buttons, dynamic/reused results, error/retry state, publisher meta extraction, and PDF viewer fallback. The popup screenshot was visually checked. Apple's Safari extension packager accepted the final manifest without unsupported-key warnings. Release macOS build and installed app/embedded-extension signature checks passed. PluginKit lists `org.researchlibrary.mac.safari`. An extension-format handoff through the registered URL scheme was durably queued in the selected library; the existing Uhlmann reference retained its PDF and was not duplicated. Evidence: `Build/Safari capture verification.json` and `Build/Safari extension popup.png`.

Live Safari content-script/native-messaging operation remains to be checked after the user enables the extension and Google access. No Apple development signing identity is available on this Mac, so this local ad-hoc build requires Safari's Allow unsigned extensions testing setting, which must be re-enabled after quitting Safari. Activation and signing instructions are in `Apple/SafariExtension/README.md`. No iOS Safari extension was added; existing iOS sharing remains available.

## Reliability and performance phase — October 8, 2026

Added durable import commit checkpoints with stable resource IDs and destination paths, verified temporary-file copying without replacing unrelated files, restart replay and preservation of post-interruption edits. Reader save retries recognize identical already-committed bytes only when the original recovery copy verifies. PDF lookup verifies readable bytes/DOI instead of assuming that an existing path is available; corrupt attachments retain their files and enter review. Reader file reads/validation/hashing and PDF parsing run in background tasks with identity/deletion checks after suspension.

Persisted rebuildable sidecar revision markers avoid rereading unchanged local metadata across launches; file inode/change-time checks catch same-size/date atomic replacements. Cached results appear after deletion reconciliation while cloud synchronization continues. Added Instruments signposts and session timing counters to diagnostics. See RELIABILITY.md for guarantees, limitations and the reproducible benchmark.

Validation: 97 core tests passed, including replay at each durable commit boundary, suffixed destinations, changed inputs/destinations, loss of the derived index, post-interruption metadata/PDF edits, and partially committed reader saves. All 55 native reader fixture checks passed. Release/Debug macOS builds and the iOS Simulator release build passed. Local 5,000-record existing-index reconciliation measured 66.6 ms versus 3,371.7 ms before persisted stamps; a one-page PDF read was 2.4 ms. These fixture timings exclude UI rendering and real iCloud latency. Evidence: Build/Reliability performance baseline.json and Build/Reliability reader verification.json.

The verified release was installed to ~/Applications/Research Library.app, retaining Build/Research Library before reliability.app as a rollback copy. Installed signatures verified. The installed app opened the actual Uhlmann PDF with all 30 pages and pdfLookup.available through its existing authorized folder access; evidence is Build/Reliability installed PDF verification.json. The application was returned to normal operation after that diagnostic run.

## Search execution and grouped results — October 8, 2026

Search now runs through a dedicated read-only WAL actor instead of waiting behind LibraryService ingestion. Request-specific SQLite progress callbacks interrupt cancelled queries and leave the connection reusable. Search/author/journal typing debounces for 180 ms; search submission runs immediately. Generation checks reject stale results/errors/completion. Metadata previews arrive before deeper results, with a progress label, and organization menus update separately from keystroke searches.

Article results deduplicate before pagination. Relevance uses metadata matches followed by rank-ordered PDF hits until enough distinct papers are found; custom sorts retain global article ordering. Excerpts are computed only for selected articles. Metadata decoding and chunk/section lookup use bounded batches. Stable article IDs preserve selection during preview refinement. Matching PDF pages loads excerpts lazily with page navigation and bounded expansion; its controls bypass row-wide PDF opening and selection-triggered opening.

Added a rebuildable article/resource/page-to-FTS-row lookup with a one-time backfill for existing indexes, plus a composite citation index. All phases of an individual search share a read snapshot. A private snapshot benchmark reports counts/timings without bibliographic records or document text. See SEARCH.md and Scripts/benchmark-search.sh.

Validation: all 104 core tests passed, including grouped pagination, large result hydration, migration/reindexing, SQLite interruption and search while the ingestion actor is blocked. All 55 native reader checks and 13 search UI checks passed. The page-expansion check activates the rendered NSButton directly; OS-level mouse injection into a duplicate app was unreliable, so it is not claimed as a physical-click test. The expansion screenshot was inspected. macOS Debug/Release and iOS Simulator release builds passed without compiler warnings.

On a private snapshot of 5,388 articles and 33,898 indexed pages, warm median complete searches measured 22.0 ms for “cell”, 35.5 ms for “microglia”, 30.1 ms for “from pixels” and 2.4 ms for the Uhlmann DOI. The old “cell” SQL measured 221.4 ms. The old microglia/from-pixels queries returned only 41/68 distinct papers in 100 rows, while the new queries return 100 papers; those timings are not equivalent workloads. Measurements exclude UI/debounce, cold caches and background contention. Evidence: Build/Search performance comparison.json, Build/Search UI verification.json and Build/Search reader verification.json. The private snapshot was deleted after measurement.

Installed the signed verified release to ~/Applications/Research Library.app and reopened it normally. Build/Research Library before search.app preserves the previous app for rollback.

## Sort and reader simplification

Search sorting now has deterministic null handling, normalized title ordering, stable tie breakers, and a publication-date mode for the visible “Newest publication” option. “Recently added” remains available when import chronology is the desired sort. The reader now uses one PDF per active reader pane; tabs still hold multiple open documents, but the side-by-side comparison state and menu have been removed. The library content area keeps one unified search field, with sorting as a separate compact control and no duplicate author, journal, or year fields.

Validation: all changed Swift sources pass parser validation and the existing reader/search fixture reports remain available. Full Xcode test/build execution was blocked in this environment after the approval quota was exhausted; the command failed before compilation because the sandbox could not access the user Swift module cache.

## Reader chrome simplification

The PDF navigation tools now live in the same right-hand Reader Sidebar as article metadata, behind a compact Metadata/PDF navigation switcher. The reader no longer renders a second left-side PDF sidebar. A single open PDF has no tab strip; tabs appear only when multiple documents are open. The reader toolbar keeps page movement, page entry, zoom, highlighting, and save state visible while moving highlight color and undo/redo into one menu. Command-F and other PDF navigation requests open the unified sidebar directly.

Validation: the changed sources pass Swift parser validation and the working tree passes `git diff --check`. Full Xcode compilation and installation remain pending because the environment approval quota is exhausted.

## OpenAlex research dashboard — October 9, 2026

Added an Overview homepage with Continue Reading, local research activity metrics, top-keyword pulse, and a personalized New Publications feed. OpenAlex work responses are cached under each library's `Metadata/OpenAlex/dashboard.json` with retrieval timestamps and complete raw JSON, while matched DOI records are merged into local metadata without overriding human edits. Exact DOI sync is available through “Sync OpenAlex”; the feed uses recent OpenAlex works weighted by the library's most frequent keywords.

OpenAlex credentials are stored in macOS Keychain through Settings and are never written into source, library snapshots, or logs. The dashboard remains useful without a key and clearly reports whether it is showing local-only or cached OpenAlex data. The application starts on Overview; All Items and the existing library scopes remain available in the sidebar.

Validation: ResearchCore type checking passed with Xcode's macOS SDK, and the Release macOS Xcode build completed successfully. The rebuilt app is installed at `Build/Research Library.app` and launched for review. OpenAlex live requests and full-library synchronization require the API key to be entered in Settings; the previously pasted chat key was not embedded in the application.

## Dashboard isolation and visual polish — October 13, 2026

Overview is now a dashboard-only workspace. Its compact middle column provides library activity at a glance, while the main detail surface holds the dashboard; it no longer presents the current PDF, PDF-unavailable state, reader toolbar, or Reader Sidebar. Open documents remain available when the user returns to a library section.

The dashboard uses restrained macOS materials, continuous rounded cards, semantic system tints, rounded numerical typography, adaptive metric cards, and compact keyword capsules. The result adds contrast and hierarchy without introducing a separate brand palette or decorative clutter.

Validation: source parser validation, `git diff --check`, and a Release macOS build passed. The signed build was installed at `~/Applications/Research Library.app` and launched.

## Dashboard and reader cache — October 13, 2026

Overview now saves a compact local snapshot of its metrics, reading queue, and keyword aggregates with the existing OpenAlex dashboard cache. On launch it can render that snapshot immediately, then refresh the full local index in the background. The snapshot contains no PDF bytes and stays small even for a large library.

Reader page thumbnails are now retained as PNGs under Application Support, keyed by PDF content hash and page number. The reader checks memory, then disk, before rendering a page again. The persistent cache is capped at 250 MB and removes least-recently-used files once it exceeds the limit; only pages opened in the thumbnail sidebar are stored.

Validation: parser validation and `git diff --check` passed, followed by a successful Release macOS build. The signed build was installed at `~/Applications/Research Library.app` and launched.
