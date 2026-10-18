// File: catalog_fixture.dart
// Purpose: A fake server for catalog, planner and dump tests: answers the
// bulk catalog queries with hand-written rows (server text, as a real
// PostgreSQL 17 returns them) for a small `shop` schema, and records
// every statement it was sent.
//
// The schema:
//   enum shop.mood ('happy', 'sad'); domain shop.posint (integer > 0)
//   shop.customers (id identity PK, name text, mood shop.mood)
//   shop.orders (id bigint, customer_id FK, no default nextval(order_no))
//     with an index, a trigger, RLS enabled and one policy
//   sequence shop.order_no OWNED BY shop.orders.no
//   function shop.total(shop.orders); aggregate shop.my_sum(integer)
//   view shop.order_view on orders and total()

import 'package:dbase_postgresql/catalog.dart';
import 'package:dbase_postgresql/ddl.dart';
import 'package:dbase_postgresql/src/catalog/catalog_sql.dart';

const pg17 = 170004;
const shopOid = 16400;
const customersOid = 16410;
const ordersOid = 16420;
const orderNoOid = 16425;
const customersIdSeqOid = 16426;
const orderViewOid = 16430;
const moodOid = 16450;
const posintOid = 16455;
const totalOid = 16460;
const mySumOid = 16465;

/// Answers known statements with fixed rows; anything else returns no
/// rows. [log] keeps every statement in order.
final class FakeCatalog {
  FakeCatalog({this.versionNum = pg17, this.rlsActive = false});

  final int versionNum;
  final bool rlsActive;
  final log = <String>[];
  final parameters = <List<String?>>[];

  Future<List<CatalogRow>> query(
    String sql, [
    List<String?> params = const [],
  ]) async {
    log.add(sql);
    parameters.add(params);
    return _answers[sql] ?? const [];
  }

