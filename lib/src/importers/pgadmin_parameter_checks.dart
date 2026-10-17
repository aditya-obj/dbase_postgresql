// File: pgadmin_parameter_checks.dart
// Purpose: Reads pgAdmin ConnectionParameters into libpq keyword settings
// and flags parameters a phone cannot use as-is (internal, not exported).

import 'package:dbase_postgresql/src/config/libpq_keywords.dart';
import 'package:dbase_postgresql/src/config/raw_setting.dart';
import 'package:dbase_postgresql/src/importers/pgadmin_server.dart';

typedef _Warn = PgAdminWarningCode;

/// libpq keywords whose value is a path on the computer that exported the
/// file. `sslrootcert=system` is not a path.
const _pathKeywords = {
  'passfile',
  'sslcert',
  'sslkey',
  'sslrootcert',
  'sslcrl',
  'sslcrldir',
  'sslkeylogfile',
  'oauth_ca_file',
  'servicefile',
};

/// Converts pgAdmin's `ConnectionParameters` object (or the legacy keys
/// already renamed to libpq keywords) into settings. pgAdmin stores some
/// values as JSON numbers (`"connect_timeout": 10`); those become decimal
/// strings. Unusable entries are skipped with a warning in [warnings].
RawSettings readConnectionParameters(
  Object? parameters,
  List<PgAdminWarning> warnings,
) {
  if (parameters == null) return {};
  if (parameters is! Map<String, Object?>) {
    warnings.add(
      const PgAdminWarning(
        _Warn.invalidField,
        'ConnectionParameters',
        'ConnectionParameters is not a JSON object and was ignored.',
      ),
    );
    return {};
  }
  final settings = <String, RawSetting>{};
  for (final MapEntry(:key, :value) in parameters.entries) {
    if (value == null) continue;
    final text = switch (value) {
      final String s => s,
      final int i => '$i',
      final double d when d.isFinite && d == d.truncateToDouble() =>
        '${d.toInt()}',
      final double d when d.isFinite => '$d',
      _ => null,
    };
    if (text == null || !isKeywordSyntax(key)) {
      final known = libpqKeywordEnvironment.containsKey(key);
      warnings.add(
        PgAdminWarning(
          _Warn.ignoredParameter,
          known ? key : null,
          text == null
              ? 'A connection parameter (${describeKeyword(key)}) has a '
                    'value that is not a string or number and was ignored.'
              : 'A connection parameter name is not a valid keyword and '
                    'was ignored.',
        ),
      );
      continue;
    }
    settings[key] = RawSetting(text, 0);
  }
  return settings;
}

/// Warnings for parameters that need attention on a phone.
List<PgAdminWarning> checkConnectionParameters(RawSettings settings) {
  String? value(String key) {
    final v = settings[key]?.value;
    return v == null || v.isEmpty ? null : v;
  }

  return [
    for (final key in settings.keys)
      if (_pathKeywords.contains(key) &&
          value(key) != null &&
          !(key == 'sslrootcert' && value(key) == 'system'))
        PgAdminWarning(
          _Warn.filePath,
          key,
          '$key is a path on the exporting computer; select the file again '
          'on this device.',
        ),
    if (value('hostaddr') != null)
      const PgAdminWarning(
        _Warn.hostAddress,
        'hostaddr',
        'hostaddr is set; verify-full still needs the server host name.',
      ),
    if (value('sslnegotiation') == 'direct')
      const PgAdminWarning(
        _Warn.directSslNegotiation,
        'sslnegotiation',
        'Direct TLS negotiation (sslnegotiation=direct) is not supported; '
            'the standard negotiation will be used.',
      ),
    if (value('gssencmode') == 'require')
      const PgAdminWarning(
        _Warn.kerberos,
        'gssencmode',
        'GSSAPI encryption is required but not supported.',
      ),
    for (final key in const ['krbsrvname', 'gsslib'])
      if (value(key) != null)
        PgAdminWarning(
          _Warn.kerberos,
          key,
          '$key configures Kerberos, which is not supported.',
        ),
    if (value('gssdelegation') == '1')
      const PgAdminWarning(
        _Warn.kerberos,
        'gssdelegation',
        'GSSAPI credential delegation is not supported.',
      ),
    for (final key in settings.keys)
      if (secretKeywords.contains(key) && value(key) != null)
        PgAdminWarning(
          _Warn.secretInFile,
          key,
          '$key is stored in the file in plain text; keep it in secure '
          'storage instead.',
        ),
    if (value('service') != null)
      const PgAdminWarning(
        _Warn.service,
        'service',
        'The server uses a connection service; import the service file to '
            'resolve it.',
      ),
  ];
}
