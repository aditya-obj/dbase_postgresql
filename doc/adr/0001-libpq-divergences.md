# ADR 0001: Deliberate divergences from libpq

- Status: Accepted (v0.1.0; importer section added in v0.2.0)
- Date: 2026-10-16 (importers: 2026-10-17)
- Scope: `PgConnectionConfig` (connection string parsing and formatting);
  the `.pgpass`, `pg_service.conf` and pgAdmin `servers.json` importers

## Context

`dabase_postgresql` follows libpq's connection string semantics. That
keeps a string pasted from `psql`, a cloud console or a `.env` file
meaning the same thing here. libpq's own URI corpus (`001_uri.pl`, 63
cases) is ported in `test/third_party/libpq_uri_corpus_test.dart` and is
the specification.

libpq is a C library that runs in a trusted process. dabase is a mobile app
that stores credentials and writes logs and crash reports. A few libpq
behaviours are unsafe or unhelpful there. Each divergence below is
deliberate, and where the corpus covers it, it is flagged per case with
`diverges:`.

## Decisions

### 1. Unknown keywords are kept, not rejected

libpq rejects unknown keywords (`invalid URI query parameter: "uzer"`).
We keep them in `PgConnectionConfig.parameters`. This lets a newer server
option, or one that dabase interprets itself, pass through without a
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
`toUri()` round-trips. Service and password files are never read; since
v0.2 the caller passes their text to the importers (decisions 8 to 12).

The keyword-to-variable table is checked against `PQconninfoOptions[]` in
`fe-connect.c` (see `lib/src/config/libpq_keywords.dart`). Like libpq,
`resolveDefaults` honours the deprecated `PGREQUIRESSL=1` and raises the
default sslmode to `verify-full` when `sslrootcert=system`. Two
differences remain: an environment variable set to the empty string is
treated as unset (libpq stores the empty value, which for most keywords
then means "use the default" anyway), and `PGDATESTYLE`, `PGTZ` and
`PGGEQO` are not applied, because libpq sends them as startup parameters
rather than as keyword fallbacks.

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
still has to decide whether dabase should default to `verify-full`.

## Importers (v0.2.0)

The importers follow `passwordFromFile()`, `pwdfMatchesString()`,
`parseServiceFile()` and `parseServiceInfo()` in libpq's `fe-connect.c`
(REL_18_STABLE), and `validate_json_data()` / `load_database_servers()` in
pgAdmin 4's `web/pgadmin/utils/__init__.py`. `.pgpass` lookups are checked
against a literal port of the C matcher
(`test/support/libpq_pgpass_reference.dart`). The importers read text that
the app passes in, which leads to these differences:

### 8. A leading byte order mark is ignored, with a warning

libpq reads a BOM as part of the first line, so the first `.pgpass` host
or the first `[service]` header silently never matches. Python's
`json.loads` rejects a BOM. Files that reach a phone often come from
Windows editors, and the author's intent is clear, so we drop the BOM and
report `byteOrderMark`.

### 9. NUL characters are rejected per line

libpq's `fgets`/`strlen` loops silently truncate a line at NUL. We skip a
`.pgpass` line that contains NUL, and in a service file it's an error that
invalidates the section. This is the same reason as decision 3.

### 10. `.pgpass`: no permission check, and the port is compared as a number

libpq ignores a password file with group or world access. Files picked
through Android's Storage Access Framework have no meaningful POSIX mode,
so the caller decides (the app warns that the file holds plaintext
passwords). `lookup` takes `port` as an `int`, as `PgHost.port` does, and
compares its decimal form. A line written as `05432` therefore never
matches, while libpq would match it against a connection string port of
`05432`.

### 11. Service files: every section is read and all errors are reported

libpq parses only the section it is looking for and stops at the first
error. We parse every section so the app can list them, and give each one
the result a libpq lookup of that name would get. Errors from lines it
would never reach (later lines in another section) don't affect it. We
report every error in a section, not just the first. Values are validated
on import (port range, `sslmode`, `connect_timeout`, host/port counts),
which libpq only does at connect time. Either way, the connection fails.

Edge cases:
- A section's name runs up to the first `]`. libpq matches
  `strncmp(line + 1, name) && line[len + 1] == ']'`, so `[a]b]` would also
  match a lookup of `a]b`. We list it as `a` only.
- `[]` is ignored. libpq would match it for an empty service name.
- `ldap...` lines are skipped with `ldapNotSupported`. libpq built with
  LDAP does a lookup; without LDAP it's a syntax error. We behave as if
  the LDAP server were unreachable (libpq's `rc = 2`: keep reading).
- `servicefile=` inside a section is reported as `nestedService`. That's
  PostgreSQL 19's message; PostgreSQL 18 says "syntax error". Both are
  errors.
- A value with leading whitespace (`host= x`) is kept, as libpq does, and
  flagged with a warning. Whitespace before `=` is an error, as in libpq.

### 12. pgAdmin `servers.json`: invalid entries don't abort the import

`validate_json_data()` returns the first error and the command-line import
stops there. We import every valid entry and report each invalid one in
`errors`. Servers with `Shared: true` are imported (pgAdmin skips them for
non-admins). `PasswordExecCommand` is never run and its text is not kept,
because it can contain a secret (pgAdmin itself won't print it in server
mode). `ConnectionParameters` values that are JSON numbers become decimal
strings; booleans, arrays and objects are skipped with a warning. When a
connection parameter repeats `host`, `port`, `user` or `dbname`, the
top-level `Host`, `Port`, `Username` or `MaintenanceDB` wins. As in
pgAdmin, the flat legacy keys are read only when `ConnectionParameters` is
absent.

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
