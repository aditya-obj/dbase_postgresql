// File: sql_statement_splitter.dart
// Purpose: Splits a SQL script into statements the way psql does and finds
// the statement under an editor cursor.
//
// Statement-boundary rules ported from src/fe_utils/psqlscan.l -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/sql/sql_lexer.dart';
import 'package:dabase_postgresql/src/sql/sql_statement.dart';
import 'package:dabase_postgresql/src/sql/sql_token.dart';

/// Number of leading words psql remembers per statement (`init_idents`).
const _initialWordLimit = 8;

const _trackedInitialWords = {
  'create', 'function', 'procedure', 'or', 'replace', // CREATE routine
  'copy', 'from', 'stdin', 'stdout', // COPY ... FROM STDIN
};

/// Splits SQL scripts into [SqlStatement]s, following psql.
///
/// A `;` ends a statement only when both of psql's counters are zero:
/// * the parenthesis depth (only `(` and `)` count, as in psql), and
/// * the BEGIN depth, tracked only inside `CREATE [OR REPLACE]
///   FUNCTION|PROCEDURE`: `BEGIN` adds one, `CASE` adds one when already
///   inside a BEGIN, `END` subtracts one. This keeps SQL-standard bodies
///   (`BEGIN ATOMIC ... END`, PostgreSQL 14+) whole.
///
/// Semicolons inside strings, dollar quotes, comments, and quoted
/// identifiers never split. Statements made only of whitespace and
/// comments are skipped. After `COPY ... FROM STDIN;` the following lines,
/// up to a line containing only `\.`, are a data block (see
/// [SqlStatement.copyDataStart]) and are not lexed as SQL.
///
/// An unbalanced `(` keeps the rest of the script in one statement, as in
/// psql; the analyzer reports it as unparseable. psql backslash
/// meta-commands and `:var` interpolation are not recognised.
final class SqlStatementSplitter {
  /// Creates a splitter that tokenizes with [lexer].
  const SqlStatementSplitter({this.lexer = const SqlLexer()});

  /// Lexer used to tokenize scripts.
  final SqlLexer lexer;

  /// Splits [script] into statements, in source order.
  List<SqlStatement> split(String script) {
    final statements = <SqlStatement>[];
    final current = <SqlToken>[];
    final initialWords = <String>[];
    var parenDepth = 0;
    var beginDepth = 0;
    var position = 0;

    restart:
    while (position < script.length) {
      for (final token in lexer.scan(script, start: position)) {
        position = token.end;
        if (token.isPunctuationOf(';') && parenDepth == 0 && beginDepth == 0) {
          final isCopyIn = _isCopyFromStdin(initialWords);
          final statement = _build(script, current, token);
          current.clear();
          initialWords.clear();
          if (statement == null) continue;
          if (!isCopyIn) {
            statements.add(statement);
            continue;
          }
          final data = _copyDataBounds(script, token.end);
          statements.add(statement.withCopyData(data.start, data.end));
          position = data.resume;
          continue restart;
        }
        current.add(token);
        if (token.isPunctuationOf('(')) {
          parenDepth++;
        } else if (token.isPunctuationOf(')')) {
          if (parenDepth > 0) parenDepth--;
        } else if (token.isWord && parenDepth == 0) {
          beginDepth = _trackWord(token, initialWords, beginDepth);
        }
      }
      break;
    }
    final last = _build(script, current, null);
    if (last != null) statements.add(last);
    return statements;
  }

