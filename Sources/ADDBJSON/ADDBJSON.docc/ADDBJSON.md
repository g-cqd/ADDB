# ``ADDBJSON``

The SQLite `json1` surface as an opt-in superset of ADSQL — `json_*` functions, the
`->` / `->>` operators, `json_each`, and the `json_group_*` aggregates.

## Overview

`import ADDBJSON` yields the whole SQL surface plus JSON: the module re-exports
`ADSQL` (which re-exports the engine), so one import gives you the engine, the SQL
language, and the JSON functions after a one-time `enableJSON()`. The JSON
functions back onto ADJSON's RFC 8259 parser and RFC 7396 merge; they are not
registered in the ADSQL core, so a JSON query throws a clear error until this module
is imported and enabled.

```swift
import ADDBJSON

let db = try Database.open(at: "/tmp/app.adsql")
defer { db.close() }
db.enableJSON()

try db.prepare("CREATE TABLE events(id INTEGER PRIMARY KEY, payload TEXT)").run()
try db.prepare("INSERT INTO events(id, payload) VALUES (?, ?)")
    .run(.integer(1), .text(#"{"kind":"click","score":42}"#))

// Extract a value by path, with json_extract or the ->> operator:
let kinds = try db.prepare("SELECT payload ->> '$.kind' FROM events").all()
let scores = try db.prepare("SELECT json_extract(payload, '$.score') FROM events").all()

// Expand a JSON array into rows with json_each:
let tags = try db.prepare("SELECT value FROM json_each('[\"a\",\"b\",\"c\"]')").all()

// Aggregate rows back into a JSON document:
let arr = try db.prepare("SELECT json_group_array(id) FROM events").all()
```

### What `enableJSON()` registers

- **Scalars** — `json`, `json_extract`, `json_array`, `json_object`,
  `json_type`, `json_valid`, `json_quote`, and the rest of the `json_*` family.
- **Operators** — `->` (returns a JSON subtree) and `->>` (returns a SQL scalar),
  and the `json_each` table-valued function used in `FROM` / `IN (SELECT …)`.
- **Aggregates** — `json_group_array` and `json_group_object`.

`->` yields JSON text for the addressed element, while `->>` yields the
SQL-typed scalar (text/number/null); both accept a `'$.path'` or a bare key/index.
Extraction and validation follow SQLite's `json1` semantics, verified by a
differential suite against SQLite.
