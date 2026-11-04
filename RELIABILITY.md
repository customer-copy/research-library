# Reliability and performance

The first hardening phase covers regular Inbox imports, reader saves and PDF opening. These are application-level recovery guarantees, not a distributed transaction across iCloud devices.

## Import commit and recovery

Before installing an attachment, the persisted Inbox request records the selected destination, expected SHA-256, stable resource ID and metadata candidate. File copying uses a temporary file and verifies its hash before a rename that refuses an occupied destination. File coordination protects cooperating writers. The source stays intact until a committed metadata sidecar and verified organized attachment permit cleanup.

A restart replays the recorded destination instead of generating another suffixed filename. A changed source or conflicting destination fails safely and retains the Inbox original. Existing metadata edits win over a stale checkpoint; an unchanged base record receives the planned enrichment. Verified edits to the organized PDF can resume using its pre-edit recovery copy. Derived text is indexed before the import completes. The checkpoint is cleared only at completion. Old requests without checkpoints continue through the legacy recovery path.

Reader saves can retry when PDF bytes committed before metadata: only identical replacement bytes plus a verified original recovery copy qualify. A different external edit remains a conflict.

## Attachment availability

An existing path is not proof that a PDF is readable. Opening checks cloud residency, PDF readability and identifier compatibility. Pending cloud downloads remain pending; unreadable or conflicting attachments enter review and retain their bytes. Verification is cached for at most 64 attachments and invalidated by changes to path, file size, inode, modification time, change time or filesystem flags. Repairing an attachment rechecks local bytes without waiting for the online-lookup cooldown.

Reader I/O, hashing, validation and PDF parsing run off the UI thread. UI objects stay on the main actor; a newly parsed PDFDocument transfers exclusive ownership after its worker completes. Loading rechecks attachment identity and deletion after suspension. Metadata edits made while a reader load is waiting are preserved.

## Startup and measurement

The app applies deletion tombstones, then presents its cached local index while metadata reconciliation runs. A rebuildable SQLite table retains file revisions across launches. Unchanged local sidecars avoid decoding and reindexing; replacing a file with the same size and modification date is still detected through inode/change time. Resetting the derived index clears its persisted revision markers.

Instruments signposts cover PDF reads, PDF lookup, import commits and metadata reconciliation. Exported diagnostics include bounded session timing counters (count, total, last and maximum milliseconds), without document text in those timing fields.

Run `Scripts/benchmark-macos.sh` for a disposable 5,000-record local fixture. Results are saved to `Build/Reliability performance baseline.json`. On the October 8, 2026 development run, existing-index reconciliation fell from 3,372 ms before persisted revisions to 67 ms afterward. First indexing was 4,992 ms; one-page PDF loading was 2.4 ms; bibliographic search was 0.7 ms. These measurements exclude full UI launch/rendering, large PDFs, OCR, cloud latency and user-library performance. They are baselines, not production service-level guarantees.

## Validation and remaining work

Recovery tests simulate interruptions after planning, copying and metadata commit, including filename collisions and loss of the derived database. Further tests cover changed files, metadata edits, PDF edits, retrying a partially committed reader save, corrupt PDFs, atomic file replacement, and interactive queries during a blocked PDF read. Existing reader fixture checks cover native presentation, highlights, save-before-close, tabs and cloud waits.

This phase does not supply multi-device processing leases, a full job scheduler, event-driven cloud reconciliation, notarized distribution or a persistent content catalog for every unassociated PDF. ZIP processing retains its existing recovery implementation. Power-loss filesystem durability and real multi-device/offline iCloud stress tests remain separate validation work. Future hardening should target those areas using the recorded timing evidence.
