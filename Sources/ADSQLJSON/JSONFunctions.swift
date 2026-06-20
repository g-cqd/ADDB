@_spi(ADDBEngine) public import ADDBCore
import ADDBExec
import ADSQL
@_spi(ADDBEngine) public import ADSQLModel

extension Database {
    /// Enables SQL JSON support: the SQLite json1 scalar functions, the
    /// `json_group_array`/`json_group_object` aggregates, and the `->`/`->>` and
    /// `json_each` operators. Registration is **process-wide** and idempotent (the
    /// functions are dialect-stateless), so one call after opening — on any handle —
    /// makes JSON available everywhere; calling it again is a no-op.
    public func enableJSON() { ADSQLJSONSupport.register() }
}

/// Registration entry point for the ADSQLJSON surface, wiring the json1 functions,
/// aggregates, and operators into ADSQL's registries. `package` so test targets can
/// enable JSON without a `Database` handle (the registries are process-wide).
package enum ADSQLJSONSupport {
    package static func register() {
        for name in [
            "JSON_EXTRACT", "JSON_TYPE", "JSON_VALID", "JSON_ARRAY_LENGTH", "JSON_QUOTE", "JSON",
            "JSON_ARRAY", "JSON_OBJECT", "JSON_SET", "JSON_INSERT", "JSON_REPLACE", "JSON_REMOVE",
            "JSON_PATCH"
        ] {
            SQLFunctionRegistry.register(name) { args, star, offset, env throws(DBError) in
                try callJSON(name, args: args, star: star, offset: offset, env)
            }
        }
        SQLAggregateRegistry.register("JSON_GROUP_ARRAY", argCount: 1 ... 1) {
            JSONGroupArrayAccumulator()
        }
        SQLAggregateRegistry.register("JSON_GROUP_OBJECT", argCount: 2 ... 2) {
            JSONGroupObjectAccumulator()
        }
        SQLJSONOperators.register(JSONOperatorWitness())
    }
}

/// The JSON-operator witness ADSQLJSON installs: routes `->`/`->>`/`json_each` to
/// ``SQLJSON``.
struct JSONOperatorWitness: JSONOperatorEvaluator {
    func arrow(_ document: Value, _ spec: Value, asJSON: Bool) throws(DBError) -> Value {
        try SQLJSON.arrow(document, spec, asJSON: asJSON)
    }
    func eachValues(_ json: String) throws(DBError) -> [Value] {
        try SQLJSON.eachValues(json)
    }
}

/// The SQLite json1 scalar surface, kept in one switch the registry fans out per
/// name. Evaluates its argument expressions through ADSQL's evaluator and renders
/// values via ``SQLJSON`` (ADJSON-backed).
func callJSON(
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
        case "JSON_EXTRACT":
            guard !star, args.count >= 2 else {
                throw DBError.sqlBind("json_extract() takes at least 2 arguments")
            }
            let document = try arg(0)
            if document.isNull { return .null }
            var paths: [String] = []
            paths.reserveCapacity(args.count - 1)
            for index in 1 ..< args.count {
                let p = try arg(index)
                if p.isNull { return .null }
                paths.append(Value.textify(p))
            }
            let json = Value.textify(document)
            if paths.count == 1 { return try SQLJSON.extract(json, path: paths[0]) }
            return try SQLJSON.extractMultiple(json, paths: paths)
        case "JSON_TYPE":
            try requireArgs(1 ... 2)
            let document = try arg(0)
            if document.isNull { return .null }
            var path: String? = nil
            if args.count == 2 {
                let p = try arg(1)
                if p.isNull { return .null }
                path = Value.textify(p)
            }
            return try SQLJSON.type(Value.textify(document), path: path)
        case "JSON_VALID":
            try requireArgs(1 ... 1)
            return SQLJSON.valid(try arg(0))
        case "JSON_ARRAY_LENGTH":
            try requireArgs(1 ... 2)
            let document = try arg(0)
            if document.isNull { return .null }
            var path: String? = nil
            if args.count == 2 {
                let p = try arg(1)
                if p.isNull { return .null }
                path = Value.textify(p)
            }
            return try SQLJSON.arrayLength(Value.textify(document), path: path)
        case "JSON_QUOTE":
            try requireArgs(1 ... 1)
            return try SQLJSON.quote(try arg(0))
        case "JSON":
            try requireArgs(1 ... 1)
            return try SQLJSON.minify(try arg(0))
        case "JSON_ARRAY":
            guard !star else { throw DBError.sqlBind("json_array() does not take *") }
            var values: [Value] = []
            values.reserveCapacity(args.count)
            for index in 0 ..< args.count { values.append(try arg(index)) }
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
            return try SQLJSON.mutate(Value.textify(document), assignments, mode: mode)
        case "JSON_REMOVE":
            guard !star, args.count >= 1 else {
                throw DBError.sqlBind("json_remove() takes at least 1 argument")
            }
            let document = try arg(0)
            if document.isNull { return .null }
            var paths: [String] = []
            for index in 1 ..< args.count {
                let pathValue = try arg(index)
                guard case .text(let path) = pathValue else {
                    throw DBError.sqlRuntime("json_remove() path must be TEXT")
                }
                paths.append(path)
            }
            if paths.isEmpty { return try SQLJSON.minify(document) }
            return try SQLJSON.removePaths(Value.textify(document), paths: paths)
        case "JSON_PATCH":
            try requireArgs(2 ... 2)
            let target = try arg(0)
            let patch = try arg(1)
            if target.isNull || patch.isNull { return .null }
            return try SQLJSON.patch(Value.textify(target), with: Value.textify(patch))
        default:
            throw DBError.sqlUnsupported("\(name)() function")
    }
}
