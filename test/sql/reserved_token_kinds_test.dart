// File: reserved_token_kinds_test.dart
// Purpose: The psql token kinds are reserved for a future `psqlMode`
// option. v0.1 must never emit them, even for psql-shaped input; this
// keeps the lexer pure SQL until psqlMode is implemented.

import 'package:dbase_postgresql/sql.dart';
import 'package:test/test.dart';

import '../support/sql_corpus.dart';
import 'invariants_test.dart' show reservedPsqlKinds;

/// Input that psql (src/fe_utils/psqlscan.l) would treat specially:
/// backslash meta-commands and `:var` / `:'var'` / `:"var"` / `:{?var}`
/// interpolation.
const _psqlShaped = <String>[
  r'\d+ users',
  r'SELECT 1 \gset',
  r'\set n 10',
  "SELECT :n, :'name', :\"ident\", :{?flag};",
  r'\copy t FROM data.csv',
  'SELECT 1;\n\\watch 2\n',
  r'\\',
];

void main() {
  test('reserved kinds exist and are distinct from every v0.1 kind', () {
    expect(SqlTokenKind.values, containsAll(reservedPsqlKinds));
    expect(reservedPsqlKinds, hasLength(2));
  });

  for (final lexer in const [
    SqlLexer(),
    SqlLexer(standardConformingStrings: false),
  ]) {
    final mode = lexer.standardConformingStrings ? 'on' : 'off';

    test('psql-shaped input never yields psql kinds (scs=$mode)', () {
      for (final sql in _psqlShaped) {
        final kinds = lexer.tokenize(sql).map((t) => t.kind).toSet();
        expect(kinds.intersection(reservedPsqlKinds), isEmpty, reason: sql);
      }
    });

    test('the SQL corpus never yields psql kinds (scs=$mode)', () {
      for (final sql in sqlCorpus) {
        final kinds = lexer.tokenize(sql).map((t) => t.kind).toSet();
        expect(kinds.intersection(reservedPsqlKinds), isEmpty, reason: sql);
      }
    });
  }

  test('backslash lexes as unknown and colon as punctuation in v0.1', () {
    final tokens = const SqlLexer().tokenize(r'\gset :v');
    expect(tokens.first.kind, SqlTokenKind.unknown);
    expect(
      tokens.firstWhere((t) => t.text == ':').kind,
      SqlTokenKind.punctuation,
    );
  });
}
