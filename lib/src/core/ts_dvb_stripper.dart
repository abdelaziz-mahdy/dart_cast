/// Streaming MPEG-TS packet filter that drops DVB-only tables.
///
/// Some HLS providers emit TS segments whose leading packets sit on
/// DVB-specific PIDs (Service Description Table on 0x0011, Network
/// Information Table on 0x0010, Event Information Table on 0x0012, …).
/// Chromecast's Shaka Player only probes the first few packets of a
/// segment to discover the PAT (`PID 0x0000`). If the PAT isn't in that
/// window — because DVB tables came first — the demuxer rejects the
/// segment and Cast returns `LOAD_FAILED` with no diagnostic detail.
///
/// Lenient demuxers (FFmpeg, mdk, VLC) scan the whole segment to find
/// PAT, so the same source plays fine in local playback. The fix on the
/// Cast path is to strip the DVB tables on egress so the receiver sees
/// PAT in the very first packet.
///
/// Usage (stream-friendly, handles arbitrary chunk boundaries):
/// ```dart
/// final filter = TsDvbStripper();
/// await for (final chunk in upstream) {
///   final out = filter.process(chunk);
///   if (out.isNotEmpty) sink.add(out);
/// }
/// final tail = filter.flush();
/// if (tail.isNotEmpty) sink.add(tail);
/// ```
class TsDvbStripper {
  /// MPEG-TS packet size in bytes.
  static const int packetSize = 188;

  /// PIDs of DVB-only tables that are not required for HLS playback and
  /// are likely to confuse strict TS demuxers when they appear before
  /// the PAT.
  static const Set<int> dvbPids = {
    0x0010, // NIT  — Network Information Table
    0x0011, // SDT/BAT — Service Description / Bouquet Association
    0x0012, // EIT  — Event Information Table
    0x0013, // RST  — Running Status Table
    0x0014, // TDT/TOT — Time / Time Offset Table
    0x001E, // DIT  — Discontinuity Information Table
    0x001F, // SIT  — Selection Information Table
  };

  /// PIDs the stream's own PAT/PMT assign to a PMT, an elementary stream
  /// or the PCR. ISO/IEC 13818-1 Table 2-3 lets a non-DVB multiplex put
  /// those on 0x0010–0x001F too, so a PID listed here is never dropped
  /// even when it is also in [dvbPids].
  final Set<int> _programPids = {};
  final Set<int> _pmtPids = {};

  /// Bytes carried over from the previous chunk that didn't form a
  /// complete TS packet on their own.
  final List<int> _carry = [];

  /// Count of packets kept (not on a DVB PID).
  int packetsKept = 0;

  /// Count of packets dropped (on a DVB PID).
  int packetsDropped = 0;

  /// Histogram of all PIDs seen in the stream (kept + dropped), keyed by
  /// PID. Used to diagnose TS structure issues — e.g. "no PAT (0x0000)
  /// present in this segment" or "audio PID not announced in PMT".
  final Map<int, int> pidCounts = {};

  /// Order in which previously-unseen PIDs appeared, useful for spotting
  /// "PAT not first" patterns that stricter demuxers reject.
  final List<int> pidArrivalOrder = [];

