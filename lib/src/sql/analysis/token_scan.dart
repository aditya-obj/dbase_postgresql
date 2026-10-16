// File: token_scan.dart
// Purpose: Index-based view over a statement's significant tokens with
// helpers for words, punctuation, and paren depth (internal).

import 'package:dbase_postgresql/src/sql/sql_token.dart';

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

  /// A sub-scan of tokens `[from, to)`.
  TokenScan slice(int from, [int? to]) => TokenScan._(tokens.sublist(from, to));

  bool _opens(int i) => isPunctuation(i, '(') || isPunctuation(i, '[');

  bool _closes(int i) => isPunctuation(i, ')') || isPunctuation(i, ']');
}
