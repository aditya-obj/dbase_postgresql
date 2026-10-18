// File: meta_command.dart
// Purpose: Parses one psql backslash command (`\dt+ public.*`) and its
// arguments with psql's quoting rules.
//
// Ported from src/bin/psql/psqlscanslash.l (xslashcmd, xslasharg,
// xslashquote, xslashdquote, xslashend states, psql_scan_slash_option,
// dequote_downcase_identifier) - PostgreSQL License, (c) 1996-2026
// PostgreSQL Global Development Group. See THIRD_PARTY_NOTICES.

/// One argument of a backslash command, as typed.
///
/// psql reads arguments differently per command (`enum
/// slash_option_type`); [value] is the normal reading (`OT_NORMAL`) and
/// [sqlIdentifier] the identifier reading (`OT_SQLID`).
final class MetaArg {
  /// Creates an argument.
  const MetaArg({
    required this.raw,
    required this.normal,
    required this.trailingUnquoted,
    this.quote,
  });

  /// The source text of the argument.
  final String raw;

  /// After `'…'` processing (quotes removed, `''` and backslash escapes
  /// applied); double quotes are kept, as psql does for name patterns.
  final String normal;

  /// How many characters at the end of [normal] were not quoted (psql
  /// strips only those trailing semicolons).
  final int trailingUnquoted;

  /// The last quote character used (`'` or `"`), or `null`.
  final String? quote;

  /// Whether any part of the argument was quoted.
  bool get isQuoted => quote != null;

