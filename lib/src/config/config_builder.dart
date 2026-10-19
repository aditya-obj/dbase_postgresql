// File: config_builder.dart
// Purpose: Validates raw libpq keyword settings into typed values and
// applies libpq's environment/default resolution (internal).

import 'package:dabase_postgresql/src/config/libpq_keywords.dart';
import 'package:dabase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dabase_postgresql/src/config/pg_connection_config.dart';
import 'package:dabase_postgresql/src/config/pg_host.dart';
import 'package:dabase_postgresql/src/config/raw_setting.dart';
import 'package:dabase_postgresql/src/config/ssl_mode.dart';

/// Keywords stored in typed fields rather than in `parameters`.
const _typedKeys = {'host', 'port', 'user', 'password', 'dbname', 'sslmode'};

/// Typed values extracted from [RawSettings].
typedef ValidatedSettings = ({
  List<PgHost> hosts,
  String? user,
  String? password,
  String? database,
  SslMode? sslMode,
  Map<String, String> parameters,
});

/// Validates [settings]. Throws [PgConfigParseException] for invalid
/// values; messages never include the value itself.
ValidatedSettings validateSettings(RawSettings settings) {
  final sslSetting = settings['sslmode'];
  SslMode? sslMode;
  if (sslSetting != null) {
    sslMode = SslMode.tryParse(sslSetting.value);
    if (sslMode == null) {
      throw PgConfigParseException(
        'Invalid sslmode. Expected one of: '
        '${SslMode.values.map((m) => m.libpqName).join(', ')}.',
        offset: sslSetting.offset,
      );
    }
  }
  final legacySsl = settings['ssl'];
  if (legacySsl != null) {
    if (legacySsl.value != 'true') {
      throw PgConfigParseException(
        'Invalid ssl value; only "true" (meaning sslmode=require) is '
        'supported.',
        offset: legacySsl.offset,
      );
    }
    sslMode ??= SslMode.require;
  }
  final timeout = settings['connect_timeout'];
  if (timeout != null && !_isDigits(timeout.value)) {
    throw PgConfigParseException(
      'connect_timeout must be a whole number of seconds.',
      offset: timeout.offset,
    );
  }
  return (
    hosts: _buildHosts(settings['host'], settings['port']),
    user: _nonEmpty(settings['user']),
    password: _nonEmpty(settings['password']),
    database: _nonEmpty(settings['dbname']),
    sslMode: sslMode,
    parameters: {
      for (final MapEntry(:key, :value) in settings.entries)
        if (!_typedKeys.contains(key) && key != 'ssl') key: value.value,
    },
  );
}

/// Converts [config] back to keyword settings (offsets are 0).
RawSettings configToSettings(PgConnectionConfig config) {
  final hosts = config.hosts;
  return {
    if (hosts.isNotEmpty)
      'host': RawSetting(hosts.map((h) => h.host).join(','), 0),
    if (hosts.any((h) => h.port != null))
      'port': RawSetting(hosts.map((h) => h.port ?? '').join(','), 0),
    if (config.user case final user?) 'user': RawSetting(user, 0),
    if (config.password case final password?)
      'password': RawSetting(password, 0),
    if (config.database case final database?) 'dbname': RawSetting(database, 0),
    if (config.sslModeWasExplicit)
      'sslmode': RawSetting(config.sslMode.libpqName, 0),
    for (final MapEntry(:key, :value) in config.parameters.entries)
      key: RawSetting(value, 0),
  };
}

/// Applies libpq's fallbacks to [settings]: each missing keyword takes its
/// `PG*` variable from [environment] (empty values ignored), `user` then
/// falls back to [defaultUser], and `dbname` falls back to the user name.
/// No database name is ever invented.
///
/// When no sslmode was given and `PGSSLMODE` is unset, the deprecated
/// `PGREQUIRESSL` (a value starting with `1`) means `require`, and
/// otherwise `sslrootcert=system` raises the default to `verify-full`.
/// Both rules follow conninfo_add_defaults() in libpq's fe-connect.c.
RawSettings withDefaults(
  RawSettings settings, {
  required Map<String, String> environment,
  required String? defaultUser,
}) {
  final resolved = {...settings};
  for (final MapEntry(:key, value: variable)
      in libpqKeywordEnvironment.entries) {
    if (variable == null || resolved.containsKey(key)) continue;
    final value = environment[variable];
    if (value != null && value.isNotEmpty) {
      resolved[key] = RawSetting(value, 0);
    }
  }
  // `ssl=true` is the JDBC-style spelling of sslmode=require.
  if (!resolved.containsKey('sslmode') && !resolved.containsKey('ssl')) {
    if (environment['PGREQUIRESSL']?.startsWith('1') ?? false) {
      resolved['sslmode'] = const RawSetting('require', 0);
    } else if (resolved['sslrootcert']?.value == 'system') {
      resolved['sslmode'] = const RawSetting('verify-full', 0);
    }
  }
  if (!resolved.containsKey('user') && defaultUser != null) {
    resolved['user'] = RawSetting(defaultUser, 0);
  }
  final user = resolved['user'];
  if (!resolved.containsKey('dbname') && user != null) {
    resolved['dbname'] = user;
  }
  return resolved;
}

List<PgHost> _buildHosts(RawSetting? hostSetting, RawSetting? port) {
  var hosts = hostSetting?.value.split(',') ?? <String>[];
  if (port == null) return [for (final host in hosts) PgHost(host)];
  final ports = port.value.split(',');
  if (hosts.isEmpty) hosts = List.filled(ports.length, '');
  if (ports.length > 1 && ports.length != hosts.length) {
    throw PgConfigParseException(
      'Got ${ports.length} ports for ${hosts.length} hosts; give one port '
      'or one per host.',
      offset: port.offset,
    );
  }
  return [
    for (var i = 0; i < hosts.length; i++)
      PgHost(
        hosts[i],
        port: _parsePort(ports.length == 1 ? ports[0] : ports[i], port),
      ),
  ];
}

int? _parsePort(String text, RawSetting setting) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final value = _isDigits(trimmed) ? int.tryParse(trimmed) : null;
  if (value == null || value < 1 || value > 65535) {
    throw PgConfigParseException(
      'Invalid port; expected a number from 1 to 65535.',
      offset: setting.offset,
    );
  }
  return value;
}

bool _isDigits(String text) =>
    text.isNotEmpty && text.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

String? _nonEmpty(RawSetting? setting) =>
    setting == null || setting.value.isEmpty ? null : setting.value;
