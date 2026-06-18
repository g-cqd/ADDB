/// On-disk format v0 constants. The format is little-endian throughout.
///
/// File layout: pages 0 and 1 are the ping-pong meta pages; every other page
/// is a typed node (branch, leaf, overflow, freelist). Committed pages are
/// immutable: a write transaction only ever writes to pages that no committed
/// meta references, so torn writes cannot corrupt committed state.
public enum Format {
    /// "ADSQLv0\0"
    public static let magicBytes: [UInt8] = Array("ADSQLv0".utf8) + [0]
    public static let lockMagicBytes: [UInt8] = Array("ADSQLLCK".utf8)

    /// v1: adds the catalog FTS record kind (`0x66`) and its three owned
    /// B+trees — gates older readers that would silently ignore FTS tables.
    public static let formatVersion: UInt32 = 1
    public static let pageSize: Int = 16384
    /// Tearing granularity assumed by the crash model (APFS/NVMe sector writes).
    public static let subBlockSize: Int = 4096

    public static let metaPageCount: UInt64 = 2
    public static let metaHeaderSize: Int = 128
    public static let nodeHeaderSize: Int = 32
    public static let slotSize: Int = 2

    /// Keys are raw bytes, compared lexicographically (memcmp order).
    public static let maxKeySize: Int = 1024
    /// A cell whose encoded size exceeds this spills its value to overflow pages.
    /// Chosen so a leaf always holds at least 4 cells:
    /// 4 × (4064 + 2-byte slot) = 16264 ≤ 16352 usable bytes.
    public static let maxInlineCellSize: Int = 4064

    public static let usablePageSize: Int = pageSize - nodeHeaderSize
    public static let overflowCapacity: Int = pageSize - nodeHeaderSize

    /// Upper bound on the eager `reserveCapacity` when reassembling an overflow
    /// value. The value length is read from a (possibly corrupt) leaf cell, so a
    /// crafted huge length must never trigger a multi-GB up-front allocation
    /// (DoS). The output still grows to the true length as REAL chain pages are
    /// read — only pages that actually resolve contribute bytes — so legitimate
    /// values are unaffected apart from a few re-growths past this size. 64 MiB
    /// pre-sizes essentially every real value exactly.
    public static let overflowReserveCap: Int = 64 << 20

    /// First allocatable data page.
    public static let firstDataPage: UInt64 = 2

    /// Hard ceiling on B+tree height. A 16 KiB page holds ≥4 cells, so even a
    /// 64 GiB database nests only ~11 levels; 64 is generous headroom. The tree
    /// walks (`forEach`/`validate`, and `freeTree` via `validate`) reject a
    /// handle whose `depth` exceeds it, bounding their recursion to a trivially
    /// stack-safe constant instead of trusting an attacker/corrupt-file-controlled
    /// depth that would otherwise overflow the stack.
    public static let maxTreeDepth: UInt16 = 64

    /// Main-tree keys beginning with this byte belong to the relational
    /// catalog; the public KV API rejects them.
    public static let reservedKeyPrefix: UInt8 = 0x00

    /// Reader table (lock file) layout.
    public static let lockHeaderSize: Int = 128
    public static let readerSlotSize: Int = 128
    public static let readerSlotCount: Int = 126
    public static let lockFileSize: Int = lockHeaderSize + readerSlotCount * readerSlotSize  // 16256 ≤ 16 KiB
}

public enum PageType: UInt8, Sendable {
    case branch = 1
    case leaf = 2
    case overflow = 3
    case freelist = 4
}
