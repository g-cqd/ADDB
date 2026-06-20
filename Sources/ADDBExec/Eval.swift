@_spi(ADDBEngine) import ADDBCore
package import ADSQL
@_spi(ADDBEngine) package import ADSQLModel

/// SQL expression evaluation with SQLite's exact semantics: three-valued
/// logic, cross-class comparison (INTEGER and REAL compare numerically and
/// without precision loss), collation resolution, NULL-propagating
/// operators, and arithmetic that promotes to REAL on integer overflow.
enum Truth: Equatable, Sendable {
    case yes
    case no
    case unknown

    var negated: Truth {
        switch self {
            case .yes: return .no
            case .no: return .yes
            case .unknown: return .unknown
        }
    }

    var asValue: Value {
        switch self {
            case .yes: return .integer(1)
            case .no: return .integer(0)
            case .unknown: return .null
        }
    }
}

/// SQL value comparison — distinct from `Value.keyOrder` (the index-byte
/// order), because SQL compares 1 = 1.0 numerically across storage classes.
enum SQLCompare {
    /// nil when either side is NULL (comparison result is unknown).
    static func compare(_ a: Value, _ b: Value, collation: Collation) -> Int? {
        switch (a, b) {
            case (.null, _), (_, .null):
                return nil
            case (.integer(let x), .integer(let y)):
                return x == y ? 0 : (x < y ? -1 : 1)
            case (.real(let x), .real(let y)):
                if x == y { return 0 }
                return x < y ? -1 : 1
            case (.integer(let i), .real(let d)):
                return intFloatCompare(i, d)
            case (.real(let d), .integer(let i)):
                return intFloatCompare(i, d).map { -$0 }
            case (.text(let x), .text(let y)):
                // Compare the UTF-8 views directly — no per-comparison Array allocation,
                // which dominated text-heavy ORDER BY sorts.
                return collation == .nocase ? compareUTF8NoCase(x, y) : compareUTF8(x, y)
            case (.blob(let x), .blob(let y)):
                return bytesCompare(x, y)
            default:
                // Cross-class: numeric < TEXT < BLOB (SQLite storage-class order).
                return rank(a) < rank(b) ? -1 : 1
        }
    }

    /// Exact Int64↔Double comparison (sqlite3IntFloatCompare): no precision
    /// loss at the 2^53 boundary or beyond.
    static func intFloatCompare(_ i: Int64, _ d: Double) -> Int? {
        if d.isNaN { return nil }  // computed NaN behaves like NULL
        if d < -9.223372036854776e18 { return 1 }
        if d >= 9.223372036854776e18 { return -1 }
        let truncated = Int64(d)
        if i < truncated { return -1 }
        if i > truncated { return 1 }
        let fraction = d - Double(truncated)
        if fraction > 0 { return -1 }
        if fraction < 0 { return 1 }
        return 0
    }

    /// Byte-order (SQLite BINARY) comparison of two strings' UTF-8, allocation
    /// free. UTF-8 byte order equals Unicode scalar order, so this matches
    /// SQLite's memcmp on stored UTF-8.
    static func compareUTF8(_ a: String, _ b: String) -> Int {
        var lhs = a.utf8.makeIterator()
        var rhs = b.utf8.makeIterator()
        while true {
            switch (lhs.next(), rhs.next()) {
                case (nil, nil): return 0
                case (nil, _): return -1
                case (_, nil): return 1
                case (.some(let x), .some(let y)) where x != y: return x < y ? -1 : 1
                default: continue
            }
        }
    }

    /// NOCASE comparison: ASCII A–Z folded to lowercase per byte (matching
    /// SQLite's NOCASE), allocation free.
    static func compareUTF8NoCase(_ a: String, _ b: String) -> Int {
        func fold(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c &+ 0x20 : c }
        var lhs = a.utf8.makeIterator()
        var rhs = b.utf8.makeIterator()
        while true {
            switch (lhs.next(), rhs.next()) {
                case (nil, nil): return 0
                case (nil, _): return -1
                case (_, nil): return 1
                case (.some(let x), .some(let y)):
                    let fx = fold(x)
                    let fy = fold(y)
                    if fx != fy { return fx < fy ? -1 : 1 }
            }
        }
    }

