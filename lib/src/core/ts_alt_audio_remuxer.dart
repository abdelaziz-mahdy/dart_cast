/// Pure-Dart MPEG-TS remuxer that combines an HLS *alternate audio*
/// rendition's TS segment with its matching video variant's TS segment
/// into a single muxed TS stream the Default Media Receiver (Shaka
/// Player) can demux without alt-audio support.
///
/// Why this exists: HLS allows audio to live in a *separate* playlist
/// referenced via `EXT-X-MEDIA:TYPE=AUDIO`. The receiver is supposed to
/// fetch both playlists and demux them in parallel — but Shaka Player
/// [explicitly does not](https://github.com/shaka-project/shaka-player/issues/4081)
/// support that scenario when the underlying segments are MPEG-TS.
/// Result: silent `LOAD_FAILED`. The fix in production at Jellyfin /
/// Plex / similar projects is to remux video + audio into a single TS
/// before serving it to Cast. This file is the pure-Dart equivalent —
/// no `ffmpeg` dependency, no external binary.
///
/// Algorithm per segment pair (`video.ts`, `audio.ts`):
///   1. Detect the PMT PID from each segment's PAT.
///   2. From each PMT, learn which elementary PID carries video / audio
///      and what `stream_type` they are.
///   3. Drop PSI (PAT/PMT/SDT) and null-packet (PID 0x1FFF) packets
///      from both inputs. Keep everything else.
///   4. Rewrite the audio packets' PID to a fixed `outputAudioPid` so
///      it never collides with the video PID (which we keep as-is).
///   5. Prepend a freshly built PAT + PMT declaring:
///        - one program (`program_number=1`),
///        - `PCR_PID = outputVideoPid` (PCR rides on video, which is
///          standard practice and matches what the source segments do),
///        - two elementary streams (video on `outputVideoPid`, audio on
///          `outputAudioPid`, each with the `stream_type` we read from
///          the source PMT).
///   6. Emit: `[PAT][PMT][video TS packets][audio TS packets]`.
///
/// Continuity counters in the output are kept consistent per PID by
/// renumbering. PSI tables use `version_number=0` and `continuity=0`
/// because each muxed segment is self-contained (Shaka resets state at
/// segment boundaries when serving HLS).
///
/// The muxer is synchronous and operates on whole segments in memory —
/// segments are typically 100 KB–1 MB so this is cheap enough.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// MPEG-TS packet size in bytes.
const int kTsPacketSize = 188;

/// MPEG-TS sync byte.
const int kTsSyncByte = 0x47;

/// Standard PID for the Program Association Table.
const int kPidPat = 0x0000;

/// Conventional PID for the null packet (used for padding by some streams).
const int kPidNull = 0x1FFF;

/// PIDs reserved for DVB tables — these never carry program data and
/// are dropped during remux to avoid confusing the receiver.
const Set<int> kDvbReservedPids = {
  0x0010, // NIT
  0x0011, // SDT / BAT
  0x0012, // EIT
  0x0013, // RST
  0x0014, // TDT / TOT
  0x001E, // DIT
  0x001F, // SIT
};

/// Result of remuxing a video + audio segment pair.
class RemuxedSegment {
  /// The combined MPEG-TS bytes ready for serving to the receiver.
  final Uint8List bytes;

  /// Number of TS packets in the output (including synthesised PAT/PMT).
  final int packetCount;

  /// Diagnostic counts for logging.
  final int videoPacketsCopied;
  final int audioPacketsCopied;
  final int packetsDropped;

  const RemuxedSegment({
    required this.bytes,
    required this.packetCount,
    required this.videoPacketsCopied,
    required this.audioPacketsCopied,
    required this.packetsDropped,
  });

  @override
  String toString() =>
      'RemuxedSegment(packets=$packetCount, video=$videoPacketsCopied, '
      'audio=$audioPacketsCopied, dropped=$packetsDropped, '
      'bytes=${bytes.length})';
}

