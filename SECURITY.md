# Security policy

## Supported versions

`dbase_postgresql` is pre-1.0. Security fixes go into the latest minor
release only.

| Version | Supported |
|---|---|
| 0.1.x | Yes |
| < 0.1 | No (never published) |

## Reporting a vulnerability

Please **do not** open a public issue, pull request or discussion for a
security problem.

Report it privately through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a
vulnerability**. Include:

- the affected version and how you use the library;
- a minimal reproduction (an input string or a small Dart program);
- the impact you expect (for example, a password reaching a log line).

Remove real hostnames, user names and passwords from anything you send.
Use placeholders such as `postgresql://user:****@host/db`.

## What to expect

- **Acknowledgement within 14 days** of your report.
- For issues rated **medium or higher**, a fixed release **within 60
  days** of the report, or sooner. If a fix needs longer, we will tell you
  why and agree on a date.
- A GitHub security advisory and a `Security` entry in `CHANGELOG.md`
  naming the fixed issue. Reporters are credited unless they prefer not
  to be.

## Scope

In scope: anything in this package, in particular

- **Parser denial of service**: inputs that make the connection string
  parser, lexer, splitter or analyzer hang, use unbounded memory, or
  throw where the API promises not to.
- **Injection**: parsed values that let one connection parameter inject
  another (for example through NUL, quoting or percent-encoding), or log
  lines that can be forged through CR/LF.
- **Credential leaks**: a password or other secret keyword reaching
  `toString()`, an exception message, `redacted()` output or a URI built
  without `includePassword: true`.
- **Downgrades**: any way parsing or `resolveDefaults` silently weakens
  the requested `sslmode`, TLS verification or SCRAM settings.
- **Wrong safety answers** from `SqlStatementAnalyzer` that make a
  writing or destructive statement look read-only.

Out of scope: vulnerabilities in PostgreSQL itself, in the Dart SDK, in
the `postgres` driver (a development dependency used only by tests), and
in the dbase app. Report those to their own projects. The analyzer's
documented limits (it is lexical, so a `SELECT` can still write through
a function) are not vulnerabilities.
