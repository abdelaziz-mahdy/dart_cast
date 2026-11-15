import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/ts_keyframe_scanner.dart';
import 'package:test/test.dart';

const _videoPid = 0x100;
const _audioPid = 0x101;

/// A video PES start packet whose PES header carries [headerDataLength]
/// bytes of optional fields before the H.264 NAL unit of type [nalType].
Uint8List _videoPes(int nalType, {int headerDataLength = 5}) {
  final p = Uint8List(188);
  p[0] = 0x47;
  p[1] = 0x40 | (_videoPid >> 8);
  p[2] = _videoPid & 0xFF;
  p[3] = 0x10; // payload only
  var i = 4;
  p.setAll(i, [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80]);
  i += 8;
  p[i++] = headerDataLength;
  // Optional fields. Fill them with an IDR-looking start code to prove the
  // scanner skips them rather than reading them as NAL data.
  final optional = List<int>.filled(headerDataLength, 0x21);
  if (headerDataLength >= 4) {
    optional.setAll(0, [0x00, 0x00, 0x01, 0x05]);
  }
  p.setAll(i, optional);
  i += headerDataLength;
  p.setAll(i, [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0]); // AUD
  i += 6;
  p.setAll(i, [0x00, 0x00, 0x01, nalType]);
  return p;
}

/// An audio packet with random_access_indicator set, as ffmpeg writes on
/// audio frames.
Uint8List _audioWithRai() {
  final p = Uint8List(188);
  p[0] = 0x47;
  p[1] = _audioPid >> 8;
  p[2] = _audioPid & 0xFF;
  p[3] = 0x30; // adaptation + payload
  p[4] = 1;
  p[5] = 0x40; // random_access_indicator
  return p;
}

Uint8List _filler(int pid) {
  final p = Uint8List(188);
  p[0] = 0x47;
  p[1] = pid >> 8;
  p[2] = pid & 0xFF;
  p[3] = 0x10;
  return p;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kf_scan_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('random_access_indicator on the audio PID is not a keyframe', () async {
    final file = File('${dir.path}/a.ts');
    await file.writeAsBytes([
      ..._videoPes(5), // 0: IDR (offset 0 is always reported)
      ..._filler(_videoPid),
      ..._audioWithRai(), // 2: audio RAI — must be ignored
      ..._videoPes(1), // 3: non-IDR slice
      ..._videoPes(5), // 4: IDR
    ]);
    expect(TsKeyframeScanner.findKeyframeOffsets(file), [0, 4 * 188]);
  });

  test('the IDR search starts after the PES optional header fields', () async {
    final file = File('${dir.path}/b.ts');
    await file.writeAsBytes([
      ..._videoPes(5),
      // Optional fields hold 00 00 01 05, the slice itself is non-IDR.
      ..._videoPes(1, headerDataLength: 10),
    ]);
    expect(TsKeyframeScanner.findKeyframeOffsets(file), [0]);
  });
}