  late final Map<String, List<CatalogRow>> _answers = {
    serverFactsSql: [
      {'version_num': '$versionNum', 'version': '17.4', 'in_recovery': 'f'},
    ],
    relationListingSql: [
      _listed(customersOid, 'customers', 'r', bytes: 8192),
      _listed(customersIdSeqOid, 'customers_id_seq', 'S'),
      _listed(orderNoOid, 'order_no', 'S'),
      _listed(orderViewOid, 'order_view', 'v'),
      _listed(ordersOid, 'orders', 'r', bytes: 16384),
    ],
    schemasSql: [
      {
        'relid': '$shopOid',
        'name': 'shop',
        'comment': 'The shop',
        'nspacl': null,
      },
    ],
    tableHeaderQuery(OidFilter.many): [
      _tableHeader(customersOid, 'customers'),
      _tableHeader(
        ordersOid,
        'orders',
        rls: true,
        rlsActive: rlsActive,
        comment: 'Orders',
      ),
    ],
    tableColumnsSql(versionNum, filter: OidFilter.many): [
      _column(customersOid, 1, 'id', 'bigint', identity: 'a', notNull: true),
      _column(customersOid, 2, 'name', 'text'),
      _column(customersOid, 3, 'mood', 'shop.mood'),
      _column(ordersOid, 1, 'id', 'bigint', notNull: true),
      _column(ordersOid, 2, 'customer_id', 'bigint'),
      _column(
        ordersOid,
        3,
        'no',
        'integer',
        defaultExpr: "nextval('shop.order_no'::regclass)",
      ),
      _column(
        ordersOid,
        4,
        'total',
        'integer',
        generated: 's',
        defaultExpr: '(no * 2)',
      ),
    ],
    tableIdentitiesQuery(OidFilter.many): [
      {
        'relid': '$customersOid',
        'attnum': '1',
        'seqstart': '1',
        'seqincrement': '1',
      },
    ],
    tableConstraintsSql(versionNum, filter: OidFilter.many): [
      _constraint(customersOid, 'customers_pkey', 'p', 'PRIMARY KEY (id)'),
      _constraint(ordersOid, 'orders_pkey', 'p', 'PRIMARY KEY (id)'),
      _constraint(
        ordersOid,
        'orders_customer_fk',
        'f',
        'FOREIGN KEY (customer_id) REFERENCES shop.customers(id)',
        confrelid: customersOid,
      ),
    ],
    relationIndexesQuery(OidFilter.many): [
      {
        'relid': '$ordersOid',
        'name': 'orders_customer_idx',
        'def':
            'CREATE INDEX orders_customer_idx ON shop.orders USING btree '
            '(customer_id)',
        'indisclustered': 'f',
        'indisvalid': 't',
        'indisreplident': 'f',
        'is_constraint': 'f',
        'comment': null,
      },
      {
        'relid': '$ordersOid',
        'name': 'orders_pkey',
        'def':
            'CREATE UNIQUE INDEX orders_pkey ON shop.orders USING btree '
            '(id)',
        'indisclustered': 'f',
        'indisvalid': 't',
        'indisreplident': 'f',
        'is_constraint': 't',
        'comment': null,
      },
    ],
    relationTriggersQuery(OidFilter.many): [
      {
        'relid': '$ordersOid',
        'tgname': 'orders_touch',
        'def':
            'CREATE TRIGGER orders_touch BEFORE UPDATE ON shop.orders '
            'FOR EACH ROW EXECUTE FUNCTION shop.touch()',
        'tgenabled': 'O',
      },
    ],
    tablePoliciesQuery(OidFilter.many): [
      {
        'relid': '$ordersOid',
        'polname': 'own_rows',
        'polpermissive': 't',
        'polcmd': 'r',
        'roles': '{PUBLIC}',
        'using_expr': '(customer_id > 0)',
        'check_expr': null,
      },
    ],
    viewHeaderQuery(OidFilter.many): [
      {
        'relid': '$orderViewOid',
        'schema': 'shop',
        'name': 'order_view',
        'relkind': 'v',
        'reloptions': null,
        'access_method': null,
        'tablespace': null,
        'relispopulated': 't',
        'def':
            ' SELECT id,\n    shop.total(o.*) AS total\n   FROM shop.orders o;',
        'owner': 'app',
        'relacl': null,
        'comment': null,
      },
    ],
    sequenceQuery(OidFilter.many): [
      _sequence(
        customersIdSeqOid,
        'customers_id_seq',
        ownedKind: 'i',
        table: 'customers',
        tableOid: customersOid,
        column: 'id',
        lastValue: '7',
      ),
      _sequence(
        orderNoOid,
        'order_no',
        ownedKind: 'a',
        table: 'orders',
        tableOid: ordersOid,
        column: 'no',
        lastValue: null,
      ),
    ],
    typesSql(versionNum): [
      _type(moodOid, 'mood', 'e', {'enum_labels': '{happy,sad}'}),
      _type(posintOid, 'posint', 'd', {
        'base_type': 'integer',
        'typnotnull': 't',
      }),
    ],
    domainConstraintsSql: [
      {
        'relid': '$posintOid',
        'conname': 'posint_check',
        'convalidated': 't',
        'def': 'CHECK (VALUE > 0)',
      },
    ],
    routineListingSql: [
      {'relid': '$totalOid'},
      {'relid': '$mySumOid'},
    ],
    routineHeaderQuery(OidFilter.many): [
      {
        'relid': '$mySumOid',
        'schema': 'shop',
        'name': 'my_sum',
        'prokind': 'a',
        'identity_args': 'integer',
        'def': null,
        'owner': 'app',
        'proacl': null,
        'comment': null,
      },
      {
        'relid': '$totalOid',
        'schema': 'shop',
        'name': 'total',
        'prokind': 'f',
        'identity_args': 'o shop.orders',
        'def':
            'CREATE OR REPLACE FUNCTION shop.total(o shop.orders)\n'
            ' RETURNS integer\n LANGUAGE sql\n'
            'AS \$function\$SELECT o.no * 2\$function\$\n',
        'owner': 'app',
        'proacl': null,
        'comment': 'Order total',
      },
    ],
    aggregatesSql: [
      {
        'relid': '$mySumOid',
        'aggkind': 'n',
        'sfunc': 'int4pl',
        'stype': 'integer',
        'sspace': '0',
        'finalfunc': null,
        'aggfinalextra': 'f',
        'aggfinalmodify': 'r',
        'combinefunc': null,
        'serialfunc': null,
        'deserialfunc': null,
        'agginitval': '0',
        'msfunc': null,
        'minvfunc': null,
        'mstype': null,
        'msspace': '0',
        'mfinalfunc': null,
        'aggmfinalextra': 'f',
        'aggmfinalmodify': 'r',
        'aggminitval': null,
        'sortop': null,
        'proparallel': 's',
      },
    ],
    extensionsSql: [
      {
        'relid': '16500',
        'name': 'pgcrypto',
        'schema': 'shop',
        'comment': null,
        'has_config': 'f',
      },
    ],
    dependenciesSql(versionNum): [
      _edge('rel', ordersOid, 'rel', orderNoOid, via: 'default', attnum: 3),
      _edge('rel', customersOid, 'type', moodOid),
      _edge('rel', orderViewOid, 'rel', ordersOid, via: 'rule'),
      _edge('rel', orderViewOid, 'proc', totalOid, via: 'rule'),
      _edge('proc', totalOid, 'rel', ordersOid, via: 'proc'),
    ],
    skippedCountsSql: [
      {
        'large_objects': '2',
        'publications': '0',
        'subscriptions': '0',
        'event_triggers': '1',
        'foreign_servers': '0',
        'foreign_tables': '0',
        'base_types': '0',
        'collations': '0',
        'operators': '0',
        'text_search_configs': '0',
      },
    ],
  };
}

