// File: dbase_postgresql.dart
// Purpose: Umbrella entrypoint exporting the whole stable public API.

/// Pure-Dart PostgreSQL toolkit: connection string parsing, `.pgpass`,
/// service file and pgAdmin importers, a PostgreSQL-dialect SQL lexer, a
/// psql-compatible statement splitter, and statement safety analysis. No
/// Flutter or `dart:io` dependency.
///
/// Import `package:dbase_postgresql/connection_string.dart`,
/// `package:dbase_postgresql/importers.dart` or
/// `package:dbase_postgresql/sql.dart` to depend on one area only.
library;

export 'connection_string.dart';
export 'importers.dart';
export 'sql.dart';
