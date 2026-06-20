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
    switch name {
        case "JSON_EXTRACT": return try jsonExtract(args, star: star, env)
        case "JSON_TYPE": return try jsonTypeOf(args, star: star, env)
        case "JSON_VALID": return try jsonValid(args, star: star, env)
        case "JSON_ARRAY_LENGTH": return try jsonArrayLength(args, star: star, env)
        case "JSON_QUOTE": return try jsonQuote(args, star: star, env)
        case "JSON": return try jsonMinify(args, star: star, env)
        case "JSON_ARRAY": return try jsonArray(args, star: star, env)
        case "JSON_OBJECT": return try jsonObject(args, star: star, env)
        case "JSON_SET", "JSON_INSERT", "JSON_REPLACE":
            return try jsonMutate(name, args, star: star, env)
        case "JSON_REMOVE": return try jsonRemove(args, star: star, env)
        case "JSON_PATCH": return try jsonPatch(args, star: star, env)
        default: throw DBError.sqlUnsupported("\(name)() function")
    }
}

private func jsonArg(_ args: [SQLExpr], _ i: Int, _ env: SQLEvalEnv) throws(DBError) -> Value {
    try SQLEval.evaluate(args[i], env)
}

private func requireJSONArgs(
    _ name: String, _ args: [SQLExpr], star: Bool, _ counts: ClosedRange<Int>
) throws(DBError) {
    guard !star, counts.contains(args.count) else {
        throw DBError.sqlBind("\(name)() takes \(counts) arguments")
    }
}

private func jsonExtract(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    guard !star, args.count >= 2 else {
        throw DBError.sqlBind("json_extract() takes at least 2 arguments")
    }
    let document = try jsonArg(args, 0, env)
    if document.isNull { return .null }
    var paths: [String] = []
    paths.reserveCapacity(args.count - 1)
    for index in 1 ..< args.count {
        let p = try jsonArg(args, index, env)
        if p.isNull { return .null }
        paths.append(Value.textify(p))
    }
    let json = Value.textify(document)
    if paths.count == 1 { return try SQLJSON.extract(json, path: paths[0]) }
    return try SQLJSON.extractMultiple(json, paths: paths)
}

private func jsonTypeOf(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    try requireJSONArgs("JSON_TYPE", args, star: star, 1 ... 2)
    let document = try jsonArg(args, 0, env)
    if document.isNull { return .null }
    var path: String? = nil
    if args.count == 2 {
        let p = try jsonArg(args, 1, env)
        if p.isNull { return .null }
        path = Value.textify(p)
    }
    return try SQLJSON.type(Value.textify(document), path: path)
}

private func jsonValid(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    try requireJSONArgs("JSON_VALID", args, star: star, 1 ... 1)
    return SQLJSON.valid(try jsonArg(args, 0, env))
}

private func jsonArrayLength(
    _ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv
) throws(DBError) -> Value {
    try requireJSONArgs("JSON_ARRAY_LENGTH", args, star: star, 1 ... 2)
    let document = try jsonArg(args, 0, env)
    if document.isNull { return .null }
    var path: String? = nil
    if args.count == 2 {
        let p = try jsonArg(args, 1, env)
        if p.isNull { return .null }
        path = Value.textify(p)
    }
    return try SQLJSON.arrayLength(Value.textify(document), path: path)
}

private func jsonQuote(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    try requireJSONArgs("JSON_QUOTE", args, star: star, 1 ... 1)
    return try SQLJSON.quote(try jsonArg(args, 0, env))
}

private func jsonMinify(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    try requireJSONArgs("JSON", args, star: star, 1 ... 1)
    return try SQLJSON.minify(try jsonArg(args, 0, env))
}

private func jsonArray(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    guard !star else { throw DBError.sqlBind("json_array() does not take *") }
    var values: [Value] = []
    values.reserveCapacity(args.count)
    for index in 0 ..< args.count { values.append(try jsonArg(args, index, env)) }
    return try SQLJSON.array(values)
}

private func jsonObject(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    guard !star, args.count % 2 == 0 else {
        throw DBError.sqlBind("json_object() requires an even number of arguments")
    }
    var pairs: [(key: Value, value: Value)] = []
    pairs.reserveCapacity(args.count / 2)
    var index = 0
    while index < args.count {
        pairs.append((try jsonArg(args, index, env), try jsonArg(args, index + 1, env)))
        index += 2
    }
    return try SQLJSON.object(pairs)
}

private func jsonMutate(
    _ name: String, _ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv
) throws(DBError) -> Value {
    guard !star, args.count >= 1, args.count % 2 == 1 else {
        throw DBError.sqlBind("\(name.lowercased())() takes a document then path/value pairs")
    }
    let document = try jsonArg(args, 0, env)
    if document.isNull { return .null }
    var assignments: [(path: String, value: Value)] = []
    assignments.reserveCapacity((args.count - 1) / 2)
    var index = 1
    while index < args.count {
        let pathValue = try jsonArg(args, index, env)
        guard case .text(let path) = pathValue else {
            throw DBError.sqlRuntime("\(name.lowercased())() path must be TEXT")
        }
        assignments.append((path, try jsonArg(args, index + 1, env)))
        index += 2
    }
    let mode: SQLJSON.MutationMode =
        name == "JSON_SET" ? .set : (name == "JSON_INSERT" ? .insert : .replace)
    return try SQLJSON.mutate(Value.textify(document), assignments, mode: mode)
}

private func jsonRemove(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    guard !star, args.count >= 1 else {
        throw DBError.sqlBind("json_remove() takes at least 1 argument")
    }
    let document = try jsonArg(args, 0, env)
    if document.isNull { return .null }
    var paths: [String] = []
    for index in 1 ..< args.count {
        let pathValue = try jsonArg(args, index, env)
        guard case .text(let path) = pathValue else {
            throw DBError.sqlRuntime("json_remove() path must be TEXT")
        }
        paths.append(path)
    }
    if paths.isEmpty { return try SQLJSON.minify(document) }
    return try SQLJSON.removePaths(Value.textify(document), paths: paths)
}

private func jsonPatch(_ args: [SQLExpr], star: Bool, _ env: SQLEvalEnv) throws(DBError) -> Value {
    try requireJSONArgs("JSON_PATCH", args, star: star, 2 ... 2)
    let target = try jsonArg(args, 0, env)
    let patch = try jsonArg(args, 1, env)
    if target.isNull || patch.isNull { return .null }
    return try SQLJSON.patch(Value.textify(target), with: Value.textify(patch))
}
