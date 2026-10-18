// File: sql_dumper_test.dart
// Purpose: The dump runner over a fake connection: transaction and lock
// statements, cursor batches re-encoded as COPY text, row-level security
// handling, cancellation and rollback on errors; and a dump read back by
// SqlScriptReader gives the same statements and rows.

import 'package:dbase_postgresql/catalog.dart';
import 'package:dbase_postgresql/dump.dart';
import 'package:test/test.dart';

import '../support/catalog_fixture.dart';

/// [FakeCatalog] plus cursor handling: DECLARE picks a table's rows,
/// FETCH FORWARD n returns the next n.
final class FakeDumpConnection implements DumpConnection {
  FakeDumpConnection(
    this.catalog,
    this.rows, {
    this.failOnFetch = false,
    this.keepRows,
  });

  final FakeCatalog catalog;
  final Map<String, List<List<String?>>> rows;
  final bool failOnFetch;

  /// Simulates a memory cap: at most this many rows of a batch are kept.
  final int? keepRows;
  List<List<String?>> _cursor = const [];
  var _position = 0;

  List<String> get log => catalog.log;

  @override
  Future<List<CatalogRow>> query(
    String sql, [
    List<String?> parameters = const [],
  ]) {
    if (sql.startsWith('DECLARE ')) {
      final table = RegExp(r'FROM ONLY (\S+)$').firstMatch(sql)!.group(1)!;
      _cursor = rows[table] ?? const [];
      _position = 0;
    }
    if (RegExp(r'^MOVE BACKWARD (\d+)').firstMatch(sql) case final m?) {
      _position -= int.parse(m.group(1)!);
    }
    return catalog.query(sql, parameters);
  }

  @override
  Future<FetchedRows> fetch(String sql) async {
    catalog.log.add(sql);
    if (failOnFetch) throw StateError('connection lost');
    final n = int.parse(RegExp(r'FORWARD (\d+)').firstMatch(sql)!.group(1)!);
    final end = (_position + n).clamp(0, _cursor.length);
    final batch = _cursor.sublist(_position, end);
    _position = end;
    final keep = keepRows;
    if (keep != null && batch.length > keep) {
      return FetchedRows(batch.sublist(0, keep), serverRows: batch.length);
    }
    return FetchedRows(batch);
  }
}

const Map<String, List<List<String?>>> _rows = {
  'shop.customers': [
    ['1', 'Ann', 'happy'],
    ['2', 'Bob\twith tab', null],
    ['3', r'C\D', 'sad'],
  ],
  'shop.orders': [
    ['10', '1', '100'],
    ['11', '2', null],
    ['12', '3', '102'],
    ['13', '1', '103'],
    ['14', '2', '104'],
  ],
};

Future<(DumpResult, String, FakeDumpConnection)> dump({
  bool rlsActive = false,
  bool visibleRowsOnly = false,
  DumpContent content = DumpContent.schemaAndData,
  List<DumpTableStatus>? statuses,
}) async {
  final connection = FakeDumpConnection(
    FakeCatalog(rlsActive: rlsActive),
    _rows,
  );
  final out = StringBuffer();
  final result = await SqlDumper(
    connection: connection,
    options: DumpOptions(
      scope: const CatalogScope.schemas([shopOid]),
      content: content,
      visibleRowsOnly: visibleRowsOnly,
    ),
    write: (chunk) async => out.write(chunk),
    generator: 'test',
    batch: const DumpBatchSizing(startRows: 2, minRows: 1, maxRows: 2),
    onTable: statuses?.add,
    now: () => DateTime.utc(2026),
  ).run();
  return (result, out.toString(), connection);
}

