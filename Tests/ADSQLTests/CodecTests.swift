import ADFCore
import ADSQLModel
import Testing

@_spi(ADDBEngine) @testable import ADDBCore
@_spi(ADDBEngine) @testable import ADDBExec
@testable import ADSQL

/// White-box page-poke helpers over the new `MutableRawSpan` vending scope (`PageBuf` no longer
/// exposes a bare pointer). These mutate a single owned page; the read-modify-write helpers read
/// through the span's borrowing view and store back, exactly as the kernel's own codec does.
extension PageBuf {
    /// XORs the byte at `offset` with `mask` (corruption injection).
    fileprivate func pokeXOR(_ offset: Int, _ mask: UInt8) {
        withMutableBytes { page in
            let current = page.bytes.unsafeLoadUnaligned(fromByteOffset: offset, as: UInt8.self)
            page.storeBytes(of: current ^ mask, toByteOffset: offset, as: UInt8.self)
        }
    }
    /// Overwrites the byte at `offset`.
    fileprivate func pokeByte(_ offset: Int, _ value: UInt8) {
        withMutableBytes { page in
            page.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
        }
    }
    fileprivate func pokeLE16(_ value: UInt16, at offset: Int) {
        withMutableBytes { $0.storeLE16(value, at: offset) }
    }
    fileprivate func pokeLE32(_ value: UInt32, at offset: Int) {
        withMutableBytes { $0.storeLE32(value, at: offset) }
    }
    fileprivate func pokeLE64(_ value: UInt64, at offset: Int) {
        withMutableBytes { $0.storeLE64(value, at: offset) }
    }
}

@Suite("Meta codec")
struct MetaCodecTests {
    func makeMeta(generation: UInt64) -> Meta {
        Meta(
            generation: generation, rootPage: 7, freeRootPage: 9,
            pageCount: 42, kvCount: 12345, treeDepth: 3, flags: 0,
            freeDepth: 2, freeEntryCount: 6)
    }

    @Test func roundTrip() {
        let buf = PageBuf()
        let meta = makeMeta(generation: 11)
        buf.withMutableBytes { meta.encode(into: &$0, pageNo: 1) }
        #expect(Meta.decode(from: buf.readOnly, pageNo: 1) == .valid(meta))
    }

    @Test func checksumIsSeededByPageNo() {
        let buf = PageBuf()
        buf.withMutableBytes { makeMeta(generation: 4).encode(into: &$0, pageNo: 0) }
        // Same bytes presented as the other meta page must fail validation.
        #expect(Meta.decode(from: buf.readOnly, pageNo: 1) == .corrupt)
    }

    @Test func flippedBitIsCorrupt() {
        let buf = PageBuf()
        buf.withMutableBytes { makeMeta(generation: 4).encode(into: &$0, pageNo: 0) }
        buf.pokeXOR(33, 0x40)
        #expect(Meta.decode(from: buf.readOnly, pageNo: 0) == .corrupt)
    }

    @Test func zeroPageIsNotAMeta() {
        let buf = PageBuf()
        #expect(Meta.decode(from: buf.readOnly, pageNo: 0) == .notAMeta)
    }

    @Test func wrongVersionIsStructural() {
        let buf = PageBuf()
        buf.withMutableBytes { makeMeta(generation: 1).encode(into: &$0, pageNo: 0) }
        buf.pokeLE32(99, at: Meta.Offset.formatVersion)
        #expect(Meta.decode(from: buf.readOnly, pageNo: 0) == .unsupportedVersion(99))
    }

    @Test func recoveryPicksNewestValid() throws {
        let m0 = PageBuf()
        let m1 = PageBuf()
        m0.withMutableBytes { makeMeta(generation: 10).encode(into: &$0, pageNo: 0) }
        m1.withMutableBytes { makeMeta(generation: 11).encode(into: &$0, pageNo: 1) }
        #expect(try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly).generation == 11)

        // Torn newest meta → fall back to the older valid one.
        m1.pokeXOR(60, 0xFF)
        #expect(try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly).generation == 10)
    }

