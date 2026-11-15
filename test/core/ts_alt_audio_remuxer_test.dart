import 'package:dart_cast/src/core/ts_alt_audio_remuxer.dart';
import 'package:test/test.dart';

import 'ts_fixtures.dart';

void main() {
  test('keeps a PCR that the source carries on its own PID', () {
    final out =
        TsAltAudioRemuxer.mux(
          videoSegment: tsVideoSegment(90000),
          audioSegment: tsAudioSegment(90000),
        ).bytes;
    // PMT is the second packet; PCR_PID sits at section offset 8-9.
    final pmt = out.sublist(188, 376);
    final pcrPid = ((pmt[5 + 8] & 0x1F) << 8) | pmt[5 + 9];
    expect(pcrPid, 0x1FF);
    final pcrPackets = [
      for (var i = 0; i < out.length ~/ 188; i++)
        if (tsPid(out, i) == 0x1FF) i,
    ];
    expect(pcrPackets, hasLength(4));
    expect(out[pcrPackets.first * 188 + 5] & 0x10, 0x10); // PCR flag kept
  });

  test('interleaves audio and video by decode time', () {
    final out =
        TsAltAudioRemuxer.mux(
          videoSegment: tsVideoSegment(90000),
          audioSegment: tsAudioSegment(90000),
        ).bytes;
    final pids = [for (var i = 2; i < out.length ~/ 188; i++) tsPid(out, i)];
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
          videoSegment: tsVideoSegment(90000),
          audioSegment: tsAudioSegment(90000),
          continuity: continuity,
        ).bytes;
    final second =
        TsAltAudioRemuxer.mux(
          videoSegment: tsVideoSegment(90000 + 14400),
          audioSegment: tsAudioSegment(90000 + 13440),
          continuity: continuity,
        ).bytes;

    int lastCc(List<int> bytes, int pid) {
      var cc = -1;
      for (var i = 0; i < bytes.length ~/ 188; i++) {
        if (tsPid(bytes, i) == pid) cc = tsCc(bytes, i);
      }
      return cc;
    }

    int firstCc(List<int> bytes, int pid) {
      for (var i = 0; i < bytes.length ~/ 188; i++) {
        if (tsPid(bytes, i) == pid) return tsCc(bytes, i);
      }
      return -1;
    }

    for (final pid in [0x000, tsPmtPid, 0x100, 0x101]) {
      expect(
        firstCc(second, pid),
        (lastCc(first, pid) + 1) & 0x0F,
        reason: 'PID 0x${pid.toRadixString(16)}',
      );
    }
  });
}
