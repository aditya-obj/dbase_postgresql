// File: pgadmin_server_mapper.dart
// Purpose: Validates one pgAdmin servers.json entry and maps it to a
// PgAdminServer (internal, not exported).
//
// Source of truth: validate_json_data() and load_database_servers() in
// pgAdmin 4's web/pgadmin/utils/__init__.py (master, fetched 2026-10-17;
// lines 697-990). Required fields and the legacy-key rule (flat keys are
// read only when `ConnectionParameters` is absent; `Timeout` becomes
// `connect_timeout`) follow that code.

import 'package:dabase_postgresql/src/config/config_builder.dart';
import 'package:dabase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dabase_postgresql/src/config/pg_connection_config.dart';
import 'package:dabase_postgresql/src/config/raw_setting.dart';
import 'package:dabase_postgresql/src/importers/pgadmin_parameter_checks.dart';
import 'package:dabase_postgresql/src/importers/pgadmin_server.dart';

typedef _Warn = PgAdminWarningCode;

/// pgAdmin's pre-6.20 flat keys and the libpq keyword each one becomes.
const _legacyKeys = {
  'HostAddr': 'hostaddr',
  'SSLMode': 'sslmode',
  'PassFile': 'passfile',
  'SSLCert': 'sslcert',
  'SSLKey': 'sslkey',
  'SSLRootCert': 'sslrootcert',
  'SSLCrl': 'sslcrl',
  'Timeout': 'connect_timeout',
  'SSLCompression': 'sslcompression',
};

final class _Rejected implements Exception {
  const _Rejected(this.code, this.field, this.message);

  final PgAdminErrorCode code;
  final String? field;
  final String message;
}

/// Maps the entry [value] stored under key [id]; exactly one of the two
/// results is non-null.
({PgAdminServer? server, PgAdminServerError? error}) mapPgAdminServer(
  String id,
  Object? value,
) {
  try {
    return (server: _map(id, value), error: null);
  } on _Rejected catch (e) {
    return (
      server: null,
      error: PgAdminServerError(id, e.code, e.field, e.message),
    );
  }
}

PgAdminServer _map(String id, Object? value) {
  if (value is! Map<String, Object?>) {
    throw const _Rejected(
      PgAdminErrorCode.notAnObject,
      null,
      'The server entry is not a JSON object.',
    );
  }
  final obj = value;
  final warnings = <PgAdminWarning>[];
  final read = _Reader(obj, warnings);

  // validate_json_data(): Group, Name; without Service also Port (an
  // integer) and Username (or SharedUsername when shared); MaintenanceDB;
  // Host unless Service.
  final group = read.required('Group');
  final name = read.required('Name');
  final service = read.optional('Service');
  final shared = read.flag('Shared');
  final sharedUsername = read.optional('SharedUsername');
  var username = read.optional('Username');
  if (shared && username == null) username = sharedUsername;
  int? port;
  if (service == null) {
    final rawPort = obj['Port'];
    if (!obj.containsKey('Port')) _missing('Port');
    if (rawPort is! int) {
      throw const _Rejected(
        PgAdminErrorCode.invalidFieldType,
        'Port',
        'Port must be an integer.',
      );
    }
    port = rawPort;
    if (username == null || username.isEmpty) {
      _missing(shared ? 'Username or SharedUsername' : 'Username');
    }
  } else {
    port = read.integer('Port');
  }
  final database = read.required('MaintenanceDB', allowEmpty: true);
  if (!obj.containsKey('Host') && service == null) _missing('Host or Service');
  final host = read.optional('Host');

  final legacy = !obj.containsKey('ConnectionParameters');
  final parameters = legacy
      ? {
          for (final MapEntry(:key, value: keyword) in _legacyKeys.entries)
            if (obj.containsKey(key)) keyword: obj[key],
        }
      : obj['ConnectionParameters'];
  final settings = <String, RawSetting>{
    ...readConnectionParameters(parameters, warnings),
    if (host != null) 'host': RawSetting(host, 0),
    if (port != null) 'port': RawSetting('$port', 0),
    if (username != null) 'user': RawSetting(username, 0),
    'dbname': RawSetting(database, 0),
  };
  final ValidatedSettings v;
  try {
    v = validateSettings(settings);
  } on PgConfigParseException catch (e) {
    throw _Rejected(PgAdminErrorCode.invalidValue, null, e.message);
  }
  warnings.addAll(checkConnectionParameters(settings));

  if (service != null) {
    warnings.add(
      const PgAdminWarning(
        _Warn.service,
        'Service',
        'The server uses a connection service; import the service file to '
            'resolve it.',
      ),
    );
  }
  if (read.flag('KerberosAuthentication')) {
    warnings.add(
      const PgAdminWarning(
        _Warn.kerberos,
        'KerberosAuthentication',
        'Kerberos authentication is not supported.',
      ),
    );
  }
  if (_isPresent(obj['PasswordExecCommand'])) {
    warnings.add(
      const PgAdminWarning(
        _Warn.passwordExecCommand,
        'PasswordExecCommand',
        'The password command was not imported and is never run.',
      ),
    );
  }
  final postSql = read.optional('PostConnectionSQL');
  if (postSql != null && postSql.trim().isNotEmpty) {
    warnings.add(
      const PgAdminWarning(
        _Warn.postConnectionSql,
        'PostConnectionSQL',
        'SQL runs after every connect; review it before enabling it.',
      ),
    );
  }

  return PgAdminServer(
    id: id,
    name: name,
    group: group,
    config: PgConnectionConfig(
      hosts: v.hosts,
      user: v.user,
      password: v.password,
      database: v.database,
      sslMode: v.sslMode,
      parameters: v.parameters,
    ),
    usesLegacyLayout: legacy,
    role: read.optional('Role'),
    comment: read.optional('Comment'),
    service: service,
    backgroundColor: read.optional('BGColor'),
    foregroundColor: read.optional('FGColor'),
    databaseRestriction: read.optional('DBRestriction'),
    databaseRestrictionType: read.optional('DBRestrictionType'),
    sshTunnel: read.flag('UseSSHTunnel') ? _tunnel(read, warnings) : null,
    postConnectionSql: postSql != null && postSql.trim().isNotEmpty
        ? postSql
        : null,
    shared: shared,
    tags: _tags(obj['Tags'], warnings),
    warnings: warnings,
  );
}

