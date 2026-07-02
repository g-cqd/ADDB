@_spi(ADDBEngine) import ADDBCore
import ADSQL
@_spi(ADDBEngine) import ADSQLModel

/// Scalar SQL functions and operators, matching SQLite's core behavior:
/// ASCII-only LOWER/UPPER, character-based LENGTH/INSTR/SUBSTR (1-based), LIKE
/// matching, and overflow-promoting arithmetic. Value storage-class coercions
/// (CAST, text/number affinity, real formatting) live on ``Value``; the
/// coercion entry points below delegate to it.
enum SQLFunctions {
    // MARK: - Coercions (delegate to the value layer)

    static func textify(_ value: Value) -> String { Value.textify(value) }

    static func realToText(_ d: Double) -> String { Value.realToText(d) }

    static func numericPrefix(_ s: String) -> Value { Value.numericPrefix(s) }

    /// Numeric coercion for arithmetic operands.
    static func toNumeric(_ value: Value) -> Value { Value.toNumeric(value) }

    static func cast(_ value: Value, to type: ColumnType) -> Value {
        Value.cast(value, to: type)
    }

    // MARK: - Arithmetic (overflow promotes to REAL; /0 and %0 yield NULL)

    static func negate(_ value: Value) -> Value {
        switch toNumeric(value) {
            case .null: return .null
            case .integer(let v):
                if v == .min { return .real(9.223372036854776e18) }
                return .integer(-v)
            case .real(let d): return .real(-d)
            default: return .null
        }
    }

    static func arithmetic(
        _ op: SQLBinaryOp, _ rawL: Value, _ rawR: Value
    ) throws(DBError) -> Value {
        let l = toNumeric(rawL)
        let r = toNumeric(rawR)
        if l.isNull || r.isNull { return .null }

        if op == .modulo {
            // SQLite %: both operands int-cast; the RESULT is REAL when either
            // input was REAL.
            guard let li = asInt(l), let ri = asInt(r) else { return .null }
            guard ri != 0 else { return .null }
            let remainder = (li == .min && ri == -1) ? 0 : li % ri
            let anyReal = isReal(l) || isReal(r)
            return anyReal ? .real(Double(remainder)) : .integer(remainder)
        }

        if case .integer(let li) = l, case .integer(let ri) = r {
            switch op {
                case .add:
                    let (sum, overflow) = li.addingReportingOverflow(ri)
                    return overflow ? .real(Double(li) + Double(ri)) : .integer(sum)
                case .subtract:
                    let (difference, overflow) = li.subtractingReportingOverflow(ri)
                    return overflow ? .real(Double(li) - Double(ri)) : .integer(difference)
                case .multiply:
                    let (product, overflow) = li.multipliedReportingOverflow(by: ri)
                    return overflow ? .real(Double(li) * Double(ri)) : .integer(product)
                case .divide:
                    guard ri != 0 else { return .null }
                    if li == .min && ri == -1 { return .real(9.223372036854776e18) }
                    return .integer(li / ri)
                default:
                    throw DBError.sqlRuntime("unsupported arithmetic operator \(op.rawValue)")
            }
        }

        let ld = asDouble(l)
        let rd = asDouble(r)
        let result: Double
        switch op {
            case .add: result = ld + rd
            case .subtract: result = ld - rd
            case .multiply: result = ld * rd
            case .divide:
                guard rd != 0 else { return .null }
                result = ld / rd
            default:
                throw DBError.sqlRuntime("unsupported arithmetic operator \(op.rawValue)")
        }
        return result.isNaN ? .null : .real(result)
    }

    private static func isReal(_ v: Value) -> Bool {
        if case .real = v { return true }
        return false
    }

    /// Int-cast with SQLite CAST semantics: saturate out-of-range doubles,
    /// NaN → 0.
    private static func asInt(_ v: Value) -> Int64? {
        switch v {
            case .integer(let i): return i
            case .real(let d):
                if d.isNaN { return 0 }
                if d <= -9.223372036854776e18 { return .min }
                if d >= 9.223372036854776e18 { return .max }
                return Int64(d)
            default: return nil
        }
    }

    /// Affinity conversion: text that is a complete well-formed number
    /// becomes numeric (leading/trailing whitespace allowed); otherwise nil.
    static func fullNumeric(_ s: String) -> Value? {
        let bytes = Array(s.utf8)
        var lo = 0
        var hi = bytes.count
        while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 || bytes[lo] == 0x0A { lo += 1 }
        while hi > lo, bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0x09 || bytes[hi - 1] == 0x0A {
            hi -= 1
        }
        guard hi > lo else { return nil }
        let core = String(decoding: bytes[lo ..< hi], as: UTF8.self)
        if let v = Int64(core) { return .integer(v) }
        // Reject hex/inf/nan spellings Double accepts but SQLite does not.
        for byte in bytes[lo ..< hi] {
            switch byte {
                case 0x30 ... 0x39, 0x2B, 0x2D, 0x2E, 0x65, 0x45: continue
                default: return nil
            }
        }
        guard let d = Double(core) else { return nil }
        return .real(d)
    }

