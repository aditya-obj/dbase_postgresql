// File: sql_lexer.dart
// Purpose: Lossless PostgreSQL-dialect SQL lexer. Never throws; lexical
// errors are reported as token diagnostics.
//
// Lexical rules ported from src/backend/parser/scan.l - PostgreSQL License,
// (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/sql/sql_char_classes.dart';
import 'package:dbase_postgresql/src/sql/sql_keywords.dart';
import 'package:dbase_postgresql/src/sql/sql_token.dart';

/// Splits SQL text into [SqlToken]s following PostgreSQL's `scan.l`.
///
/// The output is lossless: the tokens tile the input exactly, so joining
/// their text reproduces it, and whitespace and comments are kept as
/// tokens. The lexer never throws. Lexical errors PostgreSQL would reject
/// (unterminated strings or comments, `123abc`, `0x`, `$1a`) are reported
/// through [SqlToken.diagnostic].
///
/// Differences from the server lexer, by design:
/// * adjacent string constants separated by a newline stay separate tokens
///   (the server concatenates them);
/// * `..` lexes as two `.` punctuation tokens;
/// * identifiers are not truncated to 63 bytes;
/// * psql features (`:var` interpolation, backslash meta-commands) are not
///   special: `:` lexes as punctuation and `\` as [SqlTokenKind.unknown].
final class SqlLexer {
  /// Creates a lexer.
  ///
  /// [standardConformingStrings] mirrors the server setting of the same name
  /// (on by default since PostgreSQL 9.1). When `false`, backslashes escape
  /// characters inside plain `'...'` strings too.
  const SqlLexer({this.standardConformingStrings = true});

  /// Whether plain `'...'` strings treat backslash as an ordinary character.
  final bool standardConformingStrings;

  /// Tokenizes all of [source].
  List<SqlToken> tokenize(String source) => scan(source).toList();

  /// Lazily tokenizes [source] starting at offset [start] (which should be
  /// a token boundary). Token offsets are relative to [source].
  Iterable<SqlToken> scan(String source, {int start = 0}) sync* {
    RangeError.checkValueInInterval(start, 0, source.length, 'start');
    var position = start;
    while (position < source.length) {
      final token = _scanToken(source, position);
      yield token;
      position = token.end;
    }
  }

  SqlToken _scanToken(String s, int i) {
    final c = s.codeUnitAt(i);
    final next = i + 1 < s.length ? s.codeUnitAt(i + 1) : -1;

    if (isSqlSpace(c)) {
      var j = i + 1;
      while (j < s.length && isSqlSpace(s.codeUnitAt(j))) {
        j++;
      }
      return _token(s, SqlTokenKind.whitespace, i, j);
    }
    if (c == charMinus && next == charMinus) {
      final newline = s.indexOf('\n', i);
      final end = newline < 0 ? s.length : newline;
      return _token(s, SqlTokenKind.lineComment, i, end);
    }
    if (c == charSlash && next == charStar) return _blockComment(s, i);
    if (c == charQuote) {
      final backslash = !standardConformingStrings;
      return _quoted(s, i, i, SqlTokenKind.string, backslash: backslash);
    }
    if (next == charQuote) {
      switch (c | 0x20) {
        case 0x65: // e
          return _quoted(s, i, i + 1, SqlTokenKind.escapeString);
        case 0x6E: // n
          final backslash = !standardConformingStrings;
          return _quoted(
            s,
            i,
            i + 1,
            SqlTokenKind.string,
            backslash: backslash,
          );
        case 0x62 || 0x78: // b, x
          return _quoted(s, i, i + 1, SqlTokenKind.bitString, backslash: false);
      }
    }
    if ((c | 0x20) == 0x75 && next == charAmpersand && i + 2 < s.length) {
      final third = s.codeUnitAt(i + 2);
      if (third == charQuote) {
        const kind = SqlTokenKind.unicodeString;
        return _quoted(s, i, i + 2, kind, backslash: false);
      }
      if (third == charDoubleQuote) return _quotedIdentifier(s, i, i + 2);
      // Otherwise `U&` falls through to the identifier rule (xufailed).
    }
    if (c == charDoubleQuote) return _quotedIdentifier(s, i, i);
    if (c == charDollar) return _dollar(s, i, next);
    if (isDigit(c) || (c == charDot && isDigit(next))) return _number(s, i);
    if (isIdentifierStart(c)) {
      final j = scanIdentifierEnd(s, i);
      final text = s.substring(i, j);
      final kind = sqlKeywordCategory(text) == null
          ? SqlTokenKind.identifier
          : SqlTokenKind.keyword;
      return SqlToken(kind: kind, text: text, start: i);
    }
    if (c == charColon) {
      if (next == charColon) {
        return _token(s, SqlTokenKind.punctuation, i, i + 2);
      }
      if (next == charEquals) return _token(s, SqlTokenKind.operator, i, i + 2);
      return _token(s, SqlTokenKind.punctuation, i, i + 1);
    }
    if (isPunctuation(c)) return _token(s, SqlTokenKind.punctuation, i, i + 1);
    if (isOperatorChar(c)) {
      return _token(s, SqlTokenKind.operator, i, scanOperatorEnd(s, i));
    }
    return _token(s, SqlTokenKind.unknown, i, i + 1);
  }

