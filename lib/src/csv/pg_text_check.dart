// File: pg_text_check.dart
// Purpose: Client-side checks of text values against PostgreSQL types
// (a preview before importing; the server stays the judge), and type
// inference for "create a new table" from sample values.

import 'dart:convert';

/// The outcome of [checkPgText].
enum PgTextCheck {
  /// The server will accept the value.
  ok,

  /// The value is not of the type (e.g. `12x` for an integer).
  invalid,

  /// A number outside the type's range.
  outOfRange,
}

final _integer = RegExp(r'^\s*[+-]?\d+\s*$');
final _decimal = RegExp(r'^\s*[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\s*$');
final _special = RegExp(
  r'^\s*([+-]?(inf|infinity)|nan)\s*$',
  caseSensitive: false,
);
final _uuid = RegExp(
  r'^\s*\{?[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?'
  r'[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}\}?\s*$',
);
final _isoDate = RegExp(r'^\s*(\d{4})-(\d{2})-(\d{2})\s*$');
final _isoTimestamp = RegExp(
  r'^\s*(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(:(\d{2})(\.\d+)?)?'
  r'\s*(Z|[+-]\d{2}(:?\d{2})?)?\s*$',
  caseSensitive: false,
);
final _typmod = RegExp(r'\s*\(.*\)\s*');

typedef _Range = (BigInt, BigInt);

final _Range _int2 = (BigInt.from(-32768), BigInt.from(32767));
final _Range _int4 = (BigInt.from(-2147483648), BigInt.from(2147483647));
final _Range _int8 = (
  BigInt.parse('-9223372036854775808'),
  BigInt.parse('9223372036854775807'),
);

