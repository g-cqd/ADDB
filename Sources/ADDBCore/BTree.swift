public import ADSQLModel

/// The copy-on-write B+tree. Writes shadow every page on the descent path
/// (COW-once-per-transaction: a page already owned by the transaction is
/// mutated in place), so committed pages are never touched and readers on
/// older generations stay consistent without locks.
@_spi(ADDBEngine) public enum BTree {
    @_spi(ADDBEngine) public enum ValueRef: ~Escapable {
        case inline(RawSpan)
        case overflow(head: UInt64, length: Int)

        @_spi(ADDBEngine) public var length: Int {
            switch self {
                case .inline(let v): return v.byteCount
                case .overflow(_, let length): return length
            }
        }
    }

    /// Re-expresses an inline value pointer as a `RawSpan` whose lifetime is the
    /// resolver that owns the mapping, so a `~Escapable` `ValueRef.inline` cannot
    /// outlive the snapshot.
    @_lifetime(borrow resolver)
    static func boundInline<R: PageResolver>(
        _ bytes: UnsafeRawBufferPointer, to resolver: borrowing R
    ) -> RawSpan {
        let span = unsafe RawSpan(_unsafeBytes: bytes)
        return unsafe _overrideLifetime(span, borrowing: resolver)
    }

    // MARK: - Lookup

    @inline(__always)
    @_lifetime(borrow resolver)
    @_spi(ADDBEngine) public static func get<R: PageResolver>(
        resolver: borrowing R, meta: Meta, key: UnsafeRawBufferPointer
    ) throws(DBError) -> ValueRef? {
        unsafe try get(resolver: resolver, tree: meta.mainTree, key: key)
    }

    @_lifetime(borrow resolver)
    @_spi(ADDBEngine) public static func get<R: PageResolver>(
        resolver: borrowing R, tree: TreeHandle, key: UnsafeRawBufferPointer
    ) throws(DBError) -> ValueRef? {
        guard tree.rootPage != 0 else { return nil }
        var pageNo = tree.rootPage
        var level = tree.depth
        while level > 1 {
            let page = unsafe try resolver.resolvePage(pageNo)
            guard unsafe PageHeader.pageType(page) == .branch else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            pageNo = unsafe Node.descendTarget(page, key: key)
            level -= 1
        }
        let leaf = unsafe try resolver.resolvePage(pageNo)
        guard unsafe PageHeader.pageType(leaf) == .leaf else {
            throw DBError.corruptPage(pageNo: pageNo)
        }
        let (index, exact) = unsafe Node.search(leaf, key: key)
        guard exact else { return nil }
        let cell = unsafe Node.leafCell(leaf, index)
        if let inline = unsafe cell.inlineValue {
            return unsafe .inline(boundInline(inline, to: resolver))
        }
        return .overflow(head: cell.overflowHead, length: Int(cell.overflowLength))
    }

    /// Materializes a value reference (copying inline bytes or concatenating
    /// the overflow chain).
    @_spi(ADDBEngine) public static func copyValue(
        _ ref: ValueRef, resolver: some PageResolver
    ) throws(DBError) -> [UInt8] {
        switch ref {
            case .inline(let bytes):
                return bytes.withUnsafeBytes { unsafe [UInt8]($0) }
            case .overflow(let head, let length):
                return try Overflow.read(
                    head: head, length: length, pager: ReadOnlyOverflowPager(resolver: resolver))
        }
    }

    /// Zero-copy access to a value's bytes: an inline value is handed to `body`
    /// as the mapped page span directly; an overflow value is assembled once and
    /// spanned. The span is valid only for the duration of `body`.
    @_spi(ADDBEngine) public static func withValueBytes<R>(
        _ ref: ValueRef, resolver: some PageResolver,
        _ body: (UnsafeRawBufferPointer) throws(DBError) -> R
    ) throws(DBError) -> R {
        switch ref {
            case .inline(let bytes):
                return try bytes.withUnsafeBytes { (raw) throws(DBError) in unsafe try body(raw) }
            case .overflow(let head, let length):
                let assembled = try Overflow.read(
                    head: head, length: length, pager: ReadOnlyOverflowPager(resolver: resolver))
                var result: Result<R, DBError>?
                assembled.withUnsafeBytes { raw in
                    do throws(DBError) {
                        result = unsafe .success(try body(raw))
                    } catch {
                        result = .failure(error)
                    }
                }
                return try result!.get()
        }
    }

    // MARK: - Insert / update

    @inline(__always)
    @_spi(ADDBEngine) public static func put(
        ctx: TxnContext, key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer
    ) throws(DBError) {
        var tree = ctx.meta.mainTree
        unsafe try put(ctx: ctx, tree: &tree, key: key, value: value)
        ctx.meta.mainTree = tree
    }

