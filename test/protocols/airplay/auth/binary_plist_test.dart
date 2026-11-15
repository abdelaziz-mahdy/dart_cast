import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/binary_plist.dart';
import 'package:test/test.dart';

/// Helper to encode then decode, verifying roundtrip.
Map<String, dynamic> _roundtrip(Map<String, dynamic> input) {
  final encoded = BinaryPlistEncoder.encode(input);
  return BinaryPlistDecoder.decode(encoded);
}

void main() {
  group('BinaryPlistEncoder', () {
    test('output starts with bplist00 magic', () {
      final result = BinaryPlistEncoder.encode({'key': 'value'});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
    });

    test('encodes string values', () {
      final result = BinaryPlistEncoder.encode({'name': 'hello'});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // Verify the bytes contain the string "hello" and "name"
      final asString = String.fromCharCodes(result);
      expect(asString, contains('hello'));
      expect(asString, contains('name'));
    });

    test('encodes integer values', () {
      final result = BinaryPlistEncoder.encode({'count': 42});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // The integer 42 should be encoded as 0x10 0x2A (1-byte int)
      expect(result.contains(42), isTrue);
    });

    test('encodes boolean values', () {
      final result = BinaryPlistEncoder.encode({
        'enabled': true,
        'disabled': false,
      });
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // true = 0x09, false = 0x08
      expect(result.contains(0x09), isTrue);
      expect(result.contains(0x08), isTrue);
    });

    test('encodes double values', () {
      final result = BinaryPlistEncoder.encode({'pi': 3.14});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // 0x23 = float64 marker
      expect(result.contains(0x23), isTrue);
    });

    test('encodes mixed-type dict', () {
      final result = BinaryPlistEncoder.encode({
        'name': 'test',
        'count': 7,
        'ratio': 0.5,
        'active': true,
      });
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // Verify trailer is 32 bytes at the end
      expect(result.length >= 40, isTrue); // 8 header + 32 trailer minimum
    });

    test('trailer has correct structure', () {
      final result = BinaryPlistEncoder.encode({'a': 1});
      final trailerStart = result.length - 32;
      final trailer = ByteData.sublistView(result, trailerStart);

      // Bytes 0-5: unused (zero)
      for (int i = 0; i < 6; i++) {
        expect(
          trailer.getUint8(i),
          equals(0),
          reason: 'trailer byte $i should be 0',
        );
      }

      // Byte 6: offset int size (should be >= 1)
      final offsetSize = trailer.getUint8(6);
      expect(offsetSize, greaterThanOrEqualTo(1));

      // Byte 7: object ref size (should be >= 1)
      final objectRefSize = trailer.getUint8(7);
      expect(objectRefSize, greaterThanOrEqualTo(1));

      // Bytes 8-15: number of objects (big-endian uint64)
      final numObjectsHi = trailer.getUint32(8, Endian.big);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      final numObjects = (numObjectsHi << 32) | numObjectsLo;
      // {'a': 1} => dict + 'a' + 1 = 3 objects
      expect(numObjects, equals(3));

      // Bytes 16-23: top object index (should be 0)
      final topHi = trailer.getUint32(16, Endian.big);
      final topLo = trailer.getUint32(20, Endian.big);
      expect(topHi, equals(0));
      expect(topLo, equals(0));

      // Bytes 24-31: offset table offset (should be after header + objects)
      final offsetTableOffsetHi = trailer.getUint32(24, Endian.big);
      final offsetTableOffsetLo = trailer.getUint32(28, Endian.big);
      final offsetTableOffset =
          (offsetTableOffsetHi << 32) | offsetTableOffsetLo;
      expect(offsetTableOffset, greaterThan(8)); // After bplist00 header
      expect(offsetTableOffset, lessThan(result.length - 32)); // Before trailer
    });

    test('encodes SETUP body used in RTSP', () {
      final result = BinaryPlistEncoder.encode({
        'deviceID': 'AA:BB:CC:DD:EE:FF',
        'sessionUUID': '12345678-1234-1234-1234-123456789ABC',
        'timingPort': 0,
        'timingProtocol': 'NTP',
        'isMultiSelectAirPlay': true,
        'groupContainsGroupLeader': false,
        'macAddress': 'AA:BB:CC:DD:EE:FF',
        'model': 'iPhone14,3',
        'name': 'dart_cast',
        'osBuildVersion': '20F66',
        'osName': 'iPhone OS',
        'osVersion': '16.5',
        'sourceVersion': '690.7.1',
      });

      // Verify magic
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Verify it contains expected strings
      final asString = String.fromCharCodes(result);
      expect(asString, contains('deviceID'));
      expect(asString, contains('AA:BB:CC:DD:EE:FF'));
      expect(asString, contains('NTP'));
      expect(asString, contains('dart_cast'));
    });

    test('encodes /play body used in AirPlay', () {
      final result = BinaryPlistEncoder.encode({
        'Content-Location': 'http://example.com/video.m3u8',
        'Start-Position-Seconds': 0.0,
        'uuid': 'abcdef01-2345-6789-abcd-ef0123456789',
        'streamType': 1,
        'mediaType': 'file',
        'volume': 1.0,
        'rate': 1.0,
      });

      // Verify magic
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Verify it contains expected strings
      final asString = String.fromCharCodes(result);
      expect(asString, contains('Content-Location'));
      expect(asString, contains('http://example.com/video.m3u8'));
      expect(asString, contains('mediaType'));
      expect(asString, contains('file'));
    });

    test('encodes large integers correctly', () {
      final result = BinaryPlistEncoder.encode({'big': 100000});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // 100000 > 0xFFFF so needs 4-byte int (marker 0x12)
      expect(result.contains(0x12), isTrue);
    });

    test('encodes zero integer', () {
      final result = BinaryPlistEncoder.encode({'zero': 0});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // 0 fits in 1 byte, marker 0x10
      expect(result.contains(0x10), isTrue);
    });

    test('encodes empty dict', () {
      final result = BinaryPlistEncoder.encode({});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Just 1 object (the empty dict)
      final trailer = ByteData.sublistView(result, result.length - 32);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      expect(numObjectsLo, equals(1));
    });

    test('encodes nested dict', () {
      final result = BinaryPlistEncoder.encode({
        'outer': <String, dynamic>{'inner': 'value'},
      });
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      final asString = String.fromCharCodes(result);
      expect(asString, contains('outer'));
      expect(asString, contains('inner'));
      expect(asString, contains('value'));
    });

    test('encodes unicode strings', () {
      final result = BinaryPlistEncoder.encode({'emoji': '\u00e9\u00e8'});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Unicode strings use 0x6N marker
      // Check that we have a 0x62 byte (unicode string, length 2)
      expect(result.contains(0x62), isTrue);
    });

    test('handles null values in dict', () {
      final result = BinaryPlistEncoder.encode({'key': null});
      // Verify magic header
      expect(result[0], 0x62); // 'b'
      expect(result[1], 0x70); // 'p'
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Verify it contains the key string
      final asString = String.fromCharCodes(result);
      expect(asString, contains('key'));
      // Verify null marker (0x00) is present in the object table
      // dict marker + key 'key' + null (0x00) = 3 objects
      final trailer = ByteData.sublistView(result, result.length - 32);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      expect(numObjectsLo, equals(3));
    });

    test('offset table has correct number of entries', () {
      final dict = {'a': 'b', 'c': 1};
      final result = BinaryPlistEncoder.encode(dict);

      final trailer = ByteData.sublistView(result, result.length - 32);
      final offsetSize = trailer.getUint8(6);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      final offsetTableOffsetLo = trailer.getUint32(28, Endian.big);

      // Offset table should have numObjects entries of offsetSize bytes each
      final expectedOffsetTableSize = numObjectsLo * offsetSize;
      final actualOffsetTableSize = result.length - 32 - offsetTableOffsetLo;
      expect(actualOffsetTableSize, equals(expectedOffsetTableSize));
    });

    test('array encoding contains 0xA marker', () {
      final result = BinaryPlistEncoder.encode({
        'items': [1, 2, 3],
      });
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Array marker is 0xA0 | count. For 3 items: 0xA3
      expect(result.contains(0xA3), isTrue);
    });

    test('nested arrays and dicts', () {
      final result = BinaryPlistEncoder.encode({
        'data': [
          <String, dynamic>{'name': 'a'},
          <String, dynamic>{'name': 'b'},
        ],
      });
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      final asString = String.fromCharCodes(result);
      expect(asString, contains('data'));
      expect(asString, contains('name'));
      expect(asString, contains('a'));
      expect(asString, contains('b'));
    });

    test('large dict with >14 entries uses extended size header 0xDF', () {
      final dict = <String, dynamic>{};
      for (int i = 0; i < 16; i++) {
        dict['key_${i.toString().padLeft(2, '0')}'] = i;
      }
      final result = BinaryPlistEncoder.encode(dict);
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Dict with 16 entries uses extended header: 0xD0 | 0x0F = 0xDF
      expect(result.contains(0xDF), isTrue);
    });

    test('large string with >14 chars uses extended size header 0x5F', () {
      final longString = 'abcdefghijklmnopqrst'; // 20 chars
      final result = BinaryPlistEncoder.encode({'val': longString});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // ASCII string with 20 chars uses extended header: 0x50 | 0x0F = 0x5F
      expect(result.contains(0x5F), isTrue);
      final asString = String.fromCharCodes(result);
      expect(asString, contains(longString));
    });

    test('negative integer uses 8-byte int marker 0x13', () {
      final result = BinaryPlistEncoder.encode({'val': -1});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // -1 is outside 0..0xFFFFFFFF so uses 8-byte int (marker 0x13)
      expect(result.contains(0x13), isTrue);
    });

    test('mixed array with null has correct object count', () {
      final result = BinaryPlistEncoder.encode({
        'items': [1, null, 'hello'],
      });
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      final trailer = ByteData.sublistView(result, result.length - 32);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      // Objects: root dict, 'items' string, array, int 1, null, 'hello' = 6
      expect(numObjectsLo, equals(6));
    });

    test('empty string produces 0x50 marker', () {
      final result = BinaryPlistEncoder.encode({'key': ''});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // ASCII string with length 0: 0x50 | 0 = 0x50
      expect(result.contains(0x50), isTrue);
    });

    test('very large integer >32-bit uses 8-byte int marker 0x13', () {
      final result = BinaryPlistEncoder.encode({'big': 0x100000000});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // 0x100000000 > 0xFFFFFFFF so needs 8-byte int (marker 0x13)
      expect(result.contains(0x13), isTrue);
    });

    test('bytes roundtrip for simple dict matches expected format', () {
      final result = BinaryPlistEncoder.encode({'a': 1});
      // Header: bplist00
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));

      final trailer = ByteData.sublistView(result, result.length - 32);
      final offsetSize = trailer.getUint8(6);
      final objectRefSize = trailer.getUint8(7);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      final offsetTableOffsetLo = trailer.getUint32(28, Endian.big);

      // 3 objects: dict, string 'a', int 1
      expect(numObjectsLo, equals(3));
      expect(objectRefSize, equals(1));

      // Read the offset table to find where each object starts
      final offsets = <int>[];
      for (int i = 0; i < numObjectsLo; i++) {
        int offset = 0;
        for (int b = 0; b < offsetSize; b++) {
          offset =
              (offset << 8) | result[offsetTableOffsetLo + i * offsetSize + b];
        }
        offsets.add(offset);
      }

      // Object 0 (dict with 1 entry): marker should be 0xD1 (0xD0 | 1)
      expect(result[offsets[0]], equals(0xD1));
      // After marker: key ref (1 byte = index 1) then value ref (index 2)
      expect(result[offsets[0] + 1], equals(1)); // key ref -> object 1
      expect(result[offsets[0] + 2], equals(2)); // value ref -> object 2

      // Object 1 (string 'a'): marker 0x51 (ASCII string, length 1)
      expect(result[offsets[1]], equals(0x51));
      expect(result[offsets[1] + 1], equals(0x61)); // 'a' = 0x61

      // Object 2 (int 1): marker 0x10 (1-byte int), value 0x01
      expect(result[offsets[2]], equals(0x10));
      expect(result[offsets[2] + 1], equals(0x01));
    });
  });

  group('BinaryPlistDecoder', () {
    test('roundtrip: simple string values', () {
      final input = {'name': 'hello', 'city': 'world'};
      final decoded = _roundtrip(input);
      expect(decoded['name'], equals('hello'));
      expect(decoded['city'], equals('world'));
    });

    test('roundtrip: integer values', () {
      final input = {'small': 42, 'medium': 1000, 'large': 100000};
      final decoded = _roundtrip(input);
      expect(decoded['small'], equals(42));
      expect(decoded['medium'], equals(1000));
      expect(decoded['large'], equals(100000));
    });

    test('roundtrip: boolean values', () {
      final input = {'yes': true, 'no': false};
      final decoded = _roundtrip(input);
      expect(decoded['yes'], equals(true));
      expect(decoded['no'], equals(false));
    });

    test('roundtrip: double values', () {
      final input = {'pi': 3.14, 'zero': 0.0};
      final decoded = _roundtrip(input);
      expect(decoded['pi'], closeTo(3.14, 0.001));
      expect(decoded['zero'], equals(0.0));
    });

    test('roundtrip: null values', () {
      final input = {'key': null};
      final decoded = _roundtrip(input);
      expect(decoded.containsKey('key'), isTrue);
      expect(decoded['key'], isNull);
    });

    test('roundtrip: mixed types', () {
      final input = {'name': 'test', 'count': 7, 'ratio': 0.5, 'active': true};
      final decoded = _roundtrip(input);
      expect(decoded['name'], equals('test'));
      expect(decoded['count'], equals(7));
      expect(decoded['ratio'], closeTo(0.5, 0.001));
      expect(decoded['active'], equals(true));
    });

    test('roundtrip: AirPlay SETUP response with eventPort', () {
      // Simulates what a real AirPlay SETUP response might contain
      final input = {'eventPort': 51234, 'timingPort': 0};
      final decoded = _roundtrip(input);
      expect(decoded['eventPort'], equals(51234));
      expect(decoded['timingPort'], equals(0));
    });

    test('roundtrip: empty dict', () {
      final decoded = _roundtrip({});
      expect(decoded, isEmpty);
    });

    test('roundtrip: nested dict', () {
      final input = {
        'outer': <String, dynamic>{'inner': 'value'},
      };
      final decoded = _roundtrip(input);
      expect(decoded['outer'], isA<Map>());
      expect((decoded['outer'] as Map)['inner'], equals('value'));
    });

    test('roundtrip: unicode strings', () {
      final input = {'emoji': '\u00e9\u00e8'};
      final decoded = _roundtrip(input);
      expect(decoded['emoji'], equals('\u00e9\u00e8'));
    });

    test('throws on invalid header', () {
      final data = Uint8List.fromList(utf8.encode('notaplist' * 10));
      expect(
        () => BinaryPlistDecoder.decode(data),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on too-short data', () {
      final data = Uint8List(10);
      expect(
        () => BinaryPlistDecoder.decode(data),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('BinaryPlist type fidelity', () {
    test('ints and doubles of equal value keep their own types', () {
      final decoded = _roundtrip({
        'Start-Position-Seconds': 0.0,
        'streamType': 1,
        'playbackRestrictions': 0,
        'volume': 1.0,
        'rate': 1.0,
      });

      expect(decoded['Start-Position-Seconds'], isA<double>());
      expect(decoded['Start-Position-Seconds'], equals(0.0));
      expect(decoded['streamType'], isA<int>());
      expect(decoded['streamType'], equals(1));
      expect(decoded['playbackRestrictions'], isA<int>());
      expect(decoded['playbackRestrictions'], equals(0));
      expect(decoded['volume'], isA<double>());
      expect(decoded['rate'], isA<double>());
    });

    test('int, double and bool in one array keep their types', () {
      final decoded = _roundtrip({
        'a': [1, 1.0, true, 0, 0.0, false],
      });
      final list = decoded['a'] as List;
      expect(list[0], isA<int>());
      expect(list[1], isA<double>());
      expect(list[2], isTrue);
      expect(list[3], isA<int>());
      expect(list[4], isA<double>());
      expect(list[5], isFalse);
    });

    test('NaN encodes and decodes as NaN', () {
      final decoded = _roundtrip({'x': double.nan, 'y': double.nan});
      expect((decoded['x'] as double).isNaN, isTrue);
      expect((decoded['y'] as double).isNaN, isTrue);
    });

    test('Uint8List encodes as plist data (0x4N) and round-trips', () {
      final encoded = BinaryPlistEncoder.encode({
        'd': Uint8List.fromList([1, 2]),
      });
      var found = false;
      for (var i = 0; i + 2 < encoded.length; i++) {
        if (encoded[i] == 0x42 &&
            encoded[i + 1] == 0x01 &&
            encoded[i + 2] == 0x02) {
          found = true;
        }
      }
      expect(found, isTrue, reason: 'expected data marker 0x42 01 02');

      final decoded = BinaryPlistDecoder.decode(encoded);
      expect(decoded['d'], isA<Uint8List>());
      expect(decoded['d'], equals([1, 2]));
    });

    test('decodes a UID object instead of failing', () {
      final bytes = Uint8List.fromList([
        ...ascii.encode('bplist00'),
        0xD1, 0x01, 0x02, // dict {obj1: obj2}
        0x51, 0x75, // "u"
        0x80, 0x05, // UID 5
        8, 11, 13, // offset table
        0, 0, 0, 0, 0, 0, 1, 1, // trailer: offset size 1, ref size 1
        0, 0, 0, 0, 0, 0, 0, 3, // 3 objects
        0, 0, 0, 0, 0, 0, 0, 0, // top object 0
        0, 0, 0, 0, 0, 0, 0, 15, // offset table at 15
      ]);

      final decoded = BinaryPlistDecoder.decode(bytes);
      expect(decoded['u'], equals(const PlistUid(5)));
    });
  });
}
