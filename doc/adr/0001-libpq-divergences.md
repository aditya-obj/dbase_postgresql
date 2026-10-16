# ADR 0001: Deliberate divergences from libpq

- Status: Accepted (v0.1.0)
- Date: 2026-10-16
- Scope: `PgConnectionConfig` (connection string parsing and formatting)

## Context

`dbase_postgresql` follows libpq's connection string semantics. That
keeps a string pasted from `psql`, a cloud console or a `.env` file
meaning the same thing here. libpq's own URI corpus (`001_uri.pl`, 63
cases) is ported in `test/third_party/libpq_uri_corpus_test.dart` and is
the specification.

libpq is a C library that runs in a trusted process. dbase is a mobile app
that stores credentials and writes logs and crash reports. A few libpq
behaviours are unsafe or unhelpful there. Each divergence below is
deliberate, and where the corpus covers it, it is flagged per case with
`diverges:`.

## Decisions

### 1. Unknown keywords are kept, not rejected

libpq rejects unknown keywords (`invalid URI query parameter: "uzer"`).
We keep them in `PgConnectionConfig.parameters`. This lets a newer server
option, or one that dbase interprets itself, pass through without a
library release. pgx made the same choice. Corpus cases 21 and 38 diverge
for this reason.

To stop this from becoming a leak, keyword names must look like keywords
(`[A-Za-z_][A-Za-z0-9_]*`). Anything else is a parse error. The mutation
fuzzer found that a mistyped scheme (`postsql://u:pw@h/db?sslmode=...`)
otherwise turned the whole URI, password included, into a "keyword" that
`redacted()` printed.

### 2. Errors never echo the input

libpq quotes the input in its error messages, e.g. `missing "=" after
"..."`. For `host=db hunter2` that quoted text is the password. Our
`PgConfigParseException` keeps only a message and an offset. Messages
quote a keyword only when it is a known libpq keyword, and they never
include values. `PgConfigParseException`, `PgConnectionConfig.toString()`,
`SqlToken.toString()` and `SqlStatement.toString()` hold no input text.
`redacted()` masks every secret keyword and percent-encodes CR/LF, so log
lines can't be injected.

### 3. NUL is rejected

Like libpq, `%00` is rejected ("forbidden value %00"). Unlike libpq, which
works on C strings, a raw U+0000 anywhere in the input is also rejected.
NUL would act as a protocol field terminator and could inject parameters
into the startup message. This follows pgx.

### 4. `ssl=true` maps to `sslmode=require`

libpq accepts `ssl=true` in URIs for JDBC compatibility and maps it to
`sslmode=require`. We keep that mapping and accept no other value. An
explicit `sslmode` wins over `ssl=true`.

### 5. Parsing is pure; defaults are a separate step

libpq consults `PG*` environment variables, service files and password
files while parsing. Our `parse` never reads the environment, which keeps
it deterministic and web-safe. `resolveDefaults(environment:,
defaultUser:)` applies libpq's fallbacks explicitly: each keyword's `PG*`
variable, then the OS user, then `dbname = user`. It never invents
`postgres` as a database. `database` stays `null` when absent, so
`toUri()` round-trips. Service and password files are not read in v0.1.

Corpus case 63 (`sslmode=verify-full` with `PGSSLROOTCERT=system`)
diverges for this reason. libpq omits the sslmode because the environment
makes it the default. We report the explicit value.

### 6. The last `@` ends the user-info section

libpq uses the first `@`. We use the last `@` before the first `/` or `?`,
so an unencoded `@` in a password (`postgres://u:p@ss@host/db`) still
works. `/` and `?` in a password must still be percent-encoded.

### 7. Defaults for `sslmode` are reported, not changed

When `sslmode` is absent the effective mode is libpq's `prefer`, and
`sslModeWasExplicit` is `false`. We don't silently upgrade it, unlike
pg-connection-string without `uselibpqcompat`. Instead,
`securityWarnings` reports `sslModeNotSpecified` and
`sslMayFallBackToPlaintext`, and the app decides on a policy. The owner
still has to decide whether dbase should default to `verify-full`.

## Other non-libpq conventions recorded here

- No `package:meta` in v0.1 (zero runtime dependencies). `@immutable`
  can't be used, so `avoid_equals_and_hash_code_on_mutable_classes` is
  disabled. Every class that overrides `==` is `final` and has only
  `final` fields.
- The analysis options keep the classic constructor syntax, disabling
  `unnecessary_type_name_in_constructor` and
  `unnecessary_const_in_enum_constructor`. This keeps a lower SDK floor
  possible.

## Consequences

- Strings that libpq rejects for unknown keywords parse here. Code that
  needs strict libpq validation must check `parameters` itself.
- Error messages are less specific than libpq's. Callers point at the
  problem with `offset` in the original string.
