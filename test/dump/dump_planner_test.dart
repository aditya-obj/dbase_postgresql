// File: dump_planner_test.dart
// Purpose: Dump sections and ordering: pg_depend order with priorities,
// keys and foreign keys after the data, a default that calls a function
// in a cycle moved to its own ALTER, cycles reported, data-only and
// schema-only content, and the rendered text of each section.

import 'package:dabase_postgresql/catalog.dart';
import 'package:dabase_postgresql/ddl.dart';
import 'package:dabase_postgresql/dump.dart';
import 'package:test/test.dart';

import '../ddl/table_ddl_test_rows.dart';
import '../support/catalog_fixture.dart';

Future<SchemaModel> shopModel({bool includeGrants = false}) async {
  final server = FakeCatalog();
  final reader = CatalogReader(server.query, serverVersionNum: pg17);
  const scope = CatalogScope.schemas([shopOid], wholeDatabase: true);
  final listing = await reader.listRelations(scope);
  return await reader.read(scope, listing, includeGrants: includeGrants);
}

DumpPlan plan(
  SchemaModel model, [
  DumpContent content = DumpContent.schemaAndData,
]) => const DumpPlanner().plan(
  model,
  DumpOptions(scope: const CatalogScope.schemas([shopOid]), content: content),
);

String toc(DumpItem i) => '${i.type} ${i.name}';

