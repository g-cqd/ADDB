public import ADSQLModel

/// Deletion with merge-or-borrow rebalancing.
///
/// A node falling under quarter-page payload (or emptied) merges with a
/// sibling when the combined payload fits one page, otherwise borrows the
/// sibling's edge cell (rotating it through the parent separator). Only pages
/// that actually mutate are shadowed; a page that merely disappears in a
/// merge is read in place and freed.
extension BTree {
    struct PathNode {
        var pageNo: UInt64
        var buf: PageBuf
        /// Child position taken during descent: -1 = leftmost link.
        var slot: Int
    }

    /// Returns true when the key existed.
    @inline(__always)
    public static func delete(
        ctx: TxnContext, key: UnsafeRawBufferPointer
    ) throws(DBError) -> Bool {
        var tree = ctx.meta.mainTree
        let existed = unsafe try delete(ctx: ctx, tree: &tree, key: key)
        ctx.meta.mainTree = tree
        return existed
    }

    public static func delete(
        ctx: TxnContext, tree: inout TreeHandle, key: UnsafeRawBufferPointer
    ) throws(DBError) -> Bool {
        guard unsafe !key.isEmpty else { throw DBError.keyEmpty }
        guard key.count <= Format.maxKeySize else { throw DBError.keyTooLarge(key.count) }
        guard tree.rootPage != 0 else { return false }

        // Existence probe first: missing keys must not shadow anything.
        guard unsafe try get(resolver: ctx, tree: tree, key: key) != nil else { return false }

        var (currentNo, currentBuf) = try ctx.shadow(tree.rootPage)
        tree.rootPage = currentNo
        var path: [PathNode] = []

        var level = tree.depth
        while level > 1 {
            let ro = unsafe currentBuf.readOnly
            let slot = unsafe Node.branchChildSlot(ro, key: key)
            let childNo = unsafe slot < 0 ? PageHeader.link(ro) : Node.branchChild(ro, slot)
            let (newChildNo, childBuf) = try ctx.shadow(childNo)
            if newChildNo != childNo {
                currentBuf.withMutableBytes { page in
                    if slot < 0 {
                        PageHeader.setLink(&page, newChildNo)
                    } else {
                        Node.branchSetChild(&page, at: slot, child: newChildNo)
                    }
                }
            }
            path.append(PathNode(pageNo: currentNo, buf: currentBuf, slot: slot))
            (currentNo, currentBuf) = (newChildNo, childBuf)
            level -= 1
        }

        let ro = unsafe currentBuf.readOnly
        let (index, exact) = unsafe Node.search(ro, key: key)
        guard exact else {
            throw DBError.integrityFailure("delete probe found key but descent did not")
        }
        let cell = unsafe Node.leafCell(ro, index)
        if unsafe cell.inlineValue == nil {
            var pager = ctx
            try Overflow.free(head: cell.overflowHead, pager: &pager)
        }
        currentBuf.withMutableBytes { page in
            Node.removeCell(&page, at: index)
        }
        tree.count -= 1

        try rebalance(
            ctx, tree: &tree, path: path, nodePageNo: currentNo, nodeBuf: currentBuf,
            level: path.count)
        return true
    }

    // MARK: - Rebalancing

    @inline(__always)
    static func payloadBytes(_ page: UnsafeRawBufferPointer) -> Int {
        unsafe (Format.pageSize - PageHeader.cellAreaStart(page) - PageHeader.fragmentedBytes(page))
            + PageHeader.cellCount(page) * Format.slotSize
    }

    static var rebalanceThreshold: Int { Format.usablePageSize / 4 }

