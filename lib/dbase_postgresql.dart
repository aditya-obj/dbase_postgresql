// File: dbase_postgresql.dart
// Purpose: Umbrella entrypoint exporting the whole stable public API.

/// Pure-Dart PostgreSQL toolkit: connection string parsing, `.pgpass`,
/// service file and pgAdmin importers, a PostgreSQL-dialect SQL lexer, a
/// psql-compatible statement splitter, statement safety analysis, an
/// `EXPLAIN (FORMAT JSON)` analyzer, `bytea` decoding, a PostGIS EWKB
/// decoder, CSV import helpers and psql's console logic (backslash
/// commands, `\d` describe queries, the table printer), bulk catalog
/// reading, DDL generation and a pg_dump-style plain-SQL export. No
/// Flutter or `dart:io` dependency.
///
/// Import `package:dbase_postgresql/connection_string.dart`,
/// `package:dbase_postgresql/importers.dart`,
/// `package:dbase_postgresql/sql.dart`,
/// `package:dbase_postgresql/explain.dart`,
/// `package:dbase_postgresql/binary.dart`,
/// `package:dbase_postgresql/geo.dart`,
/// `package:dbase_postgresql/csv.dart`,
/// `package:dbase_postgresql/psql.dart`,
/// `package:dbase_postgresql/catalog.dart`,
/// `package:dbase_postgresql/ddl.dart` or
/// `package:dbase_postgresql/dump.dart` to depend on one area only.
library;

export 'binary.dart';
export 'catalog.dart';
export 'connection_string.dart';
export 'csv.dart';
export 'ddl.dart';
export 'dump.dart';
export 'explain.dart';
export 'geo.dart';
export 'importers.dart';
export 'psql.dart';
export 'sql.dart';