    @_spi(ADDBEngine) public static func put(
        ctx: TxnContext, tree: inout TreeHandle,
        key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer
    ) throws(DBError) {
        guard unsafe !key.isEmpty else { throw DBError.keyEmpty }
        guard key.count <= Format.maxKeySize else { throw DBError.keyTooLarge(key.count) }

        var pager = ctx
        let leafValue: Node.LeafValue
        if Node.shouldInline(keyLen: key.count, valueLen: value.count) {
            leafValue = unsafe .inline(value)
        } else {
            let head = unsafe try Overflow.write(value, pager: &pager)
            leafValue = .overflow(head: head, length: UInt32(value.count))
        }

        // Empty tree: the new leaf is the root.
        if tree.rootPage == 0 {
            let (rootNo, buf) = ctx.allocatePage()
            buf.withMutableBytes { page in
                PageHeader.initialize(&page, type: .leaf)
                _ = unsafe Node.leafInsert(&page, at: 0, key: key, value: leafValue)
            }
            tree.rootPage = rootNo
            tree.depth = 1
            tree.count += 1
            return
        }

        // Shadow the descent path top-down, repointing parents as pages move.
        var (currentNo, currentBuf) = try ctx.shadow(tree.rootPage)
        tree.rootPage = currentNo
        var path: [(buf: PageBuf, slot: Int)] = []
        path.reserveCapacity(Int(tree.depth))

        var level = tree.depth
        while level > 1 {
            let ro = unsafe currentBuf.readOnly
            guard unsafe PageHeader.pageType(ro) == .branch else {
                throw DBError.corruptPage(pageNo: currentNo)
            }
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
            path.append((currentBuf, slot))
            (currentNo, currentBuf) = (newChildNo, childBuf)
            level -= 1
        }

        let ro = unsafe currentBuf.readOnly
        guard unsafe PageHeader.pageType(ro) == .leaf else {
            throw DBError.corruptPage(pageNo: currentNo)
        }
        let (index, exact) = unsafe Node.search(ro, key: key)
        if exact {
            // Replace: drop the old cell (and its overflow chain) first.
            let old = unsafe Node.leafCell(ro, index)
            if unsafe old.inlineValue == nil {
                try Overflow.free(head: old.overflowHead, pager: &pager)
            }
            currentBuf.withMutableBytes { page in
                Node.removeCell(&page, at: index)
            }
        } else {
            tree.count += 1
        }

        let inserted = currentBuf.withMutableBytes { page in
            unsafe Node.leafInsert(&page, at: index, key: key, value: leafValue)
        }
        if inserted { return }

        // Leaf overflowed: split (left half stays on the shadowed page).
        let (rightNo, rightBuf) = ctx.allocatePage()
        // `left` aliases `currentBuf`; snapshot the pre-split image into a non-aliasing buffer so
        // the source read can't overlap the `left` span's exclusive borrow (the split copies its
        // source page-by-page from this snapshot regardless).
        let original = unsafe PageBuf(copying: currentBuf.readOnly)
        let separator = currentBuf.withMutableBytes { left in
            rightBuf.withMutableBytes { right in
                unsafe Node.splitLeafInserting(
                    original: original.readOnly, at: index, key: key, value: leafValue,
                    left: &left, right: &right)
            }
        }
        insertSeparator(ctx, tree: &tree, path: path, separator: separator, rightChild: rightNo)
    }

    /// Propagates a split upward. `path` holds the shadowed branch chain from
    /// the root (exclusive of the split node); all buffers are transaction-owned.
    static func insertSeparator(
        _ ctx: TxnContext, tree: inout TreeHandle, path: [(buf: PageBuf, slot: Int)],
        separator: [UInt8], rightChild: UInt64
    ) {
        var separator = separator
        var rightChild = rightChild
        var level = path.count - 1

        while level >= 0 {
            let parent = path[level]
            let insertAt = parent.slot + 1
            let inserted = separator.withUnsafeBytes { sep in
                parent.buf.withMutableBytes { page in
                    unsafe Node.branchInsert(&page, at: insertAt, key: sep, child: rightChild)
                }
            }
            if inserted { return }

            let (newRightNo, newRightBuf) = ctx.allocatePage()
            // `left` aliases `parent.buf`; snapshot the pre-split image so the source read can't
            // overlap the `left` span's exclusive borrow.
            let original = unsafe PageBuf(copying: parent.buf.readOnly)
            let upSeparator = separator.withUnsafeBytes { sep in
                parent.buf.withMutableBytes { left in
                    newRightBuf.withMutableBytes { right in
                        unsafe Node.splitBranchInserting(
                            original: original.readOnly, at: insertAt, key: sep, child: rightChild,
                            left: &left, right: &right)
                    }
                }
            }
            separator = upSeparator
            rightChild = newRightNo
            level -= 1
        }

        // Root split: grow the tree by one level.
        let (newRootNo, rootBuf) = ctx.allocatePage()
        let ok = separator.withUnsafeBytes { sep in
            rootBuf.withMutableBytes { page in
                PageHeader.initialize(&page, type: .branch)
                PageHeader.setLink(&page, tree.rootPage)
                return unsafe Node.branchInsert(&page, at: 0, key: sep, child: rightChild)
            }
        }
        precondition(ok, "fresh root must fit one separator")
        tree.rootPage = newRootNo
        tree.depth += 1
    }

    // MARK: - Append fast path (warm rightmost-leaf cache)

