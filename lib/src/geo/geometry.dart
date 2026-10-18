// File: geometry.dart
// Purpose: Immutable geometry values decoded from (E)WKB: points, line
// strings, polygons, their Multi* forms and collections, with optional
// Z/M ordinates and the SRID.

import 'dart:math' as math;
import 'dart:typed_data';

/// An axis-aligned bounding box in the geometry's own units.
final class GeoBounds {
  /// Creates a box; callers keep `minX <= maxX` and `minY <= maxY`.
  const GeoBounds(this.minX, this.minY, this.maxX, this.maxY);

  /// West edge.
  final double minX;

  /// South edge.
  final double minY;

  /// East edge.
  final double maxX;

  /// North edge.
  final double maxY;

  /// Width (`maxX - minX`).
  double get width => maxX - minX;

  /// Height (`maxY - minY`).
  double get height => maxY - minY;

  /// The smallest box holding this box and [other].
  GeoBounds union(GeoBounds other) => GeoBounds(
    math.min(minX, other.minX),
    math.min(minY, other.minY),
    math.max(maxX, other.maxX),
    math.max(maxY, other.maxY),
  );

  @override
  bool operator ==(Object other) =>
      other is GeoBounds &&
      other.minX == minX &&
      other.minY == minY &&
      other.maxX == maxX &&
      other.maxY == maxY;

  @override
  int get hashCode => Object.hash(minX, minY, maxX, maxY);

  @override
  String toString() => 'GeoBounds($minX, $minY, $maxX, $maxY)';
}

/// A decoded geometry. [srid] is set on the outermost geometry when the
/// EWKB carried one (`0` otherwise); nested geometries inherit nothing.
sealed class Geometry {
  const Geometry({this.srid = 0, this.hasZ = false, this.hasM = false});

  /// Spatial reference id from EWKB, `0` when absent.
  final int srid;

  /// The coordinates carry a Z (elevation) ordinate.
  final bool hasZ;

  /// The coordinates carry an M (measure) ordinate.
  final bool hasM;

  /// Number of vertices, nested geometries included.
  int get vertexCount;

  /// Bounding box of the X/Y ordinates, `null` when empty.
  GeoBounds? get bounds;

  /// Whether there are no coordinates at all.
  bool get isEmpty => bounds == null;
}

GeoBounds? _boundsOf(Float64List xy) {
  if (xy.isEmpty) return null;
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (var i = 0; i + 1 < xy.length; i += 2) {
    final x = xy[i];
    final y = xy[i + 1];
    if (x.isNaN || y.isNaN) continue;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return minX.isFinite ? GeoBounds(minX, minY, maxX, maxY) : null;
}

GeoBounds? _unionAll(Iterable<Geometry> parts) {
  GeoBounds? out;
  for (final p in parts) {
    final b = p.bounds;
    if (b != null) out = out == null ? b : out.union(b);
  }
  return out;
}

/// A point. An empty point (`POINT EMPTY`) has NaN ordinates.
final class GeoPoint extends Geometry {
  /// Creates a point.
  const GeoPoint(
    this.x,
    this.y, {
    this.z,
    this.m,
    super.srid,
    super.hasZ,
    super.hasM,
  });

  /// X (longitude for geographic data).
  final double x;

  /// Y (latitude for geographic data).
  final double y;

  /// Z ordinate when [hasZ].
  final double? z;

  /// M ordinate when [hasM].
  final double? m;

  @override
  int get vertexCount => isEmpty ? 0 : 1;

  @override
  GeoBounds? get bounds => x.isNaN || y.isNaN ? null : GeoBounds(x, y, x, y);
}

/// A line string, also used for polygon rings. [xy] holds `x0, y0, x1,
/// y1, ...`; [z] and [m] one value per vertex when present.
final class GeoLineString extends Geometry {
  /// Creates a line string.
  const GeoLineString(
    this.xy, {
    this.z,
    this.m,
    super.srid,
    super.hasZ,
    super.hasM,
  });

  /// Interleaved X/Y ordinates.
  final Float64List xy;

  /// Z per vertex when [hasZ].
  final Float64List? z;

  /// M per vertex when [hasM].
  final Float64List? m;

  @override
  int get vertexCount => xy.length >> 1;

  @override
  GeoBounds? get bounds => _boundsOf(xy);
}

/// A polygon: the first ring is the shell, the rest are holes.
final class GeoPolygon extends Geometry {
  /// Creates a polygon.
  const GeoPolygon(this.rings, {super.srid, super.hasZ, super.hasM});

  /// Shell, then holes; each ring is closed (first = last vertex).
  final List<GeoLineString> rings;

  @override
  int get vertexCount => rings.fold(0, (n, r) => n + r.vertexCount);

  @override
  GeoBounds? get bounds => _unionAll(rings);
}

/// Several points.
final class GeoMultiPoint extends Geometry {
  /// Creates a multi point.
  const GeoMultiPoint(this.points, {super.srid, super.hasZ, super.hasM});

  /// The points.
  final List<GeoPoint> points;

  @override
  int get vertexCount => points.fold(0, (n, p) => n + p.vertexCount);

  @override
  GeoBounds? get bounds => _unionAll(points);
}

/// Several line strings.
final class GeoMultiLineString extends Geometry {
  /// Creates a multi line string.
  const GeoMultiLineString(this.lines, {super.srid, super.hasZ, super.hasM});

  /// The line strings.
  final List<GeoLineString> lines;

  @override
  int get vertexCount => lines.fold(0, (n, l) => n + l.vertexCount);

  @override
  GeoBounds? get bounds => _unionAll(lines);
}

/// Several polygons.
final class GeoMultiPolygon extends Geometry {
  /// Creates a multi polygon.
  const GeoMultiPolygon(this.polygons, {super.srid, super.hasZ, super.hasM});

  /// The polygons.
  final List<GeoPolygon> polygons;

  @override
  int get vertexCount => polygons.fold(0, (n, p) => n + p.vertexCount);

  @override
  GeoBounds? get bounds => _unionAll(polygons);
}

/// A geometry collection (may nest).
final class GeoCollection extends Geometry {
  /// Creates a collection.
  const GeoCollection(this.geometries, {super.srid, super.hasZ, super.hasM});

  /// The members.
  final List<Geometry> geometries;

  @override
  int get vertexCount => geometries.fold(0, (n, g) => n + g.vertexCount);

  @override
  GeoBounds? get bounds => _unionAll(geometries);
}

/// A type this decoder doesn't draw (CircularString, CompoundCurve,
/// CurvePolygon, MultiCurve, MultiSurface, PolyhedralSurface, TIN,
/// Triangle). Decoding stops at it, so it is only ever returned as the
/// whole value: its body is not parsed.
final class GeoUnsupported extends Geometry {
  /// Creates the marker for WKB type [typeCode].
  const GeoUnsupported(this.typeCode, {super.srid, super.hasZ, super.hasM});

  /// Base WKB type number (8 to 17).
  final int typeCode;

  /// OGC name of [typeCode].
  String get typeName => switch (typeCode) {
    8 => 'CircularString',
    9 => 'CompoundCurve',
    10 => 'CurvePolygon',
    11 => 'MultiCurve',
    12 => 'MultiSurface',
    13 => 'Curve',
    14 => 'Surface',
    15 => 'PolyhedralSurface',
    16 => 'TIN',
    17 => 'Triangle',
    _ => 'Geometry type $typeCode',
  };

  @override
  int get vertexCount => 0;

  @override
  GeoBounds? get bounds => null;
}