// ---------------------------------------------------------------------------
// CRC32-MPEG (polynomial 0x04C11DB7, MSB-first, initial value 0xFFFFFFFF)
// ---------------------------------------------------------------------------

/// CRC32 used by all MPEG-2 PSI sections. Defined in ISO/IEC 13818-1
/// Annex A — polynomial `0x04C11DB7`, MSB-first, initial value
/// `0xFFFFFFFF`, no final XOR.
class _Crc32Mpeg {
  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final t = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i << 24;
      for (var j = 0; j < 8; j++) {
        if ((c & 0x80000000) != 0) {
          c = (c << 1) ^ 0x04C11DB7;
        } else {
          c <<= 1;
        }
        c &= 0xFFFFFFFF;
      }
      t[i] = c;
    }
    return t;
  }

  /// Computes the MPEG-2 CRC32 over [data].
  static int compute(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = ((crc << 8) ^ _table[((crc >> 24) ^ b) & 0xFF]) & 0xFFFFFFFF;
    }
    return crc;
  }
}

// ---------------------------------------------------------------------------
// PSI builders (PAT + PMT)
// ---------------------------------------------------------------------------

class _PsiBuilder {
  /// Builds a complete 188-byte TS packet carrying a PAT that declares
  /// a single program (program_number=1) whose PMT lives on [pmtPid].
  static Uint8List buildPatPacket({required int pmtPid}) {
    // Section body (everything after section_length, before CRC).
    //
    //   transport_stream_id  16  = 0x0001
    //   reserved              2  = 0b11
    //   version_number        5  = 0
    //   current_next          1  = 1
    //   section_number        8  = 0
    //   last_section_number   8  = 0
    //   program_number       16  = 0x0001
    //   reserved              3  = 0b111
    //   program_map_PID      13
    final body = <int>[
      0x00, 0x01, // transport_stream_id
      0xC1, // reserved + version_number=0 + current_next=1
      0x00, // section_number
      0x00, // last_section_number
      0x00, 0x01, // program_number = 1
      0xE0 | ((pmtPid >> 8) & 0x1F), pmtPid & 0xFF, // reserved + PMT PID
    ];

    // table_id + section_syntax(1)/'0'(0)/reserved(11) + section_length(12)
    // section_length = body.length + 4 (CRC32)
    final sectionLength = body.length + 4;
    final sectionHeader = <int>[
      0x00, // table_id = PAT
      0xB0 | ((sectionLength >> 8) & 0x0F),
      sectionLength & 0xFF,
    ];

    // CRC is over (table_id + section_length + body)
    final crcInput = [...sectionHeader, ...body];
    final crc = _Crc32Mpeg.compute(crcInput);
    final section = <int>[
      ...crcInput,
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ];

    return _wrapPsiInTsPacket(pid: kPidPat, section: section);
  }

  /// Builds a complete 188-byte TS packet carrying a PMT declaring the
  /// given elementary streams.
  static Uint8List buildPmtPacket({
    required int pmtPid,
    required int pcrPid,
    required List<_PmtStream> streams,
  }) {
    final streamLoop = <int>[];
    for (final s in streams) {
      streamLoop.addAll([
        s.streamType & 0xFF,
        0xE0 | ((s.elementaryPid >> 8) & 0x1F),
        s.elementaryPid & 0xFF,
        0xF0, // reserved + ES_info_length high
        0x00, // ES_info_length low (no descriptors)
      ]);
    }

    // Section body (after section_length, before CRC).
    //
    //   program_number      16
    //   reserved             2 + version 5 + current_next 1 = 0xC1
    //   section_number       8 = 0
    //   last_section_number  8 = 0
    //   reserved             3 + PCR_PID 13
    //   reserved             4 + program_info_length 12 = 0
    //   [streams loop]
    final body = <int>[
      0x00, 0x01, // program_number = 1
      0xC1,
      0x00,
      0x00,
      0xE0 | ((pcrPid >> 8) & 0x1F),
      pcrPid & 0xFF,
      0xF0, // program_info_length high (4 bits reserved + upper 4 bits)
      0x00, // program_info_length low (no program descriptors)
      ...streamLoop,
    ];

    final sectionLength = body.length + 4;
    final sectionHeader = <int>[
      0x02, // table_id = PMT
      0xB0 | ((sectionLength >> 8) & 0x0F),
      sectionLength & 0xFF,
    ];

    final crcInput = [...sectionHeader, ...body];
    final crc = _Crc32Mpeg.compute(crcInput);
    final section = <int>[
      ...crcInput,
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ];

    return _wrapPsiInTsPacket(pid: pmtPid, section: section);
  }

