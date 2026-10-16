// File: conninfo_parser.dart
// Purpose: Parses libpq key=value conninfo strings into raw keyword settings
// (internal, not exported).

import 'package:dbase_postgresql/src/config/libpq_keywords.dart';
import 'package:dbase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dbase_postgresql/src/config/raw_setting.dart';

/// Parses `host=db.example.com port=5432 password='it\'s secret'`.
///
/// Follows libpq: keywords and values are separated by `=` with optional
/// surrounding whitespace; values are either unquoted (ending at
/// whitespace) or single-quoted. In both forms a backslash escapes the next
/// character, so `\'` and `\\` work.
///
/// Error messages quote a keyword only when it is a known libpq keyword:
/// in `host=db hunter2` the "keyword" `hunter2` is really a password.
RawSettings parseConninfoSettings(String source) {
  final settings = <String, RawSetting>{};
  var i = 0;
  while (true) {
    i = _skipSpace(source, i);
    if (i >= source.length) break;

    final keyStart = i;
    while (i < source.length && source[i] != '=' && !_isSpace(source, i)) {
      i++;
    }
    final key = source.substring(keyStart, i);
    if (key.isEmpty) {
      throw PgConfigParseException(
        'Missing keyword before "=".',
        offset: keyStart,
      );
    }
    if (!isKeywordSyntax(key)) {
      throw PgConfigParseException(
        'Invalid keyword: use letters, digits, and underscores. Check that '
        'a postgres:// URI scheme is spelled correctly.',
        offset: keyStart,
      );
    }
    i = _skipSpace(source, i);
    if (i >= source.length || source[i] != '=') {
      throw PgConfigParseException(
        'Missing "=" after ${describeKeyword(key)}.',
        offset: i,
      );
    }
    i = _skipSpace(source, i + 1);

    final valueStart = i;
    final value = StringBuffer();
    if (i < source.length && source[i] == "'") {
      i++;
      var closed = false;
      while (i < source.length) {
        final char = source[i];
        if (char == r'\') {
          if (i + 1 >= source.length) break;
          value.write(source[i + 1]);
          i += 2;
        } else if (char == "'") {
          i++;
          closed = true;
          break;
        } else {
          value.write(char);
          i++;
        }
      }
      if (!closed) {
        throw PgConfigParseException(
          'Unterminated quoted value for ${describeKeyword(key)}.',
          offset: valueStart,
        );
      }
    } else {
      while (i < source.length && !_isSpace(source, i)) {
        if (source[i] == r'\' && i + 1 < source.length) i++;
        value.write(source[i]);
        i++;
      }
    }
    settings[key] = RawSetting(value.toString(), valueStart);
  }
  return settings;
}

bool _isSpace(String source, int i) {
  final unit = source.codeUnitAt(i);
  return unit == 0x20 || (unit >= 0x09 && unit <= 0x0D);
}

int _skipSpace(String source, int start) {
  var i = start;
  while (i < source.length && _isSpace(source, i)) {
    i++;
  }
  return i;
}
