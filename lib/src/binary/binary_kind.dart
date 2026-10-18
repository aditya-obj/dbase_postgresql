// File: binary_kind.dart
// Purpose: Guesses what a binary value holds from its first bytes (magic
// numbers), so a client can label it, preview images and suggest a file
// extension when sharing.

import 'dart:typed_data';

/// File formats recognised by [detectBinaryKind].
enum BinaryKind {
  /// PNG image.
  png('image/png', 'png', isImage: true),

  /// JPEG image.
  jpeg('image/jpeg', 'jpg', isImage: true),

  /// GIF image (87a or 89a).
  gif('image/gif', 'gif', isImage: true),

  /// WebP image (RIFF container).
  webp('image/webp', 'webp', isImage: true),

  /// Windows bitmap.
  bmp('image/bmp', 'bmp', isImage: true),

  /// HEIF / HEIC image (ISO base media file with a HEIF brand).
  heif('image/heif', 'heic', isImage: true),

  /// AVIF image.
  avif('image/avif', 'avif', isImage: true),

  /// PDF document.
  pdf('application/pdf', 'pdf'),

  /// ZIP archive (also docx, xlsx, jar, apk).
  zip('application/zip', 'zip'),

  /// gzip stream.
  gzip('application/gzip', 'gz'),

  /// Zstandard frame.
  zstd('application/zstd', 'zst'),

  /// SQLite 3 database file.
  sqlite('application/vnd.sqlite3', 'sqlite'),

  /// Not recognised.
  unknown('application/octet-stream', 'bin');

  const BinaryKind(this.mimeType, this.extension, {this.isImage = false});

  /// MIME type to use when sharing the bytes as a file.
  final String mimeType;

  /// File name extension without the dot.
  final String extension;

  /// An image format a client might preview.
  final bool isImage;
}

const _heifBrands = {'heic', 'heix', 'heim', 'heis', 'hevc', 'mif1', 'msf1'};
const _avifBrands = {'avif', 'avis'};

/// The format [head] (the first bytes of a value; 32 are enough) starts
/// with, or [BinaryKind.unknown].
BinaryKind detectBinaryKind(Uint8List head) {
  bool at(int offset, List<int> magic) {
    if (head.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (head[offset + i] != magic[i]) return false;
    }
    return true;
  }

  bool ascii(int offset, String text) => at(offset, text.codeUnits);

  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return BinaryKind.png;
  }
  if (at(0, const [0xFF, 0xD8, 0xFF])) return BinaryKind.jpeg;
  if (ascii(0, 'GIF87a') || ascii(0, 'GIF89a')) return BinaryKind.gif;
  if (ascii(0, 'RIFF') && ascii(8, 'WEBP')) return BinaryKind.webp;
  if (ascii(0, 'BM') && head.length >= 26) return BinaryKind.bmp;
  if (ascii(4, 'ftyp') && head.length >= 12) {
    final brand = String.fromCharCodes(head, 8, 12);
    if (_avifBrands.contains(brand)) return BinaryKind.avif;
    if (_heifBrands.contains(brand)) return BinaryKind.heif;
  }
  if (ascii(0, '%PDF-')) return BinaryKind.pdf;
  if (at(0, const [0x50, 0x4B, 0x03, 0x04])) return BinaryKind.zip;
  if (at(0, const [0x1F, 0x8B])) return BinaryKind.gzip;
  if (at(0, const [0x28, 0xB5, 0x2F, 0xFD])) return BinaryKind.zstd;
  if (ascii(0, 'SQLite format 3\u0000')) return BinaryKind.sqlite;
  return BinaryKind.unknown;
}
