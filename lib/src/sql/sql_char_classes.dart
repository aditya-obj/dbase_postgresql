// File: sql_char_classes.dart
// Purpose: Character classes and sub-scanners (numbers, operators, dollar
// tags) for SqlLexer (internal).
//
// Ported from src/backend/parser/scan.l - PostgreSQL License, (c) 1996-2026
// PostgreSQL Global Development Group. See THIRD_PARTY_NOTICES.

/// Code unit constants used by the lexer.
const charAmpersand = 0x26;

/// `'`
const charQuote = 0x27;

/// `"`
const charDoubleQuote = 0x22;

/// `$`
const charDollar = 0x24;

/// `*`
const charStar = 0x2A;

/// `+`
const charPlus = 0x2B;

/// `-`
const charMinus = 0x2D;

/// `.`
const charDot = 0x2E;

/// `/`
const charSlash = 0x2F;

/// `:`
const charColon = 0x3A;

/// `=`
const charEquals = 0x3D;

/// `\`
const charBackslash = 0x5C;

/// `_`
const charUnderscore = 0x5F;

/// Whitespace as PostgreSQL defines it: space, tab, newline, carriage
/// return, form feed (and vertical tab, which is harmless to include).
bool isSqlSpace(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D);

/// ASCII decimal digit.
bool isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isHexDigit(int c) =>
    isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

bool _isOctalDigit(int c) => c >= 0x30 && c <= 0x37;

bool _isBinaryDigit(int c) => c == 0x30 || c == 0x31;

/// First character of an unquoted identifier: letter, `_`, or any
/// non-ASCII character.
bool isIdentifierStart(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == charUnderscore ||
    c >= 0x80;

/// Later characters of an unquoted identifier (adds digits and `$`).
bool isIdentifierPart(int c) =>
    isIdentifierStart(c) || isDigit(c) || c == charDollar;

/// Single-character punctuation (`:` is handled separately).
bool isPunctuation(int c) =>
    c == 0x28 || // (
    c == 0x29 || // )
    c == 0x5B || // [
    c == 0x5D || // ]
    c == 0x2C || // ,
    c == 0x3B || // ;
    c == charDot;

const _operatorChars = '+-*/<>=~!@#%^&|`?';

/// Characters that can form an operator, per PostgreSQL's `op_chars`.
bool isOperatorChar(int c) =>
    c < 0x80 && _operatorChars.contains(String.fromCharCode(c));

/// Returns the end of the operator starting at [start], applying
/// PostgreSQL's rules: an operator stops before `--` or `/*`, and a
/// multi-character operator cannot end in `+` or `-` unless it also
/// contains one of `~ ! @ # % ^ & | ` ?`.
int scanOperatorEnd(String s, int start) {
  var j = start;
  while (j < s.length && isOperatorChar(s.codeUnitAt(j))) {
    if (j > start && j + 1 < s.length) {
      final c = s.codeUnitAt(j);
      final next = s.codeUnitAt(j + 1);
      if ((c == charMinus && next == charMinus) ||
          (c == charSlash && next == charStar)) {
        break;
      }
    }
    j++;
  }
  final text = s.substring(start, j);
  if (text.length > 1 && !text.contains(RegExp('[~!@#%^&|`?]'))) {
    var end = j;
    while (end - start > 1) {
      final last = s.codeUnitAt(end - 1);
      if (last != charPlus && last != charMinus) break;
      end--;
    }
    return end;
  }
  return j;
}

/// Returns the end of the identifier whose first character is at [start].
int scanIdentifierEnd(String s, int start) {
  var j = start;
  while (j < s.length && isIdentifierPart(s.codeUnitAt(j))) {
    j++;
  }
  return j;
}

/// Scans the numeric constant starting at [start] (a digit, or a `.`
/// followed by a digit) using PostgreSQL 16's rules: `0x1F`, `0o17`,
/// `0b101`, `_` separators between digits, `1..10` as integer + `..`.
///
/// Malformed constants (scan.l's `integer_junk`, `numeric_junk`,
/// `real_junk`, `hexfail`/`octfail`/`binfail`, `realfail`) are returned as
/// one span with `isMalformed` set, covering any trailing identifier
/// characters.
({int end, bool isMalformed}) scanNumber(String s, int start) {
  if (s.codeUnitAt(start) == 0x30 && start + 1 < s.length) {
    final digit = switch (s.codeUnitAt(start + 1) | 0x20) {
      0x78 => _isHexDigit, // x
      0x6F => _isOctalDigit, // o
      0x62 => _isBinaryDigit, // b
      _ => null,
    };
    if (digit != null) {
      final end = _digitsEnd(s, start + 2, digit, allowLeadingUnderscore: true);
      if (end > start + 2) return _withJunk(s, end);
      return (end: scanIdentifierEnd(s, start + 1), isMalformed: true);
    }
  }
  var j = start;
  if (s.codeUnitAt(j) != charDot) j = _digitsEnd(s, j, isDigit);
  // numericfail: `1..10` lexes as the integer 1 followed by `..`.
  if (j < s.length &&
      s.codeUnitAt(j) == charDot &&
      !(j + 1 < s.length && s.codeUnitAt(j + 1) == charDot)) {
    j++;
    if (j < s.length && isDigit(s.codeUnitAt(j))) {
      j = _digitsEnd(s, j, isDigit);
    }
  }
  if (j < s.length && (s.codeUnitAt(j) | 0x20) == 0x65) {
    var k = j + 1;
    final hasSign =
        k < s.length &&
        (s.codeUnitAt(k) == charPlus || s.codeUnitAt(k) == charMinus);
    if (hasSign) k++;
    if (k < s.length && isDigit(s.codeUnitAt(k))) {
      j = _digitsEnd(s, k, isDigit);
    } else if (hasSign) {
      return (end: k, isMalformed: true); // realfail: `1e+`
    }
  }
  return _withJunk(s, j);
}

({int end, bool isMalformed}) _withJunk(String s, int end) =>
    end < s.length && isIdentifierStart(s.codeUnitAt(end))
    ? (end: scanIdentifierEnd(s, end), isMalformed: true)
    : (end: end, isMalformed: false);

/// Scans digits accepted by [digit], allowing single `_` separators
/// between digits. Returns [start] when no digit is found.
int _digitsEnd(
  String s,
  int start,
  bool Function(int) digit, {
  bool allowLeadingUnderscore = false,
}) {
  bool digitAt(int index) => index < s.length && digit(s.codeUnitAt(index));
  var j = start;
  if (allowLeadingUnderscore &&
      j < s.length &&
      s.codeUnitAt(j) == charUnderscore &&
      digitAt(j + 1)) {
    j++;
  }
  if (!digitAt(j)) return start;
  while (j < s.length) {
    if (digitAt(j)) {
      j++;
    } else if (s.codeUnitAt(j) == charUnderscore && digitAt(j + 1)) {
      j += 2;
    } else {
      break;
    }
  }
  return j;
}

/// If a dollar-quote opening delimiter (`$$` or `$tag$`) starts at [start],
/// returns the offset just past it; otherwise -1. Tags use identifier
/// characters except `$` and cannot start with a digit.
int scanDollarTagEnd(String s, int start) {
  var j = start + 1;
  if (j < s.length && s.codeUnitAt(j) == charDollar) return j + 1;
  if (j >= s.length || !isIdentifierStart(s.codeUnitAt(j))) return -1;
  while (j < s.length) {
    final c = s.codeUnitAt(j);
    if (c == charDollar) return j + 1;
    if (!isIdentifierStart(c) && !isDigit(c)) return -1;
    j++;
  }
  return -1;
}
