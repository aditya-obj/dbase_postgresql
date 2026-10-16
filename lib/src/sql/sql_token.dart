// File: sql_token.dart
// Purpose: Token model produced by SqlLexer: kind, exact source text,
// UTF-16 offsets into the lexed string, and an optional lexical diagnostic.

import 'package:dbase_postgresql/src/sql/sql_keywords.dart';

/// The lexical category of a [SqlToken].
///
/// This set mirrors the token classes of PostgreSQL's `scan.l` and is
/// considered complete; lexical errors are reported through
/// [SqlToken.diagnostic] rather than extra kinds.
enum SqlTokenKind {
  /// Spaces, tabs, and line breaks.
  whitespace,

  /// A `--` comment running to the end of the line (newline excluded).
  lineComment,

  /// A `/* ... */` comment. PostgreSQL block comments nest.
  blockComment,

  /// A standard string constant `'it''s'`, also the `N'...'` form.
  string,

  /// An escape string constant `E'line\n'` (backslash escapes apply).
  escapeString,

  /// A Unicode escape string constant `U&'d\0061t'`.
  unicodeString,

  /// A bit-string constant `B'1010'` or `X'1F'`.
  bitString,

  /// A dollar-quoted string `$$...$$` or `$tag$...$tag$`.
  dollarString,

  /// An unquoted identifier that is not in the keyword list.
  identifier,

  /// A double-quoted identifier `"My Table"`, also the `U&"..."` form.
  quotedIdentifier,

  /// An unquoted word found in PostgreSQL's keyword list (`kwlist.h`, any
  /// category, case-insensitive). See [SqlToken.keywordCategory].
  keyword,

  /// A positional parameter such as `$1`.
  parameter,

  /// A numeric constant: `42`, `1.5e10`, `.5`, `0x1F`, `1_000`.
  number,

  /// An operator such as `+`, `<>`, `->>`, `@>`, `:=`, or `=>`.
  operator,

  /// One of `(` `)` `[` `]` `,` `;` `.` `:` or the cast operator `::`.
  punctuation,

  /// A character that cannot start any PostgreSQL token (e.g. a lone `$`,
  /// `\`, `{`).
  unknown,
}

/// A lexical error PostgreSQL would reject, attached to the token that
/// contains it. The lexer never throws; it reports these instead.
enum SqlTokenDiagnostic {
  /// A string, quoted identifier, dollar quote, or block comment has no
  /// closing delimiter; the token runs to the end of input.
  unterminated,

  /// A numeric constant is malformed: trailing identifier characters
  /// (`123abc`, `1_`, `1.5e`), a radix prefix without digits (`0x`), or an
  /// exponent sign without digits (`1e+`). The token covers the whole
  /// malformed text and has kind [SqlTokenKind.number].
  malformedNumber,

  /// A positional parameter is followed by identifier characters (`$1abc`).
  /// The token has kind [SqlTokenKind.parameter].
  malformedParameter,
}

/// One lexical token of a SQL string.
///
/// Offsets are UTF-16 code-unit indices into the string given to the
/// lexer, so `source.substring(token.start, token.end) == token.text`.
final class SqlToken {
  /// Creates a token.
  const SqlToken({
    required this.kind,
    required this.text,
    required this.start,
    this.diagnostic,
  });

  /// The token's category.
  final SqlTokenKind kind;

  /// The exact source text of the token, including quotes and delimiters.
  final String text;

  /// Offset of the first character.
  final int start;

  /// The lexical error in this token, or `null` when it is well formed.
  final SqlTokenDiagnostic? diagnostic;

  /// Whether a string, quoted identifier, dollar quote, or block comment
  /// reached the end of input without its closing delimiter. Such a token
  /// extends to the end of the input.
  bool get isUnterminated => diagnostic == SqlTokenDiagnostic.unterminated;

  /// The keyword category of a [SqlTokenKind.keyword] token, else `null`.
  SqlKeywordCategory? get keywordCategory =>
      kind == SqlTokenKind.keyword ? sqlKeywordCategory(text) : null;

  /// Offset just past the last character.
  int get end => start + text.length;

  /// Whether this token is whitespace or a comment.
  bool get isTrivia =>
      kind == SqlTokenKind.whitespace ||
      kind == SqlTokenKind.lineComment ||
      kind == SqlTokenKind.blockComment;

  /// Whether this token is an unquoted word (keyword or identifier).
  bool get isWord =>
      kind == SqlTokenKind.keyword || kind == SqlTokenKind.identifier;

  /// Whether this token is any kind of string constant.
  bool get isStringLiteral =>
      kind == SqlTokenKind.string ||
      kind == SqlTokenKind.escapeString ||
      kind == SqlTokenKind.unicodeString ||
      kind == SqlTokenKind.bitString ||
      kind == SqlTokenKind.dollarString;

  /// The token's value as PostgreSQL would see a name: unquoted words are
  /// lower-cased; plain double-quoted identifiers lose their quotes and
  /// `""` escapes. Other tokens return [text] unchanged.
  String get normalized {
    if (isWord) return text.toLowerCase();
    if (kind == SqlTokenKind.quotedIdentifier &&
        text.startsWith('"') &&
        !isUnterminated) {
      return text.substring(1, text.length - 1).replaceAll('""', '"');
    }
    return text;
  }

  /// Whether this is the unquoted word [lowerCaseWord] (compared
  /// case-insensitively; pass it in lower case).
  bool isWordOf(String lowerCaseWord) =>
      isWord &&
      text.length == lowerCaseWord.length &&
      text.toLowerCase() == lowerCaseWord;

  /// Whether this is the punctuation [symbol], e.g. `(` or `;`.
  bool isPunctuationOf(String symbol) =>
      kind == SqlTokenKind.punctuation && text == symbol;

  @override
  bool operator ==(Object other) =>
      other is SqlToken &&
      other.kind == kind &&
      other.text == text &&
      other.start == start &&
      other.diagnostic == diagnostic;

  @override
  int get hashCode => Object.hash(kind, text, start, diagnostic);

  /// Shows kind, offsets and diagnostic but not the text, because SQL can
  /// contain secrets (e.g. `ALTER ROLE ... PASSWORD '...'`).
  @override
  String toString() =>
      'SqlToken(${kind.name}, $start..$end'
      '${diagnostic?.name.replaceFirst('', ', ') ?? ''})';
}
