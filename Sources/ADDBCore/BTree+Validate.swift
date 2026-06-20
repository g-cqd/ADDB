public import ADSQLModel

/// B-tree traversal + structural/integrity validation for `BTree` (the tests/integrity half),
/// split from `BTree.swift` to keep the enum body within the gate.
extension BTree {
    // MARK: - Traversal (tests, integrity, future cursors build on this)

    /// In-order traversal of every (key, valueRef) pair.
    @inline(__always)
    @_spi(ADDBEngine) public static func forEach(
        resolver: some PageResolver, meta: Meta,
        _ body: (UnsafeRawBufferPointer, ValueRef) throws(DBError) -> Void
    ) throws(DBError) {
        unsafe try forEach(resolver: resolver, tree: meta.mainTree, body)
    }

    @_spi(ADDBEngine) public static func forEach(
        resolver: some PageResolver, tree: TreeHandle,
        _ body: (UnsafeRawBufferPointer, ValueRef) throws(DBError) -> Void
    ) throws(DBError) {
        guard tree.rootPage != 0 else { return }
        unsafe try walk(resolver: resolver, pageNo: tree.rootPage, level: tree.depth, body)
    }

    private static func walk(
        resolver: some PageResolver, pageNo: UInt64, level: UInt16,
        _ body: (UnsafeRawBufferPointer, ValueRef) throws(DBError) -> Void
    ) throws(DBError) {
        // `level` starts at the handle's `depth` and decrements each step, so this
        // recursion is bounded by it. Cap it so a corrupt/oversized depth throws
        // instead of overflowing the stack (a valid tree nests only a few levels).
        guard level <= Format.maxTreeDepth else { throw DBError.corruptPage(pageNo: pageNo) }
        let page = unsafe try resolver.resolvePage(pageNo)
        if level > 1 {
            guard unsafe PageHeader.pageType(page) == .branch else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            unsafe try walk(resolver: resolver, pageNo: PageHeader.link(page), level: level - 1, body)
            for i in unsafe 0 ..< PageHeader.cellCount(page) {
                unsafe try walk(resolver: resolver, pageNo: Node.branchChild(page, i), level: level - 1, body)
            }
            return
        }
        guard unsafe PageHeader.pageType(page) == .leaf else {
            throw DBError.corruptPage(pageNo: pageNo)
        }
        for i in unsafe 0 ..< PageHeader.cellCount(page) {
            let cell = unsafe Node.leafCell(page, i)
            if let inline = unsafe cell.inlineValue {
                unsafe try body(cell.key, .inline(boundInline(inline, to: resolver)))
            } else {
                unsafe try body(cell.key, .overflow(head: cell.overflowHead, length: Int(cell.overflowLength)))
            }
        }
    }

    // MARK: - Structural validation

    @_spi(ADDBEngine) public struct ValidationReport: Sendable {
        @_spi(ADDBEngine) public var reachablePages: Set<UInt64> = []
        @_spi(ADDBEngine) public var kvCount: UInt64 = 0
        @_spi(ADDBEngine) public var leafCount = 0
        @_spi(ADDBEngine) public var branchCount = 0
        @_spi(ADDBEngine) public var overflowPages = 0
    }

    /// Full structural check of the tree under `meta`: page types, in-node key
    /// order, separator bounds, uniform leaf depth, overflow chain lengths.
    /// Returns the set of reachable pages for liveness accounting.
    @inline(__always)
    @_spi(ADDBEngine) public static func validate(
        resolver: some PageResolver, meta: Meta, verifyChecksums: Bool = false
    ) throws(DBError) -> ValidationReport {
        try validate(resolver: resolver, tree: meta.mainTree, verifyChecksums: verifyChecksums)
    }

    @_spi(ADDBEngine) public static func validate(
        resolver: some PageResolver, tree: TreeHandle, verifyChecksums: Bool = false
    ) throws(DBError) -> ValidationReport {
        var report = ValidationReport()
        if tree.rootPage != 0 {
            try validateNode(
                resolver: resolver, pageNo: tree.rootPage, level: tree.depth,
                lower: nil, upper: nil, isRoot: true, verifyChecksums: verifyChecksums,
                report: &report)
        }
        guard report.kvCount == tree.count else {
            throw DBError.integrityFailure(
                "count mismatch: tree has \(report.kvCount), handle says \(tree.count)")
        }
        return report
    }