  static SqlToken _token(
    String s,
    SqlTokenKind kind,
    int start,
    int end, {
    SqlTokenDiagnostic? diagnostic,
  }) => SqlToken(
    kind: kind,
    text: s.substring(start, end),
    start: start,
    diagnostic: diagnostic,
  );

  static SqlToken _unterminated(String s, SqlTokenKind kind, int start) =>
      _token(
        s,
        kind,
        start,
        s.length,
        diagnostic: SqlTokenDiagnostic.unterminated,
      );

  static SqlToken _blockComment(String s, int start) {
    var depth = 1;
    var j = start + 2;
    while (j < s.length) {
      final c = s.codeUnitAt(j);
      final next = j + 1 < s.length ? s.codeUnitAt(j + 1) : -1;
      if (c == charSlash && next == charStar) {
        depth++;
        j += 2;
      } else if (c == charStar && next == charSlash) {
        depth--;
        j += 2;
        if (depth == 0) return _token(s, SqlTokenKind.blockComment, start, j);
      } else {
        j++;
      }
    }
    return _unterminated(s, SqlTokenKind.blockComment, start);
  }

  /// Scans a single-quoted literal whose opening quote is at [quote].
  /// `''` always escapes a quote; [backslash] enables `\x` escapes.
  static SqlToken _quoted(
    String s,
    int start,
    int quote,
    SqlTokenKind kind, {
    bool backslash = true,
  }) {
    var j = quote + 1;
    while (j < s.length) {
      final c = s.codeUnitAt(j);
      if (backslash && c == charBackslash) {
        j += 2;
      } else if (c == charQuote) {
        if (j + 1 < s.length && s.codeUnitAt(j + 1) == charQuote) {
          j += 2;
        } else {
          return _token(s, kind, start, j + 1);
        }
      } else {
        j++;
      }
    }
    return _unterminated(s, kind, start);
  }

  static SqlToken _quotedIdentifier(String s, int start, int quote) {
    var j = quote + 1;
    while (j < s.length) {
      if (s.codeUnitAt(j) == charDoubleQuote) {
        if (j + 1 < s.length && s.codeUnitAt(j + 1) == charDoubleQuote) {
          j += 2;
          continue;
        }
        return _token(s, SqlTokenKind.quotedIdentifier, start, j + 1);
      }
      j++;
    }
    return _unterminated(s, SqlTokenKind.quotedIdentifier, start);
  }

  static SqlToken _dollar(String s, int start, int next) {
    if (isDigit(next)) {
      var j = start + 1;
      while (j < s.length && isDigit(s.codeUnitAt(j))) {
        j++;
      }
      // param_junk: `$1abc`.
      if (j < s.length && isIdentifierStart(s.codeUnitAt(j))) {
        return _token(
          s,
          SqlTokenKind.parameter,
          start,
          scanIdentifierEnd(s, j),
          diagnostic: SqlTokenDiagnostic.malformedParameter,
        );
      }
      return _token(s, SqlTokenKind.parameter, start, j);
    }
    final tagEnd = scanDollarTagEnd(s, start);
    // dolqfailed: a lone `$` is returned as a single character.
    if (tagEnd < 0) return _token(s, SqlTokenKind.unknown, start, start + 1);
    final delimiter = s.substring(start, tagEnd);
    final close = s.indexOf(delimiter, tagEnd);
    if (close < 0) return _unterminated(s, SqlTokenKind.dollarString, start);
    final end = close + delimiter.length;
    return _token(s, SqlTokenKind.dollarString, start, end);
  }

  static SqlToken _number(String s, int start) {
    final scanned = scanNumber(s, start);
    return _token(
      s,
      SqlTokenKind.number,
      start,
      scanned.end,
      diagnostic: scanned.isMalformed
          ? SqlTokenDiagnostic.malformedNumber
          : null,
    );
  }
}