    private static func asDouble(_ v: Value) -> Double {
        switch v {
            case .integer(let i): return Double(i)
            case .real(let d): return d
            default: return 0
        }
    }

    // MARK: - LIKE (ASCII-case-insensitive, % and _ over characters)

    static func like(text: String, pattern: String) -> Bool {
        let t = Array(text.unicodeScalars).map(foldScalar)
        let p = Array(pattern.unicodeScalars).map(foldScalar)
        return likeMatch(t[...], p[...])
    }

    private static func foldScalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        (s.value >= 0x41 && s.value <= 0x5A) ? Unicode.Scalar(s.value + 0x20)! : s
    }

    private static func likeMatch(
        _ text: ArraySlice<Unicode.Scalar>, _ pattern: ArraySlice<Unicode.Scalar>
    ) -> Bool {
        var t = text
        var p = pattern
        while let pc = p.first {
            if pc == "%" {
                p = p.dropFirst()
                while p.first == "%" { p = p.dropFirst() }  // collapse runs
                if p.isEmpty { return true }
                var rest = t
                while true {
                    if likeMatch(rest, p) { return true }
                    if rest.isEmpty { return false }
                    rest = rest.dropFirst()
                }
            }
            guard let tc = t.first else { return false }
            guard pc == "_" || pc == tc else {
                return false
            }
            t = t.dropFirst()
            p = p.dropFirst()
        }
        return t.isEmpty
    }

    // MARK: - Scalar function dispatch

    /// Dispatches a scalar function call by name through ``SQLFunctionRegistry``.
    /// The compiled evaluator resolves the handler once at compile time (so the hot
    /// path carries the captured handler, no per-row lookup); this per-call entry
    /// serves the tree-walk evaluator. An unknown name (no core builtin, no enabled
    /// extension) throws.
    static func call(
        _ name: String, args: [SQLExpr], star: Bool, offset: Int, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        guard let handler = SQLFunctionRegistry.handler(for: name) else {
            throw DBError.sqlUnsupported("\(name)() function")
        }
        return try handler(args, star, offset, env)
    }

    /// Forces one-time registration of the core scalar builtins. Called by
    /// ``SQLFunctionRegistry/handler(for:)`` so any lookup first sees the core set;
    /// extension modules (``ADDBJSON``) register their functions on top when enabled.
    static func ensureBuiltinsRegistered() { _ = builtinsRegistered }

    private static let builtinsRegistered: Void = {
        for name in ["COALESCE", "LOWER", "UPPER", "LENGTH", "INSTR", "SUBSTR", "SUBSTRING"] {
            SQLFunctionRegistry.register(name) { args, star, offset, env throws(DBError) in
                try callCoreScalar(name, args: args, star: star, offset: offset, env)
            }
        }
        registerDateTimeFunctions()
        // COUNT/SUM reach scalar dispatch only when misused outside GROUP BY; give
        // the same diagnostic the aggregate binder would (valid use never gets here).
        for name in ["COUNT", "SUM"] {
            SQLFunctionRegistry.register(name) { _, _, _, _ throws(DBError) in
                throw DBError.sqlBind("\(name)() is an aggregate and needs GROUP BY context")
            }
        }
    }()

    /// The core scalar builtins (string/coercion), kept in one switch the registry
    /// fans out per name.
    static func callCoreScalar(
        _ name: String, args: [SQLExpr], star: Bool, offset: Int, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        switch name {
            case "COALESCE": return try coalesce(args, env)
            case "LOWER", "UPPER": return try changeCase(name, args, star: star, env)
            case "LENGTH": return try length(args, star: star, env)
            case "INSTR": return try instr(args, star: star, env)
            case "SUBSTR", "SUBSTRING": return try substr(args, star: star, env)
            default: throw DBError.sqlUnsupported("\(name)() function")
        }
    }

    private static func requireArgs(
        _ name: String, _ args: [SQLExpr], star: Bool, _ counts: ClosedRange<Int>
    ) throws(DBError) {
        guard !star, counts.contains(args.count) else {
            throw DBError.sqlBind("\(name)() takes \(counts) arguments")
        }
    }

    private static func coalesce(_ args: [SQLExpr], _ env: SQLEvalEnv) throws(DBError) -> Value {
        for expr in args {
            let value = try SQLEval.evaluate(expr, env)
            if !value.isNull { return value }
        }
        return .null
    }

    private static func changeCase(
        _ name: String, _ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        try requireArgs(name, args, star: star, 1 ... 1)
        let value = try SQLEval.evaluate(args[0], env)
        guard case .text(let s) = value else { return value.isNull ? .null : .text(textify(value)) }
        let folded = String(
            String.UnicodeScalarView(
                s.unicodeScalars.map { scalar in
                    if name == "LOWER" {
                        return (scalar.value >= 0x41 && scalar.value <= 0x5A)
                            ? Unicode.Scalar(scalar.value + 0x20)! : scalar
                    }
                    return (scalar.value >= 0x61 && scalar.value <= 0x7A)
                        ? Unicode.Scalar(scalar.value - 0x20)! : scalar
                }))
        return .text(folded)
    }

    private static func length(
        _ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        try requireArgs("LENGTH", args, star: star, 1 ... 1)
        switch try SQLEval.evaluate(args[0], env) {
            case .null: return .null
            case .text(let s): return .integer(Int64(s.count))
            case .blob(let b): return .integer(Int64(b.count))
            case .integer(let v): return .integer(Int64(String(v).count))
            case .real(let d): return .integer(Int64(realToText(d).count))
        }
    }

    private static func instr(
        _ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        try requireArgs("INSTR", args, star: star, 2 ... 2)
        let haystack = try SQLEval.evaluate(args[0], env)
        let needle = try SQLEval.evaluate(args[1], env)
        guard !haystack.isNull, !needle.isNull else { return .null }
        let h = Array(textify(haystack))
        let n = Array(textify(needle))
        if n.isEmpty { return .integer(0) }
        if n.count <= h.count {
            for start in 0 ... (h.count - n.count) where Array(h[start ..< start + n.count]) == n {
                return .integer(Int64(start + 1))
            }
        }
        return .integer(0)
    }

    private static func substr(
        _ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        try requireArgs("SUBSTR", args, star: star, 2 ... 3)
        let value = try SQLEval.evaluate(args[0], env)
        guard !value.isNull else { return .null }
        let chars = Array(textify(value))
        guard case .integer(var start) = cast(try SQLEval.evaluate(args[1], env), to: .integer)
        else { return .null }
        var length = Int64(chars.count)
        if args.count == 3 {
            guard case .integer(let l) = cast(try SQLEval.evaluate(args[2], env), to: .integer)
            else { return .null }
            length = l
        }
        // SQLite 1-based; negative start counts from the end; negative
        // length takes the |length| characters BEFORE the position.
        if start < 0 {
            start = Int64(chars.count) + start + 1
            if start < 1 {
                length += start - 1
                start = 1
            }
        } else if start == 0 {
            if length > 0 { length -= 1 }
            start = 1
        }
        if length < 0 {
            let newStart = start + length
            length = -length
            start = newStart
            if start < 1 {
                length += start - 1
                start = 1
            }
        }
        if length < 0 { return .text("") }
        let from = Int(start) - 1
        guard from < chars.count, from >= 0 else { return .text("") }
        let to = min(chars.count, from + Int(length))
        return .text(String(chars[from ..< max(from, to)]))
    }
}
extension SQLFunctions {
    /// Registers `datetime()`. Unlike `json_*`, this is a core builtin: `CivilTime`
    /// lives in ADDBCore (it also materializes the storage-level `DEFAULT
    /// datetime('now')` in DML, which never reaches this registry), so the function
    /// ships with the core rather than a separate extension module.
    static func registerDateTimeFunctions() {
        SQLFunctionRegistry.register("DATETIME") { args, star, offset, env throws(DBError) in
            try callDateTime("DATETIME", args: args, star: star, offset: offset, env)
        }
    }

    /// The datetime functions (currently `datetime('now')`).
    static func callDateTime(
        _ name: String, args: [SQLExpr], star: Bool, offset: Int, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        func requireArgs(_ counts: ClosedRange<Int>) throws(DBError) {
            guard !star, counts.contains(args.count) else {
                throw DBError.sqlBind("\(name)() takes \(counts) arguments")
            }
        }
        switch name {
            case "DATETIME":
                try requireArgs(1 ... 1)
                guard case .text("now") = try SQLEval.evaluate(args[0], env) else {
                    throw DBError.sqlUnsupported("datetime() arguments other than 'now'")
                }
                return .text(CivilTime.utcNowString(now: env.now))
            default:
                throw DBError.sqlUnsupported("\(name)() function")
        }
    }
}
