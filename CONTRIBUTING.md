# Contributing to dbase_postgresql

Thanks for helping. This file explains how to set up, which checks must
pass, and the rules that keep the parsers faithful to PostgreSQL.

## Setup

You need the Dart SDK at or above the floor in `pubspec.yaml`
(`^3.13.5`). The library has no runtime dependencies and must not import
`dart:io` or Flutter outside `test/` and `tool/`.

```sh
dart pub get
```

## Checks

Run the full gate before opening a pull request:

```sh
tool/check.sh
```

It runs, and CI repeats:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos     # very_good_analysis + strict modes
dart test                      # unit, invariant and corpus tests
dart test -P fuzz              # seeded mutation fuzzing
```

Do not add `// ignore:` comments or skip tests to make the gate pass.

## Test tags

Tags are declared in `dart_test.yaml`. A plain `dart test` excludes the
slow and environment-dependent ones.

| Tag / preset | Run with | Notes |
|---|---|---|
| (untagged) | `dart test` | Fast, no network. |
| `fuzz` | `dart test -P fuzz` | Random seed per run; `FUZZ_SEED` replays a failure, `FUZZ_ITERATIONS` changes the length. |
| `integration` | `dart test -P integration` | Needs `DBASE_PG_URL`; see `test/docker/README.md`. `-P ci-integration` is the CI variant. |
| `mutation` | `dart test -P mutation` | Reserved. |
| `golden` | (no preset yet) | Reserved. |

Anything a server can see (splitting, keywords, transaction-block rules)
should also pass the integration tests on PostgreSQL 13 to 18.

## Behaviour changes need a source

The lexer, splitter, keyword table and connection string parser are
ports. Every behaviour change must name the rule it implements, in the
code comment and in the pull request:

- lexer: `src/backend/parser/scan.l`
- splitter: `src/fe_utils/psqlscan.l`
- keywords: `src/include/parser/kwlist.h` (regenerate with
  `dart run tool/generate_keywords.dart path/to/kwlist.h`; never edit
  `sql_keyword_table.dart` by hand)
- connection strings and `PG*` defaults: `src/interfaces/libpq/fe-connect.c`
  and the libpq documentation
- transaction-block rules: `PreventInTransactionBlock()` call sites in
  `src/backend`

Deliberate differences from libpq go in
`doc/adr/0001-libpq-divergences.md`.

## Adding corpus cases

Ported corpora live in `test/third_party/` and keep their upstream
license header. To add a case:

1. Copy it from the upstream file unchanged and cite the file, the
   branch or commit, and the date fetched next to it.
2. If our behaviour deliberately differs, keep the upstream expectation
   and mark the case `diverges:` with a one-line reason that points to
   the ADR.
3. If the source is new, add it to `THIRD_PARTY_NOTICES`.

Our own cases go in the ordinary test files or in
`test/support/sql_corpus.dart`, each with a comment naming the
PostgreSQL rule it exercises.

## Corpora and goldens are the specification

Ported corpora, golden files, expected outputs and `diverges:` flags
change **only with the owner's explicit approval**, and that diff is
reviewed like code. When a corpus case fails, fix the code, not the
expectation. This applies to people and to AI coding tools alike.

## Commits and pull requests

- Keep each pull request to one topic, with tests. A bug fix includes a
  regression test.
- Add a `CHANGELOG.md` entry under the unreleased version (Breaking,
  Added, Fixed, Deprecated or Security).
- New public symbols are exported through `show` in a barrel file, have a
  `///` doc comment and a deliberate class modifier (`final` by default).
- Commit messages are short and imperative, e.g. `Flag DISCARD ALL as
  non-transactional`, with an optional body explaining why.
- The human submitting the change is its author. **No AI attribution**:
  no `Co-Authored-By` lines for AI tools, no "Generated with ..." lines
  and no robot emoji in commit messages, pull request titles or
  descriptions.
- Never commit secrets: no real connection strings, passwords, keys or
  database dumps, including in tests and issue reproductions.

## Reporting security issues

See [`SECURITY.md`](SECURITY.md). Do not open public issues for
vulnerabilities.
