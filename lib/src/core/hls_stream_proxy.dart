import 'dart:convert';
import 'dart:io';

import 'hls_alt_audio_proxy.dart';
import 'hls_parser.dart';
import 'http10_file_server.dart' show DlnaContentFeatures;
import 'ts_alt_audio_remuxer.dart';
import '../utils/logger.dart';

/// Handles fetching an HLS playlist and streaming its segments as a
/// continuous MPEG-TS byte stream.
///
/// Used by DLNA renderers that do not understand HLS — instead of
/// pointing the TV at an m3u8 URL, we resolve segments server-side and
/// concatenate them into a single `video/mp2t` response.
///
/// ## Alternate audio renditions
///
/// Sources whose master playlist declares `EXT-X-MEDIA:TYPE=AUDIO` with
/// matching variant `AUDIO="<group>"` reference are handled by routing
/// through [HlsAltAudioPlanner] + [TsAltAudioRemuxer]: each video
/// segment is fetched together with the chosen audio rendition's
/// segment, the pair is remuxed into a single TS, and the muxed bytes
/// are written to the response. The TV sees one continuous TS with
/// both streams just like a legacy muxed HLS source.
class HlsStreamHandler {
  final HttpClient _httpClient;

  /// Creates an [HlsStreamHandler] with an optional [HttpClient].
  HlsStreamHandler({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  /// Fetches the HLS playlist at [m3u8Url], resolves segments, and streams
  /// them sequentially into [response].
  ///
  /// If the playlist is a master playlist, the highest-bandwidth variant is
  /// selected automatically.
  ///
  /// [headers] are forwarded to all upstream requests (playlist + segments).
  ///
  /// [preferredAudioLanguage] is matched (case-insensitive substring)
  /// against each `EXT-X-MEDIA:TYPE=AUDIO` rendition's `NAME` attribute
  /// when the source uses alt-audio, falling back to `DEFAULT=YES` then
  /// the first rendition.
  /// Resolves [m3u8Url] and returns the total duration of the media it
  /// describes, or null when that cannot be determined.
  ///
  /// A DLNA renderer fed a piped TS has no way to work out how long the
  /// content is — there is no container header and no `Content-Length` — so it
  /// shows `00:00:01` and refuses to draw a scrub bar. Probing the playlist
  /// here lets the caller advertise the real duration in DIDL-Lite.
  ///
  /// Returns null for live playlists, whose duration is not fixed.
  Future<Duration?> probeDuration(
    String m3u8Url,
    Map<String, String> headers,
  ) async {
    try {
      var playlist = await _fetchPlaylist(m3u8Url, headers);

      if (HlsParser.isMasterPlaylist(playlist.body)) {
        final variants = HlsParser.extractVariants(
          playlist.body,
          playlist.finalUrl,
        );
        if (variants.isEmpty) return null;
        playlist = await _fetchPlaylist(variants.first.url, headers);
      }

      return HlsParser.totalDuration(playlist.body);
    } catch (e) {
      CastLogger.debug('HlsStreamHandler: duration probe failed: $e');
      return null;
    }
  }

  ///
  /// [requestHeaders] are the renderer's request headers. When given, the
  /// DLNA transfer headers it asks for are answered (DLNA guidelines
  /// 7.4.1.3): `contentFeatures.dlna.org` with [contentFeatures] (by default
  /// the value the DLNA session advertises for this route) and an echoed
  /// `transferMode.dlna.org`.
  Future<void> streamAsTransportStream(
    String m3u8Url,
    Map<String, String> headers,
    HttpResponse response, {
    String? preferredAudioLanguage,
    Duration startAt = Duration.zero,
    HttpHeaders? requestHeaders,
    String? contentFeatures,
  }) async {
    try {
      if (requestHeaders != null) {
        DlnaContentFeatures.responseHeaders(
          requestHeaders,
          contentFeatures ?? DlnaContentFeatures.pipedTransportStream,
        ).forEach(response.headers.set);
      }

      // Relative URIs resolve against the URL the playlist was finally
      // served from, after redirects (RFC 3986 §5.1.3).
      final playlist = await _fetchPlaylist(m3u8Url, headers);
      final playlistContent = playlist.body;
      final playlistUrl = playlist.finalUrl;

      // Alt-audio HLS — mux video + audio per segment, concatenate.
      if (HlsParser.isMasterPlaylist(playlistContent)) {
        final variants = HlsParser.extractVariants(
          playlistContent,
          playlistUrl,
        );
        if (variants.isEmpty) {
          response.statusCode = HttpStatus.badGateway;
          await response.close();
          return;
        }

        final picked = variants.first;
        final audioGroup = picked.audioGroup;
        if (audioGroup != null && audioGroup.isNotEmpty) {
          final audioRenditions = HlsParser.extractAudioRenditions(
            playlistContent,
            playlistUrl,
          );
          final hasMatchingAudioPlaylist = audioRenditions.any(
            (r) => r.groupId == audioGroup && r.uri != null,
          );
          if (hasMatchingAudioPlaylist) {
            await _streamMuxedAltAudio(
              m3u8Url: m3u8Url,
              headers: headers,
              response: response,
              preferredAudioLanguage: preferredAudioLanguage,
              startAt: startAt,
            );
            return;
          }
        }

        // Single-stream master — fetch the chosen variant playlist and
        // fall through to the legacy concat path below.
        final mediaPlaylist = await _fetchPlaylist(picked.url, headers);
        await _streamConcatenated(
          mediaPlaylistUrl: mediaPlaylist.finalUrl,
          mediaPlaylistContent: mediaPlaylist.body,
          headers: headers,
          response: response,
          startAt: startAt,
        );
        return;
      }

      // Media playlist directly — concat its segments.
      await _streamConcatenated(
        mediaPlaylistUrl: playlistUrl,
        mediaPlaylistContent: playlistContent,
        headers: headers,
        response: response,
        startAt: startAt,
      );
    } catch (e, stack) {
      CastLogger.error(
        'HlsStreamHandler: failed to stream TS playlist: $e\n$stack',
      );
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        // Response may already be closed.
      }
    }
  }

  /// Concatenates a media playlist's segments to [response] as a single
  /// `video/mp2t` body. Used for the simple "all-muxed segments" case.
  Future<void> _streamConcatenated({
    required String mediaPlaylistUrl,
    required String mediaPlaylistContent,
    required Map<String, String> headers,
    required HttpResponse response,
    Duration startAt = Duration.zero,
  }) async {
    // Segments this route cannot turn into a plain TS byte stream: piping
    // AES-128 / SAMPLE-AES ciphertext, or fMP4 fragments without their
    // initialization section, under a `video/mp2t` label only hands the
    // renderer garbage. Refuse them up front instead.
    if (HlsParser.isEncrypted(mediaPlaylistContent)) {
      CastLogger.error(
        'HlsStreamHandler: $mediaPlaylistUrl is encrypted (EXT-X-KEY) — '
        'cannot pipe it as plain MPEG-TS, refusing with 502',
      );
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }
    if (HlsParser.hasInitializationSection(mediaPlaylistContent)) {
      CastLogger.error(
        'HlsStreamHandler: $mediaPlaylistUrl uses fMP4/CMAF segments '
        '(EXT-X-MAP) — cannot pipe them as MPEG-TS, refusing with 502',
      );
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    final segments = HlsParser.extractMediaSegments(
      mediaPlaylistContent,
      mediaPlaylistUrl,
    );
    if (segments.isEmpty) {
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    // Seeking a piped TS is done by dropping whole segments: find the first
    // segment whose time range covers the requested offset and start there.
    // Byte ranges are meaningless here — the body is generated on the fly and
    // its length is not known in advance.
    final total = HlsParser.totalDuration(mediaPlaylistContent);
    final skip = _segmentsToSkip(
      segments.map((s) => s.duration).toList(),
      startAt,
    );
    if (skip.count >= segments.length) {
      // Seek past the end — nothing left to send.
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType('video', 'mp2t');
      await response.close();
      return;
    }

    _setStreamHeaders(
      response,
      startSeconds: skip.startSeconds,
      totalSeconds: total == null ? null : total.inMilliseconds / 1000.0,
    );

    for (final segment in segments.skip(skip.count)) {
      try {
        await _pipeSegment(segment, headers, response);
      } catch (_) {
        // Skip segments that fail to fetch.
      }
    }
    await response.close();
  }

  /// Fetches one media segment and adds its bytes to [response].
  ///
  /// An `#EXT-X-BYTERANGE` segment is fetched with a `Range` header for just
  /// its sub-range (RFC 8216 §4.3.2.2). If the server ignores the header and
  /// sends the whole resource with 200, only the sub-range is forwarded.
  Future<void> _pipeSegment(
    HlsMediaSegment segment,
    Map<String, String> headers,
    HttpResponse response,
  ) async {
    final segRequest = await _httpClient.openUrl('GET', Uri.parse(segment.url));
    for (final entry in headers.entries) {
      segRequest.headers.set(entry.key, entry.value);
    }
    final range = segment.rangeHeader;
    if (range != null) {
      segRequest.headers.set(HttpHeaders.rangeHeader, range);
    }
    final segResponse = await segRequest.close();

    if (range != null && segResponse.statusCode == HttpStatus.partialContent) {
      await for (final chunk in segResponse) {
        response.add(chunk);
      }
      return;
    }
    if (segResponse.statusCode != HttpStatus.ok) {
      await segResponse.drain<void>();
      return;
    }
    if (range == null) {
      await for (final chunk in segResponse) {
        response.add(chunk);
      }
      return;
    }

    // Range ignored: cut [offset, offset + length) out of the full body and
    // stop reading once it has been forwarded.
    final from = segment.byteRangeOffset!;
    final to = from + segment.byteRangeLength!;
    var position = 0;
    await for (final chunk in segResponse) {
      final chunkEnd = position + chunk.length;
      if (chunkEnd > from && position < to) {
        final s = from > position ? from - position : 0;
        final e = to < chunkEnd ? to - position : chunk.length;
        response.add(chunk.sublist(s, e));
      }
      position = chunkEnd;
      if (position >= to) break;
    }
  }

  /// How many leading segments to drop so the stream starts at the segment
  /// covering [startAt], and where that segment starts.
  static ({int count, double startSeconds}) _segmentsToSkip(
    List<double> durations,
    Duration startAt,
  ) {
    if (startAt <= Duration.zero) return (count: 0, startSeconds: 0.0);
    final target = startAt.inMilliseconds / 1000.0;
    var elapsed = 0.0;
    var count = 0;
    for (final duration in durations) {
      if (elapsed + duration > target) break;
      elapsed += duration;
      count++;
    }
    CastLogger.info(
      'HlsStreamHandler: time seek to ${target.toStringAsFixed(1)}s — '
      'skipping $count/${durations.length} segments, starting at '
      '${elapsed.toStringAsFixed(1)}s',
    );
    return (count: count, startSeconds: elapsed);
  }

  /// Status and headers shared by both piped-TS paths.
  ///
  /// The stream is generated on demand: byte ranges cannot be honoured, but
  /// time-based seeking can, so advertise exactly that. With no known total
  /// (a live playlist) the range is `npt=<start>-/*`.
  static void _setStreamHeaders(
    HttpResponse response, {
    required double startSeconds,
    required double? totalSeconds,
  }) {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType('video', 'mp2t');
    response.headers.set('Accept-Ranges', 'none');
    response.headers.set('Access-Control-Allow-Origin', '*');
    // HttpServer does not add Date by itself (RFC 9110 §6.6.1).
    response.headers.date = DateTime.now();
    final start = startSeconds.toStringAsFixed(3);
    if (totalSeconds != null) {
      final total = totalSeconds.toStringAsFixed(3);
      response.headers.set(
        'TimeSeekRange.dlna.org',
        'npt=$start-$total/$total',
      );
      response.headers.set('X-Seek-Range', 'npt=$start-$total');
    } else {
      response.headers.set('TimeSeekRange.dlna.org', 'npt=$start-/*');
    }
  }

  /// Fetches an alt-audio HLS plan, mux-then-writes each segment pair
  /// to [response] sequentially. The TV receives one continuous TS
  /// stream with both video and audio.
  Future<void> _streamMuxedAltAudio({
    required String m3u8Url,
    required Map<String, String> headers,
    required HttpResponse response,
    String? preferredAudioLanguage,
    Duration startAt = Duration.zero,
  }) async {
    final planner = HlsAltAudioPlanner(httpClient: _httpClient);
    final plan = await planner.plan(
      masterUrl: m3u8Url,
      headers: headers,
      preferredAudioLanguage: preferredAudioLanguage,
    );
    if (plan == null) {
      // Shouldn't happen — caller already verified alt-audio — but
      // handle defensively.
      response.statusCode = HttpStatus.badGateway;
      await response.close();
      return;
    }

    final durations = plan.segments.map((s) => s.durationSec).toList();
    final skip = _segmentsToSkip(durations, startAt);
    if (skip.count >= plan.segments.length) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType('video', 'mp2t');
      await response.close();
      return;
    }
    CastLogger.info(
      'HlsStreamHandler: streaming '
      '${plan.segments.length - skip.count}/${plan.segments.length} '
      'alt-audio segments as concatenated muxed TS',
    );

    _setStreamHeaders(
      response,
      startSeconds: skip.startSeconds,
      totalSeconds: durations.fold<double>(0.0, (a, b) => a + b),
    );

    final muxer = HlsAltAudioSegmentMuxer(planner: planner);
    // One response is one transport stream: continuity counters must run on
    // across segments rather than restart at 0 in each (§2.4.3.3).
    final continuity = TsMuxContinuity();
    for (var i = skip.count; i < plan.segments.length; i++) {
      try {
        final muxed = await muxer.muxSegment(
          plan: plan,
          segmentIndex: i,
          continuity: continuity,
        );
        response.add(muxed.bytes);
      } catch (e) {
        CastLogger.warning(
          'HlsStreamHandler: skipping segment $i — mux failed: $e',
        );
        // Skip the segment rather than abort the whole response —
        // matches the behaviour of [_streamConcatenated].
      }
    }
    await response.close();
  }

  /// Fetches a playlist and returns its text with the URL it was finally
  /// served from — the base for its relative URIs (RFC 3986 §5.1.3).
  /// [HttpClient] follows redirects silently, so the final URL is rebuilt
  /// from [HttpClientResponse.redirects].
  Future<({String body, String finalUrl})> _fetchPlaylist(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.parse(url);
    final request = await _httpClient.openUrl('GET', uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    var finalUri = uri;
    for (final redirect in response.redirects) {
      finalUri = finalUri.resolveUri(redirect.location);
    }
    return (body: utf8.decode(bytes), finalUrl: finalUri.toString());
  }

  /// Closes the underlying HTTP client.
  void close() {
    _httpClient.close(force: true);
  }
}