    /// `compareUTF8` over raw byte buffers (the zero-copy top-N path) — identical
    /// result to the `String` version on the same UTF-8 bytes: byte-lexicographic,
    /// shorter sorts first when a prefix.
    static func compareUTF8(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            let x = unsafe a[i]
            let y = unsafe b[i]
            if x != y { return x < y ? -1 : 1 }
            i += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    /// `compareUTF8NoCase` over raw byte buffers (ASCII A–Z folded per byte).
    static func compareUTF8NoCase(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
        func fold(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c &+ 0x20 : c }
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            let fx = unsafe fold(a[i])
            let fy = unsafe fold(b[i])
            if fx != fy { return fx < fy ? -1 : 1 }
            i += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    static func bytesCompare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i += 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    static func rank(_ v: Value) -> Int {
        switch v {
            case .null: return 0
            case .integer, .real: return 1
            case .text: return 2
            case .blob: return 3
        }
    }

    /// SQL equality for grouping/IN under a collation.
    static func equal(_ a: Value, _ b: Value, collation: Collation) -> Truth {
        guard let c = compare(a, b, collation: collation) else { return .unknown }
        return c == 0 ? .yes : .no
    }
}

/// Evaluation environment: parameters plus row-column resolution (closures
/// provided by the executor; column refs throw outside row contexts). `package`
/// so extension modules' registered function handlers can name it (the
/// stored closures stay internal — extensions pass the env through to
/// ``SQLEval/evaluate(_:_:)``, never construct or inspect it).
package struct SQLEvalEnv {
    /// The clock `datetime('now')` resolves against (epoch seconds). Declared first so
    /// `SQLEvalEnv(now:…)` call sites are valid; defaults to the live clock, with the
    /// statement layer threading `Database.options.now` in for deterministic tests.
    /// Structural seam — no test dependency in the SQL library.
    var now: @Sendable () -> Int64 = CivilTime.liveEpochSeconds
    var parameter: (SQLParam) throws(DBError) -> Value
    var column: (_ table: String?, _ name: String, _ offset: Int) throws(DBError) -> Value
    var collationOf: (_ table: String?, _ name: String) -> Collation?
    var columnTypeOf: (_ table: String?, _ name: String) -> ColumnType? = { _, _ in nil }
    /// Slot-resolved column access (the bind-time `.boundColumn` fast path): no
    /// per-row name resolution. Defaults throw so only a row context need install
    /// them.
    var boundColumn: (_ table: Int, _ column: Int) throws(DBError) -> Value = { _, _ throws(DBError) in
        throw DBError.sqlRuntime("bound column used outside a row context")
    }
    var boundCollation: (_ table: Int, _ column: Int) -> Collation? = { _, _ in nil }
    var boundColumnType: (_ table: Int, _ column: Int) -> ColumnType? = { _, _ in nil }
    /// Correlated scalar subquery executor (installed by the query executor).
    var scalarSubquery: (SQLSelect) throws(DBError) -> Value
    /// The current group's value for an aggregate slot (installed during
    /// GROUP BY finalization).
    var aggregateValue: (Int) throws(DBError) -> Value = { _ throws(DBError) in
        throw DBError.sqlRuntime("aggregate used outside an aggregate context")
    }

    static func parametersOnly(
        now: @escaping @Sendable () -> Int64 = CivilTime.liveEpochSeconds,
        _ lookup: @escaping (SQLParam) throws(DBError) -> Value
    ) -> SQLEvalEnv {
        SQLEvalEnv(
            now: now,
            parameter: lookup,
            column: { table, name, offset throws(DBError) in
                throw DBError.sqlBind(
                    "column \(table.map { "\($0)." } ?? "")\(name) is not available here (offset \(offset))")
            },
            collationOf: { _, _ in nil },
            scalarSubquery: { _ throws(DBError) in
                throw DBError.sqlUnsupported("subquery in this context")
            }
        )
    }
}

package enum SQLEval {
    // MARK: - Truthiness (SQLite: coerce to numeric, non-zero = true)

    static func truth(_ value: Value) -> Truth {
        switch value {
            case .null: return .unknown
            case .integer(let v): return v != 0 ? .yes : .no
            case .real(let d): return d != 0 ? .yes : .no
            case .text(let s):
                let n = SQLFunctions.numericPrefix(s)
                return truth(n)
            case .blob: return .no
        }
    }

    // MARK: - Expression evaluation

    package static func evaluate(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> Value {
        switch expr {
            case .literal(let value):
                return value
            case .parameter(let param, _):
                return try env.parameter(param)
            case .column(let table, let name, let offset):
                return try env.column(table, name, offset)
            case .boundColumn(let table, let column):
                return try env.boundColumn(table, column)
            case .aggregateResult(let slot):
                return try env.aggregateValue(slot)
            case .collate(let inner, _):
                return try evaluate(inner, env)
            case .cast(let inner, let type):
                return SQLFunctions.cast(try evaluate(inner, env), to: type)
            case .unary(.negate, let inner):
                return SQLFunctions.negate(try evaluate(inner, env))
            case .unary(.not, let inner):
                return predicate(of: try truthOf(inner, env).negated)
            case .isNull(let inner, let negated):
                let isNull = try evaluate(inner, env).isNull
                return .integer((isNull != negated) ? 1 : 0)
            case .binary(.and, let l, let r):
                return try evalAnd(expr, l, r, env)
            case .binary(.or, let l, let r):
                return try evalOr(expr, l, r, env)
            case .binary(let op, let l, let r) where op.isComparison:
                return try evalComparison(op, l, r, env)
            case .binary(.concat, let l, let r):
                return try evalConcat(l, r, env)
            case .binary(.match, _, _):
                // MATCH is an access path (the planner lowers it to `.fts`), never a
                // row-level predicate; reaching here means it appeared where it can't
                // drive an FTS scan (e.g. a projection, or on a non-FTS table).
                throw DBError.sqlRuntime("MATCH is only valid as a WHERE constraint on an FTS table")
            case .binary(.jsonExtract, let l, let r):
                return try SQLJSONOperators.arrow(try evaluate(l, env), try evaluate(r, env), asJSON: true)
            case .binary(.jsonExtractText, let l, let r):
                return try SQLJSONOperators.arrow(try evaluate(l, env), try evaluate(r, env), asJSON: false)
            case .binary(let op, let l, let r):
                return try SQLFunctions.arithmetic(op, try evaluate(l, env), try evaluate(r, env))
            case .like(let subject, let pattern, let negated):
                return try evalLike(subject, pattern, negated, env)
            case .inList(let subject, let items, let negated):
                return try evalInList(subject, items, negated, env)
            case .inJSONEach(let subject, let source, let negated):
                return try evalInJSONEach(subject, source, negated, env)
            case .scalarSubquery(let select):
                return try env.scalarSubquery(select)
            case .caseWhen(let operand, let whens, let elseExpr):
                return try evalCaseWhen(operand, whens, elseExpr, env)
            case .function(let name, let args, let star, let offset):
                return try SQLFunctions.call(name, args: args, star: star, offset: offset, env)
        }
    }

    /// `l AND r` per 3VL with short-circuit. A left-leaning chain (`l` is itself `AND`) is flattened to
    /// a loop so `a AND b AND … (N)` cannot overflow; the common non-chained case stays allocation-free.
    private static func evalAnd(
        _ expr: SQLExpr, _ l: SQLExpr, _ r: SQLExpr, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        if case .binary(.and, _, _) = l {
            return try evaluateBooleanChain(expr, env, op: .and)
        }
        let lt = try truthOf(l, env)
        if lt == .no { return .integer(0) }
        let rt = try truthOf(r, env)
        if rt == .no { return .integer(0) }
        if lt == .yes && rt == .yes { return .integer(1) }
        return .null
    }

    private static func evalOr(
        _ expr: SQLExpr, _ l: SQLExpr, _ r: SQLExpr, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        if case .binary(.or, _, _) = l {
            return try evaluateBooleanChain(expr, env, op: .or)
        }
        let lt = try truthOf(l, env)
        if lt == .yes { return .integer(1) }
        let rt = try truthOf(r, env)
        if rt == .yes { return .integer(1) }
        if lt == .no && rt == .no { return .integer(0) }
        return .null
    }

    private static func evalComparison(
        _ op: SQLBinaryOp, _ l: SQLExpr, _ r: SQLExpr, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        var lv = try evaluate(l, env)
        var rv = try evaluate(r, env)
        applyComparisonAffinity(l, &lv, r, &rv, env)
        let collation = resolveCollation(l, r, env)
        guard let c = SQLCompare.compare(lv, rv, collation: collation) else { return .null }
        guard let result = op.comparisonResult(c) else { return .null }
        return .integer(result ? 1 : 0)
    }

    private static func evalConcat(
        _ l: SQLExpr, _ r: SQLExpr, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        let lv = try evaluate(l, env)
        let rv = try evaluate(r, env)
        guard !lv.isNull, !rv.isNull else { return .null }
        return .text(SQLFunctions.textify(lv) + SQLFunctions.textify(rv))
    }

    private static func evalLike(
        _ subject: SQLExpr, _ pattern: SQLExpr, _ negated: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        let s = try evaluate(subject, env)
        let p = try evaluate(pattern, env)
        guard !s.isNull, !p.isNull else { return .null }
        let matched = SQLFunctions.like(
            text: SQLFunctions.textify(s), pattern: SQLFunctions.textify(p))
        return .integer((matched != negated) ? 1 : 0)
    }

    private static func evalInList(
        _ subject: SQLExpr, _ items: [SQLExpr], _ negated: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        var lhs = try evaluate(subject, env)
        if items.isEmpty { return .integer(negated ? 1 : 0) }
        if lhs.isNull { return .null }
        let collation = resolveCollation(subject, nil, env)
        var sawNull = false
        for item in items {
            var rhs = try evaluate(item, env)
            applyComparisonAffinity(subject, &lhs, item, &rhs, env)
            switch SQLCompare.equal(lhs, rhs, collation: collation) {
                case .yes: return .integer(negated ? 0 : 1)
                case .unknown: sawNull = true
                case .no: break
            }
        }
        if sawNull { return .null }
        return .integer(negated ? 1 : 0)
    }

    private static func evalInJSONEach(
        _ subject: SQLExpr, _ source: SQLExpr, _ negated: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        let lhs = try evaluate(subject, env)
        let json = try evaluate(source, env)
        if json.isNull { return .integer(negated ? 1 : 0) }  // empty rowset
        guard case .text(let text) = json else {
            throw DBError.sqlRuntime("json_each requires TEXT input")
        }
        let values = try SQLJSONOperators.eachValues(text)
        if values.isEmpty { return .integer(negated ? 1 : 0) }
        if lhs.isNull { return .null }
        let collation = resolveCollation(subject, nil, env)
        var sawNull = false
        for rhs in values {
            switch SQLCompare.equal(lhs, rhs, collation: collation) {
                case .yes: return .integer(negated ? 0 : 1)
                case .unknown: sawNull = true
                case .no: break
            }
        }
        if sawNull { return .null }
        return .integer(negated ? 1 : 0)
    }

    private static func evalCaseWhen(
        _ operand: SQLExpr?, _ whens: [SQLWhen], _ elseExpr: SQLExpr?, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        if let operand {
            let base = try evaluate(operand, env)
            let collation = resolveCollation(operand, nil, env)
            for when in whens {
                let candidate = try evaluate(when.condition, env)
                if SQLCompare.equal(base, candidate, collation: collation) == .yes {
                    return try evaluate(when.result, env)
                }
            }
        } else {
            for when in whens where try truthOf(when.condition, env) == .yes {
                return try evaluate(when.result, env)
            }
        }
        if let elseExpr { return try evaluate(elseExpr, env) }
        return .null
    }

    static func truthOf(_ expr: SQLExpr, _ env: SQLEvalEnv) throws(DBError) -> Truth {
        truth(try evaluate(expr, env))
    }

    /// Evaluates a left-leaning `AND`/`OR` chain iteratively: flatten the spine to
    /// operands, then short-circuit left to right under three-valued logic — `.no`
    /// ends an `AND` with 0, `.yes` ends an `OR` with 1; otherwise a NULL with no
    /// decisive operand yields NULL, else the unit (1 for AND, 0 for OR). Identical
    /// to the recursive 2-operand form (each spine node evaluates its left subtree
    /// then its right, short-circuiting on its left), so evaluation order, NULL
    /// handling, and which operands run on a short circuit are all preserved — but a
    /// chain of any length runs in a loop instead of overflowing the stack.
    private static func evaluateBooleanChain(
        _ expr: SQLExpr, _ env: SQLEvalEnv, op: SQLBinaryOp
    ) throws(DBError) -> Value {
        var operands: [SQLExpr] = []
        var node = expr
        while case .binary(let o, let l, let r) = node, o == op {
            operands.append(r)
            node = l
        }
        operands.append(node)  // leftmost (deepest) operand
        var sawNull = false
        for operand in operands.reversed() {
            let t = try truthOf(operand, env)
            if op == .and {
                if t == .no { return .integer(0) }
            } else if t == .yes {
                return .integer(1)
            }
            if t == .unknown { sawNull = true }
        }
        if op == .and { return sawNull ? .null : .integer(1) }
        return sawNull ? .null : .integer(0)
    }

    static func predicate(of truth: Truth) -> Value {
        truth.asValue
    }

    // MARK: - Comparison affinity (SQLite §type affinity in comparisons)

    enum Affinity { case numeric, text, none }

    static func affinity(_ expr: SQLExpr, _ env: SQLEvalEnv) -> Affinity {
        switch expr {
            case .cast(_, .integer), .cast(_, .real):
                return .numeric
            case .cast(_, .text):
                return .text
            case .cast(_, .blob):
                return .none
            case .column(let table, let name, _):
                switch env.columnTypeOf(table, name) {
                    case .integer, .real: return .numeric
                    case .text: return .text
                    case .blob, nil: return .none
                }
            case .boundColumn(let table, let column):
                switch env.boundColumnType(table, column) {
                    case .integer, .real: return .numeric
                    case .text: return .text
                    case .blob, nil: return .none
                }
            case .binary(.concat, _, _):
                return .text
            case .binary(.jsonExtract, _, _), .binary(.jsonExtractText, _, _):
                return .none
            case .binary(let op, _, _) where !op.isComparison && op != .and && op != .or:
                return .numeric
            case .unary(.negate, _):
                return .numeric
            case .collate(let inner, _):
                return affinity(inner, env)
            default:
                return .none
        }
    }

    /// One side with numeric affinity converts the other side's well-formed
    /// numeric TEXT; one side with TEXT affinity textifies the other side's
    /// bare numerics.
    static func applyComparisonAffinity(
        _ l: SQLExpr, _ lv: inout Value, _ r: SQLExpr, _ rv: inout Value, _ env: SQLEvalEnv
    ) {
        applyAffinities(affinity(l, env), affinity(r, env), &lv, &rv)
    }

    /// The value-conversion half of comparison affinity, with both sides' affinities
    /// already resolved — so the compiled evaluator can bake the (schema-fixed)
    /// affinities at compile time and apply only the runtime value coercion per row.
    static func applyAffinities(
        _ la: Affinity, _ ra: Affinity, _ lv: inout Value, _ rv: inout Value
    ) {
        if la == .numeric || ra == .numeric {
            if case .text(let s) = lv, let n = SQLFunctions.fullNumeric(s) { lv = n }
            if case .text(let s) = rv, let n = SQLFunctions.fullNumeric(s) { rv = n }
            return
        }
        if la == .text && ra == .none {
            if case .integer = rv { rv = .text(SQLFunctions.textify(rv)) }
            if case .real = rv { rv = .text(SQLFunctions.textify(rv)) }
        } else if ra == .text && la == .none {
            if case .integer = lv { lv = .text(SQLFunctions.textify(lv)) }
            if case .real = lv { lv = .text(SQLFunctions.textify(lv)) }
        }
    }

    /// Collation resolution: explicit COLLATE wins, else the left column's
    /// collation, else the right column's, else BINARY.
    static func resolveCollation(_ l: SQLExpr, _ r: SQLExpr?, _ env: SQLEvalEnv) -> Collation {
        if let explicit = explicitCollation(l) { return explicit }
        if let r, let explicit = explicitCollation(r) { return explicit }
        if let implied = impliedCollation(l, env) { return implied }
        if let r, let implied = impliedCollation(r, env) { return implied }
        return .binary
    }

    private static func explicitCollation(_ expr: SQLExpr) -> Collation? {
        switch expr {
            case .collate(_, let collation): return collation
            case .unary(_, let inner), .cast(let inner, _): return explicitCollation(inner)
            default: return nil
        }
    }

    private static func impliedCollation(_ expr: SQLExpr, _ env: SQLEvalEnv) -> Collation? {
        switch expr {
            case .column(let table, let name, _): return env.collationOf(table, name)
            case .boundColumn(let table, let column): return env.boundCollation(table, column)
            case .collate(let inner, _), .unary(_, let inner), .cast(let inner, _):
                return impliedCollation(inner, env)
            default: return nil
        }
    }
}

extension SQLBinaryOp {
    /// Maps a three-way comparison result (`<0`, `0`, `>0`) to this operator's
    /// boolean outcome, or nil for non-comparison operators. Single source of
    /// truth for `isComparison`, so the predicate and the evaluation cannot drift.
    func comparisonResult(_ ordering: Int) -> Bool? {
        switch self {
            case .eq: return ordering == 0
            case .ne: return ordering != 0
            case .lt: return ordering < 0
            case .le: return ordering <= 0
            case .gt: return ordering > 0
            case .ge: return ordering >= 0
            default: return nil
        }
    }

    var isComparison: Bool { comparisonResult(0) != nil }
}
