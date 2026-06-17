# Full-text search

Create an FTS5-compatible virtual table, populate it, and run ranked `MATCH` queries.

## Overview

ADSQLFullTextSearch exposes the engine's FTS5-style full-text index as a virtual
table, configured by `FTSDefinition`: the indexed columns, a tokenizer chain, a
content mode, and optional prefix indexes and positional `detail`.

### Tokenizers

- `Unicode61Tokenizer` — Unicode-aware word splitting and case folding (the
  default), the right choice for natural-language text.
- `PorterTokenizer` — layers Porter stemming over a base tokenizer, so
  `running` matches the indexed stem `run`.
- `TrigramTokenizer` — every overlapping run of three characters is a term,
  the basis for substring / `LIKE`-style matching.

### Querying

`MATCH` accepts the FTS5 query grammar — terms, quoted phrases, trailing-`*`
prefixes, the boolean operators `AND` / `OR` / `NOT` (with implicit `AND` between
adjacent terms), parenthesised groups, and `col:` / `{a b}:` column filters.
Phrase text is run through the table's own tokenizer, so a query stems the same
way the index did.

Results are ranked with **BM25**, accelerated by a block-max WAND top-k scorer
that skips blocks that cannot enter the current top-k — so a `… ORDER BY rank
LIMIT k` query does not score every matching document.

### Robustness

A `MATCH` string is untrusted input. The query parser bounds both its recursion
(nested parentheses, `col:` chains) and its operator-node count, so a crafted
query fails with a syntax error rather than exhausting the stack.
