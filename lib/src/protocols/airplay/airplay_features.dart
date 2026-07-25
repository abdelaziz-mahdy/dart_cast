/// Parses and exposes AirPlay feature flags from mDNS TXT records.
///
/// AirPlay devices advertise their capabilities as a bitmask in the `features`
/// or `ft` TXT record. The value may be a single hex number (e.g. `0x5A7FFFF7`)
/// or a two-part comma-separated value where the second part is the upper 32
/// bits (e.g. `0x5A7FFFF7,0x1E`).
class AirPlayFeatures {
  /// The raw 64-bit feature bitmask.
  final int rawValue;

  /// Creates an [AirPlayFeatures] with the given raw bitmask.
  const AirPlayFeatures(this.rawValue);

  /// Parses an AirPlay feature string from a mDNS TXT record.
  ///
  /// Accepts formats:
  /// - `"0x5A7FFFF7"` — single 32-bit hex value
  /// - `"0x5A7FFFF7,0x1E"` — lower 32 bits, upper 32 bits
  ///
  /// Returns [AirPlayFeatures] with `rawValue == 0` on empty or malformed input.
  factory AirPlayFeatures.parse(String features) {
    if (features.isEmpty) return const AirPlayFeatures(0);
    try {
      final parts = features.split(',');
      final lower = _parseHex(parts[0].trim());
      final upper = parts.length > 1 ? _parseHex(parts[1].trim()) : 0;
      return AirPlayFeatures((upper << 32) | lower);
    } catch (_) {
      return const AirPlayFeatures(0);
    }
  }

  static int _parseHex(String s) {
    final cleaned = s.replaceFirst(RegExp(r'^0[xX]'), '');
    if (cleaned.isEmpty) return 0;
    return int.parse(cleaned, radix: 16);
  }

  bool _hasBit(int bit) => (rawValue >> bit) & 1 == 1;

  /// Whether the device supports AirPlay video (v1, bit 0).
  bool get supportsVideoV1 => _hasBit(0);

  /// Whether the device supports AirPlay video (v2, bit 49).
  bool get supportsVideoV2 => _hasBit(49);

  /// Whether the device supports video playback (either v1 or v2).
  bool get supportsVideo => supportsVideoV1 || supportsVideoV2;

  /// Whether the device supports photo display (bit 1).
  bool get supportsPhoto => _hasBit(1);

  /// Whether the device supports HLS streaming (bit 4).
  bool get supportsHLS => _hasBit(4);

  /// Whether the device supports screen mirroring (bit 7).
  bool get supportsScreen => _hasBit(7);

  /// Whether the device supports audio streaming (bit 9).
  bool get supportsAudio => _hasBit(9);

  /// Whether the device supports legacy (pre-HAP) pairing (bit 27).
  bool get supportsLegacyPairing => _hasBit(27);

  /// Whether the device advertises system pairing (bit 43).
  bool get supportsSystemPairing => _hasBit(43);

  /// Whether the device supports CoreUtils pairing and encryption (bit 48).
  bool get supportsCoreUtilsPairing => _hasBit(48);

  /// Whether the device requires HAP pairing (bit 43, 46 or 48).
  ///
  /// pyatv treats bit 43 (`SupportsSystemPairing`) as requiring credentials
  /// alongside bit 48, see `pyatv/protocols/airplay/auth/__init__.py`.
  bool get requiresHapPairing => _hasBit(43) || _hasBit(46) || _hasBit(48);

  /// Whether the device accepts *transient* pairing (bit 43 or bit 48).
  ///
  /// Transient pairing needs no PIN and no persisted credentials — pyatv
  /// selects it whenever either bit is present.
  bool get supportsTransientPairing => _hasBit(43) || _hasBit(48);

  /// Whether the device uses the AirPlay 2 protocol (bit 38 or bit 48).
  bool get isV2Protocol => _hasBit(38) || _hasBit(48);

  @override
  String toString() =>
      'AirPlayFeatures(0x${rawValue.toRadixString(16)}, video=$supportsVideo, audio=$supportsAudio, screen=$supportsScreen, hap=$requiresHapPairing)';
}
