import 'dart:convert';

import 'package:dart_cast/src/protocols/airplay/auth/binary_plist.dart';
import 'package:dart_cast/src/protocols/airplay/plist_codec.dart';
import 'package:test/test.dart';

void main() {
  group('PlistCodec binary plist support', () {
    // AirPlay 2 answers /playback-info with a binary plist. Feeding that
    // through utf8.decode and an XML regex parser — the only path that
    // existed — yields an all-zero PlaybackInfo, so the session never left
    // `loading` and position/duration stayed at 0 forever.
    Map<String, dynamic> playbackInfoDict({
      double rate = 1.0,
      Map<String, dynamic>? error,
    }) => {
      'duration': 5400.0,
      'position': 123.5,
      'rate': rate,
      'readyToPlay': true,
      'playbackBufferEmpty': false,
      'playbackLikelyToKeepUp': true,
      if (error != null) 'error': error,
    };

    test('isBinaryPlist recognises the bplist00 magic', () {
      final binary = BinaryPlistEncoder.encode(playbackInfoDict());
      expect(PlistCodec.isBinaryPlist(binary), isTrue);
      expect(PlistCodec.isBinaryPlist(utf8.encode('<plist>')), isFalse);
      expect(PlistCodec.isBinaryPlist(const []), isFalse);
      expect(PlistCodec.isBinaryPlist(const [0x62, 0x70]), isFalse);
    });

    test('parses a binary plist body declared by Content-Type', () {
      final body = BinaryPlistEncoder.encode(playbackInfoDict());

      final info = PlistCodec.parsePlaybackInfoBytes(
        body,
        contentType: PlistCodec.binaryPlistContentType,
      );

      expect(info.duration, closeTo(5400.0, 0.001));
      expect(info.position, closeTo(123.5, 0.001));
      expect(info.rate, closeTo(1.0, 0.001));
      expect(info.readyToPlay, isTrue);
      expect(info.hasDuration, isTrue);
    });

    test('sniffs a binary plist when the Content-Type header is missing', () {
      final body = BinaryPlistEncoder.encode(playbackInfoDict(rate: 0.0));

      final info = PlistCodec.parsePlaybackInfoBytes(body);

      expect(info.duration, closeTo(5400.0, 0.001));
      expect(info.rate, isZero);
    });

    test('still parses an XML body on the same entry point', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>duration</key><real>300.0</real>
    <key>position</key><real>45.0</real>
    <key>rate</key><real>1.0</real>
</dict>
</plist>''';

      final info = PlistCodec.parsePlaybackInfoBytes(
        utf8.encode(xml),
        contentType: 'text/x-apple-plist+xml',
      );

      expect(info.duration, closeTo(300.0, 0.001));
      expect(info.position, closeTo(45.0, 0.001));
    });

    test('falls back to XML when a body is mislabelled as binary', () {
      const xml =
          '<plist version="1.0"><dict>'
          '<key>rate</key><real>1.0</real></dict></plist>';

      final info = PlistCodec.parsePlaybackInfoBytes(
        utf8.encode(xml),
        contentType: PlistCodec.binaryPlistContentType,
      );

      expect(info.rate, closeTo(1.0, 0.001));
    });

    test('surfaces the error dict a receiver reports', () {
      final body = BinaryPlistEncoder.encode(
        playbackInfoDict(error: {'code': -12645, 'domain': 'NSURLErrorDomain'}),
      );

      final info = PlistCodec.parsePlaybackInfoBytes(
        body,
        contentType: PlistCodec.binaryPlistContentType,
      );

      expect(info.error, isNotNull);
      expect(info.error!.code, equals(-12645));
      expect(info.error!.domain, equals('NSURLErrorDomain'));
      expect(info.error.toString(), contains('NSURLErrorDomain'));
    });

    test('hasDuration distinguishes "nothing playing" from duration 0', () {
      final idle = PlistCodec.parsePlaybackInfoBytes(
        BinaryPlistEncoder.encode({'position': 0.0, 'rate': 0.0}),
      );
      expect(idle.hasDuration, isFalse);
      expect(idle.duration, isZero);

      final zeroLength = PlistCodec.parsePlaybackInfoBytes(
        BinaryPlistEncoder.encode({'duration': 0.0, 'rate': 0.0}),
      );
      expect(zeroLength.hasDuration, isTrue);
    });

    test('returns an empty result for an empty or unparseable body', () {
      expect(PlistCodec.parsePlist(const []), isEmpty);
      expect(PlistCodec.parsePlist(utf8.encode('not a plist')), isEmpty);

      final info = PlistCodec.parsePlaybackInfoBytes(const []);
      expect(info.duration, isZero);
      expect(info.error, isNull);
    });
  });

  group('PlistCodec', () {
    group('parseXmlPlist', () {
      test('parses dict with real values', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>duration</key><real>3600.0</real>
    <key>position</key><real>120.5</real>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        expect(result['duration'], 3600.0);
        expect(result['position'], 120.5);
      });

      test('parses dict with integer values', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>features</key><integer>1518338039</integer>
    <key>count</key><integer>42</integer>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        expect(result['features'], 1518338039);
        expect(result['count'], 42);
      });

      test('parses dict with string values', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>deviceid</key><string>AA:BB:CC:DD:EE:FF</string>
    <key>model</key><string>AppleTV3,2</string>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        expect(result['deviceid'], 'AA:BB:CC:DD:EE:FF');
        expect(result['model'], 'AppleTV3,2');
      });

      test('parses dict with boolean values', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>readyToPlay</key><true/>
    <key>playbackBufferEmpty</key><false/>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        expect(result['readyToPlay'], true);
        expect(result['playbackBufferEmpty'], false);
      });

      test('parses dict with mixed types', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>duration</key><real>3600.0</real>
    <key>rate</key><real>1.0</real>
    <key>readyToPlay</key><true/>
    <key>model</key><string>AppleTV3,2</string>
    <key>features</key><integer>42</integer>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        expect(result['duration'], 3600.0);
        expect(result['rate'], 1.0);
        expect(result['readyToPlay'], true);
        expect(result['model'], 'AppleTV3,2');
        expect(result['features'], 42);
      });

      test('parses nested dict inside array (loadedTimeRanges)', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>loadedTimeRanges</key>
    <array>
        <dict>
            <key>duration</key>
            <real>120.0</real>
            <key>start</key>
            <real>0.0</real>
        </dict>
    </array>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        expect(result['loadedTimeRanges'], isList);
        final ranges = result['loadedTimeRanges'] as List;
        expect(ranges.length, 1);
        final range = ranges[0] as Map<String, dynamic>;
        expect(range['duration'], 120.0);
        expect(range['start'], 0.0);
      });

      test('parses array with multiple dicts', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>ranges</key>
    <array>
        <dict>
            <key>start</key><real>0.0</real>
            <key>duration</key><real>100.0</real>
        </dict>
        <dict>
            <key>start</key><real>200.0</real>
            <key>duration</key><real>300.0</real>
        </dict>
    </array>
</dict>
</plist>''';

        final result = PlistCodec.parseXmlPlist(xml);
        final ranges = result['ranges'] as List;
        expect(ranges.length, 2);
        expect((ranges[0] as Map)['start'], 0.0);
        expect((ranges[1] as Map)['start'], 200.0);
      });

      test('returns empty map for empty input', () {
        expect(PlistCodec.parseXmlPlist(''), isEmpty);
      });

      test('returns empty map for malformed XML', () {
        expect(PlistCodec.parseXmlPlist('<not-a-plist/>'), isEmpty);
      });

      test('returns empty map for plist without dict', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
</plist>''';
        expect(PlistCodec.parseXmlPlist(xml), isEmpty);
      });
    });

    group('parsePlaybackInfo', () {
      test('parses full playback-info response', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>duration</key>
    <real>5400.000000</real>
    <key>position</key>
    <real>123.456789</real>
    <key>rate</key>
    <real>1.000000</real>
    <key>readyToPlay</key>
    <true/>
    <key>playbackBufferEmpty</key>
    <false/>
    <key>playbackLikelyToKeepUp</key>
    <true/>
    <key>loadedTimeRanges</key>
    <array>
        <dict>
            <key>duration</key>
            <real>120.000000</real>
            <key>start</key>
            <real>0.000000</real>
        </dict>
    </array>
</dict>
</plist>''';

        final info = PlistCodec.parsePlaybackInfo(xml);
        expect(info.duration, 5400.0);
        expect(info.position, 123.456789);
        expect(info.rate, 1.0);
        expect(info.readyToPlay, true);
        expect(info.playbackBufferEmpty, false);
        expect(info.playbackLikelyToKeepUp, true);
      });

      test('handles missing keys with defaults', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>duration</key>
    <real>100.0</real>
</dict>
</plist>''';

        final info = PlistCodec.parsePlaybackInfo(xml);
        expect(info.duration, 100.0);
        expect(info.position, 0.0);
        expect(info.rate, 0.0);
        expect(info.readyToPlay, false);
        expect(info.playbackBufferEmpty, false);
        expect(info.playbackLikelyToKeepUp, false);
      });

      test('handles empty input', () {
        final info = PlistCodec.parsePlaybackInfo('');
        expect(info.duration, 0.0);
        expect(info.position, 0.0);
        expect(info.rate, 0.0);
        expect(info.readyToPlay, false);
      });
    });

    group('parseServerInfo', () {
      test('parses full server-info response', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>deviceid</key>
    <string>AA:BB:CC:DD:EE:FF</string>
    <key>features</key>
    <integer>1518338039</integer>
    <key>model</key>
    <string>AppleTV3,2</string>
    <key>protovers</key>
    <string>1.0</string>
    <key>srcvers</key>
    <string>220.68</string>
</dict>
</plist>''';

        final info = PlistCodec.parseServerInfo(xml);
        expect(info.deviceId, 'AA:BB:CC:DD:EE:FF');
        expect(info.features, 1518338039);
        expect(info.model, 'AppleTV3,2');
      });

      test('handles missing keys with defaults', () {
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>model</key>
    <string>AppleTV5,3</string>
</dict>
</plist>''';

        final info = PlistCodec.parseServerInfo(xml);
        expect(info.deviceId, '');
        expect(info.features, 0);
        expect(info.model, 'AppleTV5,3');
      });

      test('handles empty input', () {
        final info = PlistCodec.parseServerInfo('');
        expect(info.deviceId, '');
        expect(info.features, 0);
        expect(info.model, '');
      });
    });
  });
}
