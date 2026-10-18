// File: binary.dart
// Purpose: Narrow entrypoint for bytea text decoding, file type detection
// by magic bytes and image header sizes.

/// Decode `bytea` text output (hex and escape formats), recognise common
/// file formats from their first bytes, and read an image's pixel size
/// from its header without decoding it. Pure Dart; no server needed.
library;

export 'src/binary/binary_kind.dart' show BinaryKind, detectBinaryKind;
export 'src/binary/bytea_text.dart' show bytesToHex, decodeByteaText;
export 'src/binary/image_size.dart' show ImageSize, readImageSize;
