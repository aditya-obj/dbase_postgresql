import 'package:dabase_postgresql/catalog.dart';
import 'package:dabase_postgresql/ddl.dart';
import 'package:test/test.dart';

import 'table_ddl_test_rows.dart';

ViewHeader viewRow([CatalogRow extra = const {}]) => ViewHeader.fromRow({
  'schema': 'public',
  'name': 'active_orders',
  'relkind': 'v',
  'reloptions': null,
  'access_method': null,
  'tablespace': null,
  'relispopulated': 't',
  'def': ' SELECT id\n   FROM public.orders\n  WHERE qty > 0;',
  'owner': 'app',
  'relacl': null,
  'comment': null,
  ...extra,
});

SequenceRow sequenceRow([CatalogRow extra = const {}]) => SequenceRow.fromRow({
  'schema': 'public',
  'name': 'orders_id_seq',
  'relpersistence': 'p',
  'data_type': 'integer',
  'seqstart': '1',
  'seqincrement': '1',
  'seqmin': '1',
  'seqmax': '2147483647',
  'seqcache': '1',
  'seqcycle': 'f',
  'owned_kind': null,
  'owned_by_schema': null,
  'owned_by_table': null,
  'owned_by_column': null,
  'owner': 'app',
  'relacl': null,
  'comment': null,
  ...extra,
});