  /// Returns the statement an editor should run for a cursor at
  /// [cursorOffset] (a UTF-16 offset, `0 <= cursorOffset <= script.length`).
  ///
  /// Rules, in order:
  /// 1. A cursor within a statement, from its first character up to and
  ///    including just after its `;`, selects that statement.
  /// 2. Between statements, a cursor on the same line as the end of the
  ///    previous statement selects the previous statement.
  /// 3. Otherwise the next statement is selected, or the last statement
  ///    when the cursor is after the end of the script.
  ///
  /// Returns `null` only when the script has no statements. Throws a
  /// [RangeError] when [cursorOffset] is out of range.
  SqlStatement? statementAtOffset(String script, int cursorOffset) {
    RangeError.checkValueInInterval(
      cursorOffset,
      0,
      script.length,
      'cursorOffset',
    );
    SqlStatement? previous;
    for (final statement in split(script)) {
      if (cursorOffset < statement.start) {
        if (previous == null) return statement;
        final gapStart = previous.endIncludingTerminator;
        final gap = script.substring(gapStart, cursorOffset);
        return gap.contains('\n') ? statement : previous;
      }
      if (cursorOffset <= statement.endIncludingTerminator) return statement;
      previous = statement;
    }
    return previous;
  }

  /// psqlscan_track_identifier: records leading words and returns the new
  /// BEGIN depth.
  static int _trackWord(SqlToken token, List<String> words, int beginDepth) {
    final word = token.text.toLowerCase();
    if (words.length < _initialWordLimit) {
      words.add(_trackedInitialWords.contains(word) ? word : '');
    }
    if (!_isCreateRoutine(words)) return beginDepth;
    return switch (word) {
      'begin' => beginDepth + 1,
      'case' when beginDepth >= 1 => beginDepth + 1,
      'end' when beginDepth > 0 => beginDepth - 1,
      _ => beginDepth,
    };
  }

  /// psqlscan_is_create_routine: CREATE [OR REPLACE] FUNCTION|PROCEDURE.
  static bool _isCreateRoutine(List<String> w) {
    String at(int i) => i < w.length ? w[i] : '';
    bool isRoutine(String word) => word == 'function' || word == 'procedure';
    return at(0) == 'create' &&
        (isRoutine(at(1)) ||
            (at(1) == 'or' && at(2) == 'replace' && isRoutine(at(3))));
  }

  /// psqlscan_is_copy_from_stdin: COPY, up to six words, FROM, STDIN. Like
  /// psql (and the server grammar), STDOUT is accepted in place of STDIN.
  static bool _isCopyFromStdin(List<String> w) {
    if (w.isEmpty || w[0] != 'copy') return false;
    for (var i = 1; i < _initialWordLimit - 1; i++) {
      if (i >= w.length) return false;
      if (w[i] != 'from') continue;
      return i + 1 < w.length && (w[i + 1] == 'stdin' || w[i + 1] == 'stdout');
    }
    return false;
  }

  /// Finds the COPY data block after the `;` at [afterSemicolon]: it starts
  /// on the next line and ends before the line holding only `\.`.
  static ({int start, int end, int resume}) _copyDataBounds(
    String script,
    int afterSemicolon,
  ) {
    final newline = script.indexOf('\n', afterSemicolon);
    if (newline < 0) {
      return (start: script.length, end: script.length, resume: script.length);
    }
    final start = newline + 1;
    var lineStart = start;
    while (lineStart < script.length) {
      var lineEnd = script.indexOf('\n', lineStart);
      final hasNewline = lineEnd >= 0;
      if (!hasNewline) lineEnd = script.length;
      var line = script.substring(lineStart, lineEnd);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line == r'\.') {
        final resume = hasNewline ? lineEnd + 1 : lineEnd;
        return (start: start, end: lineStart, resume: resume);
      }
      lineStart = lineEnd + 1;
    }
    return (start: start, end: script.length, resume: script.length);
  }

  static SqlStatement? _build(
    String script,
    List<SqlToken> tokens,
    SqlToken? terminator,
  ) {
    final first = tokens.indexWhere((t) => !t.isTrivia);
    if (first < 0) return null;
    final last = tokens.lastIndexWhere((t) => !t.isTrivia);
    final start = tokens[first].start;
    final end = tokens[last].end;
    return SqlStatement(
      text: script.substring(start, end),
      start: start,
      end: end,
      tokens: tokens.sublist(first, last + 1),
      terminatorOffset: terminator?.start,
    );
  }
}
