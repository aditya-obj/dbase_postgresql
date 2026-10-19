// File: sql_keywords_test.dart
// Purpose: Tests for the kwlist.h-generated keyword table, categories, and
// the highlight predicate.

import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

void main() {
  test('table matches kwlist.h (499 entries in four categories)', () {
    expect(sqlKeywordCategories, hasLength(499));
    final counts = <SqlKeywordCategory, int>{};
    for (final category in sqlKeywordCategories.values) {
      counts[category] = (counts[category] ?? 0) + 1;
    }
    expect(counts.keys.toSet(), SqlKeywordCategory.values.toSet());
  });

  test('categories of well-known keywords', () {
    expect(sqlKeywordCategory('select'), SqlKeywordCategory.reserved);
    expect(sqlKeywordCategory('WHERE'), SqlKeywordCategory.reserved);
    expect(sqlKeywordCategory('update'), SqlKeywordCategory.unreserved);
    expect(sqlKeywordCategory('atomic'), SqlKeywordCategory.unreserved);
    expect(sqlKeywordCategory('int'), SqlKeywordCategory.colName);
    expect(sqlKeywordCategory('join'), SqlKeywordCategory.typeFuncName);
    expect(sqlKeywordCategory('customer'), isNull);
  });

  test('highlight predicate is category based', () {
    expect(isHighlightKeyword('data'), isTrue);
    const strict = {
      SqlKeywordCategory.reserved,
      SqlKeywordCategory.typeFuncName,
    };
    expect(isHighlightKeyword('data', categories: strict), isFalse);
    expect(isHighlightKeyword('Select', categories: strict), isTrue);
    expect(isHighlightKeyword('customer'), isFalse);
  });

  test('the table is unmodifiable', () {
    expect(
      () => sqlKeywordCategories['x'] = SqlKeywordCategory.reserved,
      throwsUnsupportedError,
    );
  });
}
