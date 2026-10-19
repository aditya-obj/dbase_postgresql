// File: redact_secrets_test.dart
// Purpose: Unit tests for redactSecrets / containsSecrets: role passwords,
// FDW password options, connection strings, and text that must stay as is.

import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

void main() {
  group('role passwords', () {
    final cases = <String, String>{
      "CREATE ROLE app LOGIN PASSWORD 's3cret'":
          "CREATE ROLE app LOGIN PASSWORD '********'",
      "ALTER ROLE app WITH ENCRYPTED PASSWORD 'it''s'":
          "ALTER ROLE app WITH ENCRYPTED PASSWORD '********'",
      r"alter user bob password E'a\'b'": "alter user bob password '********'",
      r"CREATE USER x PASSWORD $p$dollar$p$ VALID UNTIL '2030-01-01'":
          "CREATE USER x PASSWORD '********' VALID UNTIL '2030-01-01'",
      "CREATE GROUP g PASSWORD 'x'": "CREATE GROUP g PASSWORD '********'",
      r"ALTER ROLE r PASSWORD 'SCRAM-SHA-256$4096:c2FsdA==$a:b'":
          "ALTER ROLE r PASSWORD '********'",
      "ALTER ROLE r PASSWORD /* c */ 'x'":
          "ALTER ROLE r PASSWORD /* c */ '********'",
    };
    for (final MapEntry(key: input, value: expected) in cases.entries) {
      test(input, () {
        expect(redactSecrets(input), expected);
        expect(containsSecrets(input), isTrue);
      });
    }

    test('PASSWORD NULL and parameters are left alone', () {
      for (final sql in [
        'ALTER ROLE r PASSWORD NULL',
        r'ALTER ROLE r PASSWORD $1',
      ]) {
        expect(redactSecrets(sql), sql);
        expect(containsSecrets(sql), isFalse);
      }
    });

    test('an unterminated password is masked to the end', () {
      expect(
        redactSecrets("ALTER ROLE r PASSWORD 'never closed"),
        "ALTER ROLE r PASSWORD '********'",
      );
    });

    test('only in CREATE/ALTER; other statements keep a password column', () {
      const sql = "SELECT * FROM users WHERE password = 'x'";
      expect(redactSecrets(sql), sql);
      const insert = "INSERT INTO t (password) VALUES ('x')";
      expect(redactSecrets(insert), insert);
    });

    test('several statements, each masked, rest unchanged', () {
      const sql =
          "SELECT 1;\nCREATE ROLE a PASSWORD 'one';\n"
          "-- note\nALTER ROLE b PASSWORD 'two';";
      expect(
        redactSecrets(sql),
        "SELECT 1;\nCREATE ROLE a PASSWORD '********';\n"
        "-- note\nALTER ROLE b PASSWORD '********';",
      );
    });
  });

  group('FDW options', () {
    test('user mapping and server options', () {
      expect(
        redactSecrets(
          'CREATE USER MAPPING FOR app SERVER s OPTIONS '
          "(user 'remote', password 'pw')",
        ),
        'CREATE USER MAPPING FOR app SERVER s OPTIONS '
        "(user 'remote', password '********')",
      );
      expect(
        redactSecrets(
          "ALTER USER MAPPING FOR app SERVER s OPTIONS (SET password 'pw')",
        ),
        'ALTER USER MAPPING FOR app SERVER s OPTIONS '
        "(SET password '********')",
      );
      expect(
        redactSecrets(
          'CREATE SERVER s FOREIGN DATA WRAPPER postgres_fdw OPTIONS '
          "(host 'h', \"sslpassword\" 'k')",
        ),
        'CREATE SERVER s FOREIGN DATA WRAPPER postgres_fdw OPTIONS '
        "(host 'h', \"sslpassword\" '********')",
      );
    });

    test('password_required is not a secret', () {
      const sql =
          'ALTER USER MAPPING FOR app SERVER s OPTIONS '
          "(ADD password_required 'false')";
      expect(redactSecrets(sql), sql);
    });
  });

  group('connection strings', () {
    test('dblink conninfo, bare and quoted values', () {
      expect(
        redactSecrets(
          "SELECT dblink_connect('c', 'host=h user=u password=pw dbname=d')",
        ),
        "SELECT dblink_connect('c', 'host=h user=u password=******** "
        "dbname=d')",
      );
      expect(
        redactSecrets("SELECT dblink('password = ''a b'' host=h', 'SELECT 1')"),
        "SELECT dblink('password = ******** host=h', 'SELECT 1')",
      );
    });

    test('URI passwords, also in dollar quotes', () {
      expect(
        redactSecrets(r"SELECT dblink_exec($$postgresql://u:pw@h/db$$, 'x')"),
        r"SELECT dblink_exec($$postgresql://u:********@h/db$$, 'x')",
      );
      expect(
        redactSecrets("SELECT 'postgres://u@h/db'"),
        "SELECT 'postgres://u@h/db'",
      );
    });

    test('identifiers and comments are not touched', () {
      const sql =
          '-- password=abc\nSELECT "password=abc" FROM t /* postgres://u:p@h */';
      expect(redactSecrets(sql), sql);
    });
  });

  test('empty and secret-free text is returned unchanged', () {
    for (final sql in ['', '   ', 'SELECT 1', 'COPY t FROM STDIN;\na\n\\.\n']) {
      expect(redactSecrets(sql), sql);
    }
  });
}
