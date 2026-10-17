// File: token_scan.dart
// Purpose: Index-based view over a statement's significant tokens with
// helpers for words, punctuation, and paren depth (internal).

import 'package:dbase_postgresql/src/sql/sql_token.dart';

const _falseValues = {'false', 'off', '0', 'no'};

/// The non-trivia tokens of a statement with lookup helpers. Out-of-range
/// indexes are safe and simply do not match.
final class TokenScan {
  /// Keeps the significant (non-whitespace, non-comment) [tokens].
  TokenScan(Iterable<SqlToken> tokens)
    : tokens = [
        for (final token in tokens)
          if (!token.isTrivia) token,
      ];

  TokenScan._(this.tokens);

  /// Significant tokens in source order.
  final List<SqlToken> tokens;

  /// Number of significant tokens.
  int get length => tokens.length;

  /// Whether there are no significant tokens.
  bool get isEmpty => tokens.isEmpty;

  /// The lower-cased unquoted word at [index], or `null`.
  String? word(int index) =>
      index >= 0 && index < length && tokens[index].isWord
      ? tokens[index].text.toLowerCase()
      : null;

  /// Whether the token at [index] is the unquoted word [lowerCaseWord].
  bool isWord(int index, String lowerCaseWord) =>
      index >= 0 && index < length && tokens[index].isWordOf(lowerCaseWord);

  /// Whether the token at [index] is the punctuation [symbol].
  bool isPunctuation(int index, String symbol) =>
      index >= 0 && index < length && tokens[index].isPunctuationOf(symbol);

  /// Source offset of the token at [index], clamped to the scan's range.
  int offsetAt(int index) {
    if (tokens.isEmpty) return 0;
    if (index >= length) return tokens.last.end;
    return tokens[index < 0 ? 0 : index].start;
  }

  /// Index of the `)` or `]` matching the opener at [openIndex], or -1.
  int matchingClose(int openIndex) {
    var depth = 0;
    for (var i = openIndex; i < length; i++) {
      if (_opens(i)) depth++;
      if (_closes(i)) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// Whether every `(`/`[` has a matching `)`/`]` and none closes early.
  bool get isBalanced {
    var depth = 0;
    for (var i = 0; i < length; i++) {
      if (_opens(i)) depth++;
      if (_closes(i) && --depth < 0) return false;
    }
    return depth == 0;
  }

  /// Indexes from [from] onward that are not inside parentheses or
  /// brackets opened at or after [from]. Closers without a matching opener
  /// are tolerated (depth never goes below zero).
  Iterable<int> topLevelIndexes({int from = 0}) sync* {
    var depth = 0;
    for (var i = from; i < length; i++) {
      if (_closes(i)) {
        if (depth > 0) depth--;
        continue;
      }
      if (depth == 0) yield i;
      if (_opens(i)) depth++;
    }
  }

  /// Whether any top-level token from [from] is one of [words].
  bool hasTopLevelWord(Set<String> words, {int from = 0}) =>
      topLevelIndexes(from: from).any((i) => words.contains(word(i)));

  /// Whether the token at [index] is the operator [symbol], e.g. `=`.
  bool isOperator(int index, String symbol) =>
      index >= 0 &&
      index < length &&
      tokens[index].kind == SqlTokenKind.operator &&
      tokens[index].text == symbol;

  /// Whether the token at [index] can be a name part: an unquoted word or
  /// a double-quoted identifier.
  bool isName(int index) =>
      index >= 0 &&
      index < length &&
      (tokens[index].isWord ||
          tokens[index].kind == SqlTokenKind.quotedIdentifier);

  /// Reads a possibly qualified name (`a`, `s."T"`, `db.s.t`) at [index].
  /// Returns the name in server form ([SqlToken.normalized] parts joined
  /// with `.`) and the index just past it, or `null` when [index] is not a
  /// name.
  ({String name, int next})? qualifiedName(int index) {
    if (!isName(index)) return null;
    final parts = [tokens[index].normalized];
    var i = index + 1;
    while (isPunctuation(i, '.') && isName(i + 1)) {
      parts.add(tokens[i + 1].normalized);
      i += 2;
    }
    return (name: parts.join('.'), next: i);
  }

  /// Reads a comma-separated list of names at [index], as in `TRUNCATE`,
  /// `LOCK` and `DROP`. Each item may have a leading `ONLY`, a trailing
  /// `*` and a trailing parenthesised argument list, all skipped. Stops at
  /// the first token that doesn't continue the list.
  ({List<String> names, int next}) nameList(int index) {
    final names = <String>[];
    var i = index;
    while (true) {
      if (isWord(i, 'only') && isName(i + 1)) i++;
      final item = qualifiedName(i);
      if (item == null) break;
      names.add(item.name);
      i = item.next;
      if (isOperator(i, '*')) i++;
      if (isPunctuation(i, '(')) {
        final close = matchingClose(i);
        if (close < 0) break;
        i = close + 1;
      }
      if (!isPunctuation(i, ',')) break;
      i++;
    }
    return (names: names, next: i);
  }

  /// Whether an option list like `(ANALYZE, BUFFERS true)` turns on any
  /// option in [names]. This scan must hold only the tokens between the
  /// parentheses. An option with a value other than `false`/`off`/`0`/`no`
  /// (quoted or not) counts as enabled (fail closed).
  bool optionListEnables(Set<String> names) {
    var enabled = false;
    var itemStart = 0;
    for (var i = 0; i <= length; i++) {
      if (i < length && !isPunctuation(i, ',')) continue;
      if (names.contains(word(itemStart))) {
        enabled =
            itemStart + 1 >= i ||
            !_falseValues.contains(literalValue(itemStart + 1));
      }
      itemStart = i + 1;
    }
    return enabled;
  }

  /// The lower-cased value of the token at [index]: the content of a plain
  /// `'...'` string (with `''` unescaped), otherwise the token text.
  String? literalValue(int index) {
    if (index < 0 || index >= length) return null;
    final token = tokens[index];
    final text = token.text.toLowerCase();
    if (token.kind == SqlTokenKind.string &&
        text.startsWith("'") &&
        text.length >= 2) {
      return text.substring(1, text.length - 1).replaceAll("''", "'");
    }
    return text;
  }

  /// A sub-scan of tokens `[from, to)`.
  TokenScan slice(int from, [int? to]) => TokenScan._(tokens.sublist(from, to));

  bool _opens(int i) => isPunctuation(i, '(') || isPunctuation(i, '[');

  bool _closes(int i) => isPunctuation(i, ')') || isPunctuation(i, ']');
}
