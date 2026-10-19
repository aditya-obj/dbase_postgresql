// File: psql_input.dart
// Purpose: psql's line-by-line input handling: SQL accumulates in a query
// buffer until a top-level `;`, and a backslash outside quotes and
// comments starts a meta-command anywhere on a line (`select 1 \g`).
//
// Behaviour of src/bin/psql/mainloop.c with src/fe_utils/psqlscan.l -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/psql/meta_command.dart';
import 'package:dabase_postgresql/src/sql/sql_lexer.dart';
import 'package:dabase_postgresql/src/sql/sql_statement_splitter.dart';
import 'package:dabase_postgresql/src/sql/sql_token.dart';

/// What a line of input asks for, in order.
sealed class PsqlInputItem {
  const PsqlInputItem();
}

/// A query to send: ended by `;`, or by `\g` / `\gx`.
final class PsqlQueryItem extends PsqlInputItem {
  /// Creates the item.
  const PsqlQueryItem(this.sql, {this.expanded = false});

  /// The SQL, as typed (one statement, or the buffer `\g` sent).
  final String sql;

  /// `\gx`: print this result expanded.
  final bool expanded;
}

/// A backslash command to run. `\g`, `\gx`, `\r` and `\p` are handled
/// by the scanner and arrive as [PsqlQueryItem] or [PsqlTextItem].
final class PsqlMetaItem extends PsqlInputItem {
  /// Creates the item.
  const PsqlMetaItem(this.command);

  /// The parsed command.
  final MetaCommand command;
}

/// Text to print (from `\p`, `\r`, or a scanner error).
final class PsqlTextItem extends PsqlInputItem {
  /// Creates the item.
  const PsqlTextItem(this.text, {this.isError = false});

  /// The text, without a trailing newline.
  final String text;

  /// An error: the rest of the line was discarded.
  final bool isError;
}

/// The continuation state psql shows in its prompt (`%R`).
enum PsqlPromptState {
  /// Nothing buffered: `=`.
  ready,

  /// A statement continues: `-`.
  continuation,

  /// Inside a `'…'` string: `'`.
  singleQuote,

  /// Inside a `"…"` identifier: `"`.
  doubleQuote,

  /// Inside a dollar-quoted string: `$`.
  dollarQuote,

  /// Inside a `/* … */` comment: `*`.
  comment,

  /// Inside parentheses: `(`.
  parenthesis,
}

/// Feeds input lines like psql's main loop and keeps the query buffer.
final class PsqlInputScanner {
  /// Creates an empty scanner.
  PsqlInputScanner();

  static const _lexer = SqlLexer();
  static const _splitter = SqlStatementSplitter();

  String _buffer = '';
  String _previous = '';

  /// SQL typed so far that has not been sent.
  String get buffer => _buffer;

  /// The last query sent (what `\g` re-sends when the buffer is empty).
  String get previous => _previous;

  /// Whether nothing is buffered.
  bool get isEmpty => _buffer.trim().isEmpty;

  /// Clears the buffer (`\r`).
  void reset() => _buffer = '';

  /// Processes one line (without its newline). Statements completed by
  /// `;` come out as [PsqlQueryItem]s, backslash commands as
  /// [PsqlMetaItem]s, in the order they appear. A line that fails to
  /// parse yields a [PsqlTextItem] error and the rest of it is dropped,
  /// as psql does.
  List<PsqlInputItem> feedLine(String line) {
    final items = <PsqlInputItem>[];
    var pending = _buffer.isEmpty ? '' : '$_buffer\n';
    var rest = line;
    for (;;) {
      final combined = '$pending$rest';
      final backslash = _firstMetaBackslash(combined, pending.length);
      if (backslash == null) {
        pending = _emitComplete(combined, items);
        break;
      }
      pending = _emitComplete(combined.substring(0, backslash), items);
      final MetaCommand command;
      try {
        command = parseMetaCommand(combined, backslash);
      } on MetaCommandFormatException catch (e) {
        items.add(PsqlTextItem(e.message, isError: true));
        break;
      }
      rest = combined.substring(command.end);
      pending = _handle(command, pending, items);
    }
    // A line that added nothing to the buffer doesn't add its newline
    // either (psql's buffer after `select 1` and `\p` is `select 1`).
    if (_buffer.isNotEmpty && pending == '$_buffer\n') pending = _buffer;
    _buffer = pending.trim().isEmpty ? '' : pending;
    return items;
  }

  /// Runs the commands that work on the buffer; returns the new buffer.
  String _handle(
    MetaCommand command,
    String pending,
    List<PsqlInputItem> items,
  ) {
    switch (command.name) {
      case 'g' || 'gx':
        if (command.args.isNotEmpty) {
          items.add(
            PsqlTextItem(
              '\\${command.name}: sending output to a file or command, '
              r'or \g options, are not supported',
              isError: true,
            ),
          );
          return pending;
        }
        final sql = pending.trim().isEmpty ? _previous : pending.trim();
        if (sql.isNotEmpty) {
          _previous = sql;
          items.add(PsqlQueryItem(sql, expanded: command.name == 'gx'));
        }
        return '';
      case 'r' || 'reset':
        items.add(const PsqlTextItem('Query buffer reset (cleared).'));
        return '';
      case 'p' || 'print':
        final text = pending.trim().isNotEmpty
            ? pending.trimRight()
            : _previous;
        items.add(PsqlTextItem(text.isEmpty ? 'Query buffer is empty.' : text));
        return pending;
      default:
        items.add(PsqlMetaItem(command));
        return pending;
    }
  }

  /// Splits [text]; queues each `;`-terminated statement and returns the
  /// unfinished rest.
  String _emitComplete(String text, List<PsqlInputItem> items) {
    if (text.trim().isEmpty) return text;
    final statements = _splitter.split(text);
    var restStart = 0;
    for (final statement in statements) {
      if (!statement.hasTerminator) break;
      final sql = text.substring(
        statement.start,
        statement.endIncludingTerminator,
      );
      _previous = sql;
      items.add(PsqlQueryItem(sql));
      restStart = statement.endIncludingTerminator;
    }
    if (restStart == 0) return text;
    final rest = text.substring(restStart);
    return rest.trim().isEmpty ? '' : rest.trimLeft();
  }

  /// Offset of the first `\` at or after [from] that is outside strings,
  /// quoted identifiers and comments, or `null`.
  static int? _firstMetaBackslash(String text, int from) {
    for (final token in _lexer.scan(text)) {
      if (token.end <= from) continue;
      if (token.kind == SqlTokenKind.unknown && token.text.startsWith(r'\')) {
        return token.start;
      }
    }
    return null;
  }

  /// psql's `%R` for the current buffer.
  PsqlPromptState get promptState {
    if (isEmpty) return PsqlPromptState.ready;
    var depth = 0;
    SqlToken? last;
    for (final token in _lexer.scan(_buffer)) {
      last = token;
      if (token.isPunctuationOf('(')) depth++;
      if (token.isPunctuationOf(')') && depth > 0) depth--;
    }
    if (last != null && last.isUnterminated) {
      return switch (last.kind) {
        SqlTokenKind.quotedIdentifier => PsqlPromptState.doubleQuote,
        SqlTokenKind.dollarString => PsqlPromptState.dollarQuote,
        SqlTokenKind.blockComment => PsqlPromptState.comment,
        _ => PsqlPromptState.singleQuote,
      };
    }
    return depth > 0
        ? PsqlPromptState.parenthesis
        : PsqlPromptState.continuation;
  }
}
