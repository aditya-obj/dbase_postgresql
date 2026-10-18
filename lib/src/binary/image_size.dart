// File: image_size.dart
// Purpose: Reads an image's pixel size from its header without decoding
// it, so a client can refuse decompression bombs before allocating
// width x height x 4 bytes.

import 'dart:typed_data';

import 'package:dbase_postgresql/src/binary/binary_kind.dart';

/// Width and height in pixels, as an image header declares them.
final class ImageSize {
  /// Creates a size.
  const ImageSize(this.width, this.height);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// `width * height`.
  int get pixels => width * height;

  @override
  bool operator ==(Object other) =>
      other is ImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ImageSize($width x $height)';
}

/// The declared size of a PNG, GIF, JPEG, WebP, BMP or HEIF/AVIF image in
/// [bytes] (the start of the file is enough for all but JPEG, whose size
/// comes after its metadata segments), or `null` when the header is
/// missing, cut or not understood. Never throws.
ImageSize? readImageSize(Uint8List bytes) => switch (detectBinaryKind(bytes)) {
  BinaryKind.png => _png(bytes),
  BinaryKind.gif => _gif(bytes),
  BinaryKind.jpeg => _jpeg(bytes),
  BinaryKind.webp => _webp(bytes),
  BinaryKind.bmp => _bmp(bytes),
  BinaryKind.heif || BinaryKind.avif => _isoBmff(bytes),
  _ => null,
};

ImageSize? _checked(int width, int height) =>
    width > 0 && height > 0 ? ImageSize(width, height) : null;

ImageSize? _png(Uint8List b) {
  // Signature (8), IHDR length (4), "IHDR" (4), width, height (big-endian).
  if (b.length < 24 || String.fromCharCodes(b, 12, 16) != 'IHDR') return null;
  final d = ByteData.sublistView(b);
  return _checked(d.getUint32(16), d.getUint32(20));
}

ImageSize? _gif(Uint8List b) {
  if (b.length < 10) return null;
  final d = ByteData.sublistView(b);
  return _checked(d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
}

ImageSize? _jpeg(Uint8List b) {
  final d = ByteData.sublistView(b);
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // Fill byte.
      continue;
    }
    // Markers without a length: TEM, RST0-7, SOI, EOI.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      i += 2;
      continue;
    }
    final length = d.getUint16(i + 2);
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (i + 9 > b.length) return null;
      return _checked(d.getUint16(i + 7), d.getUint16(i + 5));
    }
    if (length < 2) return null;
    i += 2 + length;
  }
  return null;
}

ImageSize? _webp(Uint8List b) {
  if (b.length < 30) return null;
  final d = ByteData.sublistView(b);
  switch (String.fromCharCodes(b, 12, 16)) {
    case 'VP8 ':
      // Frame tag (3), start code 9d 01 2a, then 14-bit width and height.
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      return _checked(
        d.getUint16(26, Endian.little) & 0x3FFF,
        d.getUint16(28, Endian.little) & 0x3FFF,
      );
    case 'VP8L':
      if (b[20] != 0x2F) return null;
      final bits = d.getUint32(21, Endian.little);
      return _checked((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8X':
      int u24(int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16);
      return _checked(u24(24) + 1, u24(27) + 1);
    default:
      return null;
  }
}

ImageSize? _bmp(Uint8List b) {
  final d = ByteData.sublistView(b);
  final headerSize = d.getUint32(14, Endian.little);
  if (headerSize == 12) {
    return _checked(
      d.getUint16(18, Endian.little),
      d.getUint16(20, Endian.little),
    );
  }
  // Negative height = top-down rows.
  return _checked(
    d.getInt32(18, Endian.little),
    d.getInt32(22, Endian.little).abs(),
  );
}

/// HEIF/AVIF: the largest `ispe` (image spatial extents) property box.
ImageSize? _isoBmff(Uint8List b) {
  final d = ByteData.sublistView(b);
  ImageSize? best;
  // "ispe" = 69 73 70 65, then version/flags (4), width, height (uint32).
  for (var i = 4; i + 16 <= b.length; i++) {
    if (b[i] == 0x69 &&
        b[i + 1] == 0x73 &&
        b[i + 2] == 0x70 &&
        b[i + 3] == 0x65) {
      final size = _checked(d.getUint32(i + 8), d.getUint32(i + 12));
      if (size != null && (best == null || size.pixels > best.pixels)) {
        best = size;
      }
    }
  }
  return best;
}