    /// `level == path.count` means `node` is the leaf; otherwise
    /// `path[level]` *is* the node.
    private static func rebalance(
        _ ctx: TxnContext, tree: inout TreeHandle, path: [PathNode],
        nodePageNo: UInt64, nodeBuf: PageBuf, level: Int
    ) throws(DBError) {
        let ro = unsafe nodeBuf.readOnly
        let isLeaf = level == path.count

        if level == 0 || (path.isEmpty && isLeaf) {
            // Root rules: empty the tree, or collapse one height level.
            if isLeaf {
                if unsafe PageHeader.cellCount(ro) == 0 {
                    ctx.freePage(nodePageNo)
                    tree.rootPage = 0
                    tree.depth = 0
                }
            } else if unsafe PageHeader.cellCount(ro) == 0 {
                tree.rootPage = unsafe PageHeader.link(ro)
                tree.depth -= 1
                ctx.freePage(nodePageNo)
            }
            return
        }

        if unsafe payloadBytes(ro) >= rebalanceThreshold {
            return
        }

        let parent = path[level - 1]
        let parentRO = unsafe parent.buf.readOnly
        let parentCount = unsafe PageHeader.cellCount(parentRO)
        let slot = parent.slot

        if slot + 1 <= parentCount - 1 {
            // Right sibling exists: (left=node, right=sibling), parent cell slot+1.
            let rightNo = unsafe Node.branchChild(parentRO, slot + 1)
            try rebalancePair(
                ctx, tree: &tree, path: path, level: level,
                leftNo: nodePageNo, leftBuf: nodeBuf, leftIsTarget: true,
                rightNo: rightNo, rightBuf: nil,
                parentCellIndex: slot + 1, isLeaf: isLeaf)
        } else if slot >= 0 {
            // Only a left sibling: (left=sibling, right=node), parent cell `slot`.
            let leftNo = unsafe slot == 0 ? PageHeader.link(parentRO) : Node.branchChild(parentRO, slot - 1)
            try rebalancePair(
                ctx, tree: &tree, path: path, level: level,
                leftNo: leftNo, leftBuf: nil, leftIsTarget: false,
                rightNo: nodePageNo, rightBuf: nodeBuf,
                parentCellIndex: slot, isLeaf: isLeaf)
        }
        // slot == -1 with no cell at 0 cannot occur: branches keep ≥ 1 cell.
    }