  /// Wraps a PSI section in a 188-byte TS packet: TS header (4B) +
  /// pointer field (1B = 0) + section + 0xFF padding to 188 bytes.
  /// Assumes the section fits in a single packet (true for any PAT and
  /// for PMTs declaring a small number of streams — verified ≤183 bytes).
  static Uint8List _wrapPsiInTsPacket({
    required int pid,
    required List<int> section,
  }) {
    final packet = Uint8List(kTsPacketSize);
    packet[0] = kTsSyncByte;
    // PUSI=1 (section starts here), PID high
    packet[1] = 0x40 | ((pid >> 8) & 0x1F);
    packet[2] = pid & 0xFF;
    // No adaptation field, payload only, continuity counter = 0
    packet[3] = 0x10;
    // Pointer field — section starts immediately after.
    packet[4] = 0x00;
    var offset = 5;
    for (var i = 0; i < section.length && offset < kTsPacketSize; i++) {
      packet[offset++] = section[i];
    }
    while (offset < kTsPacketSize) {
      packet[offset++] = 0xFF;
    }
    return packet;
  }
}

/// Continuity counters per output PID, carried across consecutive
/// [TsAltAudioRemuxer.mux] calls whose outputs form one stream.
class TsMuxContinuity {
  final Map<int, int> _next = {};

  /// The counter for a packet with payload on [pid]; advances it.
  int _nextFor(int pid) {
    final value = _next[pid] ?? 0;
    _next[pid] = (value + 1) & 0x0F;
    return value;
  }

  /// The counter for a packet without payload on [pid], which repeats the
  /// previous payload packet's value (§2.4.3.3).
  int _currentFor(int pid) => ((_next[pid] ?? 0) - 1) & 0x0F;
}

class _TimedPacket {
  final Uint8List bytes;

  /// Decode time (DTS, else PTS; PCR base for PCR-only packets) of the PES
  /// this packet belongs to, on the 90 kHz clock; null before the first.
  final int? time;

  const _TimedPacket(this.bytes, this.time);
}

class _PmtStream {
  final int streamType;
  final int elementaryPid;
  const _PmtStream({required this.streamType, required this.elementaryPid});
}

// ---------------------------------------------------------------------------
// PSI parser — minimal: just enough to discover stream PIDs + types.
// ---------------------------------------------------------------------------

