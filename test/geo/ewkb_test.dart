// File: ewkb_test.dart
// Purpose: Unit tests for the EWKB / WKB decoder: every geometry type,
// SRID, Z/M flags (EWKB and ISO), both byte orders, unsupported curve
// types and malformed or hostile input.

// The WKB builder below is fluent on purpose: chained calls keep each
// test's byte layout readable.
// ignore_for_file: avoid_returning_this

import 'dart:typed_data';

import 'package:dbase_postgresql/binary.dart';
import 'package:dbase_postgresql/geo.dart';
import 'package:test/test.dart';

/// Builds WKB for tests.
final class _Wkb {
  _Wkb({this.endian = Endian.little});

  final Endian endian;
  final _out = BytesBuilder();

  _Wkb header(int type, {int? srid}) {
    _out.addByte(endian == Endian.little ? 1 : 0);
    u32(srid == null ? type : type | 0x20000000);
    if (srid != null) u32(srid);
    return this;
  }

  _Wkb u32(int v) {
    final d = ByteData(4)..setUint32(0, v, endian);
    _out.add(d.buffer.asUint8List());
    return this;
  }

  _Wkb f64(List<double> values) {
    for (final v in values) {
      final d = ByteData(8)..setFloat64(0, v, endian);
      _out.add(d.buffer.asUint8List());
    }
    return this;
  }

  _Wkb raw(List<int> bytes) {
    _out.add(bytes);
    return this;
  }

  Uint8List get bytes => _out.toBytes();
  String get hex => bytesToHex(bytes);
}

