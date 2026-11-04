# Search behavior and performance

Library search uses a separate read-only SQLite WAL connection owned by its own actor. Searches do not queue behind ingestion work in LibraryService. A cancelled task signals a request-specific, locked cancellation token checked by SQLite's progress handler. Obsolete running queries are interrupted, queued cancelled requests are skipped, and rollback/finalization leave the connection usable.

Typing in the search, author or journal fields pauses for 180 ms before starting a query. Submitting the search runs immediately. Request generations prevent stale results, errors or completion state from replacing a newer query. Existing results remain while typing; metadata previews replace them when available. A progress indicator distinguishes pending search from PDF-text lookup. Empty-state messaging waits until the search has finished.

Relevance order currently places matching metadata articles first, using weighted FTS5 rank. Ranked PDF hits then fill the remaining article slots, skipping papers already returned. Reading stops once enough distinct papers have been found. Custom title/year/date sorts select distinct matching articles in their global sort order. Repeated pagination retains one row per article. Article selection IDs remain stable between metadata preview and final results.

Only selected results receive decoded metadata, excerpts and citation details. Chunk/section details are fetched in bounded batches rather than issuing several separate queries per result. Opening Matching PDF pages lazily retrieves five page excerpts; Show more pages expands to at most twenty. Each page opens its matching PDF at the cited page. These controls are excluded from the row-wide PDF mouse handler.

The additive page_fts_lookup table maps article/resource/page to FTS row IDs. Existing local indexes backfill the mapping once. Indexing, resource reindexing, item removal and index reset maintain it. This is rebuildable local data; no authoritative metadata or PDF format changes.

## Measurement

Run `Scripts/benchmark-search.sh /path/to/index.sqlite` to create a private, temporary SQLite backup and benchmark it. The live index is opened read-only. The copy is migrated and deleted afterward. The report in Build/Search performance comparison.json contains timing and result counts, not document text or bibliographic records.

Measurements report the warm median of three runs. The legacy baseline measures SQL selection/excerpts only; the new search includes metadata decoding, excerpts and citation hydration. UI rendering, the intentional typing debounce, disk-cold behavior and background contention are excluded. Returning 100 distinct papers also does more useful work than the old 100-row page list, which could repeat papers.

The first implementation deliberately preserves literal-term/quoted-phrase behavior. Prefix matching, typo tolerance, explicit field syntax, identifier/title ranking tiers and separate user-selectable metadata/PDF scopes remain later improvements. This is lexical search, not semantic or remote search. Only extracted/indexed PDF text is searchable.