    @Test func recoveryFailsWhenBothInvalid() {
        let m0 = PageBuf()
        let m1 = PageBuf()
        m0.withMutableBytes { makeMeta(generation: 1).encode(into: &$0, pageNo: 0) }
        m1.withMutableBytes { makeMeta(generation: 2).encode(into: &$0, pageNo: 1) }
        m0.pokeXOR(16, 1)
        m1.pokeXOR(16, 1)
        #expect(throws: DBError.bothMetasInvalid) {
            try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly)
        }
    }

    @Test func recoveryOnForeignFileIsBadMagic() {
        let m0 = PageBuf()
        let m1 = PageBuf()
        #expect(throws: DBError.badMagic) {
            try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly)
        }
    }

    @Test func unsupportedVersionBeatsCorrupt() {
        let m0 = PageBuf()
        let m1 = PageBuf()
        m0.withMutableBytes { makeMeta(generation: 1).encode(into: &$0, pageNo: 0) }
        m0.pokeLE32(7, at: Meta.Offset.formatVersion)
        #expect(throws: DBError.unsupportedFormatVersion(7)) {
            try Meta.recover(meta0: m0.readOnly, meta1: m1.readOnly)
        }
    }
}

@Suite("Page header")
struct PageHeaderTests {
    @Test func initializeAndRoundTrip() {
        let buf = PageBuf(zeroed: false)
        buf.withMutableBytes { PageHeader.initialize(&$0, type: .leaf) }
        #expect(PageHeader.pageType(buf.readOnly) == .leaf)
        #expect(PageHeader.cellCount(buf.readOnly) == 0)
        #expect(PageHeader.cellAreaStart(buf.readOnly) == Format.pageSize)
        #expect(PageHeader.fragmentedBytes(buf.readOnly) == 0)
        #expect(PageHeader.link(buf.readOnly) == 0)
        #expect(PageHeader.freeSpace(buf.readOnly) == Format.pageSize - Format.nodeHeaderSize)

        buf.withMutableBytes { PageHeader.setCellCount(&$0, 3) }
        buf.withMutableBytes { PageHeader.setCellAreaStart(&$0, 16000) }
        buf.withMutableBytes { PageHeader.setFragmentedBytes(&$0, 17) }
        buf.withMutableBytes { PageHeader.setLink(&$0, 0xDEAD) }
        buf.withMutableBytes { PageHeader.setSlotOffset(&$0, 0, 16100) }
        buf.withMutableBytes { PageHeader.setSlotOffset(&$0, 1, 16050) }
        buf.withMutableBytes { PageHeader.setSlotOffset(&$0, 2, 16000) }

        #expect(PageHeader.cellCount(buf.readOnly) == 3)
        #expect(PageHeader.cellAreaStart(buf.readOnly) == 16000)
        #expect(PageHeader.fragmentedBytes(buf.readOnly) == 17)
        #expect(PageHeader.link(buf.readOnly) == 0xDEAD)
        #expect(PageHeader.slotOffset(buf.readOnly, 0) == 16100)
        #expect(PageHeader.slotOffset(buf.readOnly, 1) == 16050)
        #expect(PageHeader.slotOffset(buf.readOnly, 2) == 16000)
        #expect(PageHeader.freeSpace(buf.readOnly) == 16000 - Format.nodeHeaderSize - 6)
    }

    @Test func unknownPageTypeIsNil() {
        let buf = PageBuf()
        buf.pokeByte(PageHeader.Offset.pageType, 200)
        #expect(PageHeader.pageType(buf.readOnly) == nil)
    }

    @Test func checksumStampAndVerify() {
        let buf = PageBuf(zeroed: false)
        buf.withMutableBytes { PageHeader.initialize(&$0, type: .branch) }
        buf.withMutableBytes { PageHeader.setLink(&$0, 5) }
        buf.withMutableBytes { PageHeader.stampChecksum(&$0, pageNo: 77) }
        #expect(PageHeader.verifyChecksum(buf.readOnly, pageNo: 77))
        // Wrong location → fail (seeded by page number).
        #expect(!PageHeader.verifyChecksum(buf.readOnly, pageNo: 78))
        // Any body bit flip → fail.
        buf.pokeXOR(9000, 0x02)
        #expect(!PageHeader.verifyChecksum(buf.readOnly, pageNo: 77))
    }

    @Test func unalignedStoresWork() {
        let buf = PageBuf()
        buf.pokeLE64(0x0102_0304_0506_0708, at: 13)
        #expect(buf.readOnly.loadLE64(13) == 0x0102_0304_0506_0708)
        #expect(buf.readOnly[13] == 0x08)  // little-endian byte order on disk
        buf.pokeLE32(0xAABB_CCDD, at: 1)
        #expect(buf.readOnly.loadLE32(1) == 0xAABB_CCDD)
        buf.pokeLE16(0xBEEF, at: 3)  // overlaps the 32-bit store above
        #expect(buf.readOnly.loadLE16(3) == 0xBEEF)
    }
}