/// Checks [value] against the PostgreSQL type [typeName] (as
/// `format_type` prints it: `integer`, `numeric(10,2)`, `timestamp with
/// time zone`, …). Covers the integer types (with range), numeric and the
/// float types (NaN and Infinity included), boolean (PostgreSQL's
/// spellings and unique prefixes), uuid, json/jsonb, and ISO dates and
/// timestamps. Returns `null` when it cannot tell: another type, or a date
/// in a non-ISO style that depends on the server's DateStyle.
PgTextCheck? checkPgText(String typeName, String value) {
  final type = typeName
      .replaceAll(_typmod, ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ')
      .toLowerCase();
  switch (type) {
    case 'smallint' || 'int2':
      return _checkInt(value, _int2);
    case 'integer' || 'int' || 'int4':
      return _checkInt(value, _int4);
    case 'bigint' || 'int8':
      return _checkInt(value, _int8);
    case 'numeric' || 'decimal':
      return _decimal.hasMatch(value) || _special.hasMatch(value)
          ? PgTextCheck.ok
          : _unknownIfSeparators(value);
    case 'real' || 'float4' || 'double precision' || 'float8' || 'float':
      return _decimal.hasMatch(value) || _special.hasMatch(value)
          ? PgTextCheck.ok
          : PgTextCheck.invalid;
    case 'boolean' || 'bool':
      return _isPgBool(value) ? PgTextCheck.ok : PgTextCheck.invalid;
    case 'uuid':
      return _uuid.hasMatch(value) ? PgTextCheck.ok : PgTextCheck.invalid;
    case 'json' || 'jsonb':
      try {
        jsonDecode(value);
        return PgTextCheck.ok;
      } on FormatException {
        return PgTextCheck.invalid;
      }
    case 'date':
      return _checkDate(value);
    case 'timestamp without time zone' ||
        'timestamp with time zone' ||
        'timestamp' ||
        'timestamptz':
      return _checkTimestamp(value);
    default:
      return null;
  }
}

PgTextCheck? _checkInt(String value, (BigInt, BigInt) range) {
  if (!_integer.hasMatch(value)) return _unknownIfSeparators(value);
  final n = BigInt.parse(value.trim().replaceFirst('+', ''));
  return n < range.$1 || n > range.$2 ? PgTextCheck.outOfRange : PgTextCheck.ok;
}

/// PostgreSQL 16+ also reads `1_000`, `0x1F`, `0o17` and `0b101`; whether
/// this server does is not known here.
PgTextCheck? _unknownIfSeparators(String value) =>
    RegExp(r'^\s*[+-]?(0[xXoObB][0-9a-fA-F_]+|\d+(_\d+)+(\.\d+(_\d+)*)?)\s*$')
        .hasMatch(value)
    ? null
    : PgTextCheck.invalid;

bool _isPgBool(String value) {
  final v = value.trim().toLowerCase();
  if (v.isEmpty) return false;
  if (v == '1' || v == '0') return true;
  // Unique prefixes; "o" alone is ambiguous between "on" and "off".
  for (final word in const ['true', 'false', 'yes', 'no']) {
    if (word.startsWith(v)) return true;
  }
  return v == 'on' || v == 'of' || v == 'off';
}

PgTextCheck? _checkDate(String value) {
  final v = value.trim().toLowerCase();
  if (v == 'infinity' || v == '-infinity' || v == 'epoch') {
    return PgTextCheck.ok;
  }
  final m = _isoDate.firstMatch(value);
  if (m == null) return null;
  return _validDate(m.group(1)!, m.group(2)!, m.group(3)!)
      ? PgTextCheck.ok
      : PgTextCheck.invalid;
}

PgTextCheck? _checkTimestamp(String value) {
  final v = value.trim().toLowerCase();
  if (v == 'infinity' || v == '-infinity' || v == 'epoch' || v == 'now') {
    return PgTextCheck.ok;
  }
  final date = _isoDate.firstMatch(value);
  if (date != null) {
    return _validDate(date.group(1)!, date.group(2)!, date.group(3)!)
        ? PgTextCheck.ok
        : PgTextCheck.invalid;
  }
  final m = _isoTimestamp.firstMatch(value);
  if (m == null) return null;
  final hour = int.parse(m.group(4)!);
  final minute = int.parse(m.group(5)!);
  final second = int.tryParse(m.group(7) ?? '0') ?? 0;
  final timeOk =
      (hour < 24 && minute < 60 && second < 60) ||
      (hour == 24 && minute == 0 && second == 0);
  return _validDate(m.group(1)!, m.group(2)!, m.group(3)!) && timeOk
      ? PgTextCheck.ok
      : PgTextCheck.invalid;
}

bool _validDate(String y, String m, String d) {
  final year = int.parse(y);
  final month = int.parse(m);
  final day = int.parse(d);
  if (month < 1 || month > 12 || day < 1) return false;
  final leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= (month == 2 && leap ? 29 : days[month - 1]);
}

/// Proposes a column type for "create a new table" from sample values:
/// `boolean`, `bigint`, `numeric`, `double precision`, `date`,
/// `timestamptz`, `uuid`, `jsonb`, else `text`. A type is proposed only
/// when every non-empty value fits it, so the guess is never narrower than
/// the sample proves. Numbers with leading zeros (`007`, zip codes) stay
/// text; `0`/`1` columns are numbers, not booleans.
String inferPgType(Iterable<String?> sample) {
  final values = [
    for (final v in sample)
      if (v != null && v.trim().isNotEmpty) v.trim(),
  ];
  if (values.isEmpty) return 'text';
  bool all(bool Function(String v) test) => values.every(test);

  if (all(_isWordBool)) return 'boolean';
  if (all((v) => _isPlainInteger(v) && _checkInt(v, _int8) == PgTextCheck.ok)) {
    return 'bigint';
  }
  if (all((v) => _isPlainDecimal(v, exponent: false))) return 'numeric';
  if (all((v) => _isPlainDecimal(v, exponent: true))) {
    return 'double precision';
  }
  if (all((v) => _isoDate.hasMatch(v) && _checkDate(v) == PgTextCheck.ok)) {
    return 'date';
  }
  if (all(
    (v) => _isoTimestamp.hasMatch(v) && _checkTimestamp(v) == PgTextCheck.ok,
  )) {
    return 'timestamptz';
  }
  if (all((v) => _uuid.hasMatch(v) && v.contains('-'))) return 'uuid';
  if (all(
    (v) =>
        (v.startsWith('{') || v.startsWith('[')) &&
        checkPgText('jsonb', v) == PgTextCheck.ok,
  )) {
    return 'jsonb';
  }
  return 'text';
}

bool _isWordBool(String v) =>
    const {'true', 'false', 't', 'f', 'yes', 'no'}.contains(v.toLowerCase());

bool _hasLeadingZero(String digits) =>
    digits.length > 1 && digits.startsWith('0');

bool _isPlainInteger(String v) {
  if (!RegExp(r'^[+-]?\d+$').hasMatch(v)) return false;
  return !_hasLeadingZero(v.replaceFirst(RegExp('^[+-]'), ''));
}

bool _isPlainDecimal(String v, {required bool exponent}) {
  final pattern = exponent
      ? RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
      : RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$');
  if (!pattern.hasMatch(v)) return false;
  final intPart = v.replaceFirst(RegExp('^[+-]'), '').split(RegExp('[.eE]'))[0];
  return !_hasLeadingZero(intPart);
}
