# Concurrency and the MVCC model

How ADSQL serves many concurrent readers and one writer without locks on the read path.

## Overview

ADSQL is **single-writer / wait-free-reader**. At any instant there is at most
one write transaction, while any number of read transactions run concurrently —
and a reader never blocks the writer, nor the writer a reader.

The store is a **copy-on-write B+tree** over an `mmap`'d page heap. A write never
mutates a page that a committed generation can see: it shadows the pages it
touches into fresh pages and publishes a new root atomically at commit. A read
transaction captures the current root (a *generation*) when it begins and reads
only pages reachable from it, so it sees a stable, immutable snapshot for its
whole lifetime regardless of writes that land in the meantime.

### Reading

`Database.read` borrows a `ReadTxn` for the duration of a closure. The snapshot
is pinned for that scope and released at the end; the transaction is noncopyable,
so it cannot escape the closure and outlive its registration.

```swift
let count = try db.read { txn in
    try txn.contains(key) ? 1 : 0
}
```

Point lookups (`get`, `contains`) copy out the value; `withValue(forKey:)` hands
the value to a closure as a bounds-checked, non-escaping span over the mapped
page — no allocation for inline values.

### Writing

`Database.writeSync` runs one exclusive write transaction on a dedicated writer
thread and returns once it is durably committed (per the database's durability
profile). The closure receives a `WriteTxn`; on a thrown error nothing is
persisted.

### Page reclamation

Pages shadowed by a write can be recycled only once no live reader can still see
them. Reader registration and meta publication share one critical section, so the
writer's reclamation horizon can never advance past a reader that is still
acquiring its snapshot. Cross-process readers register in a shared lock-file slot
table, and the writer takes the minimum live generation across all processes
before reclaiming — so a second process reading the same file is respected too.
