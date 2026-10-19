// File: pg_service_file.dart
// Purpose: A parsed libpq connection service file (pg_service.conf /
// .pg_service.conf) and libpq's user-over-system file precedence.

import 'package:dabase_postgresql/src/importers/pg_import_diagnostic.dart';
import 'package:dabase_postgresql/src/importers/pg_service.dart';
import 'package:dabase_postgresql/src/importers/service_file_parser.dart';

/// A parsed connection service file.
///
/// libpq reads only the section it is asked for. This parser reads every
/// section so an app can list them, and reports for each one what libpq's
/// lookup would do: a section libpq would reject is kept, marked invalid
/// ([PgService.isValid]), with its errors in [PgService.diagnostics].
///
/// The rules are libpq's `parseServiceFile()`: `[name]` headers
/// (case-sensitive, text after `]` ignored), `key=value` lines with no
/// whitespace before `=` and no quoting, `#` comments only as the first
/// non-blank character (no inline comments), only libpq keywords, no
/// nested `service=`, the first value of a repeated keyword wins, only the
/// first section of a repeated name counts, and lines of 1023 bytes or
/// more are an error. Parsing never throws.
final class PgServiceFile {
  PgServiceFile._(this.services, this.diagnostics, this.lineTooLong);

  /// Parses the text of a service file.
  factory PgServiceFile.parse(String text) {
    final parsed = parseServiceFileText(text);
    return PgServiceFile._(
      List.unmodifiable(parsed.services),
      List.unmodifiable(parsed.diagnostics),
      parsed.lineTooLong,
    );
  }

  /// Services in file order, one per name (the first section wins).
  final List<PgService> services;

  /// Every diagnostic in the file, in line order, including lines outside
  /// any service. Never contains values.
  final List<PgLineDiagnostic<PgServiceDiagnosticCode>> diagnostics;

  /// The first line that is too long for libpq, or `null`. libpq stops
  /// reading at that line, so a lookup of any service whose section ends
  /// after it, or that is not in this file at all, fails with an error.
  final PgLineDiagnostic<PgServiceDiagnosticCode>? lineTooLong;

  /// The service named [name] (exact, case-sensitive), or `null`.
  PgService? lookup(String name) {
    for (final service in services) {
      if (service.name == name) return service;
    }
    return null;
  }

  /// Combines a user file (`PGSERVICEFILE` or `~/.pg_service.conf`) with a
  /// system file (`pg_service.conf` in `PGSYSCONFDIR`) the way libpq
  /// searches them: the user file wins for every name it defines, even when
  /// its section is invalid, because libpq then never reads the system
  /// file.
  ///
  /// Returns the user file's services in file order, then the system
  /// file's services whose names the user file lacks. If the user file has
  /// a line that is too long, libpq fails before it reaches the system
  /// file, so those system services are returned invalid, with that
  /// diagnostic.
  static List<PgService> merge({
    required PgServiceFile user,
    required PgServiceFile system,
  }) {
    final names = {for (final s in user.services) s.name};
    final blocker = user.lineTooLong;
    return [
      ...user.services,
      for (final service in system.services)
        if (!names.contains(service.name))
          if (blocker == null)
            service
          else
            PgService(
              name: service.name,
              line: service.line,
              settings: service.settings,
              config: null,
              diagnostics: [blocker, ...service.diagnostics],
            ),
    ];
  }

  @override
  String toString() =>
      'PgServiceFile(${services.length} services, '
      '${diagnostics.length} diagnostics)';
}
