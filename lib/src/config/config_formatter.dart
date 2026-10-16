// File: config_formatter.dart
// Purpose: Formats a PgConnectionConfig back into a postgresql:// URI with
// controllable secret handling (internal, not exported).

import 'package:dbase_postgresql/src/config/libpq_keywords.dart';
import 'package:dbase_postgresql/src/config/percent_codec.dart';
import 'package:dbase_postgresql/src/config/pg_connection_config.dart';
import 'package:dbase_postgresql/src/config/pg_host.dart';

/// How secrets are written by [formatConfigUri].
enum SecretOutput {
  /// Write the real values.
  include,

  /// Leave secrets out entirely.
  omit,

  /// Replace secrets with [maskedSecret].
  mask,
}

/// Placeholder written instead of a secret in [SecretOutput.mask] mode.
const maskedSecret = '****';

/// Formats [config] as a `postgresql://` URI.
String formatConfigUri(
  PgConnectionConfig config, {
  required SecretOutput secrets,
}) {
  final buffer = StringBuffer('postgresql://');
  final user = config.user;
  final password = config.password;
  final writePassword = password != null && secrets != SecretOutput.omit;
  if (user != null || writePassword) {
    buffer.write(percentEncode(user ?? ''));
    if (writePassword) {
      buffer
        ..write(':')
        ..write(
          secrets == SecretOutput.include
              ? percentEncode(password)
              : maskedSecret,
        );
    }
    buffer.write('@');
  }

  final query = <String, String>{};
  final hosts = config.hosts;
  if (hosts.any((h) => h.host.startsWith('/') || h.host.startsWith('@'))) {
    // Socket paths contain "/" and cannot live in the authority section.
    query['host'] = hosts.map((h) => h.host).join(',');
    if (hosts.any((h) => h.port != null)) {
      query['port'] = hosts.map((h) => h.port ?? '').join(',');
    }
  } else {
    buffer.write(hosts.map(_formatHost).join(','));
  }

  final database = config.database;
  if (database != null) buffer.write('/${percentEncode(database)}');

  if (config.sslModeWasExplicit) query['sslmode'] = config.sslMode.libpqName;
  for (final MapEntry(:key, :value) in config.parameters.entries) {
    if (!secretKeywords.contains(key)) {
      query[key] = value;
    } else if (secrets == SecretOutput.include) {
      query[key] = value;
    } else if (secrets == SecretOutput.mask) {
      query[key] = maskedSecret;
    }
  }
  if (query.isNotEmpty) {
    buffer
      ..write('?')
      ..write(
        query.entries
            .map((e) => '${percentEncode(e.key)}=${_encodeValue(e.value)}')
            .join('&'),
      );
  }
  return buffer.toString();
}

String _encodeValue(String value) =>
    value == maskedSecret ? value : percentEncode(value);

String _formatHost(PgHost host) {
  final name = host.isIpv6
      ? '[${host.host.replaceAll('%', '%25')}]'
      : percentEncode(host.host);
  final port = host.port;
  return port == null ? name : '$name:$port';
}