    /// Merges or borrows between an adjacent (left, right) pair under the
    /// parent cell `parentCellIndex` (the cell pointing at `right`). The target
    /// (underfull) side is `leftIsTarget ? left: right`; its buffer is already
    /// transaction-owned. The sibling's buffer is nil until shadowed on demand.
    private static func rebalancePair(
        _ ctx: TxnContext, tree: inout TreeHandle, path: [PathNode], level: Int,
        leftNo: UInt64, leftBuf: PageBuf?, leftIsTarget: Bool,
        rightNo: UInt64, rightBuf: PageBuf?,
        parentCellIndex: Int, isLeaf: Bool
    ) throws(DBError) {
        let parent = path[level - 1]
        let separator = unsafe [UInt8](Node.branchKey(parent.buf.readOnly, parentCellIndex))

        let leftRO: UnsafeRawBufferPointer =
            if let leftBuf { unsafe leftBuf.readOnly } else { unsafe try ctx.resolvePage(leftNo) }
        let rightRO: UnsafeRawBufferPointer =
            if let rightBuf { unsafe rightBuf.readOnly } else { unsafe try ctx.resolvePage(rightNo) }

        let mergedPayload =
            unsafe payloadBytes(leftRO) + payloadBytes(rightRO)
            + (isLeaf ? 0 : Node.branchCellSize(keyLen: separator.count) + Format.slotSize)

        if mergedPayload <= Format.usablePageSize {
            // MERGE right into left: left mutates, right dies unshadowed.
            let (newLeftNo, leftOwned) = try ctx.shadow(leftNo)
            if newLeftNo != leftNo {
                repointChild(parent.buf, cellIndex: parentCellIndex - 1, to: newLeftNo)
            }
            if !isLeaf {
                let insertAt = unsafe PageHeader.cellCount(leftOwned.readOnly)
                let rightLink = unsafe PageHeader.link(rightRO)
                let ok = separator.withUnsafeBytes { sep in
                    leftOwned.withMutableBytes { page in
                        unsafe Node.branchInsert(&page, at: insertAt, key: sep, child: rightLink)
                    }
                }
                precondition(ok, "merge size was pre-checked")
            }
            unsafe appendAllCells(from: rightRO, to: leftOwned)
            ctx.freePage(rightNo)
            parent.buf.withMutableBytes { page in
                Node.removeCell(&page, at: parentCellIndex)
            }
            try rebalance(
                ctx, tree: &tree, path: path,
                nodePageNo: parent.pageNo, nodeBuf: parent.buf, level: level - 1)
            return
        }

        // BORROW the richer side's edge cell into the target.
        let (newLeftNo, leftOwned) = try ctx.shadow(leftNo)
        if newLeftNo != leftNo {
            repointChild(parent.buf, cellIndex: parentCellIndex - 1, to: newLeftNo)
        }
        let (newRightNo, rightOwned) = try ctx.shadow(rightNo)
        if newRightNo != rightNo {
            repointChild(parent.buf, cellIndex: parentCellIndex, to: newRightNo)
        }

        let newSeparator: [UInt8]
        if leftIsTarget {
            // Move right's first cell into left.
            let rRO = unsafe rightOwned.readOnly
            if isLeaf {
                let image = unsafe cellImage(rRO, 0)
                rightOwned.withMutableBytes { page in
                    Node.removeCell(&page, at: 0)
                }
                appendCellImage(image, to: leftOwned)
                newSeparator = unsafe [UInt8](Node.nodeKey(rightOwned.readOnly, 0))
            } else {
                // Reads of both pages first (distinct buffers), then the targeted writes.
                let insertAt = unsafe PageHeader.cellCount(leftOwned.readOnly)
                let rightLink = unsafe PageHeader.link(rRO)
                let rightFirstChild = unsafe Node.branchChild(rRO, 0)
                newSeparator = unsafe [UInt8](Node.branchKey(rRO, 0))
                let ok = separator.withUnsafeBytes { sep in
                    leftOwned.withMutableBytes { page in
                        unsafe Node.branchInsert(&page, at: insertAt, key: sep, child: rightLink)
                    }
                }
                precondition(ok, "borrow target was underfull")
                rightOwned.withMutableBytes { page in
                    PageHeader.setLink(&page, rightFirstChild)
                    Node.removeCell(&page, at: 0)
                }
            }
        } else {
            // Move left's last cell into right.
            let lRO = unsafe leftOwned.readOnly
            let lastIndex = unsafe PageHeader.cellCount(lRO) - 1
            if isLeaf {
                let image = unsafe cellImage(lRO, lastIndex)
                newSeparator = Node.keyOfCellImage(image, type: .leaf)
                leftOwned.withMutableBytes { page in
                    Node.removeCell(&page, at: lastIndex)
                }
                let ok = image.withUnsafeBytes { raw in
                    unsafe insertCellImage(raw, into: rightOwned, at: 0)
                }
                precondition(ok, "borrow target was underfull")
            } else {
                newSeparator = unsafe [UInt8](Node.branchKey(lRO, lastIndex))
                let pushedChild = unsafe Node.branchChild(lRO, lastIndex)
                let oldLeftmost = unsafe PageHeader.link(rightOwned.readOnly)
                let ok = separator.withUnsafeBytes { sep in
                    rightOwned.withMutableBytes { page in
                        unsafe Node.branchInsert(&page, at: 0, key: sep, child: oldLeftmost)
                    }
                }
                precondition(ok, "borrow target was underfull")
                rightOwned.withMutableBytes { page in
                    PageHeader.setLink(&page, pushedChild)
                }
                leftOwned.withMutableBytes { page in
                    Node.removeCell(&page, at: lastIndex)
                }
            }
        }

        replaceSeparator(
            ctx, tree: &tree, path: path, parentLevel: level - 1,
            cellIndex: parentCellIndex, newKey: newSeparator)
    }

