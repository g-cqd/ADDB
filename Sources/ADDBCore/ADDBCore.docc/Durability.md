# Durability and crash safety

Why a committed ADDB database is recoverable after a crash or power loss, and how to choose a durability profile.

## Overview

ADDB is **crash-safe by construction**, not by replaying a journal. Because a
write only ever shadows pages into fresh locations and never overwrites a page a
committed generation can see, the previous committed state stays intact on disk
throughout a write. A commit becomes visible by atomically publishing a new root
into one of two **meta pages**; each meta page is XXH64-checksummed.

Recovery is therefore trivial and always available: on open, ADDB picks the
**newest meta page whose checksum is valid**. A crash mid-commit can at worst
leave a torn or stale meta page, which fails its checksum and is ignored — so the
database opens at the last fully-committed generation. There is no journal to
replay and no half-applied transaction to undo.

## Durability profiles

A commit publishes the new root only after the data pages are on stable storage.
How forcefully those bytes are pushed is the durability profile, set on
`DatabaseOptions`:

- **`.barrier`** (default) — one `F_BARRIERFSYNC` per commit: orders writes so a
  power loss can never expose an out-of-order, torn image, at far lower cost than
  a full flush. Crash-consistent by construction.
- **`.full`** — `F_FULLFSYNC` per commit: forces the drive to flush its cache.
  The strongest guarantee macOS offers, and the slowest.
- **`.none`** — no barrier (bulk load / ephemeral data). Still internally
  consistent on a clean process exit, but a power loss can lose recent commits.

Choose `.barrier` for normal use, `.full` when surviving sudden power loss with
zero committed-data loss is required, and `.none` only for rebuildable data.
