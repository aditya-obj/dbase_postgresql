// File: describe_context.dart
// Purpose: What every describe command needs: the server version, the
// query callback, the current database (for `db.schema.name` patterns)
// and the NULL display for printQuery-style tables.

import 'package:dabase_postgresql/src/psql/describe/list_sql.dart';
import 'package:dabase_postgresql/src/psql/describe/psql_query.dart';

/// Inputs shared by the describe commands.
final class DescribeContext {
  /// Creates the context. [version] is psql's version number
  /// ([serverVersionNumber]); servers before 13 are treated as 13.
  const DescribeContext({
    required this.version,
    required this.query,
    this.currentDatabase,
    this.nullDisplay = '',
  });

  /// Server version number, e.g. `170002`.
  final int version;

  /// Runs catalog queries.
  final PsqlQuery query;

  /// The connected database's name.
  final String? currentDatabase;

  /// `\pset null`, for tables psql prints with printQuery.
  final String nullDisplay;

  /// The same inputs for the SQL builders.
  ListContext get list =>
      ListContext(version: version, currentDatabase: currentDatabase);
}