  /// The argument as psql's `OT_NORMAL` option. With [semicolon], unquoted
  /// trailing semicolons are removed (`\d users;` means `users`).
  String value({bool semicolon = false}) {
    if (!semicolon) return normal;
    var text = normal;
    var unquoted = trailingUnquoted;
    while (unquoted-- > 0 && text.isNotEmpty && text.endsWith(';')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  /// The argument as an SQL identifier (`OT_SQLID`): double quotes
  /// removed and unquoted letters lower-cased, so `"Foo"Bar` is `Foobar`.
  String sqlIdentifier({bool semicolon = false}) =>
      dequoteDowncaseIdentifier(value(semicolon: semicolon));
}

/// A parsed backslash command.
final class MetaCommand {
  /// Creates a command.
  const MetaCommand({
    required this.name,
    required this.args,
    required this.start,
    required this.end,
    required this.source,
  });

  /// The command name without the backslash, e.g. `dt+` or `x`.
  final String name;

  /// The arguments, in order.
  final List<MetaArg> args;

  /// Offset of the backslash in [source].
  final int start;

  /// Offset just past the command (and a trailing `\\` when present).
  final int end;

  /// The text the command was parsed from.
  final String source;

  /// The command as typed, from the backslash to [end], trimmed.
  String get text => source.substring(start, end).trim();

  /// The first argument's [MetaArg.value], or `null` without one.
  String? arg(int index, {bool semicolon = false}) =>
      index < args.length ? args[index].value(semicolon: semicolon) : null;

  @override
  String toString() => 'MetaCommand(\\$name, ${args.length} args)';
}

/// Thrown by [parseMetaCommand] when the command can't be read.
final class MetaCommandFormatException implements Exception {
  /// Creates the exception.
  const MetaCommandFormatException(this.message, {required this.end});

  /// psql's message, e.g. `unterminated quoted string`.
  final String message;

  /// Where the bad command ends (the rest of the line is discarded).
  final int end;

  @override
  String toString() => 'MetaCommandFormatException: $message';
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x0B;

const _backslash = 0x5C;
const _singleQuote = 0x27;
const _doubleQuote = 0x22;
const _backquote = 0x60;

/// Parses the backslash command starting at [start] in [text] (where
/// `text[start]` is `\`). The command name runs to whitespace or the next
/// backslash; arguments are split on unquoted whitespace and end at the
/// next unquoted backslash. A `\\` right after the command is consumed:
/// what follows it is SQL again.
///
/// Throws [MetaCommandFormatException] for an unterminated quote or a
/// backquote (psql would run it as a shell command).
MetaCommand parseMetaCommand(String text, int start) {
  if (start >= text.length || text.codeUnitAt(start) != _backslash) {
    throw ArgumentError.value(start, 'start', 'not at a backslash');
  }
  var i = start + 1;
  final nameStart = i;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (_isSpace(c) || c == _backslash) break;
    i++;
  }
  final name = text.substring(nameStart, i);

  final args = <MetaArg>[];
  for (;;) {
    while (i < text.length && _isSpace(text.codeUnitAt(i))) {
      i++;
    }
    if (i >= text.length || text.codeUnitAt(i) == _backslash) break;
    final (arg, next) = _readArg(text, i);
    args.add(arg);
    i = next;
  }

  // xslashend: eat a `\\` that ends the command.
  if (i + 1 < text.length &&
      text.codeUnitAt(i) == _backslash &&
      text.codeUnitAt(i + 1) == _backslash) {
    i += 2;
  }
  return MetaCommand(
    name: name,
    args: List.unmodifiable(args),
    start: start,
    end: i,
    source: text,
  );
}

/// Reads one argument starting at [start] (not whitespace, not `\`).
(MetaArg, int) _readArg(String text, int start) {
  final out = StringBuffer();
  var i = start;
  var unquoted = 0;
  String? quote;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (_isSpace(c) || c == _backslash) break;
    if (c == _singleQuote) {
      quote = "'";
      unquoted = 0;
      i = _readSingleQuoted(text, i + 1, out);
    } else if (c == _doubleQuote) {
      quote = '"';
      unquoted = 0;
      final close = text.indexOf('"', i + 1);
      if (close < 0) {
        throw MetaCommandFormatException(
          'unterminated quoted string',
          end: text.length,
        );
      }
      out.write(text.substring(i, close + 1));
      i = close + 1;
    } else if (c == _backquote) {
      throw MetaCommandFormatException(
        'backquote (shell command) expansion is not supported',
        end: _lineEnd(text, i),
      );
    } else {
      out.writeCharCode(c);
      unquoted++;
      i++;
    }
  }
  return (
    MetaArg(
      raw: text.substring(start, i),
      normal: out.toString(),
      trailingUnquoted: unquoted,
      quote: quote,
    ),
    i,
  );
}

/// xslashquote: copies up to the closing `'`; `''` is a quote and
/// `\n \t \b \r \f`, octal and `\xHH` escapes apply. Returns the index
/// after the closing quote.
int _readSingleQuoted(String text, int start, StringBuffer out) {
  var i = start;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == _singleQuote) {
      if (i + 1 < text.length && text.codeUnitAt(i + 1) == _singleQuote) {
        out.write("'");
        i += 2;
        continue;
      }
      return i + 1;
    }
    if (c == _backslash && i + 1 < text.length) {
      final next = text[i + 1];
      switch (next) {
        case 'n':
          out.write('\n');
          i += 2;
        case 't':
          out.write('\t');
          i += 2;
        case 'b':
          out.write('\b');
          i += 2;
        case 'r':
          out.write('\r');
          i += 2;
        case 'f':
          out.write('\f');
          i += 2;
        case 'x' when _hexDigits(text, i + 2, 2) > 0:
          final n = _hexDigits(text, i + 2, 2);
          out.writeCharCode(
            int.parse(text.substring(i + 2, i + 2 + n), radix: 16),
          );
          i += 2 + n;
        default:
          final octal = _octalDigits(text, i + 1, 3);
          if (octal > 0) {
            final value = int.parse(
              text.substring(i + 1, i + 1 + octal),
              radix: 8,
            );
            out.writeCharCode(value & 0xFF);
            i += 1 + octal;
          } else {
            out.write(next);
            i += 2;
          }
      }
      continue;
    }
    out.writeCharCode(c);
    i++;
  }
  throw MetaCommandFormatException(
    'unterminated quoted string',
    end: text.length,
  );
}

int _hexDigits(String text, int start, int max) {
  var n = 0;
  while (n < max && start + n < text.length) {
    final c = text.codeUnitAt(start + n);
    final isHex =
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x46) ||
        (c >= 0x61 && c <= 0x66);
    if (!isHex) break;
    n++;
  }
  return n;
}

int _octalDigits(String text, int start, int max) {
  var n = 0;
  while (n < max && start + n < text.length) {
    final c = text.codeUnitAt(start + n);
    if (c < 0x30 || c > 0x37) break;
    n++;
  }
  return n;
}

int _lineEnd(String text, int from) {
  final newline = text.indexOf('\n', from);
  return newline < 0 ? text.length : newline;
}

/// psql's `dequote_downcase_identifier`: removes double quotes (`""`
/// inside quotes is one quote) and lower-cases ASCII letters outside them.
String dequoteDowncaseIdentifier(String text, {bool downcase = true}) {
  final out = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == _doubleQuote) {
      if (inQuotes && i + 1 < text.length && text.codeUnitAt(i + 1) == c) {
        out.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (downcase && !inQuotes && c >= 0x41 && c <= 0x5A) {
      out.writeCharCode(c + 0x20);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}
