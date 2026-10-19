// File: pgpass_line_parser.dart
// Purpose: Splits one .pgpass line into fields, and matches a line against
// lookup values exactly like libpq (internal, not exported).
//
// Matching ports pwdfMatchesString() and the password de-escaping loop of
// passwordFromFile() (libpq fe-connect.c, REL_18_STABLE, lines 7869-8030).
// libpq does not split the line first: it walks it against each lookup
// value, so an unescaped `:` in the line also matches a `:` in the value
// (an unescaped IPv6 host such as `::1:5432:...` matches host `::1`). The
// field view from [parsePgPassLine] is what the documentation describes
// and is used for listing; [matchPgPassLine] is used for lookups.
// test/importers/pgpass_libpq_equivalence_test.dart checks the matcher
// against a literal port of the C code.

import 'package:dabase_postgresql/src/importers/pg_import_diagnostic.dart';
import 'package:dabase_postgresql/src/importers/pgpass_file.dart';
import 'package:dabase_postgresql/src/importers/text_lines.dart';

typedef _Diagnostic = PgLineDiagnostic<PgPassDiagnosticCode>;

/// The result of parsing one line: an entry when libpq could match the
/// line, the line without trailing CR/LF (`source`, for [matchPgPassLine]),
/// and any diagnostics.
typedef PgPassLineResult = ({
  PgPassEntry? entry,
  String source,
  List<_Diagnostic> diagnostics,
});

/// Parses line [number] whose text (without `\n`) is [raw].
PgPassLineResult parsePgPassLine(int number, String raw) {
  // libpq checks for `#` before stripping CR/LF, at column 0 only.
  if (raw.startsWith('#')) {
    return (entry: null, source: '', diagnostics: const []);
  }
  var end = raw.length;
  while (end > 0 && (raw.codeUnitAt(end - 1) == 0x0A || raw[end - 1] == '\r')) {
    end--;
  }
  final text = raw.substring(0, end);
  if (text.trim().isEmpty) {
    return (entry: null, source: '', diagnostics: const []);
  }

  _Diagnostic diagnostic(
    PgPassDiagnosticCode code,
    PgImportSeverity severity,
    String message,
  ) => PgLineDiagnostic(
    line: number,
    code: code,
    severity: severity,
    message: message,
  );

  if (text.contains('\u0000')) {
    return (
      entry: null,
      source: text,
      diagnostics: [
        diagnostic(
          PgPassDiagnosticCode.nulCharacter,
          PgImportSeverity.warning,
          'The line contains a NUL character and was skipped.',
        ),
      ],
    );
  }

  final diagnostics = <_Diagnostic>[];
  final indentedComment = isCSpace(text.codeUnitAt(0));
  if (indentedComment) {
    final looksLikeComment = text.trimLeft().startsWith('#');
    diagnostics.add(
      looksLikeComment
          ? diagnostic(
              PgPassDiagnosticCode.indentedComment,
              PgImportSeverity.warning,
              'libpq treats "#" as a comment only in the first column; '
              'this line is read as data.',
            )
          : diagnostic(
              PgPassDiagnosticCode.leadingWhitespace,
              PgImportSeverity.warning,
              'The line starts with whitespace, which libpq keeps as part '
              'of the host name.',
            ),
    );
  }

  final fields = _splitFields(text);
  if (fields.length < 5) {
    if (!(indentedComment && text.trimLeft().startsWith('#'))) {
      diagnostics.add(
        diagnostic(
          PgPassDiagnosticCode.tooFewFields,
          PgImportSeverity.warning,
          'Expected hostname:port:database:username:password; found '
          '${fields.length} field${fields.length == 1 ? '' : 's'}. '
          'The line was skipped.',
        ),
      );
    }
    return (entry: null, source: text, diagnostics: diagnostics);
  }
  if (fields.length > 5) {
    diagnostics.add(
      diagnostic(
        PgPassDiagnosticCode.extraFields,
        PgImportSeverity.info,
        'The line has more than five fields. libpq ignores the extra ones '
        'unless a looked-up value contains ":" (an unescaped IPv6 address, '
        r'for example); write a colon inside a value as "\:".',
      ),
    );
  }
  final last = text.codeUnitAt(text.length - 1);
  if (last == 0x20 || last == 0x09) {
    diagnostics.add(
      diagnostic(
        PgPassDiagnosticCode.trailingWhitespace,
        PgImportSeverity.warning,
        'The line ends with whitespace, which libpq keeps as part of the '
        'password.',
      ),
    );
  }
  String? match(_Field field) => field.isWildcard ? null : field.value;
  return (
    entry: PgPassEntry(
      line: number,
      host: match(fields[0]),
      port: match(fields[1]),
      database: match(fields[2]),
      user: match(fields[3]),
      password: fields[4].value,
    ),
    source: text,
    diagnostics: diagnostics,
  );
}

/// A de-escaped field and whether it was written as exactly `*`.
typedef _Field = ({String value, bool isWildcard});

List<_Field> _splitFields(String text) {
  final fields = <_Field>[];
  final value = StringBuffer();
  var fieldStart = 0;
  var i = 0;
  while (i < text.length) {
    final char = text[i];
    if (char == r'\' && i + 1 < text.length) {
      value.write(text[i + 1]);
      i += 2;
    } else if (char == ':') {
      fields.add((
        value: value.toString(),
        isWildcard: i - fieldStart == 1 && text[fieldStart] == '*',
      ));
      value.clear();
      i++;
      fieldStart = i;
    } else {
      // Includes a lone `\` at the end of the line.
      value.write(char);
      i++;
    }
  }
  // The last field is never a wildcard: libpq needs `*` followed by `:`.
  fields.add((value: value.toString(), isWildcard: false));
  return fields;
}

/// Matches [source] (a line from [parsePgPassLine]) against already
/// normalised lookup values the way passwordFromFile() does. On a match,
/// returns an entry describing how libpq read the line: a field matched by
/// `*` is `null`, any other field equals its lookup value, and the
/// password is de-escaped up to the next unescaped `:`.
PgPassEntry? matchPgPassLine(
  int line,
  String source, {
  required String host,
  required String port,
  required String database,
  required String user,
}) {
  final values = [host, port, database, user];
  final matched = <String?>[];
  var at = 0;
  for (final value in values) {
    final field = _matchField(source, at, value);
    if (field == null) return null;
    matched.add(field.wildcard ? null : value);
    at = field.next;
  }
  final password = StringBuffer();
  for (var i = at; i < source.length && source[i] != ':'; i++) {
    if (source[i] == r'\' && i + 1 < source.length) i++;
    password.write(source[i]);
  }
  return PgPassEntry(
    line: line,
    host: matched[0],
    port: matched[1],
    database: matched[2],
    user: matched[3],
    password: password.toString(),
  );
}

/// pwdfMatchesString(): matches [value] against the field starting at
/// [start]; returns the index after the field's `:`, or `null`.
({int next, bool wildcard})? _matchField(String s, int start, String value) {
  if (start + 1 < s.length && s[start] == '*' && s[start + 1] == ':') {
    return (next: start + 2, wildcard: true);
  }
  var i = start;
  var v = 0;
  while (i < s.length) {
    var escaped = false;
    if (s[i] == r'\') {
      i++;
      escaped = true;
    }
    final char = i < s.length ? s[i] : null;
    if (char == ':' && v == value.length && !escaped) {
      return (next: i + 1, wildcard: false);
    }
    if (v == value.length || char != value[v]) return null;
    i++;
    v++;
  }
  return null;
}