    /// Warm cache for `appendMax`: the rightmost leaf's page number, its current
    /// max key, and the tree root the cache was taken under (a non-append mutation
    /// re-shadows the root, so a root mismatch means the cache is stale).
    struct AppendCache: Sendable {
        var leafPageNo: UInt64
        var maxKey: [UInt8]
        var rootPage: UInt64
    }

    /// Inserts `key` (which the caller GUARANTEES is strictly greater than every
    /// key already in the tree — e.g. a freshly allocated ascending rowid), reusing
    /// a warm rightmost-leaf cache to skip the root→leaf descent + per-insert COW
    /// shadow when the new cell fits the cached leaf. Produces the identical logical
    /// tree as `put`; it only avoids re-shadowing the path each row.
    ///
    /// The in-place append routes through `ctx.shadow`, so the leaf's pre-request
    /// content is recorded in the undo log and a group-commit `rollbackRequestScope`
    /// undoes it exactly like a normal write. ANY ineligibility — stale cache (root
    /// changed), leaf no longer owned, key not strictly greater, or the cell does
    /// not fit (would split) — falls through to the proven `put`, which also
    /// refreshes the cache to the (now-dirty) rightmost leaf.
    static func appendMax(
        ctx: TxnContext, tree: inout TreeHandle,
        key: UnsafeRawBufferPointer, value: UnsafeRawBufferPointer,
        cache: inout AppendCache?
    ) throws(DBError) {
        guard unsafe !key.isEmpty else { throw DBError.keyEmpty }
        guard key.count <= Format.maxKeySize else { throw DBError.keyTooLarge(key.count) }

        if let c = cache, c.rootPage == tree.rootPage, ctx.owns(c.leafPageNo),
            c.maxKey.withUnsafeBytes({ (m: UnsafeRawBufferPointer) in unsafe Node.compare(key, m) > 0 })
        {
            var pager = ctx
            let leafValue: Node.LeafValue
            if Node.shouldInline(keyLen: key.count, valueLen: value.count) {
                leafValue = unsafe .inline(value)
            } else {
                let head = unsafe try Overflow.write(value, pager: &pager)
                leafValue = .overflow(head: head, length: UInt32(value.count))
            }
            // `shadow` on a dirty page keeps the page number; under group commit it
            // clones-on-first-touch-this-request and records the undo entry. The leaf
            // stays the rightmost, so its parents still point at it — no descent needed.
            let (leafNo, buf) = try ctx.shadow(c.leafPageNo)
            let cellCount = unsafe PageHeader.cellCount(buf.readOnly)
            let inserted = buf.withMutableBytes { page in
                unsafe Node.leafInsert(&page, at: cellCount, key: key, value: leafValue)
            }
            if inserted {
                tree.count += 1
                cache = unsafe AppendCache(leafPageNo: leafNo, maxKey: [UInt8](key), rootPage: c.rootPage)
                return
            }
            // Did not fit (would split): release any overflow we wrote, then fall through
            // to the proven split path. `leafInsert` is a no-op when it returns false.
            if case .overflow(let head, _) = leafValue { try Overflow.free(head: head, pager: &pager) }
        }

        // Slow / cold path: the verified `put` (empty tree, splits, the exact-replace
        // case), then refresh the cache to the rightmost leaf now holding `key`.
        unsafe try put(ctx: ctx, tree: &tree, key: key, value: value)
        if let leafNo = try rightmostLeaf(ctx: ctx, tree: tree) {
            cache = unsafe AppendCache(leafPageNo: leafNo, maxKey: [UInt8](key), rootPage: tree.rootPage)
        } else {
            cache = nil
        }
    }

    /// Page number of the rightmost (max-key) leaf, descending the last child at
    /// each branch level — mirrors `Cursor.descend(edge:.last)` but returns only
    /// the leaf page so the append cache can be refreshed after a cold `put`.
    static func rightmostLeaf(ctx: TxnContext, tree: TreeHandle) throws(DBError) -> UInt64? {
        guard tree.rootPage != 0 else { return nil }
        var pageNo = tree.rootPage
        var level = tree.depth
        while level > 1 {
            let page = unsafe try ctx.resolvePage(pageNo)
            guard unsafe PageHeader.pageType(page) == .branch else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            let slot = unsafe PageHeader.cellCount(page) - 1
            pageNo = unsafe slot < 0 ? PageHeader.link(page) : Node.branchChild(page, slot)
            level -= 1
        }
        return pageNo
    }
}

/// Read-only adapter so lookups can stream overflow chains through any
/// resolver. Mutating members trap: reads never allocate or free.
struct ReadOnlyOverflowPager<R: PageResolver>: OverflowPager {
    let resolver: R

    func allocateOverflowPage() throws(DBError) -> (pageNo: UInt64, buf: PageBuf) {
        preconditionFailure("read-only pager cannot allocate")
    }
    func readOverflowPage(_ pageNo: UInt64) throws(DBError) -> UnsafeRawBufferPointer {
        unsafe try resolver.resolvePage(pageNo)
    }
    func freeOverflowPage(_ pageNo: UInt64) throws(DBError) {
        preconditionFailure("read-only pager cannot free")
    }
}
