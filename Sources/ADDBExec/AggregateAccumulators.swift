import ADSQL
@_spi(ADDBEngine) import ADSQLModel

// The running aggregate accumulators + finalization — the EXECUTION half of `AggregateSpec` (which
// lives in the ADSQL frontend). Uses the evaluator (`SQLEval`/`SQLFunctions`) + the registry, so it
// belongs in `ADDBExec`.

/// One aggregate slot's running state. Replaces the former six parallel arrays
/// (`count`/`sumNonNull`/`sumIsReal`/`sumInt`/`sumReal`/`custom`) with a single
/// array-of-structs: one heap allocation per group instead of six, and a per-row
/// update that touches one contiguous element per slot instead of striding six
/// arrays. Each case carries exactly the fields the old SoA held for that kind, so
/// the folded values and finalization are bit-for-bit identical.
enum SlotState {
    /// COUNT(*) / COUNT(expr): the running non-NULL tally.
    case count(Int)
    /// SUM(expr): `nonNull` (any value folded → result is non-NULL), `isReal`
    /// (promoted to floating accumulation), and the two running totals. Mirrors the
    /// former `sumNonNull`/`sumIsReal`/`sumInt`/`sumReal` lanes exactly.
    case sum(nonNull: Bool, isReal: Bool, int: Int64, real: Double)
    /// An extension-registered aggregate. The binder only emits `.custom` for a
    /// registered name, so the descriptor — and thus this accumulator — is always
    /// present when the slot is `.custom`.
    case custom(any AggregateAccumulator)
}

/// One group's running aggregate state, indexed by aggregate slot.
final class GroupAccumulators {
    private let specs: [AggregateSpec]
    /// One `SlotState` per aggregate slot (single allocation; element type chosen by
    /// the slot's kind at init). Mutated in place per row.
    private var slots: [SlotState]

    init(specs: [AggregateSpec]) {
        self.specs = specs
        self.slots = specs.map { spec in
            switch spec.kind {
                case .countStar, .count:
                    return .count(0)
                case .sum:
                    return .sum(nonNull: false, isReal: false, int: 0, real: 0)
                case .custom(let name, _):
                    // The descriptor is guaranteed present for a bound `.custom`; force it
                    // (matches the former `custom[slot]!` invariant).
                    return .custom(SQLAggregateRegistry.descriptor(for: name)!.makeAccumulator())
            }
        }
    }

    /// Folds one input row into every aggregate (arguments are evaluated against
    /// the live row via `env`).
    func update(_ env: SQLEvalEnv) throws(DBError) {
        for slot in slots.indices {
            switch specs[slot].kind {
                case .countStar:
                    guard case .count(let c) = slots[slot] else { break }
                    slots[slot] = .count(c + 1)
                case .count(let expr):
                    if !(try SQLEval.evaluate(expr, env)).isNull {
                        guard case .count(let c) = slots[slot] else { break }
                        slots[slot] = .count(c + 1)
                    }
                case .sum(let expr):
                    try addToSum(slot, try SQLEval.evaluate(expr, env))
                case .custom(_, let args):
                    var values: [Value] = []
                    values.reserveCapacity(args.count)
                    for arg in args { values.append(try SQLEval.evaluate(arg, env)) }
                    guard case .custom(let accumulator) = slots[slot] else { break }
                    try accumulator.update(values)
            }
        }
    }

    func result(_ slot: Int) -> Value {
        switch slots[slot] {
            case .count(let c):
                return .integer(Int64(c))
            case .sum(let nonNull, let isReal, let int, let real):
                guard nonNull else { return .null }  // empty / all-NULL SUM is NULL
                return isReal ? .real(real) : .integer(int)
            case .custom(let accumulator):
                return accumulator.result()
        }
    }

    private func addToSum(_ slot: Int, _ value: Value) throws(DBError) {
        // SQLite SUM ignores NULLs and applies numeric affinity to other classes.
        let numeric: Value
        switch value {
            case .null: return
            case .integer, .real: numeric = value
            case .text(let s): numeric = SQLFunctions.numericPrefix(s)
            case .blob: numeric = .integer(0)
        }
        guard case .sum(_, var isReal, var int, var real) = slots[slot] else { return }
        switch numeric {
            case .integer(let n):
                if isReal {
                    real += Double(n)
                } else {
                    let (total, overflow) = int.addingReportingOverflow(n)
                    if overflow { throw DBError.sqlRuntime("integer overflow in SUM()") }
                    int = total
                }
            case .real(let d):
                if !isReal {
                    isReal = true
                    real = Double(int)
                }
                real += d
            default:
                break
        }
        slots[slot] = .sum(nonNull: true, isReal: isReal, int: int, real: real)
    }
}
