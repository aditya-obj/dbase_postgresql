// File: sql_statement.dart
// Purpose: One statement found by SqlStatementSplitter, with its text,
// offsets, and tokens.

import 'package:dbase_postgresql/src/sql/sql_token.dart';

/// A single SQL statement within a script.
///
/// [text] runs from the first to the last significant (non-whitespace,
/// non-comment) token, so leading and trailing comments are excluded while
/// comments inside the statement are kept. The terminating `;` is not part
/// of [text]; see [terminatorOffset].
final class SqlStatement {
  /// Creates a statement. [tokens] must be the tokens of [text] (offsets
  /// relative to the whole script), including inner whitespace and comments.
  SqlStatement({
    required this.text,
    required this.start,
    required this.end,
    required List<SqlToken> tokens,
    this.terminatorOffset,
    this.copyDataStart,
    this.copyDataEnd,
  }) : tokens = List.unmodifiable(tokens);

  /// The statement source without the terminating semicolon.
  final String text;

  /// Offset of the statement's first character in the script.
  final int start;

  /// Offset just past the statement's last character (before any `;`).
  final int end;

  /// Tokens of [text], with offsets relative to the script.
  final List<SqlToken> tokens;

  /// Offset of the terminating `;`, or `null` for a final statement that
  /// has no semicolon.
  final int? terminatorOffset;

  /// For `COPY ... FROM STDIN`, the offset where the inline data block
  /// starts (the line after the statement), else `null`.
  final int? copyDataStart;

  /// For `COPY ... FROM STDIN`, the offset just past the data block (the
  /// start of the `\.` terminator line, or the end of the script when
  /// that line is missing), else `null`.
  final int? copyDataEnd;

  /// Whether this is `COPY ... FROM STDIN` with an inline data block.
  bool get isCopyFromStdin => copyDataStart != null;

  /// Returns a copy that records a COPY data block at `[start, end)`.
  SqlStatement withCopyData(int start, int end) => SqlStatement(
    text: text,
    start: this.start,
    end: this.end,
    tokens: tokens,
    terminatorOffset: terminatorOffset,
    copyDataStart: start,
    copyDataEnd: end,
  );

  /// Whether the statement ended with a semicolon.
  bool get hasTerminator => terminatorOffset != null;

  /// Offset just past the terminating `;`, or [end] when there is none.
  int get endIncludingTerminator {
    final terminator = terminatorOffset;
    return terminator == null ? end : terminator + 1;
  }

  /// Whether any token (string, quoted identifier, or comment) is missing
  /// its closing delimiter.
  bool get hasUnterminatedToken => tokens.any((t) => t.isUnterminated);

  /// Shows offsets only; the text can contain secrets.
  @override
  String toString() => 'SqlStatement($start..$end)';
}