class _TsScan {
  /// Walks [bytes] one 188-byte packet at a time and returns the first
  /// PMT PID found in any PAT packet. Returns null if no PAT is present.
  static int? findPmtPid(List<int> bytes) {
    for (var i = 0; i + kTsPacketSize <= bytes.length; i += kTsPacketSize) {
      if (bytes[i] != kTsSyncByte) continue;
      final pid = ((bytes[i + 1] & 0x1F) << 8) | bytes[i + 2];
      if (pid != kPidPat) continue;
      final pusi = (bytes[i + 1] & 0x40) != 0;
      if (!pusi) continue;
      // Payload starts at i+4 (no adaptation field assumed for PAT) +
      // pointer field at i+4.
      final pointer = bytes[i + 4];
      final sectionStart = i + 5 + pointer;
      // PAT layout: table_id(8) sectionSyntax+sectionLength(16)
      //   transportStreamId(16) ver/curNext(8) sectionNum(8) lastSecNum(8)
      //   then 4-byte program entries
      // First program entry starts at sectionStart + 8.
      // Each entry: program_number(16) + (reserved3 + pid 13)(16) = 4 bytes
      // section_length tells us how many bytes the rest occupies (incl CRC).
      if (sectionStart + 8 >= bytes.length) return null;
      final sectionLength =
          ((bytes[sectionStart + 1] & 0x0F) << 8) | bytes[sectionStart + 2];
      // sectionLength counts bytes after this field — so program entries +
      // CRC live in (sectionLength - 5 - 4) bytes (5 = the fixed header
      // fields after section_length, 4 = trailing CRC32).
      final entriesStart = sectionStart + 8; // skip 5 header fields
      final entriesEnd = sectionStart + 3 + sectionLength - 4; // before CRC
      for (var p = entriesStart; p + 4 <= entriesEnd; p += 4) {
        final programNumber = (bytes[p] << 8) | bytes[p + 1];
        if (programNumber == 0) continue; // Network PID, not a PMT
        final pmtPid = ((bytes[p + 2] & 0x1F) << 8) | bytes[p + 3];
        return pmtPid;
      }
    }
    return null;
  }

  /// The PCR_PID of the first program in [bytes], or null.
  static int? findPcrPid(List<int> bytes) {
    final pmtPid = findPmtPid(bytes);
    if (pmtPid == null) return null;
    for (var i = 0; i + kTsPacketSize <= bytes.length; i += kTsPacketSize) {
      if (bytes[i] != kTsSyncByte) continue;
      final pid = ((bytes[i + 1] & 0x1F) << 8) | bytes[i + 2];
      if (pid != pmtPid || (bytes[i + 1] & 0x40) == 0) continue;
      final sectionStart = i + 5 + bytes[i + 4];
      if (sectionStart + 10 > i + kTsPacketSize) return null;
      return ((bytes[sectionStart + 8] & 0x1F) << 8) | bytes[sectionStart + 9];
    }
    return null;
  }

  /// The decode time carried by the TS packet at [i]: the DTS (else PTS)
  /// of a PES that starts in it, or the PCR base of its adaptation field.
  /// Null when it carries neither.
  static int? decodeTime(List<int> bytes, int i) {
    final afc = (bytes[i + 3] >> 4) & 0x03;
    var payload = i + 4;
    if (afc == 0x02 || afc == 0x03) {
      final adaptationLength = bytes[i + 4];
      if (adaptationLength > 0 &&
          (bytes[i + 5] & 0x10) != 0 &&
          i + 11 <= i + kTsPacketSize) {
        // PCR: 33-bit base in the first 33 bits of the 48-bit field.
        final pcrBase =
            (bytes[i + 6] << 25) |
            (bytes[i + 7] << 17) |
            (bytes[i + 8] << 9) |
            (bytes[i + 9] << 1) |
            (bytes[i + 10] >> 7);
        if (afc == 0x02) return pcrBase;
      }
      payload += 1 + adaptationLength;
    }
    if (afc == 0x02 || (bytes[i + 1] & 0x40) == 0) return null;
    if (payload + 14 > i + kTsPacketSize) return null;
    if (bytes[payload] != 0 ||
        bytes[payload + 1] != 0 ||
        bytes[payload + 2] != 1) {
      return null;
    }
    final flags = (bytes[payload + 7] >> 6) & 0x03;
    int read(int at) =>
        (((bytes[at] >> 1) & 0x07) << 30) |
        (bytes[at + 1] << 22) |
        (((bytes[at + 2] >> 1) & 0x7F) << 15) |
        (bytes[at + 3] << 7) |
        ((bytes[at + 4] >> 1) & 0x7F);
    if (flags == 0x03 && payload + 19 <= i + kTsPacketSize) {
      return read(payload + 14); // DTS
    }
    if (flags >= 0x02) return read(payload + 9); // PTS
    return null;
  }