    /// Rewrites the parent cell `cellIndex` to carry `newKey` (child
    /// preserved). Variable-length keys can overflow the parent — then it
    /// splits like any other branch insert.
    private static func replaceSeparator(
        _ ctx: TxnContext, tree: inout TreeHandle, path: [PathNode], parentLevel: Int,
        cellIndex: Int, newKey: [UInt8]
    ) {
        let parent = path[parentLevel]
        let child = unsafe Node.branchChild(parent.buf.readOnly, cellIndex)
        let inserted = newKey.withUnsafeBytes { sep in
            parent.buf.withMutableBytes { page in
                Node.removeCell(&page, at: cellIndex)
                return unsafe Node.branchInsert(&page, at: cellIndex, key: sep, child: child)
            }
        }
        if inserted { return }
        let (newRightNo, newRightBuf) = ctx.allocatePage()
        // `left` aliases `parent.buf`; snapshot the pre-split image so the source read can't
        // overlap the `left` span's exclusive borrow.
        let original = unsafe PageBuf(copying: parent.buf.readOnly)
        let upSeparator = newKey.withUnsafeBytes { sep in
            parent.buf.withMutableBytes { left in
                newRightBuf.withMutableBytes { right in
                    unsafe Node.splitBranchInserting(
                        original: original.readOnly, at: cellIndex, key: sep, child: child,
                        left: &left, right: &right)
                }
            }
        }
        insertSeparator(
            ctx, tree: &tree, path: path[..<parentLevel].map { (buf: $0.buf, slot: $0.slot) },
            separator: upSeparator, rightChild: newRightNo)
    }

    // MARK: - Small helpers

    /// Repoints the parent's child reference `cellIndex` (-1 = leftmost link).
    private static func repointChild(
        _ parentBuf: PageBuf, cellIndex: Int, to newChild: UInt64
    ) {
        parentBuf.withMutableBytes { page in
            if cellIndex < 0 {
                PageHeader.setLink(&page, newChild)
            } else {
                Node.branchSetChild(&page, at: cellIndex, child: newChild)
            }
        }
    }

    static func cellImage(_ page: UnsafeRawBufferPointer, _ index: Int) -> [UInt8] {
        let offset = unsafe PageHeader.slotOffset(page, index)
        return unsafe [UInt8](page[offset ..< offset + Node.cellLength(page, index)])
    }

    private static func appendCellImage(_ image: [UInt8], to buf: PageBuf) {
        let index = unsafe PageHeader.cellCount(buf.readOnly)
        let ok = image.withUnsafeBytes { raw in
            unsafe insertCellImage(raw, into: buf, at: index)
        }
        precondition(ok, "append target was pre-checked")
    }

    private static func insertCellImage(
        _ image: UnsafeRawBufferPointer, into buf: PageBuf, at index: Int
    ) -> Bool {
        buf.withMutableBytes { page in
            Node.insertCell(&page, at: index, size: image.count) { cell, offset in
                unsafe Node.copyBytes(into: &cell, at: offset, from: image)
            }
        }
    }

    private static func appendAllCells(from source: UnsafeRawBufferPointer, to buf: PageBuf) {
        for i in unsafe 0 ..< PageHeader.cellCount(source) {
            let offset = unsafe PageHeader.slotOffset(source, i)
            let length = unsafe Node.cellLength(source, i)
            let index = unsafe PageHeader.cellCount(buf.readOnly)
            let ok = buf.withMutableBytes { page in
                Node.insertCell(&page, at: index, size: length) { cell, dst in
                    unsafe Node.copyBytes(
                        into: &cell, at: dst,
                        from: UnsafeRawBufferPointer(rebasing: source[offset ..< offset + length]))
                }
            }
            precondition(ok, "merge size was pre-checked")
        }
    }
}
