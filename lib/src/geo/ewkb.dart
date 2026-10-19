// File: ewkb.dart
// Purpose: Decodes PostGIS EWKB (what `geometry_out` / `geography_out`
// print as hex) and ISO/OGC WKB into Geometry values. Both byte orders,
// the EWKB SRID/Z/M flags and ISO Z/M/ZM type numbers are understood.
// Notes: Input is untrusted: every count is checked against the bytes
// left before anything is allocated, and nesting is capped, so malformed
// or hostile values fail fast with a FormatException that never repeats
// the input.

import 'dart:typed_data';

import 'package:dabase_postgresql/src/geo/geometry.dart';

const _sridFlag = 0x20000000;
const _zFlag = 0x80000000;
const _mFlag = 0x40000000;
const _maxDepth = 32;

/// Decodes [hex] (an EWKB or WKB value as hex digits, as `geometry_out`
/// prints it; an optional `\x` prefix from a `bytea` is accepted).
///
/// Throws [FormatException] for invalid hex or malformed WKB. Curved and
/// surface types come back as [GeoUnsupported].
Geometry decodeEwkbHex(String hex) {
  final start = hex.startsWith(r'\x') ? 2 : 0;
  final digits = hex.length - start;
  if (digits.isOdd) {
    throw const FormatException('Odd number of hex digits in WKB');
  }
  final bytes = Uint8List(digits >> 1);
  for (var i = 0; i < bytes.length; i++) {
    final hi = _hexValue(hex.codeUnitAt(start + 2 * i));
    final lo = _hexValue(hex.codeUnitAt(start + 2 * i + 1));
    if (hi < 0 || lo < 0) {
      throw FormatException('Invalid hex digit in WKB at offset ${2 * i}');
    }
    bytes[i] = (hi << 4) | lo;
  }
  return decodeEwkb(bytes);
}

/// Decodes [bytes] (EWKB or ISO WKB). See [decodeEwkbHex].
Geometry decodeEwkb(Uint8List bytes) {
  final reader = _WkbReader(bytes);
  try {
    final geometry = reader.geometry(0);
    if (geometry is! GeoUnsupported && reader.offset != bytes.length) {
      throw FormatException(
        'Unexpected trailing bytes in WKB at offset ${reader.offset}',
      );
    }
    return geometry;
  } on _Unsupported catch (u) {
    return GeoUnsupported(u.typeCode, srid: u.srid);
  }
}

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

/// Thrown internally when a type isn't decoded; ends decoding.
final class _Unsupported implements Exception {
  const _Unsupported(this.typeCode, this.srid);
  final int typeCode;
  final int srid;
}

final class _WkbReader {
  _WkbReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  int offset = 0;
  Endian _endian = Endian.little;

  int get _left => _bytes.length - offset;

  void _need(int n) {
    if (n > _left) {
      throw FormatException('WKB ends early at offset $offset');
    }
  }

  int _uint32() {
    _need(4);
    final v = _data.getUint32(offset, _endian);
    offset += 4;
    return v;
  }

  double _float64() {
    _need(8);
    final v = _data.getFloat64(offset, _endian);
    offset += 8;
    return v;
  }

  /// A count of items that each take at least [minBytes].
  int _count(int minBytes) {
    final n = _uint32();
    if (n * minBytes > _left) {
      throw FormatException('WKB count too large at offset ${offset - 4}');
    }
    return n;
  }

  Geometry geometry(int depth, {int? expectType}) {
    if (depth > _maxDepth) {
      throw const FormatException('WKB nested too deeply');
    }
    _need(5);
    _endian = switch (_bytes[offset]) {
      0 => Endian.big,
      1 => Endian.little,
      _ => throw FormatException('Invalid WKB byte order at offset $offset'),
    };
    offset++;
    final raw = _uint32();
    var hasZ = raw & _zFlag != 0;
    var hasM = raw & _mFlag != 0;
    var code = raw & 0x0FFFFFFF;
    // ISO WKB: 1001 = Point Z, 2001 = Point M, 3001 = Point ZM.
    if (code >= 1000 && code < 4000) {
      final dims = code ~/ 1000;
      hasZ = hasZ || dims == 1 || dims == 3;
      hasM = hasM || dims == 2 || dims == 3;
      code %= 1000;
    }
    final srid = raw & _sridFlag != 0 ? _uint32() : 0;
    if (code >= 8 && code <= 17) throw _Unsupported(code, srid);
    if (expectType != null && code != expectType) {
      throw FormatException('Unexpected WKB member type $code');
    }
    final dims = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0);
    return switch (code) {
      1 => _point(srid, hasZ, hasM),
      2 => _line(srid, hasZ, hasM, dims),
      3 => _polygon(srid, hasZ, hasM, dims),
      4 => GeoMultiPoint(
        [
          for (var i = 0, n = _count(5); i < n; i++)
            geometry(depth + 1, expectType: 1) as GeoPoint,
        ],
        srid: srid,
        hasZ: hasZ,
        hasM: hasM,
      ),
      5 => GeoMultiLineString(
        [
          for (var i = 0, n = _count(9); i < n; i++)
            geometry(depth + 1, expectType: 2) as GeoLineString,
        ],
        srid: srid,
        hasZ: hasZ,
        hasM: hasM,
      ),
      6 => GeoMultiPolygon(
        [
          for (var i = 0, n = _count(9); i < n; i++)
            geometry(depth + 1, expectType: 3) as GeoPolygon,
        ],
        srid: srid,
        hasZ: hasZ,
        hasM: hasM,
      ),
      7 => GeoCollection(
        [for (var i = 0, n = _count(5); i < n; i++) geometry(depth + 1)],
        srid: srid,
        hasZ: hasZ,
        hasM: hasM,
      ),
      _ => throw FormatException('Unknown WKB geometry type $code'),
    };
  }

  GeoPoint _point(int srid, bool hasZ, bool hasM) {
    final x = _float64();
    final y = _float64();
    final z = hasZ ? _float64() : null;
    final m = hasM ? _float64() : null;
    return GeoPoint(x, y, z: z, m: m, srid: srid, hasZ: hasZ, hasM: hasM);
  }

  GeoLineString _line(int srid, bool hasZ, bool hasM, int dims) {
    final n = _count(8 * dims);
    final xy = Float64List(2 * n);
    final z = hasZ ? Float64List(n) : null;
    final m = hasM ? Float64List(n) : null;
    for (var i = 0; i < n; i++) {
      xy[2 * i] = _float64();
      xy[2 * i + 1] = _float64();
      if (z != null) z[i] = _float64();
      if (m != null) m[i] = _float64();
    }
    return GeoLineString(xy, z: z, m: m, srid: srid, hasZ: hasZ, hasM: hasM);
  }

  GeoPolygon _polygon(int srid, bool hasZ, bool hasM, int dims) => GeoPolygon(
    [for (var i = 0, n = _count(4); i < n; i++) _line(0, hasZ, hasM, dims)],
    srid: srid,
    hasZ: hasZ,
    hasM: hasM,
  );
}
