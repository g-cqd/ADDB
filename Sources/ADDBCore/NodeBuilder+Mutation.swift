import ADFCore
public import ADSQLModel

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// B-tree page cell insertion, removal, compaction, and splitting for `Node` — the space-
/// management half, split from `NodeBuilder.swift` to keep the enum body within the gate.
extension Node {
    // MARK: - Insertion / removal

    /// Inserts an encoded cell of `size` bytes at slot `index`, claiming space
    /// from the cell area. Returns false when the page cannot fit it (split).
    static func insertCell(
        _ page: inout MutableRawSpan, at index: Int, size: Int,
        write: (inout MutableRawSpan, Int) -> Void
    ) -> Bool {
        let need = size + Format.slotSize
        // Header reads-during-write go through the page's read-only view.
        let (freeSpace, fragmented) = page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in
            unsafe (PageHeader.freeSpace(ro), PageHeader.fragmentedBytes(ro))
        }
        if freeSpace < need {
            guard freeSpace + fragmented >= need else { return false }
            compact(&page)
        }
        let (count, cellAreaStart) = page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in
            unsafe (PageHeader.cellCount(ro), PageHeader.cellAreaStart(ro))
        }
        let newOffset = cellAreaStart - size
        write(&page, newOffset)

        // Shift slots [index, count) up one position. The shift stays a single `memmove`
        // (overlapping, hot insert path) inside the span's mutable-bytes scope — not a byte loop.
        let slotBase = Format.nodeHeaderSize
        if count > index {
            let src = slotBase + index * Format.slotSize
            let len = (count - index) * Format.slotSize
            page.withUnsafeMutableBytes { buf in
                unsafe memmove(buf.baseAddress! + src + Format.slotSize, buf.baseAddress! + src, len)
                return
            }
        }
        PageHeader.setSlotOffset(&page, index, newOffset)
        PageHeader.setCellCount(&page, count + 1)
        PageHeader.setCellAreaStart(&page, newOffset)
        return true
    }

    @_spi(ADDBEngine) public static func leafInsert(
        _ page: inout MutableRawSpan, at index: Int,
        key: UnsafeRawBufferPointer, value: LeafValue
    ) -> Bool {
        insertCell(&page, at: index, size: leafCellSize(keyLen: key.count, value: value)) {
            unsafe encodeLeafCell(into: &$0, at: $1, key: key, value: value)
        }
    }

    @_spi(ADDBEngine) public static func branchInsert(
        _ page: inout MutableRawSpan, at index: Int,
        key: UnsafeRawBufferPointer, child: UInt64
    ) -> Bool {
        insertCell(&page, at: index, size: branchCellSize(keyLen: key.count)) {
            unsafe encodeBranchCell(into: &$0, at: $1, key: key, child: child)
        }
    }

    /// Removes the cell at slot `index`, accounting its bytes as fragmented
    /// (or reclaiming directly when it borders the cell area start).
    @_spi(ADDBEngine) public static func removeCell(_ page: inout MutableRawSpan, at index: Int) {
        let (count, offset, length, cellAreaStart, fragmented) =
            page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in
                unsafe (
                    PageHeader.cellCount(ro), PageHeader.slotOffset(ro, index), cellLength(ro, index),
                    PageHeader.cellAreaStart(ro), PageHeader.fragmentedBytes(ro)
                )
            }

        // Slot-array shift stays a single `memmove` (overlapping, hot delete path).
        let slotBase = Format.nodeHeaderSize
        if index < count - 1 {
            let dst = slotBase + index * Format.slotSize
            let len = (count - 1 - index) * Format.slotSize
            page.withUnsafeMutableBytes { buf in
                unsafe memmove(buf.baseAddress! + dst, buf.baseAddress! + dst + Format.slotSize, len)
                return
            }
        }
        PageHeader.setCellCount(&page, count - 1)
        if offset == cellAreaStart {
            PageHeader.setCellAreaStart(&page, offset + length)
        } else {
            PageHeader.setFragmentedBytes(&page, fragmented + length)
        }
    }

    /// Overwrites the child pointer of a branch cell in place (fixed width).
    @_spi(ADDBEngine) public static func branchSetChild(
        _ page: inout MutableRawSpan, at index: Int, child: UInt64
    ) {
        let offset = page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in
            unsafe PageHeader.slotOffset(ro, index)
        }
        page.storeLE64(child, at: offset + 2)
    }

    // MARK: - Compaction

    /// Rewrites the cell area densely (slot order preserved), clearing
    /// fragmentation. Uses a scratch copy of the page.
    @_spi(ADDBEngine) public static func compact(_ page: inout MutableRawSpan) {
        let scratch = page.withUnsafeBytes { (ro: UnsafeRawBufferPointer) in
            unsafe PageBuf(copying: ro)
        }
        let ro = unsafe scratch.readOnly
        let count = unsafe PageHeader.cellCount(ro)
        var writeEnd = Format.pageSize
        for i in 0 ..< count {
            let length = unsafe cellLength(ro, i)
            let src = unsafe PageHeader.slotOffset(ro, i)
            writeEnd -= length
            unsafe copyBytes(
                into: &page, at: writeEnd,
                from: UnsafeRawBufferPointer(rebasing: ro[src ..< src + length]))
            PageHeader.setSlotOffset(&page, i, writeEnd)
        }
        PageHeader.setCellAreaStart(&page, writeEnd)
        PageHeader.setFragmentedBytes(&page, 0)
    }

    // MARK: - Splits

    /// Raw bytes (header + payload) of the cell at slot `i`, viewed in place.
    @inline(__always)
    static func cellBytes(_ page: UnsafeRawBufferPointer, _ i: Int) -> UnsafeRawBufferPointer {
        let offset = unsafe PageHeader.slotOffset(page, i)
        return unsafe UnsafeRawBufferPointer(rebasing: page[offset ..< offset + cellLength(page, i)])
    }

    /// Key bytes of a standalone leaf-cell buffer, viewed in place.
    @inline(__always)
    static func leafCellKeyBytes(_ cell: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        let keyStart = unsafe cell[0] & leafOverflowFlag == 0 ? 5 : 15
        let keyLen = unsafe Int(cell.loadLE16(1))
        return unsafe UnsafeRawBufferPointer(rebasing: cell[keyStart ..< keyStart + keyLen])
    }

    /// Key bytes of a standalone branch-cell buffer, viewed in place.
    @inline(__always)
    static func branchCellKeyBytes(_ cell: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        let keyLen = unsafe Int(cell.loadLE16(0))
        return unsafe UnsafeRawBufferPointer(rebasing: cell[10 ..< 10 + keyLen])
    }

    static func keyOfCellImage(_ cell: [UInt8], type: PageType) -> [UInt8] {
        cell.withUnsafeBytes { raw in
            switch type {
                case .branch:
                    let keyLen = unsafe Int(raw.loadLE16(0))
                    return [UInt8](cell[10 ..< 10 + keyLen])
                default:
                    let keyLen = unsafe Int(raw.loadLE16(1))
                    let keyStart = unsafe raw[0] & leafOverflowFlag == 0 ? 5 : 15
                    return [UInt8](cell[keyStart ..< keyStart + keyLen])
            }
        }
    }

    /// Split point over the logical cells (the original page's cells with a
    /// `newCellSize` cell inserted at `index`): smallest prefix carrying ≥ half
    /// the bytes, clamped so both sides are non-empty. Mirrors the historical
    /// `splitPoint` but reads cell sizes from the page in place (no per-cell
    /// allocation).
    static func splitPointBySize(
        _ original: UnsafeRawBufferPointer, count: Int, newCellSize: Int, insertAt index: Int
    ) -> Int {
        let logical = count + 1
        func sizeOf(_ p: Int) -> Int {
            unsafe p == index ? newCellSize : cellLength(original, p < index ? p : p - 1)
        }
        var total = 0
        for p in 0 ..< logical { total += sizeOf(p) + Format.slotSize }
        var acc = 0
        for p in 0 ..< logical {
            acc += sizeOf(p) + Format.slotSize
            if acc * 2 >= total { return min(max(p + 1, 1), logical - 1) }
        }
        return logical - 1
    }

    /// Splits a full leaf while inserting (key, value) at `index`. Returns the
    /// separator key (first key of the right page).
    ///
    /// PRECONDITION: `original` must NOT alias `left` or `right` (it is read
    /// cell-by-cell *after* both target pages are zero-initialized). A caller whose
    /// left page aliases the page being split (the in-place COW case) snapshots the
    /// pre-split image into a standalone buffer and passes that as `original` — the
    /// same one 16 KiB copy this used to make internally, now hoisted to the caller
    /// (so a non-aliasing caller pays none).
    @_spi(ADDBEngine) public static func splitLeafInserting(
        original: UnsafeRawBufferPointer, at index: Int,
        key: UnsafeRawBufferPointer, value: LeafValue,
        left: inout MutableRawSpan, right: inout MutableRawSpan
    ) -> [UInt8] {
        let count = unsafe PageHeader.cellCount(original)
        let logical = count + 1
        let newSize = leafCellSize(keyLen: key.count, value: value)
        // Append/prepend bias: a key inserted at a leaf edge is the signature of a
        // sequential (often bulk) load. A 50/50 split there strands the just-filled
        // side at ~50% forever; keeping it packed and starting the new side with the
        // single edge cell yields ~100% fill on monotonic loads (random inserts land
        // interior and fall back to the balanced split).
        let split: Int
        if index == logical - 1 {
            split = logical - 1
        } else if index == 0 {
            split = 1
        } else {
            split = unsafe splitPointBySize(original, count: count, newCellSize: newSize, insertAt: index)
        }

        var newCell = [UInt8](repeating: 0, count: newSize)
        newCell.withUnsafeMutableBytes { raw in
            var cell = unsafe MutableRawSpan(_unsafeBytes: raw)
            unsafe encodeLeafCell(into: &cell, at: 0, key: key, value: value)
        }
        let src = unsafe original
        PageHeader.initialize(&left, type: .leaf)
        PageHeader.initialize(&right, type: .leaf)
        return newCell.withUnsafeBytes { (newBytes: UnsafeRawBufferPointer) -> [UInt8] in
            var leftEnd = Format.pageSize
            var rightEnd = Format.pageSize
            var leftSlot = 0
            var rightSlot = 0
            var separator: [UInt8] = []
            for p in 0 ..< logical {
                let bytes = unsafe p == index ? newBytes : cellBytes(src, p < index ? p : p - 1)
                if p < split {
                    leftEnd -= bytes.count
                    unsafe copyBytes(into: &left, at: leftEnd, from: bytes)
                    PageHeader.setSlotOffset(&left, leftSlot, leftEnd)
                    leftSlot += 1
                } else {
                    if p == split { separator = unsafe [UInt8](leafCellKeyBytes(bytes)) }
                    rightEnd -= bytes.count
                    unsafe copyBytes(into: &right, at: rightEnd, from: bytes)
                    PageHeader.setSlotOffset(&right, rightSlot, rightEnd)
                    rightSlot += 1
                }
            }
            PageHeader.setCellCount(&left, leftSlot)
            PageHeader.setCellAreaStart(&left, leftEnd)
            PageHeader.setCellCount(&right, rightSlot)
            PageHeader.setCellAreaStart(&right, rightEnd)
            return separator
        }
    }

    /// Splits a full branch while inserting (key, child) at cell position
    /// `index`. The middle key moves *up*: it is returned as the separator and
    /// its child becomes the right page's leftmost child.
    ///
    /// PRECONDITION: `original` must NOT alias `left` or `right` (read cell-by-cell
    /// after both targets are zero-initialized). An in-place caller snapshots the
    /// pre-split page and passes that — the copy is hoisted to the caller (see
    /// ``splitLeafInserting(original:at:key:value:left:right:)``).
    @_spi(ADDBEngine) public static func splitBranchInserting(
        original: UnsafeRawBufferPointer, at index: Int,
        key: UnsafeRawBufferPointer, child: UInt64,
        left: inout MutableRawSpan, right: inout MutableRawSpan
    ) -> [UInt8] {
        let leftmost = unsafe PageHeader.link(original)
        let count = unsafe PageHeader.cellCount(original)
        let logical = count + 1
        let newSize = branchCellSize(keyLen: key.count)
        let mid = unsafe splitPointBySize(original, count: count, newCellSize: newSize, insertAt: index)

        var newCell = [UInt8](repeating: 0, count: newSize)
        newCell.withUnsafeMutableBytes { raw in
            var cell = unsafe MutableRawSpan(_unsafeBytes: raw)
            unsafe encodeBranchCell(into: &cell, at: 0, key: key, child: child)
        }
        let src = unsafe original
        // The middle cell is promoted: its key is the separator and its child becomes the right
        // page's leftmost link; it lands on neither page. Read it (and the promoted child) before
        // the page writes so the `inout` span borrows don't overlap the `newCell` borrow.
        let (separator, promotedChild) = newCell.withUnsafeBytes {
            (newBytes: UnsafeRawBufferPointer) -> ([UInt8], UInt64) in
            let midCell = unsafe mid == index ? newBytes : cellBytes(src, mid < index ? mid : mid - 1)
            return unsafe ([UInt8](branchCellKeyBytes(midCell)), midCell.loadLE64(2))
        }

        PageHeader.initialize(&left, type: .branch)
        PageHeader.setLink(&left, leftmost)
        PageHeader.initialize(&right, type: .branch)
        PageHeader.setLink(&right, promotedChild)
        newCell.withUnsafeBytes { (newBytes: UnsafeRawBufferPointer) in
            var leftEnd = Format.pageSize
            var leftSlot = 0
            for p in 0 ..< mid {
                let bytes = unsafe p == index ? newBytes : cellBytes(src, p < index ? p : p - 1)
                leftEnd -= bytes.count
                unsafe copyBytes(into: &left, at: leftEnd, from: bytes)
                PageHeader.setSlotOffset(&left, leftSlot, leftEnd)
                leftSlot += 1
            }
            PageHeader.setCellCount(&left, leftSlot)
            PageHeader.setCellAreaStart(&left, leftEnd)

            var rightEnd = Format.pageSize
            var rightSlot = 0
            for p in (mid + 1) ..< logical {
                let bytes = unsafe p == index ? newBytes : cellBytes(src, p < index ? p : p - 1)
                rightEnd -= bytes.count
                unsafe copyBytes(into: &right, at: rightEnd, from: bytes)
                PageHeader.setSlotOffset(&right, rightSlot, rightEnd)
                rightSlot += 1
            }
            PageHeader.setCellCount(&right, rightSlot)
            PageHeader.setCellAreaStart(&right, rightEnd)
        }
        return separator
    }
}