    /// Verifies a page's keys are strictly ascending and each lies within the inherited separator
    /// bounds `(lower, upper]`.
    private static func checkOrderAndBounds(
        _ page: UnsafeRawBufferPointer, count: Int, pageNo: UInt64, lower: [UInt8]?, upper: [UInt8]?
    ) throws(DBError) {
        for i in 0 ..< count {
            let key = unsafe Node.nodeKey(page, i)
            if i > 0, unsafe Node.compare(Node.nodeKey(page, i - 1), key) >= 0 {
                throw DBError.integrityFailure("page \(pageNo): keys out of order at \(i)")
            }
            let lowerOK = lower.map { l in l.withUnsafeBytes { unsafe Node.compare($0, key) <= 0 } } ?? true
            let upperOK = upper.map { u in u.withUnsafeBytes { unsafe Node.compare(key, $0) < 0 } } ?? true
            guard lowerOK, upperOK else {
                throw DBError.integrityFailure("page \(pageNo): key \(i) outside separator bounds")
            }
        }
    }

    private static func validateNode(
        resolver: some PageResolver, pageNo: UInt64, level: UInt16,
        lower: [UInt8]?, upper: [UInt8]?, isRoot: Bool = false,
        verifyChecksums: Bool = false,
        report: inout ValidationReport
    ) throws(DBError) {
        // Bound the recursion by the tree-height ceiling (the cycle check below
        // also stops revisits); a corrupt oversized `depth` throws cleanly here.
        guard level <= Format.maxTreeDepth else { throw DBError.corruptPage(pageNo: pageNo) }
        guard report.reachablePages.insert(pageNo).inserted else {
            throw DBError.integrityFailure("page \(pageNo) reachable twice")
        }
        let page = unsafe try resolver.resolvePage(pageNo)
        if verifyChecksums, unsafe !PageHeader.verifyChecksum(page, pageNo: pageNo) {
            throw DBError.corruptPage(pageNo: pageNo)
        }
        let count = unsafe PageHeader.cellCount(page)

        if level > 1 {
            guard unsafe PageHeader.pageType(page) == .branch else {
                throw DBError.corruptPage(pageNo: pageNo)
            }
            guard count >= 1 else {
                throw DBError.integrityFailure("branch \(pageNo) has no separators")
            }
            report.branchCount += 1
            unsafe try checkOrderAndBounds(page, count: count, pageNo: pageNo, lower: lower, upper: upper)
            // leftmost child: (lower, key[0])
            unsafe try validateNode(
                resolver: resolver, pageNo: PageHeader.link(page), level: level - 1,
                lower: lower, upper: [UInt8](Node.branchKey(page, 0)),
                verifyChecksums: verifyChecksums, report: &report)
            for i in 0 ..< count {
                let childLower = unsafe [UInt8](Node.branchKey(page, i))
                let childUpper = unsafe i + 1 < count ? [UInt8](Node.branchKey(page, i + 1)) : upper
                unsafe try validateNode(
                    resolver: resolver, pageNo: Node.branchChild(page, i), level: level - 1,
                    lower: childLower, upper: childUpper,
                    verifyChecksums: verifyChecksums, report: &report)
            }
            return
        }

        guard unsafe PageHeader.pageType(page) == .leaf else {
            throw DBError.corruptPage(pageNo: pageNo)
        }
        guard isRoot || count >= 1 else {
            throw DBError.integrityFailure("empty non-root leaf \(pageNo)")
        }
        report.leafCount += 1
        unsafe try checkOrderAndBounds(page, count: count, pageNo: pageNo, lower: lower, upper: upper)
        report.kvCount += UInt64(count)
        unsafe try validateLeafOverflowChains(
            page, count: count, resolver: resolver, verifyChecksums: verifyChecksums, report: &report)
    }

    /// Walks each leaf cell's overflow chain, accounting every page and rejecting a revisit, a wrong
    /// page type, a bad checksum, or a stored-length mismatch.
    private static func validateLeafOverflowChains(
        _ page: UnsafeRawBufferPointer, count: Int, resolver: some PageResolver,
        verifyChecksums: Bool, report: inout ValidationReport
    ) throws(DBError) {
        for i in 0 ..< count {
            let cell = unsafe Node.leafCell(page, i)
            guard unsafe cell.inlineValue == nil else { continue }
            var chainPage = cell.overflowHead
            var remaining = Int(cell.overflowLength)
            while chainPage != 0 {
                guard report.reachablePages.insert(chainPage).inserted else {
                    throw DBError.integrityFailure("overflow page \(chainPage) reachable twice")
                }
                report.overflowPages += 1
                let overflow = unsafe try resolver.resolvePage(chainPage)
                if verifyChecksums, unsafe !PageHeader.verifyChecksum(overflow, pageNo: chainPage) {
                    throw DBError.corruptPage(pageNo: chainPage)
                }
                guard unsafe PageHeader.pageType(overflow) == .overflow else {
                    throw DBError.corruptPage(pageNo: chainPage)
                }
                unsafe remaining -= PageHeader.overflowDataLen(overflow)
                chainPage = unsafe PageHeader.link(overflow)
            }
            guard remaining == 0 else {
                throw DBError.integrityFailure(
                    "overflow chain \(cell.overflowHead): length mismatch (\(remaining) left)")
            }
        }
    }
}