void main() {
  test('one read-only repeatable-read transaction: settings, locks, '
      'catalog, cursor batches, commit', () async {
    final (result, _, connection) = await dump();
    final log = connection.log;
    expect(log.first, dumpBeginSql);
    expect(log[1], dumpSettingsSql);
    expect(log.last, 'COMMIT');
    final lock = log.indexOf(
      'LOCK TABLE shop.customers, shop.orders IN ACCESS SHARE MODE',
    );
    expect(lock, greaterThan(0));
    // Locks come before the definitions are read.
    expect(
      lock,
      lessThan(log.indexWhere((s) => s.contains('pg_get_partkeydef'))),
    );
    const declare = 'DECLARE dbase_dump SCROLL CURSOR FOR SELECT';
    expect(log.where((s) => s.startsWith('DECLARE')), [
      '$declare id, name, mood FROM ONLY shop.customers',
      '$declare id, customer_id, no FROM ONLY shop.orders',
    ]);
    // 3 rows in batches of 2: 2 + 1 (a short batch ends it); 5 rows: 2 + 2 + 1.
    expect(log.where((s) => s.startsWith('FETCH')).length, 2 + 3);
    expect(log.where((s) => s == 'CLOSE dbase_dump').length, 2);
    expect(result.rows, 8);
    expect(result.failedTables, isEmpty);
    expect(result.skipped.counts, {'large_objects': 2, 'event_triggers': 1});
  });

  test('the file: header, sections in order, COPY text', () async {
    final (_, text, _) = await dump();
    expect(text, startsWith('--\n-- PostgreSQL SQL export\n'));
    final createTable = text.indexOf('CREATE TABLE shop.orders');
    final copy = text.indexOf('COPY shop.orders (id, customer_id, no) FROM');
    final primaryKey = text.indexOf('ADD CONSTRAINT orders_pkey');
    final foreignKey = text.indexOf('ADD CONSTRAINT orders_customer_fk');
    expect(createTable, lessThan(copy));
    expect(copy, lessThan(primaryKey));
    expect(primaryKey, lessThan(foreignKey));
    expect(
      text,
      contains(
        'COPY shop.customers (id, name, mood) FROM stdin;\n'
        '1\tAnn\thappy\n'
        '2\tBob\\twith tab\t\\N\n'
        '3\tC\\\\D\tsad\n'
        '\\.\n',
      ),
    );
    expect(text, contains('\n14\t2\t104\n\\.\n'));
    expect(text, endsWith('-- SQL export complete\n--\n'));
  });

  test('schema only reads no data', () async {
    final (result, text, connection) = await dump(
      content: DumpContent.schemaOnly,
    );
    expect(connection.log.where((s) => s.startsWith('DECLARE')), isEmpty);
    expect(text, isNot(contains('COPY ')));
    expect(result.rows, 0);
  });

  test('row-level security: the table fails by default, nothing is '
      'read from it', () async {
    final statuses = <DumpTableStatus>[];
    final (result, text, connection) = await dump(
      rlsActive: true,
      statuses: statuses,
    );
    expect(
      connection.log.where((s) => s.contains('FROM ONLY shop.orders')),
      isEmpty,
    );
    expect(result.failedTables.single.name, 'orders');
    expect(result.failedTables.single.failure, DumpTableFailure.rowSecurity);
    expect(
      text,
      contains(
        '-- Data not exported (row-level security): '
        'shop.orders\n',
      ),
    );
    expect(text, contains('-- NOT EXPORTED: row-level security'));
    expect(text, isNot(contains('COPY shop.orders')));
    // The schema is still complete.
    expect(text, contains('CREATE TABLE shop.orders'));
    expect(statuses.first.state, DumpTableState.pending);
    expect(statuses.last.state, DumpTableState.done);
  });

  test('row-level security with "only rows I can see"', () async {
    final (result, text, connection) = await dump(
      rlsActive: true,
      visibleRowsOnly: true,
    );
    final log = connection.log;
    final on = log.indexOf(
      "SELECT pg_catalog.set_config('row_security', 'on', true)",
    );
    final declare = log.indexWhere((s) => s.endsWith('FROM ONLY shop.orders'));
    final off = log.indexOf(
      "SELECT pg_catalog.set_config('row_security', 'off', true)",
    );
    expect(on, allOf(greaterThan(0), lessThan(declare)));
    expect(off, greaterThan(declare));
    expect(result.failedTables, isEmpty);
    expect(
      result.warnings.map((w) => w.code),
      contains(DumpWarningCode.visibleRowsOnly),
    );
    expect(text, contains('Only the rows row-level security lets'));
  });

  test('an error rolls back and is rethrown', () async {
    final connection = FakeDumpConnection(
      FakeCatalog(),
      _rows,
      failOnFetch: true,
    );
    final dumper = SqlDumper(
      connection: connection,
      options: const DumpOptions(scope: CatalogScope.schemas([shopOid])),
      write: (_) async {},
    );
    await expectLater(dumper.run(), throwsStateError);
    expect(connection.log.last, 'ROLLBACK');
  });

  test('cancelling stops between batches and rolls back', () async {
    final connection = FakeDumpConnection(FakeCatalog(), _rows);
    var fetches = 0;
    final dumper = SqlDumper(
      connection: connection,
      options: const DumpOptions(scope: CatalogScope.schemas([shopOid])),
      write: (_) async {},
      batch: const DumpBatchSizing(startRows: 1, minRows: 1, maxRows: 1),
      isCancelled: () =>
          connection.log.where((s) => s.startsWith('FETCH')).length >= 2,
      onProgress: (_) => fetches++,
    );
    await expectLater(dumper.run(), throwsA(isA<DumpCancelledException>()));
    expect(connection.log.last, 'ROLLBACK');
    expect(fetches, greaterThan(0));
  });

  test('a checkpoint error (e.g. low disk) stops the dump', () async {
    final connection = FakeDumpConnection(FakeCatalog(), _rows);
    final dumper = SqlDumper(
      connection: connection,
      options: const DumpOptions(scope: CatalogScope.schemas([shopOid])),
      write: (_) async {},
      checkpoint: () async => throw const FormatException('disk full'),
    );
    await expectLater(dumper.run(), throwsFormatException);
    expect(connection.log.last, 'ROLLBACK');
  });

  test('a batch cut by a memory cap is fetched again in smaller batches, '
      'every row once', () async {
    final connection = FakeDumpConnection(FakeCatalog(), _rows, keepRows: 2);
    final out = StringBuffer();
    await SqlDumper(
      connection: connection,
      options: const DumpOptions(scope: CatalogScope.schemas([shopOid])),
      write: (chunk) async => out.write(chunk),
      batch: const DumpBatchSizing(startRows: 4, minRows: 1, maxRows: 4),
    ).run();
    expect(connection.log, contains('MOVE BACKWARD 2 IN dbase_dump'));
    final text = out.toString();
    final copy = text.indexOf('COPY shop.orders');
    final data = text.substring(
      text.indexOf('\n', copy) + 1,
      text.indexOf(r'\.', copy),
    );
    expect(
      data,
      '10\t1\t100\n11\t2\t\\N\n12\t3\t102\n13\t1\t103\n14\t2\t104\n',
    );
  });

  test('a single row larger than the cap fails the dump', () async {
    final connection = FakeDumpConnection(FakeCatalog(), _rows, keepRows: 0);
    final dumper = SqlDumper(
      connection: connection,
      options: const DumpOptions(scope: CatalogScope.schemas([shopOid])),
      write: (_) async {},
    );
    await expectLater(
      dumper.run(),
      throwsA(
        isA<DumpRowTooLargeException>().having(
          (e) => e.table,
          'table',
          'shop.customers',
        ),
      ),
    );
    expect(connection.log.last, 'ROLLBACK');
  });

  test('batch sizing aims at the byte target', () {
    const sizing = DumpBatchSizing(maxRows: 1000, targetBytes: 1000);
    expect(sizing.next(100, 10000), 10); // 100 bytes a row
    expect(sizing.next(100, 100), 1000); // 1 byte a row, capped
    expect(sizing.next(100, 500), 200);
    expect(sizing.next(0, 0), 1000);
  });

  test('lock statements are batched', () {
    final relations = [
      for (var i = 0; i < 5; i++)
        ListedRelation(
          oid: i,
          schemaOid: 1,
          schema: 's',
          name: 't$i',
          relkind: 'r',
        ),
    ];
    expect(lockTablesSql(relations, perStatement: 2), [
      'LOCK TABLE s.t0, s.t1 IN ACCESS SHARE MODE',
      'LOCK TABLE s.t2, s.t3 IN ACCESS SHARE MODE',
      'LOCK TABLE s.t4 IN ACCESS SHARE MODE',
    ]);
  });

  test('a dump read back gives its statements and rows', () async {
    final (_, text, _) = await dump();
    // Feed it in awkward chunks.
    final chunks = [
      for (var i = 0; i < text.length; i += 37)
        text.substring(i, (i + 37).clamp(0, text.length)),
    ];
    final items = await Stream.fromIterable(chunks)
        .transform(const SqlScriptReader(copyChunkChars: 8))
        .toList();
    final statements = [
      for (final i in items)
        if (i is ScriptStatement) i.sql,
    ];
    expect(statements.take(dumpPreamble.length), [
      for (final line in dumpPreamble) line.substring(0, line.length - 1),
    ]);
    expect(statements, contains(startsWith('CREATE TABLE shop.orders')));
    final copies = [
      for (final i in items)
        if (i is ScriptCopyStart) i.sql,
    ];
    expect(copies, [
      'COPY shop.customers (id, name, mood) FROM stdin',
      'COPY shop.orders (id, customer_id, no) FROM stdin',
    ]);
    final data = [
      for (final i in items)
        if (i is ScriptCopyData) i.text,
    ].join();
    final decoded = [
      for (final line in data.split('\n'))
        if (line.isNotEmpty) decodeCopyTextRow(line),
    ];
    expect(decoded, [..._rows['shop.customers']!, ..._rows['shop.orders']!]);
    final firstCopy = items.whereType<ScriptCopyStart>().first;
    expect(firstCopy.toc?.type, 'TABLE DATA');
    expect(firstCopy.toc?.name, 'customers');
    expect(firstCopy.toc?.schema, 'shop');
  });
}
