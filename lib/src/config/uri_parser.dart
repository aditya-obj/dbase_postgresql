// File: uri_parser.dart
// Purpose: Parses postgres:// and postgresql:// URIs into raw libpq keyword
// settings (internal, not exported).

import 'package:dbase_postgresql/src/config/libpq_keywords.dart';
import 'package:dbase_postgresql/src/config/percent_codec.dart';
import 'package:dbase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dbase_postgresql/src/config/raw_setting.dart';

const _schemes = ['postgresql://', 'postgres://'];

/// Returns the length of the URI scheme prefix of [source] (ASCII
/// case-insensitive), or 0 when [source] is not a PostgreSQL URI.
int uriSchemeLength(String source) {
  final lower = source.toLowerCase();
  for (final scheme in _schemes) {
    if (lower.startsWith(scheme)) return scheme.length;
  }
  return 0;
}

/// Parses `postgresql://[user[:password]@][host[:port][,...]][/db][?k=v&...]`.
///
/// [source] must start with a scheme accepted by [uriSchemeLength]. Offsets
/// in errors and settings are relative to [baseOffset].
///
/// Deviation from libpq: the user-info section ends at the **last** `@`
/// before the first `/` or `?`, so an unencoded `@` in a password still
/// works. `/` and `?` in a password must be percent-encoded.
RawSettings parseUriSettings(String source, {int baseOffset = 0}) {
  final settings = <String, RawSetting>{};
  final schemeLength = uriSchemeLength(source);
  var authorityEnd = source.length;
  for (var i = schemeLength; i < source.length; i++) {
    final char = source[i];
    if (char == '/' || char == '?') {
      authorityEnd = i;
      break;
    }
  }

  final authority = source.substring(schemeLength, authorityEnd);
  final at = authority.lastIndexOf('@');
  var hostStart = schemeLength;
  if (at >= 0) {
    final userInfo = authority.substring(0, at);
    final colon = userInfo.indexOf(':');
    final userText = colon >= 0 ? userInfo.substring(0, colon) : userInfo;
    final userOffset = baseOffset + schemeLength;
    settings['user'] = RawSetting(
      percentDecode(userText, baseOffset: userOffset),
      userOffset,
    );
    if (colon >= 0) {
      final passwordOffset = userOffset + colon + 1;
      settings['password'] = RawSetting(
        percentDecode(
          userInfo.substring(colon + 1),
          baseOffset: passwordOffset,
        ),
        passwordOffset,
      );
    }
    hostStart = schemeLength + at + 1;
  }

  _parseHostList(
    source.substring(hostStart, authorityEnd),
    baseOffset + hostStart,
    settings,
  );

  var pathEnd = source.length;
  final query = source.indexOf('?', authorityEnd);
  if (query >= 0) pathEnd = query;
  if (authorityEnd < source.length && source[authorityEnd] == '/') {
    final dbOffset = baseOffset + authorityEnd + 1;
    final db = percentDecode(
      source.substring(authorityEnd + 1, pathEnd),
      baseOffset: dbOffset,
    );
    if (db.isNotEmpty) settings['dbname'] = RawSetting(db, dbOffset);
  }

  if (query >= 0) {
    _parseQuery(source.substring(query + 1), baseOffset + query + 1, settings);
  }
  return settings;
}

void _parseHostList(String hostSpec, int offset, RawSettings settings) {
  if (hostSpec.isEmpty) return;
  final hosts = <String>[];
  final ports = <String>[];
  var entryStart = 0;
  while (entryStart <= hostSpec.length) {
    var entryEnd = hostSpec.indexOf(',', entryStart);
    if (hostSpec.startsWith('[', entryStart)) {
      final close = hostSpec.indexOf(']', entryStart);
      if (close < 0) {
        throw PgConfigParseException(
          'Missing "]" after IPv6 host address.',
          offset: offset + entryStart,
        );
      }
      entryEnd = hostSpec.indexOf(',', close);
    }
    if (entryEnd < 0) entryEnd = hostSpec.length;
    final (host, port) = _parseHostEntry(
      hostSpec.substring(entryStart, entryEnd),
      offset + entryStart,
    );
    hosts.add(host);
    ports.add(port);
    entryStart = entryEnd + 1;
  }
  settings['host'] = RawSetting(hosts.join(','), offset);
  if (ports.any((port) => port.isNotEmpty)) {
    settings['port'] = RawSetting(ports.join(','), offset);
  }
}

