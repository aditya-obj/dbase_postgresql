// File: libpq_pgpass_reference.dart
// Purpose: A literal port of libpq's password-file lookup, used as the
// oracle for PgPassFile. Deliberately written like the C code, not like
// idiomatic Dart, so a reviewer can compare it line by line.
//
// Source: passwordFromFile() and pwdfMatchesString() in PostgreSQL's
// src/interfaces/libpq/fe-connect.c, REL_18_STABLE, lines 7869-8030
// (fetched 2026-10-17). C strings end at the string length here; inputs
// never contain NUL (PgPassFile rejects NUL lines on purpose).

/// pwdfMatchesString(buf + start, token): the index just after the
/// matched field's `:`, or `null`.
int? _pwdfMatchesString(String buf, int? start, String token) {
  if (start == null) return null;
  var tbuf = start;
  var ttok = 0;
  var bslash = false;
  String at(int i) => i < buf.length ? buf[i] : '\u0000';
  String tokAt(int i) => i < token.length ? token[i] : '\u0000';
  if (at(tbuf) == '*' && at(tbuf + 1) == ':') return tbuf + 2;
  while (at(tbuf) != '\u0000') {
    if (at(tbuf) == r'\' && !bslash) {
      tbuf++;
      bslash = true;
    }
    if (at(tbuf) == ':' && tokAt(ttok) == '\u0000' && !bslash) {
      return tbuf + 1;
    }
    bslash = false;
    if (tokAt(ttok) == '\u0000') return null;
    if (at(tbuf) == tokAt(ttok)) {
      tbuf++;
      ttok++;
    } else {
      return null;
    }
  }
  return null;
}

/// passwordFromFile() over [text], after libpq's own normalisation of
/// [hostname] and [port]. Returns the de-escaped password or `null`.
String? libpqPasswordFromText(
  String text, {
  required String hostname,
  required String port,
  required String dbname,
  required String username,
  String socketDirectory = '/tmp',
}) {
  if (dbname.isEmpty || username.isEmpty) return null;
  var host = hostname;
  if (host.isEmpty) {
    host = 'localhost';
  } else if ((host.startsWith('/') || host.startsWith('@')) &&
      host == socketDirectory) {
    host = 'localhost';
  }
  final effectivePort = port.isEmpty ? '5432' : port;

  // fgets() loop: each line keeps its '\n'.
  var start = 0;
  while (start < text.length) {
    final newline = text.indexOf('\n', start);
    final end = newline < 0 ? text.length : newline + 1;
    var line = text.substring(start, end);
    start = end;
    if (line.startsWith('#')) continue;
    // pg_strip_crlf()
    while (line.isNotEmpty && (line.endsWith('\n') || line.endsWith('\r'))) {
      line = line.substring(0, line.length - 1);
    }
    if (line.isEmpty) continue;
    var t = _pwdfMatchesString(line, 0, host);
    t = _pwdfMatchesString(line, t, effectivePort);
    t = _pwdfMatchesString(line, t, dbname);
    t = _pwdfMatchesString(line, t, username);
    if (t == null) continue;
    // De-escape password.
    final out = StringBuffer();
    var p1 = t;
    while (p1 < line.length && line[p1] != ':') {
      if (line[p1] == r'\' && p1 + 1 < line.length) p1++;
      out.write(line[p1]);
      p1++;
    }
    return out.toString();
  }
  return null;
}