  /// Reads the PMT at PID [pmtPid] from [bytes] and returns the
  /// elementary streams it declares. Returns empty list if PMT not
  /// found / malformed.
  static List<_PmtStream> readPmtStreams(List<int> bytes, int pmtPid) {
    for (var i = 0; i + kTsPacketSize <= bytes.length; i += kTsPacketSize) {
      if (bytes[i] != kTsSyncByte) continue;
      final pid = ((bytes[i + 1] & 0x1F) << 8) | bytes[i + 2];
      if (pid != pmtPid) continue;
      final pusi = (bytes[i + 1] & 0x40) != 0;
      if (!pusi) continue;
      final pointer = bytes[i + 4];
      final sectionStart = i + 5 + pointer;
      if (sectionStart + 12 >= bytes.length) return const [];
      final sectionLength =
          ((bytes[sectionStart + 1] & 0x0F) << 8) | bytes[sectionStart + 2];
      // PMT layout after section_length:
      //   programNumber(16) ver/curNext(8) secNum(8) lastSecNum(8)
      //   reserved3+PCR_PID(16) reserved4+programInfoLen(16) ...
      final programInfoLen =
          ((bytes[sectionStart + 10] & 0x0F) << 8) | bytes[sectionStart + 11];
      var p = sectionStart + 12 + programInfoLen;
      final streamsEnd = sectionStart + 3 + sectionLength - 4; // before CRC
      final result = <_PmtStream>[];
      while (p + 5 <= streamsEnd && p + 5 <= bytes.length) {
        final streamType = bytes[p];
        final esPid = ((bytes[p + 1] & 0x1F) << 8) | bytes[p + 2];
        final esInfoLen = ((bytes[p + 3] & 0x0F) << 8) | bytes[p + 4];
        result.add(_PmtStream(streamType: streamType, elementaryPid: esPid));
        p += 5 + esInfoLen;
      }
      return result;
    }
    return const [];
  }
}

// ---------------------------------------------------------------------------
// Main remuxer
// ---------------------------------------------------------------------------

