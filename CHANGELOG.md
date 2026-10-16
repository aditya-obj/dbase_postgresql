# Changelog

## 0.1.0 (unreleased)

### Added

- `PgConnectionConfig`: parses `postgres://` / `postgresql://` URIs and
  libpq `key=value` strings with libpq semantics. Supports percent-decoding,
  bracketed IPv6, multi-host lists with parallel ports, Unix-socket hosts,
  quoted values and `ssl=true`. Unknown keywords are kept. Also adds
  `tryParse`, `toUri`, `redacted`, `copyWith`, `effectiveDatabase`,
  `resolveDefaults` (injectable `PG*` environment) and `securityWarnings`.
- `SslMode`, `PgHost`, `PgSecurityWarning`, `PgConfigParseException`
  (offset only, never echoes input).
- `SqlLexer` / `SqlToken`: a lossless PostgreSQL lexer ported from
  `scan.l`. Includes PostgreSQL 16 numeric literals and junk rules, nested
  comments, every string form, dollar quotes, the operator trailing `+`/`-`
  rule, token diagnostics and a `standardConformingStrings` option.
- The full keyword table generated from `kwlist.h`, with
  `SqlKeywordCategory` and `isHighlightKeyword`.
- `SqlStatementSplitter`: psql-compatible splitting ported from
  `psqlscan.l`, with `BEGIN ATOMIC` bodies, `COPY ... FROM STDIN` data
  blocks and `statementAtOffset`.
- `SqlStatementAnalyzer` / `StatementAnalysis`: statement kind, `writes`,
  `cannotRunInTransactionBlock` and `SafetyFinding`s. Fails closed.
- Entry points: `dbase_postgresql.dart`, `connection_string.dart` and
  `sql.dart`.

### Security

- Parse errors, `toString()` and `redacted()` never contain passwords or
  other secret keywords. CR/LF are percent-encoded in `redacted()`.
- NUL is rejected, both raw and as `%00`.
- Keyword names must look like keywords, so a mistyped URI scheme can't
  turn a password into a stored parameter name. The mutation fuzzer found
  this before release.
