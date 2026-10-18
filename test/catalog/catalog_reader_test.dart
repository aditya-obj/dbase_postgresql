// File: catalog_reader_test.dart
// Purpose: The bulk catalog reader builds a SchemaModel from fixture
// catalog rows, in a bounded number of round trips, and its queries are
// version-gated for PostgreSQL 13 to 18.

import 'package:dbase_postgresql/catalog.dart';
import 'package:dbase_postgresql/ddl.dart';
import 'package:dbase_postgresql/src/catalog/catalog_sql.dart';
import 'package:test/test.dart';

import '../support/catalog_fixture.dart';

void main() {
  group('CatalogReader on the shop fixture', () {
    late FakeCatalog server;
    late CatalogReader reader;
    const scope = CatalogScope.schemas([shopOid], wholeDatabase: true);

    setUp(() {
      server = FakeCatalog();
      reader = CatalogReader(server.query, serverVersionNum: pg17);
    });

    test('server facts', () async {
      final facts = await CatalogReader.serverFacts(server.query);
      expect(facts.versionNum, pg17);
      expect(facts.version, '17.4');
      expect(facts.inRecovery, isFalse);
    });

    test('listing splits relations by kind', () async {
      final listing = await reader.listRelations(scope);
      expect(server.parameters.single, ['{$shopOid}', null]);
      expect([for (final r in listing.tables) r.name], ['customers', 'orders']);
      expect([for (final r in listing.views) r.name], ['order_view']);
      expect(listing.sequences, hasLength(2));
      expect(
        [for (final r in listing.lockable) r.name],
        ['customers', 'orders'],
      );
      expect(listing.totalBytes, 8192 + 16384);
    });

    test('a table scope passes the picked tables', () async {
      await reader.listRelations(const CatalogScope.tables([ordersOid]));
      expect(server.parameters.single, ['{}', '{$ordersOid}']);
    });

    test('read groups rows per object', () async {
      final listing = await reader.listRelations(scope);
      final model = await reader.read(scope, listing, serverVersion: '17.4');

      expect(model.serverVersionNum, pg17);
      expect(model.schemas.single.name, 'shop');
      expect(model.schemas.single.comment, 'The shop');
      expect(model.extensions.single.name, 'pgcrypto');

      final orders = model.tables.firstWhere((t) => t.oid == ordersOid);
      expect(
        [for (final c in orders.source.columns) c.name],
        ['id', 'customer_id', 'no', 'total'],
      );
      expect(orders.dataColumns, ['id', 'customer_id', 'no']);
      expect(orders.source.constraints, hasLength(2));
      expect(orders.source.constraints.last.referencedTable, customersOid);
      expect(orders.source.indexes, hasLength(2));
      expect(orders.source.triggers.single.name, 'orders_touch');
      expect(orders.source.policies.single.name, 'own_rows');
      expect(orders.totalBytes, 16384);
      expect(orders.rowSecurityActive, isFalse);

      final customers = model.tables.firstWhere((t) => t.oid == customersOid);
      expect(customers.source.identities.single.attnum, 1);
      expect(customers.source.triggers, isEmpty);

      expect(model.views.single.name, 'order_view');
      final identity = model.sequences.firstWhere((s) => s.isIdentity);
      expect(identity.lastValue, '7');
      expect(identity.ownedByRelation, customersOid);
      final serial = model.sequences.firstWhere((s) => !s.isIdentity);
      expect(serial.lastValue, isNull);
      expect(serial.row.ownedKind, 'a');

      expect([for (final t in model.types) t.row.name], ['mood', 'posint']);
      expect(model.types.first.row.enumLabels, ['happy', 'sad']);
      expect(model.types.last.constraints.single.def, 'CHECK (VALUE > 0)');

      final aggregate = model.routines.firstWhere((r) => r.oid == mySumOid);
      expect(aggregate.aggregate?.transitionFunction, 'int4pl');
      expect(aggregate.aggregate?.initialValue, '0');
      expect(
        model.routines.firstWhere((r) => r.oid == totalOid).aggregate,
        isNull,
      );

      expect(model.dependencies, hasLength(5));
      expect(
        model.dependencies.first,
        const DependencyEdge(
          ObjectKey(ObjectKind.relation, ordersOid),
          ObjectKey(ObjectKind.relation, orderNoOid),
          defaultOfColumn: 3,
        ),
      );
      expect(model.skipped.counts, {'large_objects': 2, 'event_triggers': 1});
      expect(model.defaultPrivileges, isEmpty);
    });

    test('one statement per kind of object, not per object', () async {
      final listing = await reader.listRelations(scope);
      await reader.read(scope, listing, includeGrants: true);
      expect(server.log.length, lessThan(30));
      // Every relation query covers all relations at once.
      final relationArrays = {
        for (final (i, sql) in server.log.indexed)
          if (sql == tableColumnsSql(pg17, filter: OidFilter.many))
            server.parameters[i].single,
      };
      expect(relationArrays, {'{$customersOid,$ordersOid}'});
    });

    test('grants and default privileges are read only when asked', () async {
      final listing = await reader.listRelations(scope);
      await reader.read(scope, listing);
      expect(server.log, isNot(contains(defaultPrivilegesSql)));
      expect(server.log, isNot(contains(relationGrantsQuery(OidFilter.many))));
      server.log.clear();
      await reader.read(scope, listing, includeGrants: true);
      expect(server.log, contains(defaultPrivilegesSql));
      expect(server.log, contains(relationGrantsQuery(OidFilter.many)));
      expect(server.log, contains(schemaGrantsSql));
    });

    test('a table scope reads no types, routines or extensions', () async {
      const tables = CatalogScope.tables([ordersOid]);
      final listing = await reader.listRelations(tables);
      final model = await reader.read(tables, listing);
      expect(model.types, isEmpty);
      expect(model.routines, isEmpty);
      expect(model.extensions, isEmpty);
      expect(server.log, isNot(contains(typesSql(pg17))));
      // The schemas of the listed relations still get CREATE SCHEMA.
      expect(model.schemas.single.name, 'shop');
    });
  });

  group('version gates', () {
    test('attcompression from PostgreSQL 14', () {
      expect(tableColumnsSql(130000), isNot(contains('a.attcompression')));
      expect(tableColumnsSql(140000), contains('a.attcompression'));
    });

    test('NOT NULL constraints from PostgreSQL 18', () {
      expect(tableConstraintsSql(170000), isNot(contains("'n')")));
      expect(tableConstraintsSql(180000), contains(", 'n')"));
    });

    test('multirange types from PostgreSQL 14', () {
      for (final v in [130000, 140000, 150000, 160000, 170000, 180000]) {
        final types = typesSql(v);
        final deps = dependenciesSql(v);
        if (v >= 140000) {
          expect(types, contains('rngmultitypid'), reason: '$v');
          expect(deps, contains('rngmultitypid'), reason: '$v');
        } else {
          expect(types, isNot(contains('rngmultitypid')), reason: '$v');
          expect(deps, isNot(contains('rngmultitypid')), reason: '$v');
          expect(types, contains('NULL::pg_catalog.text AS range_multirange'));
        }
      }
    });

    test('bulk recipe queries filter by an OID array, Browse by one OID', () {
      expect(tableHeaderSql, contains(r'c.oid = $1::pg_catalog.oid'));
      expect(
        tableHeaderQuery(OidFilter.many),
        contains(r'c.oid = ANY ($1::pg_catalog.oid[])'),
      );
      expect(sequenceSql, isNot(contains('pg_sequence_last_value')));
      expect(sequenceQuery(OidFilter.many), contains('pg_sequence_last_value'));
    });
  });

  test('relid is a numeric OID in every bulk query (aggfnoid is regproc, '
      'whose text is a name, so it is cast)', () {
    expect(aggregatesSql, contains('a.aggfnoid::pg_catalog.oid AS relid'));
    // A regproc relid printed as a name can't be read back.
    expect(
      () => rowRelid(const {'relid': 'dbase_export_live.my_sum'}),
      throwsFormatException,
    );
  });

  test('oidArrayLiteral', () {
    expect(oidArrayLiteral([]), '{}');
    expect(oidArrayLiteral([1, 22]), '{1,22}');
  });
}