class TsAltAudioRemuxer {
  /// Combines a video TS [videoSegment] and an audio TS [audioSegment]
  /// into one TS stream Chromecast can play.
  ///
  /// [outputVideoPid] and [outputAudioPid] control where each stream
  /// ends up in the muxed output — they default to 0x100 / 0x101, the
  /// most common HLS-TS layout.
  ///
  /// [outputPmtPid] is the PID of the synthesised PMT. 0x1000 is a
  /// conventional choice and avoids the DVB-reserved range and PAT.
  ///
  /// Pass the same [continuity] to consecutive calls when their outputs
  /// are concatenated into one stream (the DLNA pipe), so every PID's
  /// continuity_counter runs on across segment boundaries as ISO/IEC
  /// 13818-1 §2.4.3.3 requires. Without it each segment starts at 0.
  static RemuxedSegment mux({
    required List<int> videoSegment,
    required List<int> audioSegment,
    int outputVideoPid = 0x100,
    int outputAudioPid = 0x101,
    int outputPmtPid = 0x1000,
    int outputPcrPid = 0x1FF,
    TsMuxContinuity? continuity,
  }) {
    final cc = continuity ?? TsMuxContinuity();

    // 1. Discover source PIDs + stream types from each input's PMT.
    final videoStreams = _inspect(videoSegment);
    final audioStreams = _inspect(audioSegment);

    final videoStream = _pickByCategory(videoStreams, _StreamCategory.video);
    final audioStream = _pickByCategory(audioStreams, _StreamCategory.audio);

    if (videoStream == null && audioStream == null) {
      // Neither input has a recognisable elementary stream — return the
      // video segment unchanged to avoid making things worse.
      return RemuxedSegment(
        bytes: Uint8List.fromList(videoSegment),
        packetCount: videoSegment.length ~/ kTsPacketSize,
        videoPacketsCopied: 0,
        audioPacketsCopied: 0,
        packetsDropped: 0,
      );
    }

    // 2. Where the source carries its PCR. ISO/IEC 13818-1 §2.4.4.9: the
    //    program's PCR rides on PCR_PID, which need not be an elementary
    //    PID. When it is a PCR-only PID, those packets are kept (on
    //    [outputPcrPid]) — dropping them leaves the output with no clock.
    final timingSource = videoStream != null ? videoSegment : audioSegment;
    final timingStream = videoStream ?? audioStream!;
    final timingOutputPid =
        videoStream != null ? outputVideoPid : outputAudioPid;
    final sourcePcrPid = _TsScan.findPcrPid(timingSource);
    final hasSeparatePcr =
        sourcePcrPid != null &&
        sourcePcrPid != timingStream.elementaryPid &&
        sourcePcrPid != kPidNull;
    final pcrPid = hasSeparatePcr ? outputPcrPid : timingOutputPid;

    // 3. Build synthesised PSI.
    final pmtStreams = <_PmtStream>[
      if (videoStream != null)
        _PmtStream(
          streamType: videoStream.streamType,
          elementaryPid: outputVideoPid,
        ),
      if (audioStream != null)
        _PmtStream(
          streamType: audioStream.streamType,
          elementaryPid: outputAudioPid,
        ),
    ];
    final patPacket = _PsiBuilder.buildPatPacket(pmtPid: outputPmtPid);
    final pmtPacket = _PsiBuilder.buildPmtPacket(
      pmtPid: outputPmtPid,
      pcrPid: pcrPid,
      streams: pmtStreams,
    );

    // 4. Collect each stream's packets with the decode time of the PES they
    //    belong to.
    List<_TimedPacket> collect(List<int> source, int sourcePid, int target) {
      final packets = <_TimedPacket>[];
      int? current;
      for (var i = 0; i + kTsPacketSize <= source.length; i += kTsPacketSize) {
        if (source[i] != kTsSyncByte) continue;
        final pid = ((source[i + 1] & 0x1F) << 8) | source[i + 2];
        if (pid != sourcePid) continue;
        current = _TsScan.decodeTime(source, i) ?? current;
        final pkt = Uint8List.fromList(source.sublist(i, i + kTsPacketSize));
        // Rewrite PID in bytes 1–2 while preserving the high 3 flag bits
        // of byte 1 (TEI, PUSI, transport_priority).
        pkt[1] = (pkt[1] & 0xE0) | ((target >> 8) & 0x1F);
        pkt[2] = target & 0xFF;
        packets.add(_TimedPacket(pkt, current));
      }
      return packets;
    }

    final video =
        videoStream == null
            ? const <_TimedPacket>[]
            : collect(videoSegment, videoStream.elementaryPid, outputVideoPid);
    final audio =
        audioStream == null
            ? const <_TimedPacket>[]
            : collect(audioSegment, audioStream.elementaryPid, outputAudioPid);
    final pcr =
        hasSeparatePcr
            ? collect(timingSource, sourcePcrPid, outputPcrPid)
            : const <_TimedPacket>[];
    final inputPackets =
        (videoStream != null ? videoSegment.length ~/ kTsPacketSize : 0) +
        (audioStream != null ? audioSegment.length ~/ kTsPacketSize : 0);
    final dropped = inputPackets - video.length - audio.length - pcr.length;

    // 5. Interleave by decode time (§2.4.2, T-STD): emitting all video and
    //    then all audio delivers the audio a whole segment late.
    final merged = _mergeByTime([video, pcr, audio]);

    // 6. Emit PAT, PMT, then the packets with continuity counters renumbered
    //    per output PID. The counter only advances on packets that carry a
    //    payload (§2.4.3.3).
    final out = BytesBuilder(copy: false);
    void emit(Uint8List pkt, int pid) {
      final afc = (pkt[3] >> 4) & 0x03;
      if (afc == 0x01 || afc == 0x03) {
        pkt[3] = (pkt[3] & 0xF0) | cc._nextFor(pid);
      } else {
        pkt[3] = (pkt[3] & 0xF0) | cc._currentFor(pid);
      }
      out.add(pkt);
    }

    emit(patPacket, kPidPat);
    emit(pmtPacket, outputPmtPid);
    for (final p in merged) {
      emit(p.bytes, ((p.bytes[1] & 0x1F) << 8) | p.bytes[2]);
    }

    final bytes = out.toBytes();
    return RemuxedSegment(
      bytes: bytes,
      packetCount: bytes.length ~/ kTsPacketSize,
      videoPacketsCopied: video.length,
      audioPacketsCopied: audio.length,
      packetsDropped: dropped < 0 ? 0 : dropped,
    );
  }

