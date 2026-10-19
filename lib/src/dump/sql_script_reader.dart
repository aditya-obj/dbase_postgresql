// File: sql_script_reader.dart
// Purpose: Reads a plain-SQL dump (ours or pg_dump's plain format) as a
// stream, the way `psql -f` would: complete statements, the data lines of
// each `COPY ... FROM stdin;` up to `\.`, and backslash meta-commands at
// the start of a statement. Memory stays bounded by the largest single
// statement; COPY data is passed on in chunks of whole lines.
// Notes: Statement boundaries come from SqlStatementSplitter (psqlscan.l
// rules); a buffered statement is re-split only when a line ends with `;`.
// pg_dump's TOC comments (`-- Name: t; Type: TABLE; Schema: s`) are
// remembered so a restore can say which object it is on.

import 'dart:async';

import 'package:dabase_postgresql/src/sql/sql_lexer.dart';
import 'package:dabase_postgresql/src/sql/sql_statement_splitter.dart';
import 'package:dabase_postgresql/src/sql/sql_token.dart';

/// The last pg_dump TOC comment seen before an item.
final class ScriptTocEntry {
  /// Creates a TOC entry.
  const ScriptTocEntry({required this.name, required this.type, this.schema});

  /// Object name.
  final String name;

  /// pg_dump's TOC type (`TABLE`, `TABLE DATA`, ...).
  final String type;

  /// Schema, or `null` for `-`.
  final String? schema;

  @override
  String toString() => schema == null ? '$type $name' : '$type $schema.$name';
}

/// One thing a restore must do, in file order.
sealed class ScriptItem {
  const ScriptItem({required this.line, this.toc});

  /// 1-based line the item starts on.
  final int line;

  /// The TOC comment it follows, if any.
  final ScriptTocEntry? toc;
}

/// One SQL statement (without its `;`).
final class ScriptStatement extends ScriptItem {
  /// Creates a statement item.
  const ScriptStatement(this.sql, {required super.line, super.toc});

  /// The statement text.
  final String sql;
}

/// `COPY ... FROM stdin` (without its `;`); its data follows as
/// [ScriptCopyData] items and a [ScriptCopyEnd].
final class ScriptCopyStart extends ScriptItem {
  /// Creates a COPY start item.
  const ScriptCopyStart(this.sql, {required super.line, super.toc});

  /// The COPY statement.
  final String sql;

  /// Whether the data can be sent in several COPY statements, cut at any
  /// line: text format (no CSV, where a quoted value may span lines, and
  /// no binary).
  bool get canSplit {
    final words = const SqlLexer()
        .scan(sql)
        .where(
          (t) =>
              t.kind == SqlTokenKind.keyword ||
              t.kind == SqlTokenKind.identifier,
        )
        .map((t) => t.text.toLowerCase());
    return !words.any((w) => w == 'csv' || w == 'binary');
  }
}

/// Whole data lines of the current COPY, each ending with `\n`.
final class ScriptCopyData extends ScriptItem {
  /// Creates a data chunk.
  const ScriptCopyData(this.text, {required this.lines, required super.line});

  /// The lines.
  final String text;

  /// How many lines [text] holds.
  final int lines;
}

/// The end of a COPY's data. [terminated] is `false` when the file ended
/// before the `\.` line.
final class ScriptCopyEnd extends ScriptItem {
  /// Creates a COPY end item.
  const ScriptCopyEnd({required super.line, this.terminated = true});

  /// The `\.` line was there.
  final bool terminated;
}

/// A psql backslash command at the start of a statement, such as
/// `\connect db` or pg_dump's `\restrict key`.
final class ScriptMetaCommand extends ScriptItem {
  /// Creates a meta-command item.
  const ScriptMetaCommand(this.command, this.arguments, {required super.line});

  /// The command without its backslash, e.g. `connect`.
  final String command;

  /// The rest of the line.
  final String arguments;

  /// pg_dump 17.6+ / 16.10+ brackets its output with `\restrict` and
  /// `\unrestrict`; a restore can skip them safely.
  bool get isIgnorable => command == 'restrict' || command == 'unrestrict';
}

/// Splits a stream of script text (any chunking) into [ScriptItem]s.
final class SqlScriptReader extends StreamTransformerBase<String, ScriptItem> {
  /// Creates a reader. COPY data is passed on in chunks of about
  /// [copyChunkChars] characters.
  const SqlScriptReader({this.copyChunkChars = 256 * 1024});

  /// Target size of a [ScriptCopyData] chunk.
  final int copyChunkChars;

