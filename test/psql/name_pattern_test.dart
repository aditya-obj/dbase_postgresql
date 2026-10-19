// File: name_pattern_test.dart
// Purpose: \d name patterns against psql's processSQLNamePattern. The
// expected clauses are what psql 17 printed with -E for the same
// patterns.

import 'package:dabase_postgresql/psql.dart';
import 'package:test/test.dart';

String _tableClause(String? pattern) => processNamePattern(
  pattern,
  haveWhere: true,
  schemaVar: 'n.nspname',
  nameVar: 'c.relname',
  visibilityRule: 'pg_catalog.pg_table_is_visible(c.oid)',
  currentDatabase: 'postgres',
).sql;

const _visible = '  AND pg_catalog.pg_table_is_visible(c.oid)\n';

String _name(String regex) =>
    '  AND c.relname OPERATOR(pg_catalog.~) $regex '
    'COLLATE pg_catalog.default\n';

String _schema(String regex) =>
    '  AND n.nspname OPERATOR(pg_catalog.~) $regex '
    'COLLATE pg_catalog.default\n';

void main() {
  group('matches psql -E output', () {
    final cases = <String, String>{
      'Foo*': "${_name(r"'^(foo.*)$'")}$_visible",
      '"Foo"*': "${_name(r"'^(Foo.*)$'")}$_visible",
      'public.t?st': "${_name(r"'^(t.st)$'")}${_schema(r"'^(public)$'")}",
      '*.users': _name(r"'^(users)$'"),
      '"my.schema".tbl':
          "${_name(r"'^(tbl)$'")}${_schema(r"E'^(my\\.schema)$'")}",
      r'a$b': "${_name(r"E'^(a\\$b)$'")}$_visible",
      '"a""b"': "${_name("'^(a\"b)\$'")}$_visible",
      'postgres.public.x': "${_name(r"'^(x)$'")}${_schema(r"'^(public)$'")}",
      'x|y': "${_name(r"'^(x|y)$'")}$_visible",
      'arr[]': "${_name(r"E'^(arr\\[])$'")}$_visible",
    };
    for (final MapEntry(key: pattern, value: expected) in cases.entries) {
      test(pattern, () => expect(_tableClause(pattern), expected));
    }
  });

  test('no pattern: only the visibility rule', () {
    expect(_tableClause(null), _visible);
    expect(
      processNamePattern(null, haveWhere: false, nameVar: 'x').addedClause,
      isFalse,
    );
  });

  test('* alone matches everything (no name condition)', () {
    expect(_tableClause('*'), _visible);
    expect(_tableClause('*.*'), isEmpty);
  });

  test('WHERE is used when the query has none yet', () {
    final clause = processNamePattern(
      'Al*',
      haveWhere: false,
      nameVar: 'r.rolname',
      maxParts: 1,
    );
    expect(
      clause.sql,
      r"WHERE r.rolname OPERATOR(pg_catalog.~) '^(al.*)$' "
      'COLLATE pg_catalog.default\n',
    );
    expect(clause.addedClause, isTrue);
  });

  test('the alternate name is matched too (types)', () {
    final clause = processNamePattern(
      'int4',
      haveWhere: true,
      schemaVar: 'n.nspname',
      nameVar: 't.typname',
      altNameVar: 'pg_catalog.format_type(t.oid, NULL)',
    );
    expect(
      clause.sql,
      startsWith(
        r"  AND (t.typname OPERATOR(pg_catalog.~) '^(int4)$' COLLATE "
        'pg_catalog.default\n        OR pg_catalog.format_type(t.oid, NULL) '
        r"OPERATOR(pg_catalog.~) '^(int4)$' COLLATE pg_catalog.default)"
        '\n',
      ),
    );
  });

  group('errors like psql', () {
    test('too many dots', () {
      expect(
        () => _tableClause('a.b.c.d'),
        throwsA(
          isA<NamePatternException>().having(
            (e) => e.message,
            'message',
            'improper qualified name (too many dotted names): a.b.c.d',
          ),
        ),
      );
      expect(
        () => processNamePattern(
          'a.b',
          haveWhere: false,
          nameVar: 'r.rolname',
          maxParts: 1,
        ),
        throwsA(isA<NamePatternException>()),
      );
    });

    test('another database', () {
      expect(
        () => _tableClause('otherdb.public.t'),
        throwsA(
          isA<NamePatternException>().having(
            (e) => e.message,
            'message',
            'cross-database references are not implemented: '
                'otherdb.public.t',
          ),
        ),
      );
    });
  });

  group('patternToRegex', () {
    test('wildcards, case and quoting', () {
      expect(patternToRegex('Ab*c?').name, r'^(ab.*c.)$');
      expect(patternToRegex('"Ab*c?"').name, r'^(Ab\*c\?)$');
      expect(patternToRegex('a.b').name, r'^(a.b)$');
      expect(patternToRegex('a.b').dotCount, 1);
    });

    test('splits schema and database parts', () {
      final regex = patternToRegex('"Db".s.t', maxParts: 3);
      expect(regex.name, r'^(t)$');
      expect(regex.schema, r'^(s)$');
      expect(regex.database, 'Db');
    });

    test('forceEscape quotes regex characters', () {
      expect(patternToRegex('a+b', forceEscape: true).name, r'^(a\+b)$');
    });
  });

  test('sqlStringLiteral uses E strings for backslashes', () {
    expect(sqlStringLiteral("it's"), "'it''s'");
    expect(sqlStringLiteral(r'a\b'), r"E'a\\b'");
  });
}
