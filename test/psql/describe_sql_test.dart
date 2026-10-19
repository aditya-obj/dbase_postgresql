// File: describe_sql_test.dart
// Purpose: The describe queries the library builds: byte-for-byte the
// SQL psql 17 sends for the same commands (fixtures in test/psql/psql_e,
// captured with psql -E against PostgreSQL 18), and the version gates for
// PostgreSQL 13–18.

import 'dart:io';

import 'package:dabase_postgresql/psql.dart';
import 'package:test/test.dart';

const _v18 = ListContext(version: 180006, currentDatabase: 'postgres');

String _list(String letters, String? pattern, ListContext context) =>
    listTablesSql(
      context,
      RelationKinds.parse(letters),
      pattern,
      verbose: letters.contains('+'),
      showSystem: letters.contains('S'),
    );

final Map<String, String Function()> _builders = {
  r'\dt': () => _list('t', null, _v18),
  r'\dt+': () => _list('t+', null, _v18),
  r'\di': () => _list('i', null, _v18),
  r'\dv': () => _list('v', null, _v18),
  r'\dm': () => _list('m', null, _v18),
  r'\ds': () => _list('s', null, _v18),
  r'\dE': () => _list('E', null, _v18),
  r'\d': () => _list('', null, _v18),
  r'\dtS': () => _list('tS', null, _v18),
  r'\dn': () => listSchemasSql(_v18, null, verbose: false, showSystem: false),
  r'\dn+': () => listSchemasSql(_v18, null, verbose: true, showSystem: false),
  r'\df': () => listFunctionsSql(
    _v18,
    '',
    null,
    const [],
    verbose: false,
    showSystem: false,
  ),
  r'\dfa': () => listFunctionsSql(
    _v18,
    'a',
    null,
    const [],
    verbose: false,
    showSystem: false,
  ),
  r'\dfn': () => listFunctionsSql(
    _v18,
    'n',
    null,
    const [],
    verbose: false,
    showSystem: false,
  ),
  r'\dT': () => listTypesSql(_v18, null, verbose: false, showSystem: false),
  r'\dT+': () => listTypesSql(_v18, null, verbose: true, showSystem: false),
  r'\dD': () => listDomainsSql(_v18, null, verbose: false, showSystem: false),
  r'\dD+': () => listDomainsSql(_v18, null, verbose: true, showSystem: false),
  r'\dp': () => permissionsSql(_v18, null, showSystem: false),
  r'\l': () => listDatabasesSql(_v18, null, verbose: false),
  r'\l+': () => listDatabasesSql(_v18, null, verbose: true),
  r'\du': () => listRolesSql(_v18, null, verbose: false, showSystem: false),
  r'\du+': () => listRolesSql(_v18, null, verbose: true, showSystem: false),
  r'\df foo int4 -': () => listFunctionsSql(
    _v18,
    '',
    'foo',
    const ['int4', '-'],
    verbose: false,
    showSystem: false,
  ),
  r'\dt public.t?st': () => _list('t', 'public.t?st', _v18),
  r'\dT int[]': () =>
      listTypesSql(_v18, 'int[]', verbose: false, showSystem: false),
};

void main() {
  group('same SQL as psql -E', () {
    final index = File('test/psql/psql_e/index.tsv').readAsLinesSync();
    for (final line in index.where((l) => l.trim().isNotEmpty)) {
      final [number, command] = line.split('\t');
      test(command, () {
        final expected = File('test/psql/psql_e/$number.sql')
            .readAsStringSync();
        expect(_builders[command]!(), expected.trimRight());
      });
    }

    test('every fixture has a builder', () {
      expect(index.where((l) => l.trim().isNotEmpty).length, _builders.length);
    });
  });

  group('version gates', () {
    ListContext v(int version) => ListContext(version: version);

    test(r'\l: locale columns by version', () {
      final v13 = listDatabasesSql(v(130000), null, verbose: false);
      expect(v13, contains("'libc' AS \"Locale Provider\""));
      expect(v13, contains('NULL as "Locale"'));
      expect(v13, contains('NULL as "ICU Rules"'));
      final v15 = listDatabasesSql(v(150004), null, verbose: false);
      expect(v15, contains('d.datlocprovider'));
      expect(v15, contains('d.daticulocale as "Locale"'));
      expect(v15, contains('NULL as "ICU Rules"'));
      final v16 = listDatabasesSql(v(160000), null, verbose: false);
      expect(v16, contains('d.daticurules as "ICU Rules"'));
      final v17 = listDatabasesSql(v(170002), null, verbose: false);
      expect(v17, contains('d.datlocale as "Locale"'));
    });

    test(r'\dx includes the psql 18 Default version column', () {
      expect(
        listExtensionsSql(v(130000), null),
        contains('ae.default_version AS "Default version"'),
      );
    });

    test(r'\d name: relation lookup qualifies and checks visibility', () {
      final context = DescribeContext(
        version: 170000,
        query: (_) async => throw StateError('unused'),
        currentDatabase: 'app',
      );
      final sql = findRelationsSql(context, 'users', showSystem: false);
      expect(sql, contains(r"c.relname OPERATOR(pg_catalog.~) '^(users)$'"));
      expect(sql, contains('pg_catalog.pg_table_is_visible(c.oid)'));
      expect(sql, endsWith('ORDER BY 2, 3;'));
    });

    test('patterns are escaped into the SQL, never pasted raw', () {
      final sql = _list('t', "x'; drop table y; --", _v18);
      expect(sql, contains(r"'^(x''; drop table y; --)$'"));
    });
  });

  group('RelationKinds', () {
    test('default set and titles', () {
      expect(RelationKinds.parse('').title, 'List of relations');
      expect(RelationKinds.parse('t').title, 'List of tables');
      expect(RelationKinds.parse('ti').title, 'List of relations');
      expect(
        RelationKinds.parse('i').notFound(null),
        'Did not find any indexes.',
      );
      expect(
        RelationKinds.parse('v').notFound('x*'),
        'Did not find any views named "x*".',
      );
    });
  });

  test('mapTypenamePattern maps grammar names', () {
    expect(mapTypenamePattern('INT'), 'integer');
    expect(mapTypenamePattern('varchar[]'), 'character varying[]');
    expect(mapTypenamePattern('text'), 'text');
    expect(mapTypenamePattern(null), isNull);
  });

  test('serverVersionNumber reads server_version', () {
    expect(serverVersionNumber('17.2'), 170002);
    expect(serverVersionNumber('16.4 (Debian 16.4-1)'), 160004);
    expect(serverVersionNumber('18beta1'), 180000);
    expect(serverVersionNumber('9.6.3'), 90603);
    expect(serverVersionNumber('junk'), isNull);
    expect(serverVersionNumber(null), isNull);
  });
}
