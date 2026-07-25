import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:test/test.dart';

void main() {
  group('AirPlayFeatures', () {
    group('parsing', () {
      test('parses single-part hex string', () {
        final f = AirPlayFeatures.parse('0x5A7FFFF7');
        expect(f.rawValue, equals(0x5A7FFFF7));
      });
      test('parses two-part hex string (lower,upper)', () {
        final f = AirPlayFeatures.parse('0x5A7FFFF7,0x1E');
        expect(f.rawValue, equals((0x1E << 32) | 0x5A7FFFF7));
      });
      test('handles 0x0', () {
        final f = AirPlayFeatures.parse('0x0');
        expect(f.rawValue, equals(0));
        expect(f.supportsVideo, isFalse);
      });
      test('handles empty string', () {
        final f = AirPlayFeatures.parse('');
        expect(f.rawValue, equals(0));
      });
      test('handles malformed input', () {
        final f = AirPlayFeatures.parse('not-hex');
        expect(f.rawValue, equals(0));
      });
      test('case insensitive', () {
        final f1 = AirPlayFeatures.parse('0xAB');
        final f2 = AirPlayFeatures.parse('0xab');
        expect(f1.rawValue, equals(f2.rawValue));
      });
    });
    group('video flags', () {
      test('supportsVideoV1 checks bit 0', () {
        final f = AirPlayFeatures.parse('0x1');
        expect(f.supportsVideoV1, isTrue);
        expect(f.supportsVideo, isTrue);
      });
      test('supportsVideoV2 checks bit 49', () {
        final f = AirPlayFeatures.parse('0x0,0x20000');
        expect(f.supportsVideoV2, isTrue);
        expect(f.supportsVideo, isTrue);
      });
      test('supportsVideo false if neither', () {
        final f = AirPlayFeatures.parse('0x0');
        expect(f.supportsVideo, isFalse);
      });
    });
    group('other flags', () {
      test('supportsAudio checks bit 9', () {
        final f = AirPlayFeatures.parse('0x200');
        expect(f.supportsAudio, isTrue);
      });
      test('supportsScreen checks bit 7', () {
        final f = AirPlayFeatures.parse('0x80');
        expect(f.supportsScreen, isTrue);
      });
      test('supportsHLS checks bit 4', () {
        final f = AirPlayFeatures.parse('0x10');
        expect(f.supportsHLS, isTrue);
      });
      test('requiresHapPairing checks bit 43, 46 or 48', () {
        final f43 = AirPlayFeatures.parse('0x0,0x800');
        expect(f43.requiresHapPairing, isTrue);
        final f46 = AirPlayFeatures.parse('0x0,0x4000');
        expect(f46.requiresHapPairing, isTrue);
        final f48 = AirPlayFeatures.parse('0x0,0x10000');
        expect(f48.requiresHapPairing, isTrue);
        expect(AirPlayFeatures.parse('0xFFFF').requiresHapPairing, isFalse);
      });
      test('supportsTransientPairing checks bit 43 or 48', () {
        expect(
          AirPlayFeatures.parse('0x0,0x800').supportsTransientPairing,
          isTrue,
        );
        expect(
          AirPlayFeatures.parse('0x0,0x10000').supportsTransientPairing,
          isTrue,
        );
        // Bit 46 alone means HAP pairing, but not transient pairing.
        expect(
          AirPlayFeatures.parse('0x0,0x4000').supportsTransientPairing,
          isFalse,
        );
      });
      test('supportsLegacyPairing checks bit 27', () {
        expect(
          AirPlayFeatures.parse('0x8000000').supportsLegacyPairing,
          isTrue,
        );
        expect(
          AirPlayFeatures.parse('0x4000000').supportsLegacyPairing,
          isFalse,
        );
      });
      test('isV2Protocol checks bit 38 or 48', () {
        final f38 = AirPlayFeatures.parse('0x0,0x40');
        expect(f38.isV2Protocol, isTrue);
      });
    });
    group('toString', () {
      test('includes flag summary', () {
        final f = AirPlayFeatures.parse('0x1');
        expect(f.toString(), contains('video=true'));
      });
    });
    // Bitmasks captured from real receivers on the developer's network,
    // recorded in test/integration/logs.txt (2026-07 discovery run). These
    // replace an invented "Apple TV 4K" value that matched no real device.
    group('captured hardware bitmasks', () {
      const macOsReceiver = AirPlayFeatures(0x38174fde4a7fcfd5);
      const rokuExpress = AirPlayFeatures(0x038bcf46007f8ad0);
      const tclGoogleTv = AirPlayFeatures(0x000bcf46007f8ad0);

      test('macOS receiver (MacBook Pro) advertises video V1 and V2', () {
        expect(macOsReceiver.supportsVideoV1, isTrue, reason: 'bit 0');
        expect(macOsReceiver.supportsVideoV2, isTrue, reason: 'bit 49');
        expect(macOsReceiver.supportsSystemPairing, isTrue, reason: 'bit 43');
        expect(
          macOsReceiver.supportsCoreUtilsPairing,
          isTrue,
          reason: 'bit 48',
        );
        expect(macOsReceiver.supportsLegacyPairing, isTrue, reason: 'bit 27');
        expect(macOsReceiver.isV2Protocol, isTrue);
      });

      test('Roku Express advertises video V2 but NOT video V1', () {
        expect(rokuExpress.supportsVideoV1, isFalse, reason: 'bit 0 is clear');
        expect(rokuExpress.supportsVideoV2, isTrue, reason: 'bit 49');
        expect(rokuExpress.supportsSystemPairing, isTrue, reason: 'bit 43');
        expect(rokuExpress.supportsCoreUtilsPairing, isTrue, reason: 'bit 48');
        expect(rokuExpress.supportsLegacyPairing, isFalse, reason: 'bit 27');
        expect(rokuExpress.isV2Protocol, isTrue);
        expect(rokuExpress.supportsTransientPairing, isTrue);
      });

      test('TCL Google TV advertises video V2 but NOT video V1', () {
        expect(tclGoogleTv.supportsVideoV1, isFalse, reason: 'bit 0 is clear');
        expect(tclGoogleTv.supportsVideoV2, isTrue, reason: 'bit 49');
        expect(tclGoogleTv.supportsSystemPairing, isTrue, reason: 'bit 43');
        expect(tclGoogleTv.supportsCoreUtilsPairing, isTrue, reason: 'bit 48');
        expect(tclGoogleTv.supportsLegacyPairing, isFalse, reason: 'bit 27');
        expect(tclGoogleTv.isV2Protocol, isTrue);
        expect(tclGoogleTv.supportsTransientPairing, isTrue);
      });

      test('all three are AirPlay 2 receivers (bit 38 and bit 48)', () {
        for (final f in [macOsReceiver, rokuExpress, tclGoogleTv]) {
          expect(f.isV2Protocol, isTrue, reason: '$f');
          expect(f.requiresHapPairing, isTrue, reason: '$f');
        }
      });

      test('split form treats the second word as the HIGH 32 bits', () {
        final split = AirPlayFeatures.parse('0x007f8ad0,0x000bcf46');
        expect(split.rawValue, equals(tclGoogleTv.rawValue));
        expect(split.supportsVideoV1, isFalse);
        expect(split.supportsVideoV2, isTrue);
      });
    });

    group('real-world feature strings', () {
      test('device with only audio and mirroring', () {
        final f = AirPlayFeatures.parse('0x280');
        expect(f.supportsVideo, isFalse);
        expect(f.supportsAudio, isTrue);
        expect(f.supportsScreen, isTrue);
      });
      test('device with HAP pairing required', () {
        final f = AirPlayFeatures.parse('0x280,0x10000');
        expect(f.requiresHapPairing, isTrue);
        expect(f.isV2Protocol, isTrue);
      });
    });
  });
}
