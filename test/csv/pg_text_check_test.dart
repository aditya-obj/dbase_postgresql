// File: pg_text_check_test.dart
// Purpose: checkPgText (client-side pre-checks by type) and inferPgType
// (column types for a new table).

import 'package:dbase_postgresql/csv.dart';
import 'package:test/test.dart';

void main() {
  group('checkPgText', () {
    test('integers with range', () {
      expect(checkPgText('integer', ' 42 '), PgTextCheck.ok);
      expect(checkPgText('int4', '-2147483648'), PgTextCheck.ok);
      expect(checkPgText('integer', '2147483648'), PgTextCheck.outOfRange);
      expect(checkPgText('smallint', '40000'), PgTextCheck.outOfRange);
      expect(checkPgText('bigint', '9223372036854775807'), PgTextCheck.ok);
      expect(checkPgText('integer', '12x'), PgTextCheck.invalid);
      expect(checkPgText('integer', '1.5'), PgTextCheck.invalid);
      // PostgreSQL 16+ only: left to the server.
      expect(checkPgText('integer', '1_000'), isNull);
      expect(checkPgText('integer', '0x1F'), isNull);
    });

    test('numeric and floats', () {
      expect(checkPgText('numeric(10,2)', '-1.50'), PgTextCheck.ok);
      expect(checkPgText('numeric', 'NaN'), PgTextCheck.ok);
      expect(checkPgText('double precision', '1e-5'), PgTextCheck.ok);
      expect(checkPgText('real', '-Infinity'), PgTextCheck.ok);
      expect(checkPgText('real', 'inf'), PgTextCheck.ok);
      expect(checkPgText('numeric', 'abc'), PgTextCheck.invalid);
      expect(checkPgText('float8', '1,5'), PgTextCheck.invalid);
    });

    test('booleans in PostgreSQL spellings', () {
      for (final v in ['t', 'TRUE', 'y', 'yes', 'on', 'off', '1', '0', 'f']) {
        expect(checkPgText('boolean', v), PgTextCheck.ok, reason: v);
      }
      expect(checkPgText('boolean', 'o'), PgTextCheck.invalid);
      expect(checkPgText('bool', 'maybe'), PgTextCheck.invalid);
    });

    test('uuid and json', () {
      expect(
        checkPgText('uuid', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'),
        PgTextCheck.ok,
      );
      expect(
        checkPgText('uuid', '{a0eebc999c0b4ef8bb6d6bb9bd380a11}'),
        PgTextCheck.ok,
      );
      expect(checkPgText('uuid', 'nope'), PgTextCheck.invalid);
      expect(checkPgText('jsonb', '{"a": [1, null]}'), PgTextCheck.ok);
      expect(checkPgText('json', '{a:1}'), PgTextCheck.invalid);
    });

    test('ISO dates and timestamps; other styles left to the server', () {
      expect(checkPgText('date', '2024-02-29'), PgTextCheck.ok);
      expect(checkPgText('date', '2023-02-29'), PgTextCheck.invalid);
      expect(checkPgText('date', 'infinity'), PgTextCheck.ok);
      expect(checkPgText('date', '05/06/2026'), isNull);
      expect(
        checkPgText('timestamp with time zone', '2026-10-18T09:30:00+05:30'),
        PgTextCheck.ok,
      );
      expect(
        checkPgText('timestamp(3) without time zone', '2026-10-18 25:00'),
        PgTextCheck.invalid,
      );
      expect(checkPgText('timestamptz', '2026-10-18'), PgTextCheck.ok);
    });

    test('other types are not checked', () {
      expect(checkPgText('text', 'anything'), isNull);
      expect(checkPgText('interval', '1 day'), isNull);
      expect(checkPgText('my_enum', 'x'), isNull);
    });
  });

  group('inferPgType', () {
    test('the narrowest type every value fits', () {
      expect(inferPgType(['1', '2', null, '']), 'bigint');
      expect(inferPgType(['1', '2.5']), 'numeric');
      expect(inferPgType(['1e3', '2']), 'double precision');
      expect(inferPgType(['true', 'F']), 'boolean');
      expect(inferPgType(['2026-01-01', '2026-12-31']), 'date');
      expect(
        inferPgType(['2026-01-01 10:00', '2026-01-02T11:00:00Z']),
        'timestamptz',
      );
      expect(inferPgType(['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']), 'uuid');
      expect(inferPgType(['{"a":1}', '[1]']), 'jsonb');
      expect(inferPgType(['1', 'x']), 'text');
    });

    test('leading zeros stay text, 0/1 are numbers, nothing is text', () {
      expect(inferPgType(['007', '123']), 'text');
      expect(inferPgType(['0.5', '00.5']), 'text');
      expect(inferPgType(['0', '1']), 'bigint');
      expect(inferPgType([null, '']), 'text');
      expect(inferPgType(['99999999999999999999']), 'numeric');
    });
  });
}
