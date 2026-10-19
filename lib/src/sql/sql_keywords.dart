// File: sql_keywords.dart
// Purpose: Keyword lookup by PostgreSQL grammar category and a
// category-based "highlight as keyword" predicate.

import 'package:dabase_postgresql/src/sql/sql_keyword_table.dart';

/// PostgreSQL's keyword categories, as in `kwlist.h` and appendix C of the
/// PostgreSQL manual.
enum SqlKeywordCategory {
  /// Usable as any kind of name (e.g. `update`, `data`, `name`).
  unreserved,

  /// Usable as a column or table name but not as a function or type name
  /// (e.g. `int`, `coalesce`, `values`).
  colName,

  /// Usable as a function or type name but not as a column name
  /// (e.g. `left`, `join`, `ilike`).
  typeFuncName,

  /// Fully reserved; must be double-quoted to be used as a name
  /// (e.g. `select`, `where`, `table`).
  reserved,
}

final Map<String, SqlKeywordCategory> _categoryByWord = {
  for (final (text, category) in [
    (unreservedKeywords, SqlKeywordCategory.unreserved),
    (colNameKeywords, SqlKeywordCategory.colName),
    (typeFuncNameKeywords, SqlKeywordCategory.typeFuncName),
    (reservedKeywords, SqlKeywordCategory.reserved),
  ])
    for (final word in text.split(' ')) word: category,
};

/// Every keyword PostgreSQL knows (lower case), with its category.
/// Generated from PostgreSQL's `kwlist.h`; unmodifiable.
final Map<String, SqlKeywordCategory> sqlKeywordCategories = Map.unmodifiable(
  _categoryByWord,
);

/// Returns the category of [word] (matched case-insensitively), or `null`
/// when it is not a PostgreSQL keyword.
SqlKeywordCategory? sqlKeywordCategory(String word) =>
    _categoryByWord[word.toLowerCase()];

/// Categories highlighted by default: all of them, since statement words
/// such as `UPDATE` and `BEGIN` are unreserved.
const Set<SqlKeywordCategory> defaultHighlightCategories = {
  SqlKeywordCategory.unreserved,
  SqlKeywordCategory.colName,
  SqlKeywordCategory.typeFuncName,
  SqlKeywordCategory.reserved,
};

/// Whether an editor should style [word] as a keyword.
///
/// Pass a narrower [categories] set (for example only
/// [SqlKeywordCategory.reserved] and [SqlKeywordCategory.typeFuncName]) to
/// avoid highlighting ordinary column names such as `name` or `data`, which
/// are unreserved keywords.
bool isHighlightKeyword(
  String word, {
  Set<SqlKeywordCategory> categories = defaultHighlightCategories,
}) {
  final category = sqlKeywordCategory(word);
  return category != null && categories.contains(category);
}
