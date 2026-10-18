// File: binary_test.dart
// Purpose: Unit tests for bytea text decoding (hex and escape formats,
// cut input), magic-byte detection and image header sizes.

import 'dart:typed_data';

import 'package:dbase_postgresql/binary.dart';
import 'package:test/test.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

Uint8List _png(int w, int h) {
  final d = ByteData(24);
  _b(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      .asMap()
      .forEach(d.setUint8);
  d
    ..setUint32(8, 13)
    ..setUint32(16, w)
    ..setUint32(20, h);
  'IHDR'.codeUnits.asMap().forEach((i, c) => d.setUint8(12 + i, c));
  return d.buffer.asUint8List();
}

void main() {
  group('decodeByteaText', () {
    test('hex format, either case, whitespace between pairs', () {
      expect(decodeByteaText(r'\xDEADbeef'), [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(decodeByteaText(r'\x'), isEmpty);
      expect(decodeByteaText(r'\x00 ff'), [0, 255]);
    });

    test('a cut hex value drops the odd nibble only when allowed', () {
      expect(() => decodeByteaText(r'\xabc'), throwsA(isA<FormatException>()));
      expect(decodeByteaText(r'\xabc', allowTruncated: true), [0xAB]);
    });

    test('invalid hex digit names the offset, not the value', () {
      expect(
        () => decodeByteaText(r'\x0g'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('offset 3'), isNot(contains('0g'))),
          ),
        ),
      );
    });

    test('escape format: octal, doubled backslash, plain ASCII', () {
      expect(decodeByteaText(r'a\\b\000\377z'), [
        0x61,
        0x5C,
        0x62,
        0,
        255,
        0x7A,
      ]);
      expect(decodeByteaText(''), isEmpty);
      // Non-ASCII stands for its UTF-8 bytes (what byteain does).
      expect(decodeByteaText('é'), [0xC3, 0xA9]);
    });

    test('escape format errors and cut escapes', () {
      expect(() => decodeByteaText(r'a\q'), throwsFormatException);
      expect(() => decodeByteaText(r'\400'), throwsFormatException);
      expect(() => decodeByteaText(r'ab\0'), throwsFormatException);
      expect(decodeByteaText(r'ab\0', allowTruncated: true), [0x61, 0x62]);
      expect(decodeByteaText(r'ab\', allowTruncated: true), [0x61, 0x62]);
    });

    test('bytesToHex', () {
      expect(bytesToHex(const [0, 15, 16, 255]), '000f10ff');
    });
  });

  group('detectBinaryKind', () {
    final cases = <BinaryKind, List<int>>{
      BinaryKind.png: _png(1, 1),
      BinaryKind.jpeg: const [0xFF, 0xD8, 0xFF, 0xE0],
      BinaryKind.gif: 'GIF89a'.codeUnits,
      BinaryKind.webp: [...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits],
      BinaryKind.bmp: [...'BM'.codeUnits, ...List.filled(30, 0)],
      BinaryKind.heif: [0, 0, 0, 24, ...'ftypheic'.codeUnits],
      BinaryKind.avif: [0, 0, 0, 24, ...'ftypavif'.codeUnits],
      BinaryKind.pdf: '%PDF-1.7'.codeUnits,
      BinaryKind.zip: const [0x50, 0x4B, 0x03, 0x04, 0],
      BinaryKind.gzip: const [0x1F, 0x8B, 8],
      BinaryKind.zstd: const [0x28, 0xB5, 0x2F, 0xFD],
      BinaryKind.sqlite: 'SQLite format 3\u0000'.codeUnits,
      BinaryKind.unknown: const [1, 2, 3],
    };
    for (final MapEntry(key: kind, value: bytes) in cases.entries) {
      test(kind.name, () => expect(detectBinaryKind(_b(bytes)), kind));
    }

    test('short input and look-alikes are unknown', () {
      expect(detectBinaryKind(_b(const [])), BinaryKind.unknown);
      expect(detectBinaryKind(_b('RIFF'.codeUnits)), BinaryKind.unknown);
      expect(
        detectBinaryKind(_b([0, 0, 0, 24, ...'ftypisom'.codeUnits])),
        BinaryKind.unknown,
      );
    });

    test('labels', () {
      expect(BinaryKind.jpeg.extension, 'jpg');
      expect(BinaryKind.png.mimeType, 'image/png');
      expect(BinaryKind.png.isImage, isTrue);
      expect(BinaryKind.pdf.isImage, isFalse);
    });
  });

  group('readImageSize', () {
    test('PNG from IHDR (a 16 MP bomb is readable before decoding)', () {
      expect(readImageSize(_png(640, 480)), const ImageSize(640, 480));
      expect(readImageSize(_png(20000, 20000))!.pixels, 400000000);
    });

    test('GIF logical screen', () {
      expect(
        readImageSize(_b([...'GIF89a'.codeUnits, 0x40, 0x01, 0xF0, 0x00])),
        const ImageSize(320, 240),
      );
    });

    test('JPEG: skips APP segments and fill bytes to SOF', () {
      final bytes = _b([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, 2 bytes of data
        0xFF, 0xFF, // fill
        0xFF, 0xC2, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80, // SOF2
      ]);
      expect(readImageSize(bytes), const ImageSize(640, 480));
      // Cut before the frame header.
      expect(readImageSize(_b(bytes.sublist(0, 12))), isNull);
    });

    test('WebP lossy, lossless and extended', () {
      List<int> riff(String chunk, List<int> body) => [
        ...'RIFF'.codeUnits,
        0, 0, 0, 0, //
        ...'WEBP'.codeUnits,
        ...chunk.codeUnits,
        0, 0, 0, 0, //
        ...body,
        ...List.filled(10, 0),
      ];
      expect(
        readImageSize(
          _b(riff('VP8 ', [0, 0, 0, 0x9D, 0x01, 0x2A, 0x80, 0x02, 0xE0, 0x01])),
        ),
        const ImageSize(640, 480),
      );
      // VP8L: 14 bits width-1, 14 bits height-1.
      const bits = (640 - 1) | ((480 - 1) << 14);
      expect(
        readImageSize(
          _b(
            riff('VP8L', [
              0x2F,
              bits & 0xFF,
              (bits >> 8) & 0xFF,
              (bits >> 16) & 0xFF,
              (bits >> 24) & 0xFF,
            ]),
          ),
        ),
        const ImageSize(640, 480),
      );
      expect(
        readImageSize(
          _b(riff('VP8X', [0, 0, 0, 0, 0x7F, 0x02, 0, 0xDF, 0x01, 0])),
        ),
        const ImageSize(640, 480),
      );
    });

    test('BMP, including top-down negative height', () {
      final d = ByteData(26)
        ..setUint8(0, 0x42)
        ..setUint8(1, 0x4D)
        ..setUint32(14, 40, Endian.little)
        ..setInt32(18, 100, Endian.little)
        ..setInt32(22, -50, Endian.little);
      expect(readImageSize(d.buffer.asUint8List()), const ImageSize(100, 50));
    });

    test('HEIF: largest ispe box', () {
      final d = ByteData(64);
      'ftypheic'.codeUnits.asMap().forEach((i, c) => d.setUint8(4 + i, c));
      void ispe(int at, int w, int h) {
        'ispe'.codeUnits.asMap().forEach((i, c) => d.setUint8(at + i, c));
        d
          ..setUint32(at + 8, w)
          ..setUint32(at + 12, h);
      }

      ispe(16, 512, 512);
      ispe(36, 4032, 3024);
      expect(
        readImageSize(d.buffer.asUint8List()),
        const ImageSize(4032, 3024),
      );
    });

    test('not an image, cut headers and zero sizes give null', () {
      expect(readImageSize(_b('%PDF-1.7'.codeUnits)), isNull);
      expect(readImageSize(_png(0, 10)), isNull);
      expect(readImageSize(_b(_png(1, 1).sublist(0, 20))), isNull);
    });
  });
}
