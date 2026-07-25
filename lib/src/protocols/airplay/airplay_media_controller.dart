import 'dart:convert';
import 'dart:math';

import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/protocols/airplay/auth/binary_plist.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:dart_cast/src/protocols/airplay/plist_codec.dart';
import 'package:dart_cast/src/protocols/airplay/timing_server.dart';
import 'package:dart_cast/src/utils/logger.dart';

/// Controls AirPlay video playback (play, pause, seek, stop, etc.) over an
/// existing [HapSession].
///
/// The protocol version is chosen **from the device's advertised feature
/// bits**, never by probing:
///
/// - bit 38 or bit 48 set → AirPlay 2. Requires bit 49 (`SupportsAirPlayVideoV2`),
///   an RTSP `SETUP`/`RECORD` handshake with a live UDP timing server, and a
///   `/rate` command after `/play`.
/// - otherwise → AirPlay 1. Requires bit 0 (`SupportsAirPlayVideoV1`) and needs
///   no RTSP setup.
///
/// A device that advertises neither video bit is rejected before a single byte
/// goes out. The package used to send a V1 `/play` first and walk a 404/415
/// fallback ladder; every AirPlay 2–only receiver answers that first request
/// with 404, which is the device correctly refusing a request it never claimed
/// to support.
class AirPlayMediaController {
  /// The encrypted HAP session used for all communication.
  final HapSession session;

  /// Feature flags for the target AirPlay device.
  final AirPlayFeatures features;

  /// The UDP timing server used for AirPlay 2 playback.
  final AirPlayTimingServer timingServer;

  /// Creates an [AirPlayMediaController].
  AirPlayMediaController({
    required this.session,
    required this.features,
    AirPlayTimingServer? timingServer,
  }) : timingServer = timingServer ?? AirPlayTimingServer();

  // ---------------------------------------------------------------------------
  // Play commands
  // ---------------------------------------------------------------------------

  /// Sends a V1 binary plist `/play` request.
  ///
  /// [startPositionFraction] is a 0.0–1.0 *fraction* of the media, which is
  /// what the AirPlay 1 `Start-Position` parameter means. AirPlay 2's
  /// `Start-Position-Seconds` is absolute instead — see [playV2].
  ///
  /// Does NOT set up an RTSP session first — V1 works over plain HTTP/1.1.
  Future<HapHttpResponse> playV1(
    String url,
    double startPositionFraction,
  ) async {
    CastLogger.debug('AirPlayMediaController: playV1 url=$url');
    final body = BinaryPlistEncoder.encode({
      'Content-Location': url,
      'Start-Position': startPositionFraction,
      'X-Apple-Session-ID': session.sessionId,
    });
    return session.sendRequest(
      'POST',
      '/play',
      headers: {
        'Content-Type': 'application/x-apple-binary-plist',
        'User-Agent': 'MediaControl/1.0',
      },
      body: body,
    );
  }

  /// Sends a V1 text/parameters `/play` request.
  ///
  /// Uses the legacy plain-text body format. Does NOT set up an RTSP session.
  /// [startPositionFraction] carries the same 0.0–1.0 meaning as in [playV1].
  ///
  /// Kept for receivers that reject the binary plist body; it is never used
  /// automatically, because a receiver's feature bits already say which major
  /// version it speaks.
  Future<HapHttpResponse> playV1Text(
    String url,
    double startPositionFraction,
  ) async {
    CastLogger.debug('AirPlayMediaController: playV1Text url=$url');
    final bodyStr =
        'Content-Location: $url\nStart-Position: $startPositionFraction\n';
    return session.sendRequest(
      'POST',
      '/play',
      headers: {
        'Content-Type': 'text/parameters',
        'User-Agent': 'MediaControl/1.0',
        'X-Apple-Session-ID': session.sessionId,
      },
      body: utf8.encode(bodyStr),
    );
  }

