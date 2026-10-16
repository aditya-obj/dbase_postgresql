// File: main.dart
// Purpose: Runnable tour of dbase_postgresql: parse a connection string,
// split a script, and check statements before running them.

import 'dart:io';

import 'package:dbase_postgresql/dbase_postgresql.dart';

void main() {
  // 1. Connection strings: parse, inspect warnings, log safely.
  final config = PgConnectionConfig.parse(
    'postgres://alice:s3cret@db.example.com:5432/shop?application_name=demo',
  );
  stdout
    ..writeln('Connecting to ${config.redacted()}')
    ..writeln('Database: ${config.effectiveDatabase}');
  for (final warning in config.securityWarnings) {
    stdout.writeln('  ! ${warning.code.name}: ${warning.message}');
  }
  final secure = config.copyWith(sslMode: SslMode.verifyFull);
  stdout.writeln('Upgraded sslmode: ${secure.sslMode.libpqName}');

  // 2. Split a script the way psql would.
  const script = r'''
-- nightly cleanup
DELETE FROM sessions;
UPDATE orders SET status = 'done' WHERE id IN (SELECT id FROM paid);
CREATE INDEX CONCURRENTLY orders_status ON orders (status);
SELECT $$ a ; inside a dollar quote $$;
''';
  const splitter = SqlStatementSplitter();
  const analyzer = SqlStatementAnalyzer();

  // 3. Analyze each statement before running it.
  for (final statement in splitter.split(script)) {
    final analysis = analyzer.analyzeStatement(statement);
    stdout.writeln(
      '\n${statement.text}\n'
      '  kind=${analysis.kind.name} writes=${analysis.writes} '
      'confirm=${analysis.requiresConfirmation} '
      'noTransaction=${analysis.cannotRunInTransactionBlock}',
    );
    for (final finding in analysis.findings) {
      stdout.writeln('  [${finding.severity.name}] ${finding.message}');
    }
  }

  // 4. Which statement is under the editor cursor?
  final cursor = script.indexOf('orders SET');
  stdout.writeln(
    '\nUnder cursor: ${splitter.statementAtOffset(script, cursor)?.text}',
  );
}
