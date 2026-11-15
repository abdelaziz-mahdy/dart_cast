// Synthetic MPEG-TS builders shared by the remuxer and stream-proxy tests.
//
// Packets are 188 bytes, payload padded with 0xFF; sections carry a zero
// CRC, which the code under test does not check.

import 'dart:typed_data';

const tsPmtPid = 0x1000;

Uint8List tsPacket(int pid, {bool pusi = false, int afc = 1}) {
  final p = Uint8List(188)..fillRange(4, 188, 0xFF);
  p[0] = 0x47;
  p[1] = (pusi ? 0x40 : 0) | (pid >> 8);
  p[2] = pid & 0xFF;
  p[3] = afc << 4;
  return p;
}

Uint8List tsPsi(int pid, List<int> section) =>
    tsPacket(pid, pusi: true)
      ..[4] = 0
      ..setRange(5, 5 + section.length, section);

Uint8List tsPat() => tsPsi(0, [
  0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, //
  0x00, 0x01, 0xE0 | (tsPmtPid >> 8), tsPmtPid & 0xFF, //
  0, 0, 0, 0,
]);

Uint8List tsPmt({
  required int pcrPid,
  required int streamType,
  required int esPid,
}) => tsPsi(tsPmtPid, [
  0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, //
  0xE0 | (pcrPid >> 8), pcrPid & 0xFF, 0xF0, 0x00, //
  streamType, 0xE0 | (esPid >> 8), esPid & 0xFF, 0xF0, 0x00, //
  0, 0, 0, 0,
]);

List<int> tsTimestamp(int prefix, int t) => [
  (prefix << 4) | (((t >> 30) & 0x07) << 1) | 1,
  (t >> 22) & 0xFF,
  (((t >> 15) & 0x7F) << 1) | 1,
  (t >> 7) & 0xFF,
  ((t & 0x7F) << 1) | 1,
];

/// A PES start packet on [pid] carrying PTS (and DTS when [dts] is set).
Uint8List tsPes(int pid, int streamId, int pts, {int? dts}) {
  final p = tsPacket(pid, pusi: true);
  final header = <int>[
    0x00, 0x00, 0x01, streamId, 0x00, 0x00, 0x80, //
    dts == null ? 0x80 : 0xC0,
    dts == null ? 5 : 10,
    ...tsTimestamp(dts == null ? 0x2 : 0x3, pts),
    if (dts != null) ...tsTimestamp(0x1, dts),
  ];
  p.setRange(4, 4 + header.length, header);
  return p;
}

/// An adaptation-only packet carrying a PCR whose base is [base].
Uint8List tsPcr(int pid, int base) {
  final p = tsPacket(pid, afc: 2);
  p[4] = 183;
  p[5] = 0x10; // PCR_flag
  p[6] = (base >> 25) & 0xFF;
  p[7] = (base >> 17) & 0xFF;
  p[8] = (base >> 9) & 0xFF;
  p[9] = (base >> 1) & 0xFF;
  p[10] = ((base & 1) << 7) | 0x7E;
  return p;
}

int tsPid(List<int> bytes, int packet) =>
    ((bytes[packet * 188 + 1] & 0x1F) << 8) | bytes[packet * 188 + 2];

int tsCc(List<int> bytes, int packet) => bytes[packet * 188 + 3] & 0x0F;

/// Video: PCR on its own PID 0x1FF0, frames every 3600 ticks (40 ms).
List<int> tsVideoSegment(int start) => [
  ...tsPat(),
  ...tsPmt(pcrPid: 0x1FF0, streamType: 0x1B, esPid: 0x200),
  for (var f = 0; f < 4; f++) ...[
    ...tsPcr(0x1FF0, start + f * 3600),
    ...tsPes(0x200, 0xE0, start + f * 3600 + 3600, dts: start + f * 3600),
    ...tsPacket(0x200),
  ],
];

/// Audio: frames every 1920 ticks.
List<int> tsAudioSegment(int start) => [
  ...tsPat(),
  ...tsPmt(pcrPid: 0x300, streamType: 0x0F, esPid: 0x300),
  for (var f = 0; f < 7; f++) ...tsPes(0x300, 0xC0, start + f * 1920),
];