  /// Sends a V2 binary plist `/play` request.
  ///
  /// Binds the [timingServer] and calls [HapSession.setupRtspSession] first
  /// (SETUP with the timing port + feedback + RECORD), then sends the extended
  /// AirPlay 2 plist body via HTTP/1.1.
  ///
  /// [startPositionSeconds] is an absolute offset in seconds.
  ///
  /// This does NOT send the post-`/play` command sequence — [play] does that.
  Future<HapHttpResponse> playV2(
    String url,
    double startPositionSeconds,
  ) async {
    CastLogger.debug('AirPlayMediaController: playV2 url=$url');

    final timingPort = await timingServer.bind();
    await session.setupRtspSession(timingPort: timingPort);

    final body = BinaryPlistEncoder.encode({
      'Content-Location': url,
      'Start-Position-Seconds': startPositionSeconds,
      'uuid': _generateUuid(),
      'streamType': 1,
      'mediaType': 'file',
      'mightSupportStorePastisKeyRequests': true,
      'playbackRestrictions': 0,
      'volume': 1.0,
      'rate': 1.0,
      'SenderMACAddress': 'AA:BB:CC:DD:EE:FF',
      'model': 'iPhone14,3',
      'clientBundleID': 'dev.dartcast',
      'clientProcName': 'dart_cast',
      'osBuildVersion': '20F66',
    });

    return session.sendRequest(
      'POST',
      '/play',
      headers: {
        'Content-Type': 'application/x-apple-binary-plist',
        'User-Agent': 'AirPlay/550.10',
        'X-Apple-ProtocolVersion': '1',
        'X-Apple-Session-ID': session.sessionId,
        'X-Apple-Stream-ID': '1',
      },
      body: body,
    );
  }

