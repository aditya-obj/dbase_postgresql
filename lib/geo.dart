// File: geo.dart
// Purpose: Narrow entrypoint for decoding PostGIS EWKB / OGC WKB values.

/// Decode the hex EWKB that PostGIS prints for `geometry` and `geography`
/// values (and ISO WKB) into typed geometries with SRID and Z/M flags.
/// Pure Dart; no server or PostGIS needed.
library;

export 'src/geo/ewkb.dart' show decodeEwkb, decodeEwkbHex;
export 'src/geo/geometry.dart'
    show
        GeoBounds,
        GeoCollection,
        GeoLineString,
        GeoMultiLineString,
        GeoMultiPoint,
        GeoMultiPolygon,
        GeoPoint,
        GeoPolygon,
        GeoUnsupported,
        Geometry;
