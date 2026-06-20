@_spi(ADDBEngine) import ADDBCore
import ADSQL
import ADSQLModel

/// RETURNING projection + the write-transaction evaluation environments for
/// `Writer`. Split from `Writer.swift` to keep the enum body within the gate.
extension Writer {
    // MARK: - RETURNING

    /// Resolves RETURNING columns to (name, expression), expanding `*`.
    static func bindReturning(
        _ columns: [SQLResultColumn], definition: TableDefinition
    ) throws(DBError) -> [(name: String, expr: SQLExpr)]? {
        guard !columns.isEmpty else { return nil }
        var outputs: [(name: String, expr: SQLExpr)] = []
        for column in columns {
            switch column {
                case .star, .tableStar:
                    for name in definition.columns.map(\.name) {
                        outputs.append((name, .column(table: nil, name: name, offset: 0)))
                    }
                case .expr(let expr, let alias, let sourceText):
                    let name: String
                    if let alias {
                        name = alias
                    } else if case .column(_, let columnName, _) = expr {
                        name = columnName
                    } else {
                        name = sourceText
                    }
                    outputs.append((name, expr))
            }
        }
        return outputs
    }

    /// Evaluates the RETURNING expressions against a row's values.
    static func projectRow(
        _ returning: [(name: String, expr: SQLExpr)], table: TableDefinition, values rowValues: [Value],
        header: SQLColumnHeader, params: SQLParameters
    ) throws(DBError) -> SQLRow {
        let env = rowEnv(table: table, values: rowValues, params: params)
        var values: [Value] = []
        values.reserveCapacity(returning.count)
        for output in returning { values.append(try SQLEval.evaluate(output.expr, env)) }
        return SQLRow(header: header, values: values)
    }

    /// An evaluation env over one materialized row of a single table. When this
    /// runs inside a trigger body (a frame is active on `ctx`), `new.col`/`old.col`
    /// resolve from the frame before the table's own columns — so a trigger body's
    /// `UPDATE … SET x = new.y WHERE id = old.id` reads NEW/OLD correctly.
    static func rowEnv(
        table: TableDefinition, values: [Value], params: SQLParameters,
        triggerCtx: TxnContext? = nil
    ) -> SQLEvalEnv {
        SQLEvalEnv(
            now: params.now,
            parameter: { p throws(DBError) in try params.lookup(p) },
            column: { (qualifier, name, offset) throws(DBError) in
                if let triggerCtx,
                    let value = try SQLTriggerEngine.triggerColumn(
                        triggerCtx, qualifier: qualifier, name: name, offset: offset)
                {
                    return value
                }
                guard let index = table.columnIndex(of: name) else {
                    throw DBError.noSuchColumn(table: qualifier ?? table.name, column: name)
                }
                return values[index]
            },
            collationOf: { (qualifier, name) in
                if let triggerCtx,
                    let c = SQLTriggerEngine.triggerCollation(triggerCtx, qualifier: qualifier, name: name)
                {
                    return c
                }
                return table.columnIndex(of: name).map { table.columns[$0].collation }
            },
            columnTypeOf: { (qualifier, name) in
                if let triggerCtx,
                    let t = SQLTriggerEngine.triggerColumnType(triggerCtx, qualifier: qualifier, name: name)
                {
                    return t
                }
                return table.columnIndex(of: name).map { table.columns[$0].type }
            },
            scalarSubquery: { _ throws(DBError) in
                throw DBError.sqlUnsupported("subquery in this context")
            })
    }

    /// The base evaluation env for a write statement's VALUES expressions:
    /// parameters, plus `new.col`/`old.col` when running inside a trigger body
    /// (a frame active on the txn's context). Outside a trigger it is exactly a
    /// parameters-only env, so non-trigger writes are unchanged.
    static func writeEnv(txn: borrowing WriteTxn, params: SQLParameters) -> SQLEvalEnv {
        let ctx = txn.ctx
        guard ctx.triggerFrame != nil else {
            return SQLEvalEnv.parametersOnly(now: params.now) { p throws(DBError) in try params.lookup(p) }
        }
        return SQLTriggerEngine.bodyEnv(ctx, params: params)
    }
}