  /// Merges per-stream packet lists by decode time. Each list keeps its
  /// own order; packets before the first timestamp in their list go
  /// first. Times are compared on the 33-bit clock relative to the
  /// earliest one, so a wrap does not reorder the streams. Ties keep the
  /// order of [lists].
  static List<_TimedPacket> _mergeByTime(List<List<_TimedPacket>> lists) {
    int? base;
    for (final list in lists) {
      for (final p in list) {
        final t = p.time;
        if (t != null && (base == null || _relative(t, base) < 0)) base = t;
      }
    }
    final index = List<int>.filled(lists.length, 0);
    final result = <_TimedPacket>[];
    while (true) {
      var pick = -1;
      var pickTime = 0;
      for (var l = 0; l < lists.length; l++) {
        if (index[l] >= lists[l].length) continue;
        final t = lists[l][index[l]].time;
        final rel = (t == null || base == null) ? -1 << 40 : _relative(t, base);
        if (pick < 0 || rel < pickTime) {
          pick = l;
          pickTime = rel;
        }
      }
      if (pick < 0) break;
      result.add(lists[pick][index[pick]++]);
    }
    return result;
  }

  static const int _clockMask = (1 << 33) - 1;

  /// [t] − [base] on the 33-bit 90 kHz clock, as a signed value.
  static int _relative(int t, int base) {
    final d = (t - base) & _clockMask;
    return d >= (1 << 32) ? d - (1 << 33) : d;
  }

  /// Reads a segment's PAT → PMT → declared elementary streams, then
  /// categorises each stream by its `stream_type`.
  static List<_TypedStream> _inspect(List<int> bytes) {
    final pmtPid = _TsScan.findPmtPid(bytes);
    if (pmtPid == null) return const [];
    final streams = _TsScan.readPmtStreams(bytes, pmtPid);
    return streams.map(_TypedStream.fromPmtStream).toList();
  }

  static _TypedStream? _pickByCategory(
    List<_TypedStream> streams,
    _StreamCategory category,
  ) {
    for (final s in streams) {
      if (s.category == category) return s;
    }
    return null;
  }
}

/// Stream-type categorisation (subset — extend as needed).
enum _StreamCategory { video, audio, other }

class _TypedStream {
  final int streamType;
  final int elementaryPid;
  final _StreamCategory category;

  const _TypedStream({
    required this.streamType,
    required this.elementaryPid,
    required this.category,
  });

  factory _TypedStream.fromPmtStream(_PmtStream s) {
    final category = _categoriseStreamType(s.streamType);
    return _TypedStream(
      streamType: s.streamType,
      elementaryPid: s.elementaryPid,
      category: category,
    );
  }

  static _StreamCategory _categoriseStreamType(int t) {
    // Common video stream_types
    switch (t) {
      case 0x01: // MPEG-1 video
      case 0x02: // MPEG-2 video
      case 0x10: // MPEG-4 part 2
      case 0x1B: // H.264 / AVC
      case 0x24: // HEVC
        return _StreamCategory.video;
      case 0x03: // MPEG-1 audio
      case 0x04: // MPEG-2 audio
      case 0x0F: // AAC (ADTS)
      case 0x11: // AAC (LATM/LOAS)
      case 0x81: // AC-3
      case 0x87: // E-AC-3
        return _StreamCategory.audio;
    }
    return _StreamCategory.other;
  }
}
