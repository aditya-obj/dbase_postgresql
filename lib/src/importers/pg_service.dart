// File: pg_service.dart
// Purpose: One named section of a libpq connection service file, its
// diagnostics, and libpq's "connection string wins" merge.

import 'package:dbase_postgresql/src/config/config_builder.dart';
import 'package:dbase_postgresql/src/config/libpq_keywords.dart' as keywords;
import 'package:dbase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dbase_postgresql/src/config/pg_connection_config.dart';
import 'package:dbase_postgresql/src/config/raw_setting.dart';
import 'package:dbase_postgresql/src/importers/pg_import_diagnostic.dart';

/// Stable identifiers for `pg_service.conf` [PgLineDiagnostic]s.
///
/// Codes with [PgImportSeverity.error] mark the service as broken, because
/// libpq would refuse to connect with it.
enum PgServiceDiagnosticCode {
  /// The file starts with a byte order mark, which was ignored (warning).
  byteOrderMark,

  /// A line is 1023 bytes or longer. libpq stops reading the file there,
  /// so every service whose lookup reaches this line fails (error).
  lineTooLong,

  /// A line starts with `[` but has no `]`. Lines up to the next section
  /// belong to no service (warning).
  malformedSectionHeader,

  /// `[]` names no service; its lines were ignored (warning).
  emptyServiceName,

  /// A second section with an existing name. libpq only reads the first,
  /// so this one was ignored (info).
  duplicateService,

  /// A setting before the first section, or under an ignored one. libpq
  /// never reads it (info).
  outsideSection,

  /// A line in a section has no `=` (error).
  missingEquals,

  /// Whitespace before `=`. libpq takes the key literally (`host `) and
  /// rejects it (error).
  spaceAroundEquals,

  /// The key is not a libpq connection keyword (error).
  unknownKeyword,

  /// `service=` or `servicefile=` inside a service (error).
  nestedService,

  /// The keyword already appeared in this section; libpq keeps the first
  /// value (info).
  duplicateKeyword,

  /// The value starts with whitespace, which libpq keeps (warning).
  valueHasLeadingWhitespace,

  /// An `ldap` line. LDAP lookups are not supported; the line was skipped,
  /// as libpq does when the LDAP server is unreachable (warning).
  ldapNotSupported,

  /// The line contains a NUL character and was skipped (error inside a
  /// section, otherwise warning).
  nulCharacter,

  /// A value is invalid, e.g. a port out of range or an unknown sslmode
  /// (error).
  invalidValue,
}

/// One service (a `[name]` section) of a connection service file.
final class PgService {
  /// Creates a service. Normally produced by `PgServiceFile.parse`.
  PgService({
    required this.name,
    required this.line,
    required Map<String, String> settings,
    required this.config,
    required List<PgLineDiagnostic<PgServiceDiagnosticCode>> diagnostics,
  }) : settings = Map.unmodifiable(settings),
       diagnostics = List.unmodifiable(diagnostics);

  /// The name between the brackets, case-sensitive and untrimmed.
  final String name;

  /// One-based line number of the `[name]` header.
  final int line;

  /// The keyword values in file order, first occurrence only (libpq keeps
  /// the first). Values are exactly as written: no quoting or escaping.
  /// May hold secrets (see [secretKeywords]); never log it.
  final Map<String, String> settings;

  /// The connection settings, or `null` when [isValid] is `false`.
  final PgConnectionConfig? config;

  /// Problems in this service, in line order. Never contains values.
  final List<PgLineDiagnostic<PgServiceDiagnosticCode>> diagnostics;

  /// Whether libpq would accept this service.
  bool get isValid => config != null;

  /// Keywords in [settings] that hold secrets (`password`, `sslpassword`,
  /// ...). Store their values in secure storage.
  Set<String> get secretKeywords =>
      settings.keys.where(keywords.secretKeywords.contains).toSet();

  /// Applies this service to [target] the way libpq applies a `service=`
  /// keyword: every keyword already set in [target] wins, and the service
  /// fills in the rest. Apply it before `resolveDefaults`, since service
  /// values beat `PG*` variables.
  ///
  /// Throws [PgImportException] when this service is not [isValid] or the
  /// combination is invalid (for example two hosts with three ports).
  PgConnectionConfig applyTo(PgConnectionConfig target) {
    if (!isValid) {
      throw const PgImportException(
        'The service is invalid; see its diagnostics.',
      );
    }
    final own = configToSettings(target);
    if (target.hosts.every((h) => h.host.isEmpty)) own.remove('host');
    final merged = <String, RawSetting>{
      for (final MapEntry(:key, :value) in settings.entries)
        key: RawSetting(value, 0),
      ...own,
    };
    final ValidatedSettings v;
    try {
      v = validateSettings(merged);
    } on PgConfigParseException catch (e) {
      throw PgImportException(
        'The service does not combine with the connection: ${e.message}',
      );
    }
    return target.copyWith(
      hosts: v.hosts,
      user: v.user,
      // Passing the target's own password would drop its
      // passwordInConnectionString warning.
      password: target.password == null ? v.password : null,
      database: v.database,
      sslMode: v.sslMode,
      parameters: v.parameters,
    );
  }

  @override
  String toString() =>
      'PgService($name, line $line, ${isValid ? 'valid' : 'invalid'}, '
      'keywords: ${settings.keys.join(', ')})';
}