Never _missing(String field) => throw _Rejected(
  PgAdminErrorCode.missingField,
  field,
  'Required field $field is missing.',
);

bool _isPresent(Object? value) =>
    value != null && value != '' && value != false && value != 0;

PgAdminSshTunnel _tunnel(_Reader read, List<PgAdminWarning> warnings) {
  final auth = read.integer('TunnelAuthentication', allowBool: true);
  if (auth != null && auth != 0 && auth != 1) {
    warnings.add(
      const PgAdminWarning(
        _Warn.invalidField,
        'TunnelAuthentication',
        'Unknown tunnel authentication; password authentication is assumed.',
      ),
    );
  }
  final identityFile = read.optional('TunnelIdentityFile');
  if (identityFile != null && identityFile.isNotEmpty) {
    warnings.add(
      const PgAdminWarning(
        _Warn.filePath,
        'TunnelIdentityFile',
        'The SSH key file is a path on the exporting computer; select the '
            'key file again on this device.',
      ),
    );
  }
  final port = read.integer('TunnelPort');
  final keepAlive = read.integer('TunnelKeepAlive');
  return PgAdminSshTunnel(
    host: read.optional('TunnelHost'),
    port: port == null || port < 1 || port > 65535 ? 22 : port,
    username: read.optional('TunnelUsername'),
    authentication: auth == 1
        ? PgAdminTunnelAuthentication.identityFile
        : PgAdminTunnelAuthentication.password,
    identityFile: identityFile == null || identityFile.isEmpty
        ? null
        : identityFile,
    promptPassword: read.flag('TunnelPromptPassword'),
    keepAlive: keepAlive == null || keepAlive <= 0
        ? null
        : Duration(seconds: keepAlive),
  );
}

List<PgAdminTag> _tags(Object? value, List<PgAdminWarning> warnings) {
  if (value == null) return const [];
  final tags = <PgAdminTag>[];
  var invalid = value is! List<Object?>;
  if (value is List<Object?>) {
    for (final item in value) {
      if (item case {'text': final String text}) {
        final color = item['color'];
        tags.add(PgAdminTag(text, color: color is String ? color : null));
      } else {
        invalid = true;
      }
    }
  }
  if (invalid) {
    warnings.add(
      const PgAdminWarning(
        _Warn.invalidField,
        'Tags',
        'Some tags are not {"text", "color"} objects and were ignored.',
      ),
    );
  }
  return tags;
}

/// Typed access to one entry's fields, adding an invalidField warning for
/// optional fields of the wrong type.
final class _Reader {
  _Reader(this.obj, this.warnings);

  final Map<String, Object?> obj;
  final List<PgAdminWarning> warnings;

  String required(String field, {bool allowEmpty = false}) {
    if (!obj.containsKey(field)) _missing(field);
    final value = obj[field];
    if (value is! String) {
      throw _Rejected(
        PgAdminErrorCode.invalidFieldType,
        field,
        '$field must be a string.',
      );
    }
    if (!allowEmpty && value.isEmpty) _missing(field);
    return value;
  }

  String? optional(String field) {
    final value = obj[field];
    if (value == null || value is String) return value as String?;
    _invalid(field);
    return null;
  }

  int? integer(String field, {bool allowBool = false}) {
    final value = obj[field];
    if (value == null) return null;
    if (value is int) return value;
    if (allowBool && value is bool) return value ? 1 : 0;
    if (value is String && isDigitsOnly(value)) return int.tryParse(value);
    _invalid(field);
    return null;
  }

  /// pgAdmin stores booleans as `true`/`false` or `0`/`1`.
  bool flag(String field) {
    final value = obj[field];
    if (value == null) return false;
    if (value is bool) return value;
    if (value is int) return value != 0;
    _invalid(field);
    return false;
  }

  void _invalid(String field) => warnings.add(
    PgAdminWarning(
      _Warn.invalidField,
      field,
      '$field has an unexpected type and was ignored.',
    ),
  );
}

/// Whether [text] is non-empty ASCII digits.
bool isDigitsOnly(String text) =>
    text.isNotEmpty && text.codeUnits.every((c) => c >= 0x30 && c <= 0x39);
