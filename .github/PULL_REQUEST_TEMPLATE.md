## What and why

<!-- What this changes and why. Link the issue if there is one. -->

## PostgreSQL reference

<!--
For lexer, splitter, keyword, connection string or analyzer changes: the
rule this implements (scan.l, psqlscan.l, kwlist.h, fe-connect.c,
PreventInTransactionBlock call site, docs section).
-->

## Checklist

- [ ] `tool/check.sh` passes (format, analyze --fatal-infos, test, fuzz)
- [ ] Tests added or updated; bug fixes include a regression test
- [ ] Server-visible behaviour checked with `dart test -P integration`
      (or left to CI)
- [ ] No ported corpus, golden or `diverges:` flag changed, **or** the
      owner approved the change
- [ ] New public symbols exported with `show`, documented, and given a
      class modifier
- [ ] `CHANGELOG.md` updated
- [ ] No secrets (real connection strings, passwords, keys) in code,
      tests or this description
- [ ] No AI attribution in commits, title or description