void main() {
  const views = ViewDdlAssembler();

  group('views', () {
    test('check option moves out of WITH; security_invoker stays', () {
      final ddl = views.assemble(
        ViewDdlSource(
          header: viewRow({
            'reloptions': '{security_invoker=true,check_option=local}',
          }),
        ),
      );
      expect(
        ddl,
        'CREATE OR REPLACE VIEW public.active_orders '
        'WITH (security_invoker=true) AS\n'
        ' SELECT id\n'
        '   FROM public.orders\n'
        '  WHERE qty > 0\n'
        '  WITH LOCAL CHECK OPTION;\n'
        '\n'
        'ALTER VIEW public.active_orders OWNER TO app;\n',
      );
    });

    test('plain view keeps the viewdef semicolon; triggers, rules, '
        'grants and comments follow', () {
      final ddl = views.assemble(
        ViewDdlSource(
          header: viewRow({'relacl': '{}', 'comment': 'view'}),
          columnComments: [
            ColumnCommentRow.fromRow({'attname': 'id', 'comment': 'key'}),
          ],
          triggers: [
            TriggerRow.fromRow({
              'tgname': 'ins',
              'def':
                  'CREATE TRIGGER ins INSTEAD OF INSERT ON '
                  'public.active_orders FOR EACH ROW '
                  'EXECUTE FUNCTION public.f()',
              'tgenabled': 'D',
            }),
          ],
          rules: [
            RuleRow.fromRow({
              'rulename': 'r',
              'def':
                  'CREATE RULE r AS ON DELETE TO public.active_orders '
                  'DO INSTEAD NOTHING;',
            }),
          ],
          grants: [grantRow('reader', 'SELECT')],
        ),
      );
      expect(ddl, contains('  WHERE qty > 0;\n\nCREATE TRIGGER ins'));
      expect(
        ddl,
        contains('ALTER TABLE public.active_orders DISABLE TRIGGER ins;'),
      );
      expect(ddl, contains('DO INSTEAD NOTHING;\n'));
      expect(
        ddl,
        contains('GRANT SELECT ON TABLE public.active_orders TO reader;'),
      );
      expect(ddl, contains("COMMENT ON VIEW public.active_orders IS 'view';"));
      expect(
        ddl,
        contains("COMMENT ON COLUMN public.active_orders.id IS 'key';"),
      );
    });

    test('materialized view WITH NO DATA, options and indexes', () {
      final ddl = views.assemble(
        ViewDdlSource(
          header: viewRow({
            'name': 'mv',
            'relkind': 'm',
            'access_method': 'heap',
            'reloptions': '{fillfactor=90}',
            'tablespace': 'fast',
            'relispopulated': 'f',
            'comment': 'snapshot',
          }),
          indexes: [indexRow('mv_id', 'CREATE INDEX mv_id ON public.mv (id)')],
        ),
      );
      expect(
        ddl,
        'CREATE MATERIALIZED VIEW public.mv WITH (fillfactor=90) '
        'TABLESPACE fast AS\n'
        ' SELECT id\n'
        '   FROM public.orders\n'
        '  WHERE qty > 0\n'
        'WITH NO DATA;\n'
        '\n'
        'CREATE INDEX mv_id ON public.mv (id);\n'
        '\n'
        'ALTER MATERIALIZED VIEW public.mv OWNER TO app;\n'
        '\n'
        "COMMENT ON MATERIALIZED VIEW public.mv IS 'snapshot';\n",
      );
    });

    test('populated materialized view says WITH DATA', () {
      final ddl = views.assemble(
        ViewDdlSource(header: viewRow({'relkind': 'm', 'name': 'mv'})),
      );
      expect(ddl, contains('\nWITH DATA;\n'));
    });
  });

  group('routines', () {
    const routines = RoutineDdlAssembler();

    test('function: def trimmed and terminated; owner, grants, comment', () {
      final ddl = routines.assemble(
        RoutineHeader.fromRow({
          'schema': 'public',
          'name': 'add one',
          'prokind': 'f',
          'identity_args': 'x integer',
          'def':
              'CREATE OR REPLACE FUNCTION public."add one"(x integer)\n'
              ' RETURNS integer\n LANGUAGE sql\n'
              'AS \$function\$select x + 1\$function\$\n',
          'owner': 'app',
          'proacl': '{=X/app}',
          'comment': 'adds',
        }),
        grants: [
          grantRow('PUBLIC', 'EXECUTE'),
          grantRow('app', 'EXECUTE', owner: true),
        ],
      );
      expect(
        ddl,
        'CREATE OR REPLACE FUNCTION public."add one"(x integer)\n'
        ' RETURNS integer\n'
        ' LANGUAGE sql\n'
        'AS \$function\$select x + 1\$function\$;\n'
        '\n'
        'ALTER FUNCTION public."add one"(x integer) OWNER TO app;\n'
        '\n'
        'GRANT EXECUTE ON FUNCTION public."add one"(x integer) TO PUBLIC;\n'
        '\n'
        "COMMENT ON FUNCTION public.\"add one\"(x integer) IS 'adds';\n",
      );
    });

    test('procedure uses PROCEDURE in ALTER, GRANT and COMMENT', () {
      final ddl = routines.assemble(
        RoutineHeader.fromRow({
          'schema': 'public',
          'name': 'p',
          'prokind': 'p',
          'identity_args': 'IN n integer',
          'def':
              'CREATE OR REPLACE PROCEDURE public.p(IN n integer)\n'
              ' LANGUAGE sql\nAS \$procedure\$select n\$procedure\$',
          'owner': 'app',
          'comment': 'c',
        }),
        grants: [grantRow('bob', 'EXECUTE')],
      );
      expect(ddl, contains('ALTER PROCEDURE public.p(IN n integer) OWNER'));
      expect(
        ddl,
        contains('GRANT EXECUTE ON PROCEDURE public.p(IN n integer)'),
      );
      expect(ddl, contains('COMMENT ON PROCEDURE public.p(IN n integer)'));
    });

    test('aggregate is shown as a note, not CREATE AGGREGATE', () {
      final ddl = routines.assemble(
        RoutineHeader.fromRow({
          'schema': 'public',
          'name': 'my_sum',
          'prokind': 'a',
          'identity_args': 'integer',
          'def': null,
          'owner': 'app',
        }),
        aggregate: AggregateRow.fromRow({
          'aggkind': 'n',
          'sfunc': 'int4pl',
          'stype': 'integer',
          'finalfunc': null,
          'combinefunc': 'int4pl',
          'initcond': '0',
        }),
      );
      expect(
        ddl,
        startsWith(
          '-- aggregate public.my_sum(integer)\n'
          '-- CREATE AGGREGATE is not generated; its definition:\n'
          '--   sfunc: int4pl\n'
          '--   stype: integer\n'
          '--   combinefunc: int4pl\n'
          "--   initcond: '0'\n",
        ),
      );
      expect(ddl, isNot(contains('CREATE AGGREGATE public')));
      expect(
        ddl,
        contains('ALTER AGGREGATE public.my_sum(integer) OWNER TO app;'),
      );
    });
  });

  group('sequences', () {
    const sequences = SequenceDdlAssembler();

    test('fully explicit CREATE SEQUENCE with OWNED BY', () {
      final ddl = sequences.assemble(
        sequenceRow({
          'owned_kind': 'a',
          'owned_by_schema': 'public',
          'owned_by_table': 'Orders',
          'owned_by_column': 'id',
          'relacl': '{}',
          'comment': 'ids',
        }),
        grants: [
          grantRow('reader', 'USAGE'),
          grantRow('app', 'SELECT', owner: true),
        ],
      );
      expect(
        ddl,
        'CREATE SEQUENCE public.orders_id_seq\n'
        '    AS integer\n'
        '    START WITH 1\n'
        '    INCREMENT BY 1\n'
        '    MINVALUE 1\n'
        '    MAXVALUE 2147483647\n'
        '    CACHE 1\n'
        '    NO CYCLE;\n'
        '\n'
        'ALTER SEQUENCE public.orders_id_seq OWNED BY public."Orders".id;\n'
        '\n'
        'ALTER SEQUENCE public.orders_id_seq OWNER TO app;\n'
        '\n'
        'GRANT USAGE ON SEQUENCE public.orders_id_seq TO reader;\n'
        '\n'
        "COMMENT ON SEQUENCE public.orders_id_seq IS 'ids';\n",
      );
    });

    test('unlogged cycling sequence with negative bounds', () {
      final ddl = sequences.assemble(
        sequenceRow({
          'relpersistence': 'u',
          'data_type': 'bigint',
          'seqincrement': '-1',
          'seqmin': '-9223372036854775808',
          'seqmax': '-1',
          'seqstart': '-1',
          'seqcycle': 't',
        }),
      );
      expect(
        ddl,
        startsWith('CREATE UNLOGGED SEQUENCE public.orders_id_seq\n'),
      );
      expect(ddl, contains('MINVALUE -9223372036854775808\n'));
      expect(ddl, contains('    CYCLE;\n'));
    });

    test('identity sequence shows only a note', () {
      final ddl = sequences.assemble(
        sequenceRow({
          'owned_kind': 'i',
          'owned_by_schema': 'public',
          'owned_by_table': 'orders',
          'owned_by_column': 'id',
        }),
      );
      expect(
        ddl,
        '-- public.orders_id_seq is the identity sequence of column '
        'public.orders.id.\n'
        "-- It is created by the column's GENERATED ... AS IDENTITY clause;\n"
        "-- see that table's DDL.\n",
      );
    });
  });

  group('indexes', () {
    const indexes = IndexDdlAssembler();

    test('index def terminated, with comment', () {
      final ddl = indexes.assemble(
        IndexHeader.fromRow({
          'schema': 'public',
          'name': 'Orders Idx',
          'def': 'CREATE INDEX "Orders Idx" ON public.orders USING btree (a)',
          'indisvalid': 't',
          'comment': 'by a',
        }),
      );
      expect(
        ddl,
        'CREATE INDEX "Orders Idx" ON public.orders USING btree (a);\n'
        '\n'
        "COMMENT ON INDEX public.\"Orders Idx\" IS 'by a';\n",
      );
    });

    test('invalid index is marked', () {
      final ddl = indexes.assemble(
        IndexHeader.fromRow({
          'schema': 'public',
          'name': 'i',
          'def': 'CREATE UNIQUE INDEX i ON public.t USING btree (v)',
          'indisvalid': 'f',
        }),
      );
      expect(
        ddl,
        '-- INVALID (failed CREATE INDEX CONCURRENTLY)\n'
        'CREATE UNIQUE INDEX i ON public.t USING btree (v);\n',
      );
    });
  });
}
