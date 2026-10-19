// File: sql_quoting.dart
// Purpose: Client-side identifier and literal quoting for generated SQL,
// matching the server's quote_ident / quote_literal so assembled text reads
// the same as what pg_get_*def prints. Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/sql/sql_keywords.dart';

final _plainIdentifier = RegExp(r'^[a-z_][a-z0-9_$]*$');

/// Quotes [name] the way PostgreSQL's `quote_ident` does: left bare only
/// when it is lower case ASCII (`^[a-z_][a-z0-9_$]*$`) and not a keyword
/// outside the unreserved category. `quote_ident` also quotes column-name
/// and type/function-name keywords (`int`, `left`), not only fully
/// reserved ones, so this does too.
///
/// The keyword table is PostgreSQL master's, so a word that became a
/// keyword in a newer release than the server is quoted too. That is
/// harmless: a quoted name means the same thing.
String quoteIdent(String name) {
  final isPlain =
      _plainIdentifier.hasMatch(name) &&
      switch (sqlKeywordCategory(name)) {
        null || SqlKeywordCategory.unreserved => true,
        _ => false,
      };
  return isPlain ? name : '"${name.replaceAll('"', '""')}"';
}

/// `schema.name`, each part quoted with [quoteIdent].
String qualifiedName(String schema, String name) =>
    '${quoteIdent(schema)}.${quoteIdent(name)}';

/// A standard-conforming string literal: `'` doubled, backslashes literal.
String quoteLiteral(String value) => "'${value.replaceAll("'", "''")}'";

final _plainOptionValue = RegExp(r'^[A-Za-z0-9_.+-]+$');

/// Renders a `reloptions` / `ftoptions` entry (`name=value`) for a
/// `WITH (...)` list, quoting the value when it is not a plain word or
/// number, as pg_dump does. [prefix] is prepended to the name
/// (`toast.` for TOAST options).
String reloptionEntry(String option, {String prefix = ''}) {
  final eq = option.indexOf('=');
  if (eq < 0) return '$prefix$option';
  final name = option.substring(0, eq);
  final value = option.substring(eq + 1);
  final rendered = _plainOptionValue.hasMatch(value)
      ? value
      : quoteLiteral(value);
  return '$prefix$name=$rendered';
}

/// Renders an FDW option (`name=value`) as `name 'value'` for an
/// `OPTIONS (...)` list.
String fdwOptionEntry(String option) {
  final eq = option.indexOf('=');
  if (eq < 0) return quoteIdent(option);
  return '${quoteIdent(option.substring(0, eq))} '
      '${quoteLiteral(option.substring(eq + 1))}';
}

/// [body] dollar-quoted with a tag that does not occur in it (`$cmd$`,
/// then `$cmd1$`, `$cmd2$`, ...), for long literal bodies such as pg_cron
/// commands.
String dollarQuote(String body, {String tag = 'cmd'}) {
  var candidate = tag;
  for (var n = 1; body.contains('\$$candidate\$'); n++) {
    candidate = '$tag$n';
  }
  return '\$$candidate\$$body\$$candidate\$';
}
