# Execution strategies

How a query is planned and evaluated, and the opt-in strategies you can select per database or per statement.

## Overview

`prepare` lexes and parses a statement once; each execution binds it against the
transaction's schema and reuses the bound plan while the catalog version is
unchanged. The planner chooses an access path (rowid lookup, index probe or
range, covering index-only scan, FTS scan, or a full table scan) and a join
order from a cost model.

Alternative execution strategies are **opt-in and benchmarked before becoming a
default**: each lands beside the reference path and is selected through
`ExecutionOptions` (on `DatabaseOptions`, or per statement). This lets a new
strategy be proven equivalent (the cross-strategy differential suite runs the
same query under every strategy and against SQLite) before it ships on.

### The evaluator

`ExecutionOptions.Evaluator` selects how row expressions are evaluated:

- **tree-walk** — the reference interpreter over the bound expression tree.
- **compiled closures** (the default) — the bound expression is lowered once to a
  closure tree that bakes in the schema-fixed work (slot reads, comparison
  affinity, collation resolution) the tree-walk would recompute per row. It falls
  back to tree-walk for any construct it does not yet compile, so it is
  equivalent by construction.

Long boolean (`AND`/`OR`) chains are flattened to iteration in both evaluators,
so a deep `WHERE` clause is evaluated in a loop rather than by recursion.

### Index-only scans

An index with covering `includes` columns (see `IndexDefinition`) can serve a
query that reads only the rowid and covered columns directly from the index
entry — no descent into the table tree.
