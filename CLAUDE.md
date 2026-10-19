# dabase_postgresql: notes for Claude

A pure-Dart PostgreSQL toolkit (no Flutter, no `dart:io` in `lib/`, no runtime
dependencies) used by the DaBase Android app. This repository is **public**.

## Ground rules

- **Public repo:** never commit credentials, real hosts, private notes or
  anything about the owner's servers. Test fixtures use throwaway values.
- **Owner is the only author:** commit as the configured git user; no AI
  attribution of any kind (no Co-Authored-By, no "Generated with").
- Commit and push finished work to `main` directly (owner-approved). The
  `origin` remote is HTTPS and has no credentials here; push over SSH:
  `git push git@github.com:aditya-obj/dbase_postgresql.git HEAD:main`
  (switch to `…/dabase_postgresql.git` after the owner renames the repo).
  The app repo pins this repo as a submodule: commit and push here first, then
  commit the new submodule pointer in the app repo.
- Ask the owner before adding any dependency (runtime or dev) or changing CI.
- **Never write our own cryptography.**
- Every feature ships with thorough unit tests; keep the analyzer at
  `--fatal-infos` clean and code formatted.

## Layout

- `lib/<area>.dart`: public entry points (connection_string, importers, sql,
  explain, binary, geo, csv, psql, catalog, ddl, dump);
  `lib/dabase_postgresql.dart` exports everything. Implementation in
  `lib/src/<area>/`.
- `test/`: unit tests per area; `live` tag for tests against a real server
  (`DABASE_PG_URL`; Docker compose and TLS cert script in `tool/`);
  integration, fuzz and mutation tags are excluded by default
  (`dart_test.yaml`).
- `README.md` (feature table), `CHANGELOG.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `THIRD_PARTY_NOTICES` (ported code: PostgreSQL `scan.l`,
  psql `describe.c`, PEV2 heuristics…).

## Status

- Version **0.7.0 (unreleased)**: renamed from `dbase_postgresql` on
  2026-10-19 (the app became DaBase because of the dBASE trademark).
  `publish_to: none`; not on pub.dev yet.
- 1,364 tests passing (default tags). BSD-3-Clause.
- Before the first pub.dev release (see the app repo's `TODO.md`):
  final repository URLs after the GitHub rename, remove `publish_to: none`,
  `pana` 160/160, verified publisher, tag-triggered publish workflow,
  `dart_apitool` job.

## Checks

```
dart pub get
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed .
dart test
```
