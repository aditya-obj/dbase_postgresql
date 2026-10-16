---
name: Bug report
about: Something parses, splits or analyzes differently from PostgreSQL
title: ''
labels: bug
assignees: ''
---

<!--
Security problems (for example a password showing up in a log or an
error message): do NOT file them here. See SECURITY.md.
-->

## What happened

<!-- What you ran, what you expected, and what you got instead. -->

## Reproduction

```dart
// The smallest program or input that shows the problem.
```

## Versions

- `dbase_postgresql` version:
- Dart SDK version (`dart --version`):
- PostgreSQL server version (`SELECT version();`), if relevant:
- Platform (Android, iOS, web, macOS, Linux, Windows, server):

## Connection string (REDACTED)

<!--
Only if the bug is about connection strings. REDACT it first: replace the
password, user name, host names and any other secret with placeholders,
and keep only the structure that triggers the bug, e.g.

  postgresql://user:****@host1:5432,host2/db?sslmode=verify-full

`PgConnectionConfig.parse(...).redacted()` masks passwords for you, but
check host and user names yourself.
-->

```text
```

## What libpq or psql does

<!-- If you know: the output of psql, or the libpq rule involved. -->