void main() {
  group('shop fixture, schema and data', () {
    late DumpPlan p;
    setUp(() async => p = plan(await shopModel()));

    test('pre-data follows dependencies, then priority, then name', () {
      expect(p.preData.map(toc), [
        'SCHEMA shop',
        'EXTENSION pgcrypto',
        'TYPE mood',
        'DOMAIN posint',
        'AGGREGATE my_sum(integer)',
        'SEQUENCE order_no',
        'TABLE customers',
        'TABLE orders',
        'FUNCTION total(o shop.orders)',
        'VIEW order_view',
        'SEQUENCE OWNED BY order_no',
      ]);
      expect(p.warnings, isEmpty);
    });

    test('CREATE TABLE keeps checks and defaults but not keys or foreign '
        'keys', () {
      final orders = p.preData.firstWhere((i) => i.name == 'orders');
      expect(
        orders.statements.single,
        'CREATE TABLE shop.orders (\n'
        '    id bigint NOT NULL,\n'
        '    customer_id bigint,\n'
        "    no integer DEFAULT nextval('shop.order_no'::regclass),\n"
        '    total integer GENERATED ALWAYS AS ((no * 2)) STORED\n'
        ');',
      );
    });

    test('types, aggregates, schemas and extensions', () {
      String sql(String name) =>
          p.preData.firstWhere((i) => i.name == name).statements.join('\n');
      expect(sql('shop'), 'CREATE SCHEMA IF NOT EXISTS shop;');
      expect(
        sql('pgcrypto'),
        'CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA shop;',
      );
      expect(
        sql('mood'),
        "CREATE TYPE shop.mood AS ENUM (\n    'happy',\n    'sad'\n);",
      );
      expect(
        sql('posint'),
        'CREATE DOMAIN shop.posint AS integer\n'
        '    NOT NULL\n'
        '    CONSTRAINT posint_check CHECK (VALUE > 0);',
      );
      expect(
        sql('my_sum(integer)'),
        'CREATE AGGREGATE shop.my_sum(integer) (\n'
        '    SFUNC = int4pl,\n'
        '    STYPE = integer,\n'
        "    INITCOND = '0',\n"
        '    PARALLEL = SAFE\n'
        ');',
      );
      expect(sql('total(o shop.orders)'), endsWith(r'$function$;'));
      expect(
        sql('order_view'),
        'CREATE OR REPLACE VIEW shop.order_view AS\n'
        ' SELECT id,\n    shop.total(o.*) AS total\n   FROM shop.orders o;',
      );
    });

    test('data in foreign-key order, with sequence values', () {
      expect([for (final t in p.dataTables) t.name], ['customers', 'orders']);
      const setval = 'SELECT pg_catalog.setval';
      const customersId = "'shop.customers', 'id'";
      expect(
        [for (final i in p.sequenceValues) i.statements.single],
        [
          '$setval(pg_catalog.pg_get_serial_sequence($customersId), 7, true);',
          "SELECT pg_catalog.setval('shop.order_no', 1, false);",
        ],
      );
    });

    test('post-data: indexes, keys, foreign keys, triggers, RLS, '
        'comments', () {
      expect(p.postData.map(toc), [
        'INDEX orders',
        'CONSTRAINT customers',
        'CONSTRAINT orders',
        'FK CONSTRAINT orders',
        'TRIGGER orders',
        'ROW SECURITY orders',
        'COMMENT shop',
        'COMMENT total(o shop.orders)',
        'COMMENT orders',
      ]);
      String sql(String type, String name) => p.postData
          .firstWhere((i) => i.type == type && i.name == name)
          .statements
          .join('\n');
      expect(
        sql('CONSTRAINT', 'orders'),
        'ALTER TABLE shop.orders ADD CONSTRAINT orders_pkey PRIMARY KEY (id);',
      );
      expect(
        sql('FK CONSTRAINT', 'orders'),
        'ALTER TABLE shop.orders ADD CONSTRAINT orders_customer_fk FOREIGN '
        'KEY (customer_id) REFERENCES shop.customers(id);',
      );
      expect(
        sql('ROW SECURITY', 'orders'),
        'ALTER TABLE shop.orders ENABLE ROW LEVEL SECURITY;\n'
        'CREATE POLICY own_rows ON shop.orders AS PERMISSIVE\n'
        '  FOR SELECT\n  TO PUBLIC\n  USING ((customer_id > 0));',
      );
      expect(
        sql('COMMENT', 'total(o shop.orders)'),
        'COMMENT ON FUNCTION shop.total(o shop.orders) IS '
        "'Order total';",
      );
      // No ownership anywhere.
      final everything = [
        for (final i in [...p.preData, ...p.postData]) ...i.statements,
      ].join('\n');
      expect(everything, isNot(contains('OWNER TO')));
      expect(everything, isNot(contains('GRANT')));
    });
  });

  test('schema only: no data, no sequence values', () async {
    final p = plan(await shopModel(), DumpContent.schemaOnly);
    expect(p.preData, isNotEmpty);
    expect(p.dataTables, isEmpty);
    expect(p.sequenceValues, isEmpty);
  });

  test('data only: no DDL', () async {
    final p = plan(await shopModel(), DumpContent.dataOnly);
    expect(p.preData, isEmpty);
    expect(p.postData, isEmpty);
    expect(p.dataTables, hasLength(2));
    expect(p.sequenceValues, hasLength(2));
  });

  test('a default calling a function caught in a cycle with its table is '
      'moved after both', () {
    const table = ObjectKey(ObjectKind.relation, 100);
    const function = ObjectKey(ObjectKind.routine, 200);
    final model = SchemaModel(
      serverVersionNum: pg17,
      tables: [
        TableInfo(
          oid: 100,
          source: TableDdlSource(
            header: headerRow({'schema': 's', 'name': 't'}),
            columns: [
              columnRow(1, 'id', 'integer'),
              columnRow(2, 'v', 'integer', {
                'default_or_generation_expr': 's.f()',
              }),
            ],
          ),
        ),
      ],
      routines: const [
        RoutineInfo(
          oid: 200,
          header: RoutineHeader(
            schema: 's',
            name: 'f',
            identityArgs: '',
            def:
                'CREATE OR REPLACE FUNCTION s.f()\n RETURNS integer\n'
                ' LANGUAGE sql\nBEGIN ATOMIC\n SELECT count(*) FROM s.t;\nEND',
          ),
        ),
      ],
      dependencies: const [
        DependencyEdge(table, function, defaultOfColumn: 2),
        DependencyEdge(function, table),
      ],
    );
    final p = plan(model, DumpContent.schemaOnly);
    expect(p.warnings, isEmpty);
    expect(p.preData.map(toc), ['TABLE t', 'FUNCTION f()', 'DEFAULT t']);
    expect(p.preData.first.statements.single, isNot(contains('DEFAULT')));
    expect(
      p.preData.last.statements.single,
      'ALTER TABLE s.t ALTER COLUMN v SET DEFAULT s.f();',
    );
    expect(p.preData.any((i) => i.inCycle), isFalse);
  });

  test('an unbreakable cycle is written in priority order and reported', () {
    const view = ObjectKey(ObjectKind.relation, 300);
    const function = ObjectKey(ObjectKind.routine, 400);
    const model = SchemaModel(
      serverVersionNum: pg17,
      views: [
        ViewInfo(
          oid: 300,
          source: ViewDdlSource(
            header: ViewHeader(schema: 's', name: 'v', def: ' SELECT 1;'),
          ),
        ),
      ],
      routines: [
        RoutineInfo(
          oid: 400,
          header: RoutineHeader(
            schema: 's',
            name: 'g',
            identityArgs: '',
            def: 'CREATE FUNCTION s.g() RETURNS SETOF s.v BEGIN ATOMIC END',
          ),
        ),
      ],
      dependencies: [
        DependencyEdge(view, function),
        DependencyEdge(function, view),
      ],
    );
    final p = plan(model, DumpContent.schemaOnly);
    expect(p.preData.map(toc), ['FUNCTION g()', 'VIEW v']);
    expect(p.preData.first.inCycle, isTrue);
    expect(p.warnings.single.code, DumpWarningCode.dependencyCycle);
    expect(p.warnings.single.subjects, ['s.g()', 's.v']);
  });

  test('foreign keys to tables outside the dump are reported', () {
    final model = SchemaModel(
      serverVersionNum: pg17,
      tables: [
        TableInfo(
          oid: 1,
          source: TableDdlSource(
            header: headerRow({'schema': 'public', 'name': 'profiles'}),
            constraints: [
              constraintRow(
                'profiles_user_fk',
                'f',
                'FOREIGN KEY (user_id) REFERENCES auth.users(id)',
                {'confrelid': '999'},
              ),
            ],
          ),
        ),
      ],
    );
    final p = plan(model);
    expect(p.warnings.single.code, DumpWarningCode.outsideReference);
    expect(p.warnings.single.subjects, ['public.profiles -> auth.users']);
  });

  test('partitioned indexes are created without ONLY so they recurse', () {
    final model = SchemaModel(
      serverVersionNum: pg17,
      tables: [
        TableInfo(
          oid: 1,
          source: TableDdlSource(
            header: headerRow({
              'name': 'measure',
              'relkind': 'p',
              'partition_key': 'RANGE (d)',
            }),
            indexes: [
              indexRow(
                'measure_d_idx',
                'CREATE INDEX measure_d_idx ON ONLY public.measure USING '
                    'btree (d)',
              ),
            ],
          ),
        ),
      ],
    );
    final p = plan(model, DumpContent.schemaOnly);
    expect(
      p.postData.single.statements.single,
      'CREATE INDEX measure_d_idx ON public.measure USING btree (d);',
    );
  });

  test('grants when asked', () async {
    const defaults = 'ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA public';
    final model = SchemaModel(
      serverVersionNum: pg17,
      tables: [
        TableInfo(
          oid: 1,
          source: TableDdlSource(
            header: headerRow(),
            grants: [
              grantRow('reader', 'SELECT'),
              grantRow('app', 'ALL', owner: true),
            ],
          ),
        ),
      ],
      defaultPrivileges: const [
        DefaultPrivilegeRow(
          role: 'app',
          schema: 'public',
          objectType: 'r',
          grantee: 'reader',
          privilege: 'SELECT',
        ),
      ],
    );
    final p = const DumpPlanner().plan(
      model,
      const DumpOptions(
        scope: CatalogScope.schemas([1]),
        content: DumpContent.schemaOnly,
        includeGrants: true,
      ),
    );
    expect(
      [
        for (final i in p.postData)
          if (i.type == 'ACL') ...i.statements,
      ],
      [
        'GRANT SELECT ON TABLE public.orders TO reader;',
        '$defaults GRANT SELECT ON TABLES TO reader;',
      ],
    );
  });

  group('DumpWriter', () {
    test('header names no host or user, and carries the preamble', () {
      final text = const DumpWriter().start(
        DumpHeader(
          generator: 'dabase 1.0',
          serverVersion: '17.4',
          createdUtc: DateTime.utc(2026, 10, 18, 9, 5, 7),
          content: DumpContent.schemaAndData,
          skipped: const SkippedObjects(counts: {'large_objects': 2}),
          warnings: const [
            DumpWarning(DumpWarningCode.moneyColumns, ['s.t']),
          ],
          tablesNotExported: const ['s.secret'],
        ),
      );
      expect(text, contains('-- Written by: dabase 1.0\n'));
      expect(text, contains('-- Snapshot taken: 2026-10-18 09:05:07 UTC\n'));
      expect(text, contains('-- Not included: 2 large objects\n'));
      expect(
        text,
        contains('-- Data not exported (row-level security): s.secret\n'),
      );
      expect(text, contains('-- Warning: moneyColumns: s.t\n'));
      for (final line in dumpPreamble) {
        expect(text, contains('$line\n'));
      }
    });

    test('items get a TOC comment; names cannot break out of it', () {
      final text = const DumpWriter().item(
        const DumpItem(
          section: DumpSection.preData,
          type: 'TABLE',
          name: 'evil\nDROP TABLE x;',
          schema: 's',
          statements: ['CREATE TABLE s."evil\nDROP TABLE x;" ();'],
        ),
      );
      expect(
        text,
        startsWith(
          '--\n'
          r'-- Name: evil\nDROP TABLE x;; Type: TABLE; Schema: s',
        ),
      );
    });

    test('COPY block', () async {
      final model = await shopModel();
      final orders = model.tables.firstWhere((t) => t.oid == ordersOid);
      expect(
        const DumpWriter().copyStart(orders),
        '--\n-- Data for Name: orders; Type: TABLE DATA; Schema: shop\n--\n\n'
        'COPY shop.orders (id, customer_id, no) FROM stdin;\n',
      );
      expect(const DumpWriter().copyEnd(), '\\.\n\n');
    });
  });
}