  /// Starts video playback, choosing the protocol version from [features].
  ///
  /// [startPositionSeconds] is an absolute offset. AirPlay 1 cannot express
  /// that — its `Start-Position` is a fraction of a duration the sender does
  /// not know yet — so a non-zero value is dropped with a warning on the V1
  /// path rather than being silently reinterpreted as "99% of the way in".
  ///
  /// Throws [UnsupportedFeatureException] if the device advertises no usable
  /// video bit, and [PlaybackException] if the receiver rejects `/play` or the
  /// mandatory `/rate` that follows it.
  Future<void> play(String url, {double startPositionSeconds = 0.0}) async {
    if (features.isV2Protocol) {
      if (!features.supportsVideoV2) {
        throw UnsupportedFeatureException(
          'AirPlay 2 receiver does not advertise video URL playback '
          '(bit 49 clear, features=$features). It is most likely a '
          'mirroring-only or audio-only receiver — try Chromecast or DLNA.',
        );
      }
      CastLogger.info('AirPlayMediaController: play via AirPlay 2 (bit 49)');
      final resp = await playV2(url, startPositionSeconds);
      CastLogger.debug(
        'AirPlayMediaController: playV2 response: ${resp.statusCode}',
      );
      if (resp.statusCode == 404) {
        // A receiver that advertises AirPlay 1 video as well gets one attempt
        // at it. This is NOT the old fallback ladder: that probed V1 first on
        // every device, including ones whose bits said they do not speak it,
        // and read the resulting 404 as "cannot cast video". This fires only
        // when bit 0 is actually set, so the request is one the device said it
        // accepts. Apple TVs and the macOS receiver advertise both versions.
        if (features.supportsVideoV1) {
          CastLogger.info(
            'AirPlayMediaController: AirPlay 2 /play returned 404 and this '
            'device also advertises AirPlay 1 video (bit 0) — retrying on V1',
          );
          return _playV1AfterV2Fallback(url, startPositionSeconds);
        }

        // Verified on a TCL Google TV running Apple's licensed AirPlay
        // receiver SDK 3.5.0.244: the handshake up to and including RECORD is
        // accepted, but the receiver exports only /command, /feedback, /info
        // and /server-info. There is no /play, /playback-info, /rate or
        // /scrub, and the string "Content-Location" does not appear in its
        // binary at all — the AirPlay 1-era REST endpoints simply are not
        // implemented. Such receivers drive playback over AirPlay 2 unified
        // media control (feature bit 38) instead, which this package does not
        // speak yet.
        throw UnsupportedFeatureException(
          'Receiver completed the AirPlay 2 handshake but has no /play '
          'endpoint (404), and advertises no AirPlay 1 video either. It uses '
          'AirPlay 2 unified media control, which dart_cast does not '
          'implement — use Chromecast or DLNA for this device. See '
          'doc/AIRPLAY.md.',
        );
      }
      if (resp.statusCode != 200) {
        throw PlaybackException(
          'Device rejected AirPlay 2 /play: ${resp.statusCode}',
          statusCode: resp.statusCode,
        );
      }
      await sendPostPlaySequence();
      return;
    }

    if (!features.supportsVideoV1) {
      throw UnsupportedFeatureException(
        'Device advertises no AirPlay video support '
        '(bits 0 and 49 clear, features=$features). '
        'Try Chromecast or DLNA for this device.',
      );
    }

    if (startPositionSeconds != 0.0) {
      CastLogger.warning(
        'AirPlayMediaController: AirPlay 1 Start-Position is a 0.0-1.0 '
        'fraction, not seconds — starting from the beginning instead of '
        '${startPositionSeconds}s',
      );
    }

    CastLogger.info('AirPlayMediaController: play via AirPlay 1 (bit 0)');
    final resp = await playV1(url, 0.0);
    CastLogger.debug(
      'AirPlayMediaController: playV1 response: ${resp.statusCode}',
    );
    if (resp.statusCode != 200) {
      throw PlaybackException(
        'Device rejected AirPlay 1 /play: ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }
  }

  /// Retries playback over AirPlay 1 after an AirPlay 2 `/play` returned 404.
  ///
  /// Only reachable for receivers advertising bit 0. The RTSP session stays up
  /// — it was accepted, and tearing it down gains nothing — but control
  /// commands switch to the HTTP forms, because a receiver answering the V1
  /// `/play` expects the V1 control endpoints too.
  Future<void> _playV1AfterV2Fallback(
    String url,
    double startPositionSeconds,
  ) async {
    if (startPositionSeconds != 0.0) {
      CastLogger.warning(
        'AirPlayMediaController: AirPlay 1 Start-Position is a 0.0-1.0 '
        'fraction, not seconds — starting from the beginning instead of '
        '${startPositionSeconds}s',
      );
    }

    final resp = await playV1(url, 0.0);
    CastLogger.debug(
      'AirPlayMediaController: V1 fallback response: ${resp.statusCode}',
    );
    if (resp.statusCode != 200) {
      throw PlaybackException(
        'Device rejected both the AirPlay 2 /play (404) and the AirPlay 1 '
        '/play (${resp.statusCode}), despite advertising both versions.',
        statusCode: resp.statusCode,
      );
    }

    _usingV1Fallback = true;
    CastLogger.info('AirPlayMediaController: AirPlay 1 fallback accepted');
  }

  /// Whether playback fell back to AirPlay 1 after a 404 from the V2 `/play`.
  bool _usingV1Fallback = false;

  /// Sends the commands an AirPlay 2 receiver expects after `/play`.
  ///
  /// Order and payloads follow pyatv's `AirPlayV2.play_url`
  /// (`pyatv/protocols/raop/protocols/airplayv2.py`):
  ///
  /// 1. `PUT /setProperty?isInterestedInDateRange`
  /// 2. `PUT /setProperty?actionAtItemEnd`
  /// 3. `POST /rate?value=1.000000`
  /// 4. `PUT /setProperty?forwardEndTime`
  /// 5. `PUT /setProperty?reverseEndTime`
  ///
  /// `/rate` is the one that matters: **an AirPlay 2 `/play` starts the item
  /// paused**, so a session without it shows a black screen no matter how
  /// correct the rest of the handshake is. Its failure is fatal; the
  /// `/setProperty` calls are best-effort.
  Future<void> sendPostPlaySequence() async {
    await _setProperty('isInterestedInDateRange', {'value': true});
    await _setProperty('actionAtItemEnd', {'value': 0});

    CastLogger.info('AirPlayMediaController: POST /rate?value=1.000000');
    final rateResp = await session.sendRtspRequest(
      'POST',
      '/rate?value=1.000000',
    );
    if (rateResp.statusCode != 200) {
      throw PlaybackException(
        'Device rejected /rate after /play: ${rateResp.statusCode}. '
        'AirPlay 2 playback starts paused without it.',
        statusCode: rateResp.statusCode,
      );
    }

    const zeroTime = {'flags': 0, 'value': 0, 'epoch': 0, 'timescale': 0};
    await _setProperty('forwardEndTime', {'value': zeroTime});
    await _setProperty('reverseEndTime', {'value': zeroTime});
  }

  Future<void> _setProperty(String property, Map<String, dynamic> body) async {
    try {
      final resp = await session.sendRtspRequest(
        'PUT',
        '/setProperty?$property',
        headers: {'Content-Type': 'application/x-apple-binary-plist'},
        body: BinaryPlistEncoder.encode(body),
      );
      if (resp.statusCode != 200) {
        CastLogger.debug(
          'AirPlayMediaController: /setProperty?$property returned '
          '${resp.statusCode} — continuing',
        );
      }
    } catch (e) {
      CastLogger.debug(
        'AirPlayMediaController: /setProperty?$property failed: $e — '
        'continuing',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Control commands
  // ---------------------------------------------------------------------------

  /// Pauses playback by sending `/rate?value=0`.
  Future<void> pause() async {
    CastLogger.info('AirPlayMediaController: pause');
    await _sendControl('POST', '/rate', queryParameters: {'value': '0'});
  }

  /// Resumes playback by sending `/rate?value=1`.
  Future<void> resume() async {
    CastLogger.info('AirPlayMediaController: resume');
    await _sendControl('POST', '/rate', queryParameters: {'value': '1'});
  }

  /// Seeks to [positionSeconds] by sending `/scrub?position=<pos>`.
  Future<void> seek(double positionSeconds) async {
    CastLogger.info('AirPlayMediaController: seek to $positionSeconds');
    await _sendControl(
      'POST',
      '/scrub',
      queryParameters: {'position': '$positionSeconds'},
    );
  }

  /// Stops playback by sending `/stop`.
  Future<void> stop() async {
    CastLogger.info('AirPlayMediaController: stop');
    await _sendControl('POST', '/stop');
  }

  // ---------------------------------------------------------------------------
  // Info
  // ---------------------------------------------------------------------------

  /// Fetches current playback state from the device via `GET /playback-info`.
  ///
  /// AirPlay 2 answers with a binary plist, AirPlay 1 with XML; both are
  /// handled by decoding the raw body against the response `Content-Type`.
  Future<PlaybackInfo> getPlaybackInfo() async {
    CastLogger.debug('AirPlayMediaController: getPlaybackInfo');
    final resp = await session.sendRequest('GET', '/playback-info');
    return PlistCodec.parsePlaybackInfoBytes(
      resp.body,
      contentType: resp.contentType,
    );
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Releases resources held by this controller.
  ///
  /// Closes the UDP timing server. Does NOT close the underlying [session] —
  /// that is owned by the caller and should be closed separately.
  Future<void> dispose() async {
    await timingServer.close();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Whether control commands should travel over RTSP rather than HTTP.
  ///
  /// pyatv issues `/rate` and friends as RTSP exchanges once an AirPlay 2
  /// session is up; AirPlay 1 receivers only understand the HTTP form.
  bool get _useRtspControl =>
      features.isV2Protocol && session.isRtspSessionSetUp && !_usingV1Fallback;

  Future<void> _sendControl(
    String method,
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    if (_useRtspControl) {
      final query = _buildQuery(queryParameters);
      await session.sendRtspRequest(method, '$path$query');
      return;
    }
    await session.sendRequest(method, path, queryParameters: queryParameters);
  }

  static String _buildQuery(Map<String, String>? queryParameters) {
    if (queryParameters == null || queryParameters.isEmpty) return '';
    final encoded = queryParameters.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
    return '?$encoded';
  }

  static final _random = Random.secure();

  static String _generateUuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}'
        '-${hex(bytes[4])}${hex(bytes[5])}'
        '-${hex(bytes[6])}${hex(bytes[7])}'
        '-${hex(bytes[8])}${hex(bytes[9])}'
        '-${hex(bytes[10])}${hex(bytes[11])}${hex(bytes[12])}${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
  }
}
