// File: redact_secrets.dart
// Purpose: Masks secrets in SQL text before it is stored or shown again
// (query history, logs): role passwords, FDW password options and
// passwords inside connection strings.

import 'package:dabase_postgresql/src/sql/sql_statement_splitter.dart';
import 'package:dabase_postgresql/src/sql/sql_token.dart';

/// What a masked string constant is replaced with.
const redactedSecretLiteral = "'********'";

/// What a masked password inside a connection string is replaced with.
const redactedSecretValue = '********';

/// Option and keyword names whose following string constant is a secret.
const _secretNames = {'password', 'sslpassword'};

/// `password=value` / `sslpassword=value` in a libpq conninfo string. The
/// value is a quoted conninfo value (`''…''` inside a standard SQL string,
/// `'…'` inside a dollar-quoted one) or a bare word.
final _conninfoPassword = RegExp(
  r"(\b(?:ssl)?password\s*=\s*)(''(?:\\''|[^'])*''|'(?:\\'|[^'])*'|[^\s'$&]+)",
  caseSensitive: false,
);

/// The password part of `postgres://user:password@host` URIs.
final _uriPassword = RegExp(
  r"(postgres(?:ql)?://[^\s'/@:]*:)([^\s'@/]+)(@)",
  caseSensitive: false,
);

/// Returns [sql] with secrets masked; everything else is unchanged.
///
/// Masked:
/// * in `CREATE` / `ALTER` statements, the string constant right after
///   `PASSWORD` (role, user and group passwords, with or without
///   `ENCRYPTED`, including SCRAM and MD5 verifiers) and after a `password` /
///   `sslpassword` option name (`CREATE|ALTER SERVER` and `USER MAPPING …
///   OPTIONS (password '…')`, also with `ADD` / `SET`). The whole constant
///   becomes [redactedSecretLiteral];
/// * in any string constant of any statement, `password=…` in a libpq
///   connection string (`dblink_connect('… password=…')`) and the password
///   of a `postgres://user:password@host` URI. Only the value becomes
///   [redactedSecretValue].
///
/// Lexical and best effort, like the analyzer: secrets built at run time
/// (`format()`, concatenation, `\password` in psql) are not seen. An
/// unterminated string after `PASSWORD` is masked to the end of the text.
/// The result is for storage and display only; running it would set the
/// literal mask as the password.
String redactSecrets(String sql) {
  final edits = <({int start, int end, String text})>[];
  for (final statement in const SqlStatementSplitter().split(sql)) {
    final tokens = [
      for (final token in statement.tokens)
        if (!token.isTrivia) token,
    ];
    if (tokens.isEmpty) continue;
    final createOrAlter =
        tokens.first.isWordOf('create') || tokens.first.isWordOf('alter');
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final next = i + 1 < tokens.length ? tokens[i + 1] : null;
      if (createOrAlter &&
          next != null &&
          _isSecretName(token) &&
          _isTextConstant(next)) {
        edits.add((
          start: next.start,
          end: next.end,
          text: redactedSecretLiteral,
        ));
        i++;
        continue;
      }
      if (_isTextConstant(token)) {
        final masked = _maskConnectionStrings(token.text);
        if (masked != token.text) {
          edits.add((start: token.start, end: token.end, text: masked));
        }
      }
    }
  }
  if (edits.isEmpty) return sql;
  final out = StringBuffer();
  var at = 0;
  for (final edit in edits) {
    out
      ..write(sql.substring(at, edit.start))
      ..write(edit.text);
    at = edit.end;
  }
  out.write(sql.substring(at));
  return out.toString();
}

/// Whether [redactSecrets] would mask anything in [sql].
bool containsSecrets(String sql) => redactSecrets(sql) != sql;

bool _isSecretName(SqlToken token) =>
    (token.isWord || token.kind == SqlTokenKind.quotedIdentifier) &&
    _secretNames.contains(token.normalized.toLowerCase());

bool _isTextConstant(SqlToken token) =>
    token.isStringLiteral && token.kind != SqlTokenKind.bitString;

String _maskConnectionStrings(String text) => text
    .replaceAllMapped(
      _conninfoPassword,
      (m) => '${m.group(1)}$redactedSecretValue',
    )
    .replaceAllMapped(
      _uriPassword,
      (m) => '${m.group(1)}$redactedSecretValue${m.group(3)}',
    );