  @override
  Stream<ScriptItem> bind(Stream<String> stream) async* {
    final state = _ReaderState(copyChunkChars);
    final partial = StringBuffer();
    await for (final chunk in stream) {
      var start = 0;
      while (true) {
        final newline = chunk.indexOf('\n', start);
        if (newline < 0) {
          partial.write(chunk.substring(start));
          break;
        }
        partial.write(chunk.substring(start, newline));
        final line = partial.toString();
        partial.clear();
        start = newline + 1;
        yield* Stream.fromIterable(state.line(line));
      }
    }
    if (partial.isNotEmpty) {
      yield* Stream.fromIterable(state.line(partial.toString()));
    }
    yield* Stream.fromIterable(state.finish());
  }
}

final _tocLine = RegExp(
  r'^-- (?:Data for )?Name: (.*); Type: (.*); Schema: ([^;]*)(?:; Owner: .*)?$',
);

final class _ReaderState {
  _ReaderState(this.copyChunkChars);

  final int copyChunkChars;
  static const _splitter = SqlStatementSplitter();

  var _lineNumber = 0;

  /// The statement being collected and the line it started on.
  final _pending = StringBuffer();
  var _pendingStart = 0;
  var _pendingHasText = false;

  ScriptTocEntry? _toc;

  /// In a COPY's data, with lines collected so far.
  var _inCopy = false;
  final _copy = StringBuffer();
  var _copyLines = 0;
  var _copyStart = 0;

  List<ScriptItem> line(String raw) {
    _lineNumber++;
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (_inCopy) return _copyLine(line);
    final trimmed = line.trimLeft();
    if (!_pendingHasText) {
      final toc = _tocLine.firstMatch(line);
      if (toc != null) {
        final schema = toc.group(3)!;
        _toc = ScriptTocEntry(
          name: toc.group(1)!,
          type: toc.group(2)!,
          schema: schema == '-' ? null : schema,
        );
      }
      // Blank and comment lines between statements are not kept.
      if (trimmed.isEmpty || trimmed.startsWith('--')) return const [];
    }
    if (_pendingIsBlank) {
      if (trimmed.startsWith(r'\')) {
        _resetPending();
        final body = trimmed.substring(1);
        final space = body.indexOf(RegExp(r'\s'));
        return [
          ScriptMetaCommand(
            space < 0 ? body : body.substring(0, space),
            space < 0 ? '' : body.substring(space).trim(),
            line: _lineNumber,
          ),
        ];
      }
    }
    if (!_pendingHasText) _pendingStart = _lineNumber;
    _pendingHasText = true;
    _pending
      ..write(line)
      ..write('\n');
    if (!line.trimRight().endsWith(';')) return const [];
    return _flush(atEnd: false);
  }

  /// Nothing but whitespace and comments collected so far.
  bool get _pendingIsBlank {
    if (!_pendingHasText) return true;
    return const SqlLexer().scan(_pending.toString()).every((t) => t.isTrivia);
  }

  void _resetPending() {
    _pending.clear();
    _pendingHasText = false;
  }

  List<ScriptItem> _flush({required bool atEnd}) {
    final text = _pending.toString();
    final statements = _splitter.split(text);
    final out = <ScriptItem>[];
    var consumed = 0;
    for (final s in statements) {
      if (!s.hasTerminator && !atEnd) break;
      final line =
          _pendingStart + '\n'.allMatches(text.substring(0, s.start)).length;
      final sql = s.text;
      consumed = s.hasTerminator ? s.endIncludingTerminator : text.length;
      if (s.isCopyFromStdin) {
        out.add(ScriptCopyStart(sql, line: line, toc: _toc));
        _inCopy = true;
        _copyStart = _lineNumber + 1;
        // Whatever followed the `;` on that line is ignored, as psql
        // starts the data on the next line.
        consumed = text.length;
        break;
      }
      out.add(ScriptStatement(sql, line: line, toc: _toc));
    }
    final rest = text.substring(consumed);
    _resetPending();
    if (rest.trim().isNotEmpty && !_inCopy) {
      _pendingStart =
          _pendingStart + '\n'.allMatches(text.substring(0, consumed)).length;
      _pendingHasText = true;
      _pending.write(rest);
    }
    return out;
  }

  List<ScriptItem> _copyLine(String line) {
    if (line == r'\.') {
      final out = [..._takeCopy(), ScriptCopyEnd(line: _lineNumber)];
      _inCopy = false;
      return out;
    }
    _copy
      ..write(line)
      ..write('\n');
    _copyLines++;
    return _copy.length >= copyChunkChars ? _takeCopy() : const [];
  }

  List<ScriptItem> _takeCopy() {
    if (_copyLines == 0) return const [];
    final item = ScriptCopyData(
      _copy.toString(),
      lines: _copyLines,
      line: _copyStart,
    );
    _copyStart += _copyLines;
    _copy.clear();
    _copyLines = 0;
    return [item];
  }

  List<ScriptItem> finish() {
    if (_inCopy) {
      final out = [
        ..._takeCopy(),
        ScriptCopyEnd(line: _lineNumber, terminated: false),
      ];
      _inCopy = false;
      return out;
    }
    if (_pendingIsBlank) return const [];
    return _flush(atEnd: true);
  }
}
