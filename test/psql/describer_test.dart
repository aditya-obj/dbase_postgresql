// File: describer_test.dart
// Purpose: The describe commands end to end over a fake catalog: the
// queries they send per server version and the text they print. Expected
// texts are real psql 17 output for the same objects on PostgreSQL 18.

import 'dart:io';

import 'package:dbase_postgresql/psql.dart';
import 'package:test/test.dart';

/// Answers catalog queries by the first rule whose key the SQL contains.
final class _Catalog {
  _Catalog(this.rules);

  final Map<String, PsqlResult> rules;
  final sent = <String>[];

  Future<PsqlResult> query(String sql) async {
    sent.add(sql);
    for (final MapEntry(:key, :value) in rules.entries) {
      if (sql.contains(key)) return value;
    }
    return const PsqlResult(columns: [], rows: []);
  }
}

PsqlResult _rows(List<List<String?>> rows) => PsqlResult(
  columns: [
    for (var i = 0; i < (rows.isEmpty ? 0 : rows[0].length); i++) 'c$i',
  ],
  rows: rows,
);

const _empty = PsqlResult(columns: [], rows: []);

const _viewDefinition =
    ' SELECT id,\n    user_id,\n    total\n   FROM orders\n'
    '  WHERE total > 100::numeric;';

Map<String, PsqlResult> _usersCatalog() => {
  'SELECT c.oid,\n  n.nspname': _rows([
    ['16391', 'public', 'users'],
  ]),
  'SELECT c.relchecks': _rows([
    [
      '1',
      'r',
      't',
      'f',
      'f',
      'f',
      'f',
      'f',
      'f',
      '',
      '0',
      '',
      'p',
      'd',
      'heap',
    ],
  ]),
  'SELECT a.attname': _rows([
    ['id', 'integer', null, 't', null, 'a', ''],
    ['email', 'text', null, 't', null, '', ''],
    ['created', 'timestamp with time zone', 'now()', 'f', null, '', ''],
  ]),
  'SELECT c2.relname, i.indisprimary': _rows([
    [
      'users_pkey',
      't',
      't',
      'f',
      't',
      'CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id)',
      'PRIMARY KEY (id)',
      'p',
      'f',
      'f',
      'f',
      '0',
      'f',
    ],
  ]),
  "r.contype = 'c'": _rows([
    ['users_email_check', "CHECK (email <> ''::text)"],
  ]),
  'SELECT true as sametable': _empty,
  'confrelid IN': _rows([
    [
      'orders_user_id_fkey',
      'orders',
      'FOREIGN KEY (user_id) REFERENCES users(id)',
    ],
  ]),
};

String _golden(String name) =>
    File('test/psql/describe_goldens/$name.txt').readAsStringSync();

Future<String> _print(
  _Catalog catalog,
  String line, {
  int version = 180006,
  PrintOptions options = const PrintOptions(),
}) async {
  final context = DescribeContext(
    version: version,
    query: catalog.query,
    currentDatabase: 'postgres',
    nullDisplay: options.nullDisplay,
  );
  final outputs = await runDescribe(context, parseMetaCommand(line, 0));
  return [
    for (final output in outputs)
      switch (output) {
        PsqlTableOutput(:final table) => printTable(table, options),
        PsqlMessageOutput(:final text) => '$text\n',
      },
  ].join();
}

