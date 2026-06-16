// Instruments signpost intervals for the writer / reader paths. Compiled in only
// when the package is built with `ADDB_SIGNPOSTS=1` (a dev/bench profiling build);
// `os` is a system framework — never a package dependency — and OSSignposter ships
// back to the platform floor. On a default build (and anywhere `os` is unavailable,
// e.g. Linux) the `#else` no-ops inline to just `body()`, so the shipping library
// pays nothing and the call sites need no `#if`.

#if ADDB_SIGNPOSTS && canImport(os)
    import os

    enum Signposts {
        static let writer = OSSignposter(subsystem: "fr.gcqd.addb", category: "writer")
        static let reader = OSSignposter(subsystem: "fr.gcqd.addb", category: "reader")
    }

    @inline(__always)
    func withWriterSignpost<R, E: Error>(
        _ name: StaticString, _ body: () throws(E) -> R
    ) throws(E) -> R {
        let state = Signposts.writer.beginInterval(name, id: Signposts.writer.makeSignpostID())
        defer { Signposts.writer.endInterval(name, state) }
        return try body()
    }

    @inline(__always)
    func withReaderSignpost<R, E: Error>(
        _ name: StaticString, _ body: () throws(E) -> R
    ) throws(E) -> R {
        let state = Signposts.reader.beginInterval(name, id: Signposts.reader.makeSignpostID())
        defer { Signposts.reader.endInterval(name, state) }
        return try body()
    }
#else
    @inline(__always)
    func withWriterSignpost<R, E: Error>(
        _ name: StaticString, _ body: () throws(E) -> R
    ) throws(E) -> R {
        try body()
    }

    @inline(__always)
    func withReaderSignpost<R, E: Error>(
        _ name: StaticString, _ body: () throws(E) -> R
    ) throws(E) -> R {
        try body()
    }
#endif
