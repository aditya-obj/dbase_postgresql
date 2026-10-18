import 'package:dbase_postgresql/ddl.dart';
import 'package:test/test.dart';

import 'table_ddl_test_rows.dart';

const pg17 = TableDdlAssembler(serverVersionNum: 170004);

void main() {
  group('partitioning', () {
    test('partitioned parent gets PARTITION BY', () {
      final ddl = pg17.assemble(
        TableDdlSource(
          header: headerRow({
            'name': 'measure',
            'relkind': 'p',
            'access_method': null,
            'partition_key': 'RANGE (logdate)',
          }),
          columns: [
            columnRow(1, 'logdate', 'date', {'attnotnull': 't'}),
          ],
        ),
      );
      expect(
        ddl,
        startsWith(
          'CREATE TABLE public.measure (\n'
          '    logdate date NOT NULL\n'
          ')\n'
          'PARTITION BY RANGE (logdate);\n',
        ),
      );
    });

    test('partition: PARTITION OF parent FOR VALUES, no column list', () {
      final ddl = pg17.assemble(
        TableDdlSource(
          header: headerRow({
            'name': 'measure_2026',
            'relispartition': 't',
            'partition_bound':
                "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
          }),
          parents: [
            ParentRow.fromRow({
              'schema': 'public',
              'name': 'measure',
              'inhseqno': '1',
            }),
          ],
          columns: [
            columnRow(1, 'logdate', 'date', {
              'attnotnull': 't',
              'attislocal': 'f',
              'comment': 'day',
            }),
          ],
          constraints: [
            constraintRow('measure_pkey', 'p', 'PRIMARY KEY (logdate)', {
              'conislocal': 'f',
            }),
            constraintRow('only_here', 'c', 'CHECK (true)'),
          ],
        ),
      );
      expect(
        ddl,
        startsWith(
          'CREATE TABLE public.measure_2026 PARTITION OF public.measure (\n'
          '    CONSTRAINT only_here CHECK (true)\n'
          ')\n'
          "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');\n",
        ),
      );
      expect(ddl, isNot(contains('logdate date')));
      expect(ddl, isNot(contains('measure_pkey')));
      // Column comments still apply to the partition's own columns.
      expect(
        ddl,
        contains("COMMENT ON COLUMN public.measure_2026.logdate IS 'day';"),
      );
    });

    test('default partition', () {
      final ddl = pg17.assemble(
        TableDdlSource(
          header: headerRow({
            'name': 'm_other',
            'relispartition': 't',
            'partition_bound': 'DEFAULT',
          }),
          parents: [
            ParentRow.fromRow({'schema': 'public', 'name': 'm'}),
          ],
        ),
      );
      expect(
        ddl,
        startsWith(
          'CREATE TABLE public.m_other PARTITION OF public.m\nDEFAULT;',
        ),
      );
    });
  });

  test('inheritance child: only local columns, INHERITS in order', () {
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow({'name': 'child'}),
        parents: [
          ParentRow.fromRow({'schema': 'public', 'name': 'base'}),
          ParentRow.fromRow({'schema': 'other', 'name': 'Audit'}),
        ],
        columns: [
          columnRow(1, 'a', 'integer', {'attislocal': 'f'}),
          columnRow(2, 'c', 'integer'),
        ],
      ),
    );
    expect(
      ddl,
      startsWith(
        'CREATE TABLE public.child (\n'
        '    c integer\n'
        ')\n'
        'INHERITS (public.base, other."Audit");\n',
      ),
    );
  });

  test('RLS enable/force, then policies', () {
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow({'relrowsecurity': 't', 'relforcerowsecurity': 't'}),
        policies: [
          PolicyRow.fromRow({
            'polname': 'own rows',
            'polpermissive': 't',
            'polcmd': '*',
            'roles': '{PUBLIC}',
            'using_expr': '(owner = CURRENT_USER)',
            'check_expr': '(owner = CURRENT_USER)',
          }),
          PolicyRow.fromRow({
            'polname': 'no_delete',
            'polpermissive': 'f',
            'polcmd': 'd',
            // Server text of ARRAY[quote_ident(...)]: quotes are escaped.
            'roles': r'{alice,"\"Bob Role\""}',
            'using_expr': 'false',
            'check_expr': null,
          }),
        ],
      ),
    );
    expect(
      ddl,
      contains(
        'ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;\n'
        'ALTER TABLE public.orders FORCE ROW LEVEL SECURITY;\n'
        'CREATE POLICY "own rows" ON public.orders AS PERMISSIVE\n'
        '  FOR ALL\n'
        '  TO PUBLIC\n'
        '  USING ((owner = CURRENT_USER))\n'
        '  WITH CHECK ((owner = CURRENT_USER));\n'
        'CREATE POLICY no_delete ON public.orders AS RESTRICTIVE\n'
        '  FOR DELETE\n'
        '  TO alice, "Bob Role"\n'
        '  USING (false);\n',
      ),
    );
  });

  test('triggers keep their firing state; rules and statistics follow', () {
    TriggerRow trigger(String name, String enabled) => TriggerRow.fromRow({
      'tgname': name,
      'def':
          'CREATE TRIGGER $name AFTER INSERT ON public.orders '
          'FOR EACH ROW EXECUTE FUNCTION public.f()',
      'tgenabled': enabled,
    });
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow(),
        triggers: [
          trigger('on_t', 'O'),
          trigger('off_t', 'D'),
          trigger('replica_t', 'R'),
          trigger('always_t', 'A'),
        ],
        rules: [
          RuleRow.fromRow({
            'rulename': 'r1',
            'def':
                'CREATE RULE r1 AS ON DELETE TO public.orders '
                'DO INSTEAD NOTHING;',
          }),
        ],
        statistics: const [
          'CREATE STATISTICS public.s1 (dependencies) ON a, b FROM t',
        ],
      ),
    );
    expect(ddl, contains('FOR EACH ROW EXECUTE FUNCTION public.f();\n'));
    expect(ddl, contains('ALTER TABLE public.orders DISABLE TRIGGER off_t;'));
    expect(
      ddl,
      contains('ALTER TABLE public.orders ENABLE REPLICA TRIGGER replica_t;'),
    );
    expect(
      ddl,
      contains('ALTER TABLE public.orders ENABLE ALWAYS TRIGGER always_t;'),
    );
    expect(ddl, isNot(contains('TRIGGER on_t;')));
    expect(ddl, contains('DO INSTEAD NOTHING;\nCREATE STATISTICS'));
    expect(ddl, contains('ON a, b FROM t;\n'));
  });

  test('indexes: constraint-owned skipped, invalid marked, CLUSTER ON and '
      'REPLICA IDENTITY', () {
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow({'relreplident': 'i'}),
        indexes: [
          indexRow(
            'orders_pkey',
            'CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)',
            {'is_constraint': 't', 'indisclustered': 't'},
          ),
          indexRow(
            'orders_broken',
            'CREATE UNIQUE INDEX orders_broken ON public.orders '
                'USING btree (x)',
            {'indisvalid': 'f'},
          ),
          indexRow(
            'orders_ri',
            'CREATE UNIQUE INDEX orders_ri ON public.orders USING btree (y)',
            {'indisreplident': 't'},
          ),
        ],
      ),
    );
    expect(ddl, isNot(contains('INDEX orders_pkey ON')));
    expect(
      ddl,
      contains(
        '-- INVALID (failed CREATE INDEX CONCURRENTLY)\n'
        'CREATE UNIQUE INDEX orders_broken ON public.orders USING btree (x);\n'
        'CREATE UNIQUE INDEX orders_ri ON public.orders USING btree (y);\n'
        '\n'
        'ALTER TABLE public.orders CLUSTER ON orders_pkey;\n'
        'ALTER TABLE public.orders REPLICA IDENTITY USING INDEX orders_ri;\n',
      ),
    );
  });

  test('replica identity FULL / NOTHING', () {
    expect(
      pg17.assemble(TableDdlSource(header: headerRow({'relreplident': 'f'}))),
      contains('ALTER TABLE public.orders REPLICA IDENTITY FULL;'),
    );
    expect(
      pg17.assemble(TableDdlSource(header: headerRow({'relreplident': 'n'}))),
      contains('ALTER TABLE public.orders REPLICA IDENTITY NOTHING;'),
    );
  });

  test('foreign table: SERVER, OPTIONS and column OPTIONS', () {
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow({
          'relkind': 'f',
          'access_method': null,
          'foreign_server': 'remote',
          'foreign_options': '{schema_name=public,table_name=orders}',
          'comment': 'remote orders',
        }),
        columns: [
          columnRow(1, 'id', 'integer', {
            'attfdwoptions': '{column_name=order_id}',
            'attnotnull': 't',
          }),
        ],
      ),
    );
    expect(
      ddl,
      startsWith(
        'CREATE FOREIGN TABLE public.orders (\n'
        "    id integer OPTIONS (column_name 'order_id') NOT NULL\n"
        ')\n'
        'SERVER remote\n'
        "OPTIONS (schema_name 'public', table_name 'orders');\n",
      ),
    );
    expect(ddl, contains('ALTER FOREIGN TABLE public.orders OWNER TO app;'));
    expect(ddl, contains('COMMENT ON FOREIGN TABLE public.orders IS'));
  });

  test('typed table: OF type, only columns with options', () {
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow({'of_type': 'public.order_t'}),
        columns: [
          columnRow(1, 'id', 'integer', {'attnotnull': 't'}),
          columnRow(2, 'note', 'text'),
        ],
      ),
    );
    expect(
      ddl,
      startsWith(
        'CREATE TABLE public.orders OF public.order_t (\n'
        '    id WITH OPTIONS NOT NULL\n'
        ');\n',
      ),
    );
  });

  test('assembly order follows §3.4', () {
    final ddl = pg17.assemble(
      TableDdlSource(
        header: headerRow({
          'relrowsecurity': 't',
          'relacl': '{}',
          'comment': 'c',
          'relreplident': 'f',
        }),
        constraints: [
          constraintRow('fk', 'f', 'FOREIGN KEY (a) REFERENCES public.x(a)'),
        ],
        indexes: [indexRow('i', 'CREATE INDEX i ON public.orders (a)')],
        triggers: [
          TriggerRow.fromRow({
            'tgname': 't',
            'def': 'CREATE TRIGGER t',
            'tgenabled': 'O',
          }),
        ],
        grants: [grantRow('r', 'SELECT')],
      ),
    );
    final markers = [
      'CREATE TABLE',
      'ADD CONSTRAINT fk',
      'CREATE INDEX i',
      'REPLICA IDENTITY',
      'CREATE TRIGGER t',
      'ENABLE ROW LEVEL SECURITY',
      'OWNER TO',
      'GRANT SELECT',
      'COMMENT ON TABLE',
    ];
    final positions = [for (final m in markers) ddl.indexOf(m)];
    expect(positions, everyElement(isNonNegative));
    expect(positions, orderedEquals([...positions]..sort()));
  });

  test('IndexRow and GrantRow defaults', () {
    final index = IndexRow.fromRow({'name': 'i', 'def': 'CREATE INDEX i'});
    expect(index.isValid, isTrue);
    expect(index.isConstraintIndex, isFalse);
    expect(grantRow('x', 'SELECT').isOwner, isFalse);
  });
}
