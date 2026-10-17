// File: sql_corpus.dart
// Purpose: Shared SQL and connection-string inputs for invariant and
// mutation-fuzz tests.

const _atomicFunction =
    'CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC '
    'SELECT CASE WHEN true THEN 1 END; END; SELECT 2;';

/// SQL scripts that exercise every lexer and splitter path.
const sqlCorpus = <String>[
  '',
  'SELECT 1',
  r"SELECT 'it''s', E'a\'b', U&'d\0061t', B'101', X'1F', N'n';",
  r'SELECT $$a;b$$, $tag$ $$ ; $tag$, $1, $2::int;',
  'SELECT "Quoted ""Id""", U&"x" FROM t -- c;\n WHERE a <> b;',
  '/* outer /* inner ; */ still */ SELECT 1; /* unterminated',
  'SELECT 1.5e10, .5, 0x1F, 0o17, 0b101, 1_000, 123abc, 1..10;',
  'SELECT a->>b, a@>b, a=-1, a?-b, x := 1, f(y => 2), :var;',
  _atomicFunction,
  'COPY t FROM STDIN;\n1\t2\n\\.\nSELECT 3;',
  "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d; UPDATE t SET a='x'",
  'EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t WHERE (a = 1;',
  "SELECT 'unterminated",
  r'SELECT $x$ unterminated dollar',
  'SELECT café, \u{1F600} FROM "té"; \\d+',
  r"DO $$ BEGIN RAISE NOTICE 'x;'; END $$; VACUUM; ALTER SYSTEM SET a=1",
  "SET default_transaction_read_only = 'off'; BEGIN READ WRITE; RESET ALL",
  "SELECT pg_catalog.set_config('transaction_read_only', 'off', true)",
  'LOCK TABLE ONLY a, "B" * IN SHARE ROW EXCLUSIVE MODE NOWAIT;',
  'DELETE FROM ONLY s.t WHERE (1 = 1) RETURNING *; UPDATE t SET a=1 WHERE x=x',
  'MERGE INTO t USING s ON true WHEN NOT MATCHED BY SOURCE THEN DELETE',
  'TRUNCATE a, b CASCADE; DROP FUNCTION f(int), g() CASCADE;',
  'REINDEX (CONCURRENTLY true) TABLE t; REINDEX SCHEMA s',
];

/// Connection strings, valid and invalid, for parser fuzzing.
const connectionCorpus = <String>[
  'postgresql://uri-user:secret@host:12345/db?sslmode=require',
  'postgres://[::1]:5432,h2:6000/db?application_name=x%20y',
  r"host=h port=5432 dbname=d user=u password='p\'w'",
  'postgres://%2Fvar%2Frun/db?options=-c%20a%3Db',
];

/// Fragments spliced into inputs by the mutation fuzzer.
const mutationFragments = <String>[
  "'",
  r'$tag$',
  '/*',
  '--',
  "E'",
  'U&',
  '%00',
  '"',
  ';',
  '(',
  ')',
  r'\',
  '\n',
  '\u0000',
  '\u{1F600}',
  'BEGIN',
  'END',
];
