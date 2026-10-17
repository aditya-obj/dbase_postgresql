// File: pgadmin_servers_file.dart
// Purpose: Parses a pgAdmin 4 servers.json export (both the 6.20+
// ConnectionParameters layout and the older flat keys).

import 'dart:convert';

import 'package:dbase_postgresql/src/importers/pg_import_diagnostic.dart';
import 'package:dbase_postgresql/src/importers/pgadmin_server.dart';
import 'package:dbase_postgresql/src/importers/pgadmin_server_mapper.dart';
import 'package:dbase_postgresql/src/importers/text_lines.dart';

/// A parsed pgAdmin `servers.json` file:
/// `{"Servers": {"1": {...}, "2": {...}}}`.
///
/// Entries are validated with pgAdmin's own rules (`Name`, `Group` and
/// `MaintenanceDB` are required; without `Service`, so are `Host`, an
/// integer `Port` and `Username`). Unlike pgAdmin, which stops at the first
/// invalid entry, every valid entry is imported and each invalid one is
/// reported in [errors]. Shared servers are imported too.
///
/// Nothing in the file is ever executed: `PasswordExecCommand` is dropped
/// and `PostConnectionSQL` is only stored. See [PgAdminServer.warnings].
final class PgAdminServersFile {
  PgAdminServersFile._(this.servers, this.errors);

  /// Parses the JSON text of a `servers.json` export. A leading byte order
  /// mark is ignored.
  ///
  /// Throws [PgImportException] when the text is not JSON, is not an
  /// object, or has no `Servers` object. The message never repeats the
  /// input.
  factory PgAdminServersFile.parse(String json) {
    final text = json.startsWith(byteOrderMark) ? json.substring(1) : json;
    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException catch (e) {
      // FormatException.toString() quotes the source; keep only the offset.
      final offset = e.offset;
      throw PgImportException(
        'The file is not valid JSON.',
        offset: offset == null || text == json ? offset : offset + 1,
      );
    }
    if (root is! Map<String, Object?>) {
      throw const PgImportException(
        'Expected a JSON object with a "Servers" attribute.',
      );
    }
    final entries = root['Servers'];
    if (!root.containsKey('Servers')) {
      throw const PgImportException('"Servers" attribute not found.');
    }
    if (entries is! Map<String, Object?>) {
      throw const PgImportException('"Servers" is not a JSON object.');
    }
    final servers = <PgAdminServer>[];
    final errors = <PgAdminServerError>[];
    for (final MapEntry(:key, :value) in entries.entries) {
      final result = mapPgAdminServer(key, value);
      if (result.server case final server?) servers.add(server);
      if (result.error case final error?) errors.add(error);
    }
    return PgAdminServersFile._(
      List.unmodifiable(servers),
      List.unmodifiable(errors),
    );
  }

  /// Like [PgAdminServersFile.parse] but returns `null` instead of
  /// throwing.
  static PgAdminServersFile? tryParse(String json) {
    try {
      return PgAdminServersFile.parse(json);
    } on PgImportException {
      return null;
    }
  }

  /// Imported servers, in file order.
  final List<PgAdminServer> servers;

  /// Entries that could not be imported, in file order.
  final List<PgAdminServerError> errors;

  @override
  String toString() =>
      'PgAdminServersFile(${servers.length} servers, '
      '${errors.length} errors)';
}
