// File: raw_setting.dart
// Purpose: Intermediate keyword=value pairs shared by the URI and conninfo
// parsers (internal, not exported).

/// A libpq keyword value as it appeared in the source, with the offset of
/// the value so later validation errors can point at it.
final class RawSetting {
  /// Creates a raw setting.
  const RawSetting(this.value, this.offset);

  /// The decoded value (percent-decoding / quote handling already applied).
  final String value;

  /// Offset of the value in the original connection string.
  final int offset;
}

/// Ordered libpq keyword settings; later duplicates replace earlier ones.
typedef RawSettings = Map<String, RawSetting>;