CatalogRow _listed(int oid, String name, String relkind, {int? bytes}) => {
  'relid': '$oid',
  'schema': 'shop',
  'name': name,
  'relkind': relkind,
  'relispartition': 'f',
  'schema_oid': '$shopOid',
  'total_bytes': bytes == null ? null : '$bytes',
};

CatalogRow _tableHeader(
  int oid,
  String name, {
  bool rls = false,
  bool rlsActive = false,
  String? comment,
}) => {
  'relid': '$oid',
  'schema': 'shop',
  'name': name,
  'relkind': 'r',
  'relpersistence': 'p',
  'relispartition': 'f',
  'of_type': null,
  'partition_key': null,
  'partition_bound': null,
  'access_method': 'heap',
  'reloptions': null,
  'toast_reloptions': null,
  'tablespace': null,
  'relrowsecurity': rls ? 't' : 'f',
  'relforcerowsecurity': 'f',
  'rls_active': rlsActive ? 't' : 'f',
  'relreplident': 'd',
  'owner': 'app',
  'relacl': null,
  'comment': comment,
  'foreign_server': null,
  'foreign_options': null,
};

CatalogRow _column(
  int relid,
  int attnum,
  String name,
  String type, {
  String identity = '',
  String generated = '',
  bool notNull = false,
  String? defaultExpr,
}) => {
  'relid': '$relid',
  'attnum': '$attnum',
  'attname': name,
  'type': type,
  'attnotnull': notNull ? 't' : 'f',
  'attidentity': identity,
  'attgenerated': generated,
  'default_or_generation_expr': defaultExpr,
  'collation': null,
  'attislocal': 't',
  'attinhcount': '0',
  'attcompression': '',
  'attfdwoptions': null,
  'comment': null,
};

CatalogRow _constraint(
  int relid,
  String name,
  String type,
  String def, {
  int confrelid = 0,
}) => {
  'relid': '$relid',
  'oid': '${relid + 1000}',
  'conname': name,
  'contype': type,
  'conislocal': 't',
  'convalidated': 't',
  'connoinherit': 'f',
  'attnum': null,
  'confrelid': '$confrelid',
  'def': def,
  'comment': null,
};

CatalogRow _sequence(
  int oid,
  String name, {
  required String ownedKind,
  required String table,
  required int tableOid,
  required String column,
  required String? lastValue,
}) => {
  'relid': '$oid',
  'schema': 'shop',
  'name': name,
  'relpersistence': 'p',
  'data_type': 'bigint',
  'seqstart': '1',
  'seqincrement': '1',
  'seqmin': '1',
  'seqmax': '9223372036854775807',
  'seqcache': '1',
  'seqcycle': 'f',
  'owned_kind': ownedKind,
  'owned_by_schema': 'shop',
  'owned_by_table': table,
  'owned_by_column': column,
  'owned_by_relid': '$tableOid',
  'owner': 'app',
  'relacl': null,
  'comment': null,
  'readable': 't',
  'last_value': lastValue,
};

CatalogRow _type(int oid, String name, String kind, CatalogRow extra) => {
  'relid': '$oid',
  'schema': 'shop',
  'name': name,
  'typtype': kind,
  'base_type': null,
  'typnotnull': 'f',
  'typdefault': null,
  'collation': null,
  'range_subtype': null,
  'range_opclass': null,
  'range_collation': null,
  'range_canonical': null,
  'range_subdiff': null,
  'range_multirange': null,
  'enum_labels': null,
  'comment': null,
  ...extra,
};

CatalogRow _edge(
  String kind,
  int key,
  String refKind,
  int refKey, {
  String via = 'class',
  int attnum = 0,
}) => {
  'kind': kind,
  'key': '$key',
  'via': via,
  'attnum': '$attnum',
  'ref_kind': refKind,
  'ref_key': '$refKey',
};
