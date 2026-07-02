# ``ADDBFTS``

Full-text search as an opt-in superset of ADSQL — an FTS5-compatible `MATCH`
surface with BM25 ranking, layered over the engine's full-text index.

## Overview

`import ADDBFTS` yields the whole SQL surface plus full-text search:
the module re-exports `ADSQL` (which re-exports the engine), so one import gives
you the engine, the SQL language, and `MATCH` / `rank` / `bm25`. Call
`enableFullTextSearch()` once on a database to register the query evaluator; the
full-text *index* itself is part of the engine and is maintained on every write,
but the query language is only available once this module is imported and enabled.

```swift
import ADDBFTS

let db = try Database.open(at: "/tmp/app.adsql")
defer { db.close() }
db.enableFullTextSearch()

try db.prepare(
    "CREATE VIRTUAL TABLE documents_fts USING fts5(title, body, tokenize='porter unicode61')"
).run()
try db.prepare("INSERT INTO documents_fts(rowid, title, body) VALUES (?, ?, ?)")
    .run(.integer(1), .text("swift programming"), .text("the quick brown fox"))

// Ranked search: BM25 via the `rank` column, top-k accelerated by a WAND scorer.
let hits = try db.prepare(
    "SELECT rowid, rank FROM documents_fts WHERE documents_fts MATCH ? ORDER BY rank LIMIT 10"
).all(.text("swift AND quick"))
```

Without `enableFullTextSearch()`, a `MATCH` query throws a clear error directing
you to import this module. See <doc:FullTextSearch> for the tokenizers, the `MATCH`
query grammar, BM25 ranking, and the robustness bounds on untrusted query strings.

## Topics

### Guides

- <doc:FullTextSearch>