void main() {
  test('PostGIS output: SRID=4326;POINT(1 2)', () {
    final g = decodeEwkbHex(
      '0101000020E6100000000000000000F03F0000000000000040',
    );
    expect(g, isA<GeoPoint>());
    final p = g as GeoPoint;
    expect((p.x, p.y, p.srid, p.hasZ, p.hasM), (1.0, 2.0, 4326, false, false));
    expect(p.bounds, const GeoBounds(1, 2, 1, 2));
    expect(p.vertexCount, 1);
  });

  test(r'big-endian, no SRID; bytea-style \x prefix accepted', () {
    final w = _Wkb(endian: Endian.big).header(1).f64([3, 4]);
    final p = decodeEwkbHex(r'\x' + w.hex) as GeoPoint;
    expect((p.x, p.y, p.srid), (3.0, 4.0, 0));
  });

  test('EWKB Z and M flags, and ISO ZM type numbers', () {
    final zm = decodeEwkb(
      _Wkb().header(0x80000001 | 0x40000000, srid: 3857).f64([
        1,
        2,
        3,
        4,
      ]).bytes,
    ) as GeoPoint;
    expect(
      (zm.z, zm.m, zm.hasZ, zm.hasM, zm.srid),
      (3.0, 4.0, true, true, 3857),
    );

    final iso = decodeEwkb(
      _Wkb().header(3002).u32(2).f64([0, 0, 1, 2, 5, 5, 3, 4]).bytes,
    ) as GeoLineString;
    expect(iso.hasZ && iso.hasM, isTrue);
    expect(iso.xy, [0, 0, 5, 5]);
    expect(iso.z, [1, 3]);
    expect(iso.m, [2, 4]);

    final m = decodeEwkb(_Wkb().header(2001).f64([1, 2, 9]).bytes) as GeoPoint;
    expect((m.hasZ, m.hasM, m.m), (false, true, 9.0));
  });

  test('LineString and Polygon with a hole', () {
    final line = decodeEwkb(
      _Wkb().header(2, srid: 4326).u32(3).f64([0, 0, 1, 1, 2, 0]).bytes,
    ) as GeoLineString;
    expect(line.vertexCount, 3);
    expect(line.bounds, const GeoBounds(0, 0, 2, 1));

    final polygon = decodeEwkb(
      _Wkb()
          .header(3)
          .u32(2)
          .u32(5)
          .f64([0, 0, 10, 0, 10, 10, 0, 10, 0, 0])
          .u32(4)
          .f64([2, 2, 3, 2, 2, 3, 2, 2])
          .bytes,
    ) as GeoPolygon;
    expect(polygon.rings, hasLength(2));
    expect(polygon.vertexCount, 9);
    expect(polygon.bounds, const GeoBounds(0, 0, 10, 10));
  });

  test('Multi* and nested collections; members may switch byte order', () {
    final multiPoint = decodeEwkb(
      _Wkb()
          .header(4, srid: 4326)
          .u32(2)
          .header(1)
          .f64([1, 1])
          .raw(_Wkb(endian: Endian.big).header(1).f64([-1, 5]).bytes)
          .bytes,
    ) as GeoMultiPoint;
    expect(multiPoint.srid, 4326);
    expect(multiPoint.points.map((p) => (p.x, p.y)), [(1.0, 1.0), (-1.0, 5.0)]);
    expect(multiPoint.bounds, const GeoBounds(-1, 1, 1, 5));

    final multiLine = decodeEwkb(
      _Wkb().header(5).u32(1).header(2).u32(2).f64([0, 0, 1, 1]).bytes,
    ) as GeoMultiLineString;
    expect(multiLine.lines.single.vertexCount, 2);

    final multiPolygon = decodeEwkb(
      _Wkb().header(6).u32(1).header(3).u32(1).u32(4).f64([
        0,
        0,
        1,
        0,
        0,
        1,
        0,
        0,
      ]).bytes,
    ) as GeoMultiPolygon;
    expect(multiPolygon.polygons.single.rings.single.vertexCount, 4);

    final collection = decodeEwkb(
      _Wkb()
          .header(7, srid: 4326)
          .u32(2)
          .header(1)
          .f64([7, 8])
          .header(7)
          .u32(1)
          .header(2)
          .u32(2)
          .f64([0, 0, 2, 2])
          .bytes,
    ) as GeoCollection;
    expect(collection.geometries, hasLength(2));
    expect(collection.geometries.last, isA<GeoCollection>());
    expect(collection.vertexCount, 3);
    expect(collection.bounds, const GeoBounds(0, 0, 7, 8));
  });

  test('empty geometries', () {
    final emptyPoint = decodeEwkb(
      _Wkb().header(1).f64([double.nan, double.nan]).bytes,
    );
    expect(emptyPoint.isEmpty, isTrue);
    expect(emptyPoint.vertexCount, 0);
    final emptyCollection = decodeEwkb(_Wkb().header(7).u32(0).bytes);
    expect(emptyCollection.bounds, isNull);
  });

  test('curves are reported, not drawn', () {
    final g = decodeEwkb(_Wkb().header(8, srid: 4326).u32(3).bytes);
    expect(g, isA<GeoUnsupported>());
    expect((g as GeoUnsupported).typeName, 'CircularString');
    expect(g.srid, 4326);
    // Inside a collection, the whole value is unsupported.
    final nested = decodeEwkb(_Wkb().header(7).u32(1).header(9).bytes);
    expect((nested as GeoUnsupported).typeName, 'CompoundCurve');
  });

  group('malformed input throws FormatException without echoing it', () {
    final cases = <String, String>{
      'odd hex': '010',
      'bad hex digit': '01zz',
      'empty': '',
      'bad byte order': '0201000000',
      'cut coordinates': _Wkb().header(1).f64([1]).hex,
      'unknown type': _Wkb().header(99).hex,
      'huge count': _Wkb().header(2).u32(0x7FFFFFFF).hex,
      'trailing bytes': '${_Wkb().header(1).f64([1, 2]).hex}00',
      'wrong member type': _Wkb().header(4).u32(1).header(2).u32(0).hex,
    };
    for (final MapEntry(key: name, value: hex) in cases.entries) {
      test(name, () {
        expect(
          () => decodeEwkbHex(hex),
          throwsA(
            isA<FormatException>().having((e) => e.source, 'source', isNull),
          ),
        );
      });
    }

    test('nesting depth is capped', () {
      final w = _Wkb();
      for (var i = 0; i < 40; i++) {
        w.header(7).u32(1);
      }
      w.header(1).f64([0, 0]);
      expect(() => decodeEwkb(w.bytes), throwsFormatException);
    });
  });
}