  /// Filters [chunk] and returns the bytes that should be written to the
  /// downstream response. Whole TS packets are kept or dropped; partial
  /// trailing packets are buffered internally until enough bytes arrive.
  List<int> process(List<int> chunk) {
    if (chunk.isEmpty) return const <int>[];

    // Combine carry + new chunk. Most segments arrive in just a few
    // chunks so allocation cost is negligible.
    final buf = [..._carry, ...chunk];
    _carry.clear();

    final output = <int>[];
    var i = 0;

    while (i + packetSize <= buf.length) {
      if (buf[i] != 0x47) {
        // Resync — search forward for the next sync byte. This handles
        // garbage at the start of the very first chunk and recovers if
        // a non-188-aligned upstream injects padding.
        var next = i + 1;
        while (next < buf.length && buf[next] != 0x47) {
          next++;
        }
        i = next;
        continue;
      }

      // Bytes 1–2 carry the PID in the low 13 bits.
      final pid = ((buf[i + 1] & 0x1F) << 8) | buf[i + 2];

      // Histogram + arrival order — capped at first 4096 distinct PIDs
      // so a malformed stream can't grow the map unboundedly.
      if (!pidCounts.containsKey(pid)) {
        if (pidArrivalOrder.length < 4096) {
          pidArrivalOrder.add(pid);
        }
      }
      pidCounts[pid] = (pidCounts[pid] ?? 0) + 1;

      final payloadUnitStart = (buf[i + 1] & 0x40) != 0;
      if (payloadUnitStart && (pid == 0 || _pmtPids.contains(pid))) {
        _readProgramTable(buf, i, pid);
      }

      if (dvbPids.contains(pid) && !_programPids.contains(pid)) {
        packetsDropped++;
      } else {
        packetsKept++;
        output.addAll(buf.getRange(i, i + packetSize));
      }

      i += packetSize;
    }

    // Stash any incomplete trailing packet for the next call.
    if (i < buf.length) {
      _carry.addAll(buf.getRange(i, buf.length));
    }
    return output;
  }

  /// Records the PMT PIDs from a PAT, or the elementary and PCR PIDs from
  /// a PMT, when the section starts in the packet at [start]. Sections
  /// spanning several packets are rare for PAT/PMT and are left unread;
  /// the packets then follow the plain [dvbPids] rule.
  void _readProgramTable(List<int> buf, int start, int pid) {
    final end = start + packetSize;
    final afc = (buf[start + 3] >> 4) & 0x3;
    if (afc == 0 || afc == 2) return; // no payload
    var p = start + 4;
    if (afc == 3) p += 1 + buf[p]; // skip adaptation field
    if (p >= end) return;
    p += 1 + buf[p]; // pointer_field
    if (p + 3 > end) return;
    final tableId = buf[p];
    final sectionLength = ((buf[p + 1] & 0x0F) << 8) | buf[p + 2];
    final sectionEnd = p + 3 + sectionLength - 4; // exclude CRC_32
    if (sectionEnd > end) return;

    if (pid == 0 && tableId == 0x00) {
      // program_association_section: 8 bytes header, then 4-byte loops.
      for (var q = p + 8; q + 4 <= sectionEnd; q += 4) {
        final programNumber = (buf[q] << 8) | buf[q + 1];
        final mapPid = ((buf[q + 2] & 0x1F) << 8) | buf[q + 3];
        if (programNumber != 0) {
          _pmtPids.add(mapPid);
          _programPids.add(mapPid);
        }
      }
    } else if (tableId == 0x02) {
      // TS_program_map_section.
      if (p + 12 > sectionEnd) return;
      _programPids.add(((buf[p + 8] & 0x1F) << 8) | buf[p + 9]); // PCR_PID
      final programInfoLength = ((buf[p + 10] & 0x0F) << 8) | buf[p + 11];
      var q = p + 12 + programInfoLength;
      while (q + 5 <= sectionEnd) {
        _programPids.add(((buf[q + 1] & 0x1F) << 8) | buf[q + 2]);
        final esInfoLength = ((buf[q + 3] & 0x0F) << 8) | buf[q + 4];
        q += 5 + esInfoLength;
      }
    }
  }

  /// Final byte flush. Returns any leftover bytes that didn't form a
  /// complete 188-byte packet — passed through unfiltered so we don't
  /// truncate the response if upstream returned a non-multiple of 188.
  /// In practice this is almost always empty for well-formed TS files.
  List<int> flush() {
    final remaining = List<int>.from(_carry);
    _carry.clear();
    return remaining;
  }

  /// Whether this stripper actually changed anything.
  bool get didDropAny => packetsDropped > 0;

  @override
  String toString() =>
      'TsDvbStripper(kept=$packetsKept, dropped=$packetsDropped)';
}
