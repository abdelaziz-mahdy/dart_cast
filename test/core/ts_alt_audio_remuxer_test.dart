import 'dart:typed_data';

import 'package:dart_cast/src/core/ts_alt_audio_remuxer.dart';
import 'package:test/test.dart';

const _pmtPid = 0x1000;

Uint8List _packet(int pid, {bool pusi = false, int afc = 1}) {
  final p = Uint8List(188)..fillRange(4, 188, 0xFF);
  p[0] = 0x47;
  p[1] = (pusi ? 0x40 : 0) | (pid >> 8);
  p[2] = pid & 0xFF;
  p[3] = afc << 4;
  return p;
}

Uint8List _psi(int pid, List<int> section) =>
    _packet(pid, pusi: true)
      ..[4] = 0
      ..setRange(5, 5 + section.length, section);

Uint8List _pat() => _psi(0, [
  0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, //
  0x00, 0x01, 0xE0 | (_pmtPid >> 8), _pmtPid & 0xFF, //
  0, 0, 0, 0,
]);

Uint8List _pmt({
  required int pcrPid,
  required int streamType,
  required int esPid,
}) => _psi(_pmtPid, [
  0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, //
  0xE0 | (pcrPid >> 8), pcrPid & 0xFF, 0xF0, 0x00, //
  streamType, 0xE0 | (esPid >> 8), esPid & 0xFF, 0xF0, 0x00, //
  0, 0, 0, 0,
]);

List<int> _timestamp(int prefix, int t) => [
  (prefix << 4) | (((t >> 30) & 0x07) << 1) | 1,
  (t >> 22) & 0xFF,
  (((t >> 15) & 0x7F) << 1) | 1,
  (t >> 7) & 0xFF,
  ((t & 0x7F) << 1) | 1,
];

/// A PES start packet on [pid] carrying PTS (and DTS when [dts] is set).
Uint8List _pes(int pid, int streamId, int pts, {int? dts}) {
  final p = _packet(pid, pusi: true);
  final header = <int>[
    0x00, 0x00, 0x01, streamId, 0x00, 0x00, 0x80, //
    dts == null ? 0x80 : 0xC0,
    dts == null ? 5 : 10,
    ..._timestamp(dts == null ? 0x2 : 0x3, pts),
    if (dts != null) ..._timestamp(0x1, dts),
  ];
  p.setRange(4, 4 + header.length, header);
  return p;
}

/// An adaptation-only packet carrying a PCR whose base is [base].
Uint8List _pcr(int pid, int base) {
  final p = _packet(pid, afc: 2);
  p[4] = 183;
  p[5] = 0x10; // PCR_flag
  p[6] = (base >> 25) & 0xFF;
  p[7] = (base >> 17) & 0xFF;
  p[8] = (base >> 9) & 0xFF;
  p[9] = (base >> 1) & 0xFF;
  p[10] = ((base & 1) << 7) | 0x7E;
  return p;
}

int _pid(List<int> bytes, int packet) =>
    ((bytes[packet * 188 + 1] & 0x1F) << 8) | bytes[packet * 188 + 2];

int _cc(List<int> bytes, int packet) => bytes[packet * 188 + 3] & 0x0F;

/// Video: PCR on its own PID 0x1FF0, frames every 3600 ticks (40 ms).
List<int> _videoSegment(int start) => [
  ..._pat(),
  ..._pmt(pcrPid: 0x1FF0, streamType: 0x1B, esPid: 0x200),
  for (var f = 0; f < 4; f++) ...[
    ..._pcr(0x1FF0, start + f * 3600),
    ..._pes(0x200, 0xE0, start + f * 3600 + 3600, dts: start + f * 3600),
    ..._packet(0x200),
  ],
];

/// Audio: frames every 1920 ticks.
List<int> _audioSegment(int start) => [
  ..._pat(),
  ..._pmt(pcrPid: 0x300, streamType: 0x0F, esPid: 0x300),
  for (var f = 0; f < 7; f++) ..._pes(0x300, 0xC0, start + f * 1920),
];

void main() {
  test('keeps a PCR that the source carries on its own PID', () {
    final out =
        TsAltAudioRemuxer.mux(
          videoSegment: _videoSegment(90000),
          audioSegment: _audioSegment(90000),
        ).bytes;
    // PMT is the second packet; PCR_PID sits at section offset 8-9.
    final pmt = out.sublist(188, 376);
    final pcrPid = ((pmt[5 + 8] & 0x1F) << 8) | pmt[5 + 9];
    expect(pcrPid, 0x1FF);
    final pcrPackets = [
      for (var i = 0; i < out.length ~/ 188; i++)
        if (_pid(out, i) == 0x1FF) i,
    ];
    expect(pcrPackets, hasLength(4));
    expect(out[pcrPackets.first * 188 + 5] & 0x10, 0x10); // PCR flag kept
  });

  test('interleaves audio and video by decode time', () {
    final out =
        TsAltAudioRemuxer.mux(
          videoSegment: _videoSegment(90000),
          audioSegment: _audioSegment(90000),
        ).bytes;
    final pids = [for (var i = 2; i < out.length ~/ 188; i++) _pid(out, i)];
    // Audio must not all trail the video.
    final firstAudio = pids.indexOf(0x101);
    final lastVideo = pids.lastIndexOf(0x100);
    expect(firstAudio, lessThan(lastVideo));
    // Audio frame at t=0 comes before the second video frame (t=3600).
    final secondVideoPes = pids.indexOf(0x100, pids.indexOf(0x100) + 2);
    expect(firstAudio, lessThan(secondVideoPes));
  });

  test('continuity counters run on across segments sharing a state', () {
    final continuity = TsMuxContinuity();
    final first =
        TsAltAudioRemuxer.mux(
          videoSegment: _videoSegment(90000),
          audioSegment: _audioSegment(90000),
          continuity: continuity,
        ).bytes;
    final second =
        TsAltAudioRemuxer.mux(
          videoSegment: _videoSegment(90000 + 14400),
          audioSegment: _audioSegment(90000 + 13440),
          continuity: continuity,
        ).bytes;

    int lastCc(List<int> bytes, int pid) {
      var cc = -1;
      for (var i = 0; i < bytes.length ~/ 188; i++) {
        if (_pid(bytes, i) == pid) cc = _cc(bytes, i);
      }
      return cc;
    }

    int firstCc(List<int> bytes, int pid) {
      for (var i = 0; i < bytes.length ~/ 188; i++) {
        if (_pid(bytes, i) == pid) return _cc(bytes, i);
      }
      return -1;
    }

    for (final pid in [0x000, _pmtPid, 0x100, 0x101]) {
      expect(
        firstCc(second, pid),
        (lastCc(first, pid) + 1) & 0x0F,
        reason: 'PID 0x${pid.toRadixString(16)}',
      );
    }
  });
}
