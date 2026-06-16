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
        let core = String(decoding: bytes[lo..<hi], as: UTF8.self)
        if let v = Int64(core) { return .integer(v) }
        // Reject hex/inf/nan spellings Double accepts but SQLite does not.
        for byte in bytes[lo..<hi] {
            switch byte {
            case 0x30...0x39, 0x2B, 0x2D, 0x2E, 0x65, 0x45: continue
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
            if pc == "_" || pc == tc {
                t = t.dropFirst()
                p = p.dropFirst()
            } else {
                return false
            }
        }
        return t.isEmpty
    }

    // MARK: - Scalar function dispatch

    static func call(
        _ name: String, args: [SQLExpr], star: Bool, offset: Int, _ env: SQLEvalEnv
    ) throws(DBError) -> Value {
        func arg(_ i: Int) throws(DBError) -> Value {
            try SQLEval.evaluate(args[i], env)
        }
        func requireArgs(_ counts: ClosedRange<Int>) throws(DBError) {
            guard !star, counts.contains(args.count) else {
                throw DBError.sqlBind("\(name)() takes \(counts) arguments")
            }
        }

        switch name {
        case "COALESCE":
            for expr in args {
                let value = try SQLEval.evaluate(expr, env)
                if !value.isNull { return value }
            }
            return .null
        case "LOWER", "UPPER":
            try requireArgs(1...1)
            let value = try arg(0)
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
        case "LENGTH":
            try requireArgs(1...1)
            switch try arg(0) {
            case .null: return .null
            case .text(let s): return .integer(Int64(s.count))
            case .blob(let b): return .integer(Int64(b.count))
            case .integer(let v): return .integer(Int64(String(v).count))
            case .real(let d): return .integer(Int64(realToText(d).count))
            }
        case "INSTR":
            try requireArgs(2...2)
            let haystack = try arg(0)
            let needle = try arg(1)
            guard !haystack.isNull, !needle.isNull else { return .null }
            let h = Array(textify(haystack))
            let n = Array(textify(needle))
            if n.isEmpty { return .integer(0) }
            if n.count <= h.count {
                for start in 0...(h.count - n.count) where Array(h[start..<start + n.count]) == n {
                    return .integer(Int64(start + 1))
                }
            }
            return .integer(0)
        case "SUBSTR", "SUBSTRING":
            try requireArgs(2...3)
            let value = try arg(0)
            guard !value.isNull else { return .null }
            let chars = Array(textify(value))
            guard case .integer(var start) = cast(try arg(1), to: .integer) else { return .null }
            var length = Int64(chars.count)
            if args.count == 3 {
                guard case .integer(let l) = cast(try arg(2), to: .integer) else { return .null }
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
            return .text(String(chars[from..<max(from, to)]))
        case "DATETIME":
            try requireArgs(1...1)
            guard case .text("now") = try arg(0) else {
                throw DBError.sqlUnsupported("datetime() arguments other than 'now'")
            }
            return .text(CivilTime.utcNowString())
        case "JSON_EXTRACT":
            guard !star, args.count >= 2 else {
                throw DBError.sqlBind("json_extract() takes at least 2 arguments")
            }
            let document = try arg(0)
            if document.isNull { return .null }
            var paths: [String] = []
            paths.reserveCapacity(args.count - 1)
            for index in 1..<args.count {
                let p = try arg(index)
                if p.isNull { return .null }
                paths.append(SQLFunctions.textify(p))
            }
            let json = SQLFunctions.textify(document)
            if paths.count == 1 { return try SQLJSON.extract(json, path: paths[0]) }
            return try SQLJSON.extractMultiple(json, paths: paths)
        case "JSON_TYPE":
            try requireArgs(1...2)
            let document = try arg(0)
            if document.isNull { return .null }
            var path: String? = nil
            if args.count == 2 {
                let p = try arg(1)
                if p.isNull { return .null }
                path = SQLFunctions.textify(p)
            }
            return try SQLJSON.type(SQLFunctions.textify(document), path: path)
        case "JSON_VALID":
            try requireArgs(1...1)
            return SQLJSON.valid(try arg(0))
        case "JSON_ARRAY_LENGTH":
            try requireArgs(1...2)
            let document = try arg(0)
            if document.isNull { return .null }
            var path: String? = nil
            if args.count == 2 {
                let p = try arg(1)
                if p.isNull { return .null }
                path = SQLFunctions.textify(p)
            }
            return try SQLJSON.arrayLength(SQLFunctions.textify(document), path: path)
        case "JSON_QUOTE":
            try requireArgs(1...1)
            return try SQLJSON.quote(try arg(0))
        case "JSON":
            try requireArgs(1...1)
            return try SQLJSON.minify(try arg(0))
        case "JSON_ARRAY":
            guard !star else { throw DBError.sqlBind("json_array() does not take *") }
            var values: [Value] = []
            values.reserveCapacity(args.count)
            for index in 0..<args.count { values.append(try arg(index)) }
            return try SQLJSON.array(values)
        case "JSON_OBJECT":
            guard !star, args.count % 2 == 0 else {
                throw DBError.sqlBind("json_object() requires an even number of arguments")
            }
            var pairs: [(key: Value, value: Value)] = []
            pairs.reserveCapacity(args.count / 2)
            var index = 0
            while index < args.count {
                pairs.append((try arg(index), try arg(index + 1)))
                index += 2
            }
            return try SQLJSON.object(pairs)
        case "JSON_SET", "JSON_INSERT", "JSON_REPLACE":
            guard !star, args.count >= 1, args.count % 2 == 1 else {
                throw DBError.sqlBind("\(name.lowercased())() takes a document then path/value pairs")
            }
            let document = try arg(0)
            if document.isNull { return .null }
            var assignments: [(path: String, value: Value)] = []
            assignments.reserveCapacity((args.count - 1) / 2)
            var index = 1
            while index < args.count {
                let pathValue = try arg(index)
                guard case .text(let path) = pathValue else {
                    throw DBError.sqlRuntime("\(name.lowercased())() path must be TEXT")
                }
                assignments.append((path, try arg(index + 1)))
                index += 2
            }
            let mode: SQLJSON.MutationMode =
                name == "JSON_SET" ? .set : (name == "JSON_INSERT" ? .insert : .replace)
            return try SQLJSON.mutate(SQLFunctions.textify(document), assignments, mode: mode)
        case "JSON_REMOVE":
            guard !star, args.count >= 1 else {
                throw DBError.sqlBind("json_remove() takes at least 1 argument")
            }
            let document = try arg(0)
            if document.isNull { return .null }
            var paths: [String] = []
            for index in 1..<args.count {
                let pathValue = try arg(index)
                guard case .text(let path) = pathValue else {
                    throw DBError.sqlRuntime("json_remove() path must be TEXT")
                }
                paths.append(path)
            }
            if paths.isEmpty { return try SQLJSON.minify(document) }
            return try SQLJSON.removePaths(SQLFunctions.textify(document), paths: paths)
        case "JSON_PATCH":
            try requireArgs(2...2)
            let target = try arg(0)
            let patch = try arg(1)
            if target.isNull || patch.isNull { return .null }
            return try SQLJSON.patch(SQLFunctions.textify(target), with: SQLFunctions.textify(patch))
        case "COUNT", "SUM":
            throw DBError.sqlBind("\(name)() is an aggregate and needs GROUP BY context")
        default:
            throw DBError.sqlUnsupported("\(name)() function")
        }
    }
}