(String host, String port) _parseHostEntry(String entry, int offset) {
  if (entry.startsWith('[')) {
    final close = entry.indexOf(']');
    if (close == 1) {
      throw PgConfigParseException(
        'IPv6 host address may not be empty.',
        offset: offset,
      );
    }
    final host = percentDecode(entry.substring(1, close), baseOffset: offset);
    final rest = entry.substring(close + 1);
    if (rest.isEmpty) return (host, '');
    if (!rest.startsWith(':')) {
      throw PgConfigParseException(
        'Unexpected characters after "]" in IPv6 host address.',
        offset: offset + close + 1,
      );
    }
    return (host, rest.substring(1));
  }
  final colon = entry.indexOf(':');
  if (colon < 0) return (percentDecode(entry, baseOffset: offset), '');
  if (entry.indexOf(':', colon + 1) >= 0) {
    throw PgConfigParseException(
      'IPv6 host addresses must be enclosed in brackets, e.g. [::1]:5432.',
      offset: offset,
    );
  }
  return (
    percentDecode(entry.substring(0, colon), baseOffset: offset),
    entry.substring(colon + 1),
  );
}

void _parseQuery(String query, int offset, RawSettings settings) {
  var start = 0;
  while (start <= query.length) {
    var end = query.indexOf('&', start);
    if (end < 0) end = query.length;
    final pair = query.substring(start, end);
    if (pair.isNotEmpty) _parseQueryPair(pair, offset + start, settings);
    start = end + 1;
  }
}

/// Parses one `key=value` pair. Like libpq, spaces around the key and the
/// value are ignored, spaces inside them are rejected (use `%20`), and a
/// second `=` is an error.
void _parseQueryPair(String pair, int offset, RawSettings settings) {
  final eq = pair.indexOf('=');
  if (eq < 0) {
    throw PgConfigParseException(
      'URI query parameter is missing the "=" separator.',
      offset: offset,
    );
  }
  if (pair.indexOf('=', eq + 1) >= 0) {
    throw PgConfigParseException(
      'URI query parameter has an extra "=" separator; percent-encode it '
      'as %3D.',
      offset: offset + pair.indexOf('=', eq + 1),
    );
  }
  final key = _trimmedPart(pair, 0, eq, offset);
  final value = _trimmedPart(pair, eq + 1, pair.length, offset);
  final name = percentDecode(key.text, baseOffset: key.offset);
  if (!isKeywordSyntax(name)) {
    throw PgConfigParseException(
      name.isEmpty
          ? 'URI query parameter has an empty name.'
          : 'Invalid URI query parameter name: use letters, digits, and '
                'underscores.',
      offset: offset,
    );
  }
  settings[name] = RawSetting(
    percentDecode(value.text, baseOffset: value.offset),
    value.offset,
  );
}

({String text, int offset}) _trimmedPart(
  String pair,
  int from,
  int to,
  int offset,
) {
  var start = from;
  var end = to;
  while (start < end && pair.codeUnitAt(start) == 0x20) {
    start++;
  }
  while (end > start && pair.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  final text = pair.substring(start, end);
  final space = text.indexOf(' ');
  if (space >= 0) {
    throw PgConfigParseException(
      'Unexpected space in URI query parameter; use %20 instead.',
      offset: offset + start + space,
    );
  }
  return (text: text, offset: offset + start);
}