void main() {
  test(r'\d users prints like psql', () async {
    final catalog = _Catalog(_usersCatalog());
    expect(await _print(catalog, r'\d users'), _golden('describe_users'));
  });

  test(r'\d name stays unexpanded under \x on, as in psql', () async {
    final catalog = _Catalog(_usersCatalog());
    final text = await _print(
      catalog,
      r'\d users',
      options: const PrintOptions(expanded: ExpandedMode.on),
    );
    expect(text, _golden('describe_users'));
  });

  test(r'\d of a sequence prints its settings and owner', () async {
    final catalog = _Catalog({
      'SELECT c.oid,\n  n.nspname': _rows([
        ['16402', 'public', 'orders_id_seq'],
      ]),
      'SELECT c.relchecks': _rows([
        [
          '0',
          'S',
          'f',
          'f',
          'f',
          'f',
          'f',
          'f',
          'f',
          '',
          '0',
          '',
          'p',
          'n',
          null,
        ],
      ]),
      'FROM pg_catalog.pg_sequence': const PsqlResult(
        columns: [
          'Type',
          'Start',
          'Minimum',
          'Maximum',
          'Increment',
          'Cycles?',
          'Cache',
        ],
        typeOids: [25, 20, 20, 20, 20, 25, 20],
        rows: [
          ['bigint', '1', '1', '9223372036854775807', '1', 'no', '1'],
        ],
      ),
      'd.deptype': _rows([
        ['public.orders.id', 'a'],
      ]),
    });
    expect(
      await _print(catalog, r'\d orders_id_seq'),
      _golden('describe_sequence'),
    );
  });

  test(r'\d of an index prints the key columns and the summary', () async {
    final catalog = _Catalog({
      'SELECT c.oid,\n  n.nspname': _rows([
        ['16410', 'public', 'orders_user_idx'],
      ]),
      'SELECT c.relchecks': _rows([
        [
          '0',
          'i',
          'f',
          'f',
          'f',
          'f',
          'f',
          'f',
          'f',
          '',
          '0',
          '',
          'p',
          'n',
          'btree',
        ],
      ]),
      'SELECT a.attname': _rows([
        ['user_id', 'integer', 'yes', 'user_id'],
      ]),
      'SELECT i.indisunique': _rows([
        [
          'f',
          'f',
          'f',
          't',
          'f',
          'f',
          'f',
          'f',
          'btree',
          'orders',
          'total > 0::numeric',
        ],
      ]),
    });
    expect(
      await _print(catalog, r'\d orders_user_idx'),
      _golden('describe_index'),
    );
  });

  test(r'\d+ of a view adds storage, description and the definition', () async {
    final catalog = _Catalog({
      'SELECT c.oid,\n  n.nspname': _rows([
        ['16420', 'public', 'big_orders'],
      ]),
      'SELECT c.relchecks': _rows([
        [
          '0',
          'v',
          'f',
          't',
          'f',
          'f',
          'f',
          'f',
          'f',
          '',
          '0',
          '',
          'p',
          'n',
          null,
        ],
      ]),
      'SELECT a.attname': _rows([
        ['id', 'bigint', null, 'f', null, '', '', 'p', null],
        ['user_id', 'integer', null, 'f', null, '', '', 'p', null],
        ['total', 'numeric(10,2)', null, 'f', null, '', '', 'm', null],
      ]),
      'pg_get_viewdef': _rows([
        [_viewDefinition],
      ]),
    });
    expect(
      await _print(catalog, r'\d+ big_orders'),
      _golden('describe_view_verbose'),
    );
  });

  test(r'\d nothing-there is an error', () async {
    final catalog = _Catalog({});
    final context = DescribeContext(version: 170000, query: catalog.query);
    final outputs = await runDescribe(context, parseMetaCommand(r'\d nope', 0));
    final message = outputs.single as PsqlMessageOutput;
    expect(message.text, 'Did not find any relation named "nope".');
    expect(message.fails, isTrue);
  });

  test(r'\dt with no tables says so but does not fail', () async {
    final catalog = _Catalog({});
    final context = DescribeContext(version: 170000, query: catalog.query);
    final outputs = await runDescribe(context, parseMetaCommand(r'\dt', 0));
    final message = outputs.single as PsqlMessageOutput;
    expect(message.text, 'Did not find any tables.');
    expect(message.isError, isTrue);
    expect(message.fails, isFalse);
  });

  test(r'\dt prints the list with its title and row count', () async {
    final catalog = _Catalog({
      'FROM pg_catalog.pg_class c': const PsqlResult(
        columns: ['Schema', 'Name', 'Type', 'Owner'],
        typeOids: [19, 19, 25, 19],
        rows: [
          ['public', 'orders', 'table', 'postgres'],
          ['public', 'users', 'table', 'postgres'],
        ],
      ),
    });
    // psql 17 titles every list "List of relations"; psql 18, which the
    // library follows, says "List of tables" for \dt.
    final golden = _golden(
      'list_tables',
    ).replaceFirst('${' ' * 9}List of relations', '${' ' * 11}List of tables');
    expect(await _print(catalog, r'\dt'), golden);
  });

  test(r'\du builds the Attributes column on the client', () async {
    final catalog = _Catalog({
      'FROM pg_catalog.pg_roles r': _rows([
        ['alice', 't', 't', 't', 't', 't', '-1', null, 't', 't'],
        [
          'bob',
          'f',
          'f',
          'f',
          'f',
          'f',
          '3',
          '2030-01-01 00:00:00+00',
          'f',
          'f',
        ],
      ]),
    });
    expect(await _print(catalog, r'\du'), _golden('list_roles'));
  });

  test(r'\l, \dn, \df, \dT, \dD, \dp, \dx run their lists', () async {
    for (final (line, title) in const [
      (r'\l', 'List of databases'),
      (r'\dn', 'List of schemas'),
      (r'\df', 'List of functions'),
      (r'\dT', 'List of data types'),
      (r'\dD', 'List of domains'),
      (r'\dp', 'Access privileges'),
      (r'\z', 'Access privileges'),
      (r'\dx', 'List of installed extensions'),
    ]) {
      final catalog = _Catalog({
        'SELECT': const PsqlResult(columns: ['Name'], rows: []),
      });
      final text = await _print(catalog, line);
      expect(text, contains(title), reason: line);
      expect(text, contains('(0 rows)'), reason: line);
    }
  });

  test('bad patterns become psql error messages', () async {
    final catalog = _Catalog({});
    final context = DescribeContext(
      version: 170000,
      query: catalog.query,
      currentDatabase: 'app',
    );
    final outputs = await runDescribe(
      context,
      parseMetaCommand(r'\dt other.public.t', 0),
    );
    expect(
      (outputs.single as PsqlMessageOutput).text,
      'cross-database references are not implemented: other.public.t',
    );
    expect(catalog.sent, isEmpty);
  });

  group(r'version gates in \d', () {
    Future<List<String>> sent(int version, String line) async {
      final rules = _usersCatalog()
        // Only the queries matter here; no columns to print.
        ..['SELECT a.attname'] = _empty
        ..['SELECT c.relchecks'] = _rows([
          [
            '1',
            'p',
            't',
            'f',
            't',
            'f',
            'f',
            'f',
            't',
            '',
            '0',
            '',
            'p',
            'd',
            'heap',
          ],
        ]);
      final catalog = _Catalog(rules);
      await _print(catalog, line, version: version);
      return catalog.sent;
    }

    test('PostgreSQL 13 avoids columns added later', () async {
      final queries = (await sent(130000, r'\d+ users')).join('\n');
      expect(queries, isNot(contains('attcompression')));
      expect(queries, isNot(contains('c.relkind, inhdetachpending')));
      expect(queries, contains('false as inhdetachpending'));
      expect(queries, contains('false AS conperiod'));
      expect(queries, contains("refclassid = 'pg_catalog.pg_trigger'"));
      expect(queries, contains('UNION ALL'));
    });

    test('PostgreSQL 18 uses the newest catalog columns', () async {
      final queries = (await sent(180000, r'\d+ users')).join('\n');
      expect(queries, contains('a.attcompression'));
      expect(queries, contains('con.conperiod'));
      expect(queries, contains('pg_get_statisticsobjdef_columns'));
      expect(queries, contains('pg_publication_namespace'));
      expect(queries, contains('c.relkind, inhdetachpending'));
      expect(queries, isNot(contains("refclassid = 'pg_catalog.pg_trigger'")));
    });
  });

  test('describe helpers know their commands', () {
    expect(isDescribeCommand('dt+'), isTrue);
    expect(isDescribeCommand('dSx'), isTrue);
    expect(isDescribeCommand('l+'), isTrue);
    expect(isDescribeCommand('dq'), isFalse);
    expect(isDescribeCommand('x'), isFalse);
    expect(describeArgumentCount('df'), isNull);
    expect(describeArgumentCount('dt'), 1);
  });
}
