import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/cast_exceptions.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import '../../core/media_transformer.dart';
import '../../utils/logger.dart';
import 'airplay_client.dart';
import 'airplay_features.dart';
import 'airplay_media_controller.dart';
import 'auth/airplay_auth.dart';
import 'auth/airplay_transient_auth.dart';
import 'auth/hap_credentials.dart';
import 'auth/hap_session.dart';
import 'plist_codec.dart';

/// AirPlay 1 cast session with playback control and position polling.
///
/// Extends [CastSession] to implement AirPlay-specific behavior:
/// - Connects to a device via [AirPlayClient]
/// - Proxies media through [MediaProxy] so the AirPlay device can reach it
/// - Polls `/playback-info` periodically to update position/duration/state
/// - Supports HAP authentication for devices that require it (Apple TV tvOS 10.2+)
class AirPlaySession extends CastSession {
  AirPlayClient? _client;
  HapSession? _hapSession;
  AirPlayMediaController? _mediaController;
  final MediaProxy _proxy = MediaProxy();
  final MediaTransformer _mediaTransformer;
  Timer? _pollTimer;
  bool _isPolling = false;
  int _pollFailures = 0;
  bool _isLoadingMedia = false;
  CastMedia? _currentMedia;

  /// Stored HAP credentials for pair-verify. Set these before calling
  /// [connect] if the device requires authentication.
  HapCredentials? credentials;

  /// Creates an [AirPlaySession] for the given AirPlay [device].
  ///
  /// An optional [mediaTransformer] can customize media preparation.
  AirPlaySession(
    super.device, {
    this.credentials,
    MediaTransformer? mediaTransformer,
  }) : _mediaTransformer = mediaTransformer ?? const DefaultMediaTransformer();

  /// The underlying AirPlay HTTP client (available after [connect]).
  AirPlayClient? get client => _client;

  /// Connects to the AirPlay device.
  ///
  /// Probes the device with `GET /info`, falling back to `GET /server-info`.
  /// The transport is then chosen from the device's **advertised feature
  /// bits**, not from the HTTP status:
  ///
  /// - AirPlay 2 receiver (bit 38 or 48) → raw socket, pairing, encrypted HAP
  ///   session with an [AirPlayMediaController]. Transient pairing is used
  ///   when the device advertises bit 43 or 48, otherwise stored
  ///   [credentials] drive a pair-verify.
  /// - anything else that answered 403 → the same path, but pair-verify only.
  /// - otherwise → the plain HTTP AirPlay 1 client.
  ///
  /// Previously the encrypted path was reachable *only* through a 403 from
  /// `/server-info`. AirPlay 2 receivers using transient encryption do not
  /// return 403, so every one of them silently fell through to an
  /// unauthenticated AirPlay 1 client.
  ///
  /// Throws [NeedsPairingException] when pairing is required and no usable
  /// route to it exists.
  @override
  Future<void> connect() async {
    CastLogger.info(
      'AirPlay: connecting to ${device.name} at ${device.address.address}:${device.port}',
    );
    stateMachine.transitionTo(SessionState.connecting);

    _client = AirPlayClient(host: device.address.address, port: device.port);

    try {
      final probe = await _client!.probeDeviceInfo();
      final features = _parseFeatures();
      CastLogger.info(
        'AirPlay: ${device.name} features=$features '
        '(v2=${features.isV2Protocol}, videoV1=${features.supportsVideoV1}, '
        'videoV2=${features.supportsVideoV2}, '
        'transient=${features.supportsTransientPairing})',
      );
      if (probe.properties.isEmpty && !probe.authRequired) {
        CastLogger.warning(
          'AirPlay: ${device.name} answered neither /info nor /server-info '
          'with 200 — continuing with mDNS-advertised capabilities only',
        );
      }

      if (features.isV2Protocol || probe.authRequired) {
        await _establishEncryptedSession(features);
        return;
      }

      CastLogger.info(
        'AirPlay: connected to ${device.name} (AirPlay 1, plain)',
      );
      stateMachine.transitionTo(SessionState.connected);
    } on NeedsPairingException {
      rethrow;
    } catch (e) {
      CastLogger.error('AirPlay: connection failed to ${device.name}: $e');
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      rethrow;
    }
  }

  /// Opens the encrypted HAP channel used by AirPlay 2 and paired devices.
  ///
  /// Opens a SINGLE raw TCP socket and pairs over it. On success, that SAME
  /// socket is promoted to an encrypted HAP session. This is critical because
  /// AirPlay devices bind authentication state to the TCP connection — a new
  /// socket would be unauthenticated.
  Future<void> _establishEncryptedSession(AirPlayFeatures features) async {
    final useTransient =
        credentials == null && features.supportsTransientPairing;

    if (!useTransient && credentials == null) {
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      throw NeedsPairingException(
        'AirPlay device "${device.name}" requires pairing. '
        'Call pairSetup(pin) first.',
      );
    }

    Socket? rawSocket;
    StreamController<Uint8List>? socketBroadcast;
    try {
      CastLogger.info('AirPlay: opening raw socket for pairing + HAP session');
      rawSocket = await Socket.connect(device.address.address, device.port);

      // Wrap the socket's single-subscription stream in a broadcast controller.
      // This lets both the pairing step and HapSession subscribe independently.
      socketBroadcast = StreamController<Uint8List>.broadcast();
      rawSocket.listen(
        (data) => socketBroadcast!.add(Uint8List.fromList(data)),
        onError: (e) => socketBroadcast!.addError(e),
        onDone: () => socketBroadcast!.close(),
      );

      final Uint8List sharedSecret;
      if (useTransient) {
        CastLogger.info(
          'AirPlay: using transient pairing (no PIN, no stored credentials)',
        );
        final transient = AirPlayTransientPairing.withSocket(
          rawSocket,
          host: device.address.address,
          port: device.port,
          dataStream: socketBroadcast.stream,
        );
        sharedSecret = await transient.execute();
        // Stop the pairing reader before the encrypted reader takes over,
        // otherwise it keeps a copy of every encrypted byte for the life of
        // the session.
        await transient.releaseSocket();
      } else {
        final pairVerify = AirPlayPairVerify.withSocket(
          rawSocket,
          host: device.address.address,
          port: device.port,
          dataStream: socketBroadcast.stream,
        );
        CastLogger.info(
          'AirPlay: attempting pair-verify with stored credentials',
        );
        sharedSecret = await pairVerify.execute(credentials!);
        await pairVerify.releaseSocket();
      }

      CastLogger.info('AirPlay: pairing successful, creating HAP session');

      // Derive encryption keys and create HAP session on the SAME socket
      // using the SAME broadcast stream for reading
      final keys = await deriveHapSessionKeys(sharedSecret);
      _hapSession = HapSession(
        socket: rawSocket,
        outputKey: keys.outputKey,
        inputKey: keys.inputKey,
        host: device.address.address,
        port: device.port,
        sessionId: _client!.sessionId,
        sharedSecret: sharedSecret,
        dataStream: socketBroadcast.stream,
      );

      _mediaController = AirPlayMediaController(
        session: _hapSession!,
        features: features,
      );

      CastLogger.info('AirPlay: HAP encrypted session established');
      stateMachine.transitionTo(SessionState.connected);
    } on AirPlayAuthException catch (e) {
      // Auth failure — credentials may be stale, need re-pairing
      CastLogger.error('AirPlay: pairing failed: $e');
      rawSocket?.destroy();
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      throw NeedsPairingException(
        'AirPlay pairing failed for "${device.name}": ${e.message}',
      );
    } catch (e) {
      // Network error — don't discard credentials
      CastLogger.error('AirPlay: pairing network error: $e');
      rawSocket?.destroy();
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      rethrow;
    }
  }

  /// Performs HAP pair-setup with the device using the given [pin].
  ///
  /// This triggers the device to display a 4-digit PIN, which the user
  /// must enter. On success, stores [credentials] for future sessions.
  ///
  /// [clientId] is an optional identifier for this client. If not provided,
  /// a random UUID is generated.
  Future<HapCredentials> pairSetup(
    String pin, {
    String? clientId,
    bool triggerPinDisplay = true,
  }) async {
    final id = clientId ?? _generateUuid();

    final pairSetup = AirPlayPairSetup(
      host: device.address.address,
      port: device.port,
    );

    try {
      // Trigger PIN display on TV (skip if already triggered externally)
      if (triggerPinDisplay) {
        CastLogger.info('AirPlay: triggering PIN display on TV');
        pairSetup.startPinDisplay(); // Fire-and-forget — TV may not respond
      }

      // Run pair-setup SRP flow with the user-entered PIN
      CastLogger.info('AirPlay: starting SRP pair-setup with PIN');
      credentials = await pairSetup.pairSetup(pin: pin, clientId: id);

      CastLogger.info('AirPlay: pair-setup complete, credentials stored');
      return credentials!;
    } finally {
      pairSetup.close();
    }
  }

  /// Loads media onto the AirPlay device.
  ///
  /// Starts the media proxy, registers the media URL, and sends a `POST /play`
  /// to the device. Begins position polling after playback starts.
  @override
  Future<void> loadMedia(CastMedia media) async {
    if (_isLoadingMedia) {
      CastLogger.warning(
        'AirPlay: loadMedia called while already loading — ignoring',
      );
      return;
    }
    _isLoadingMedia = true;
    try {
      await _loadMediaInternal(media);
    } finally {
      _isLoadingMedia = false;
    }
  }

  Future<void> _loadMediaInternal(CastMedia media) async {
    _ensureClient();
    stateMachine.transitionTo(SessionState.loading);

    try {
      // Start proxy server
      await _proxy.start(targetDeviceIp: device.address.address);

      _currentMedia = media;

      // Transform and register media with the proxy
      final transformed = await _mediaTransformer.transform(media, _proxy);
      final proxyUrl = transformed.proxyUrl;

      // Determine the final URL to send to the device
      String playUrl;

      if (media.subtitles.isNotEmpty && media.type == CastMediaType.hls) {
        // Inject subtitles into HLS playlist via wrapper m3u8
        playUrl = _buildSubtitleWrapper(
          proxyUrl,
          media.subtitles,
          media.httpHeaders,
        );
      } else {
        playUrl = proxyUrl;
      }

      // `Start-Position-Seconds` (AirPlay 2) is absolute; `Start-Position`
      // (AirPlay 1) is a 0.0-1.0 fraction. The controller converts, or warns
      // and starts from the beginning when the version cannot express it.
      final startSeconds =
          (media.startPosition ?? Duration.zero).inMilliseconds / 1000.0;

      // Start playback on the device via encrypted channel if available
      CastLogger.info(
        'AirPlay: sending /play with URL: ${playUrl.substring(0, playUrl.length.clamp(0, 80))}... '
        '(start=${startSeconds}s)',
      );
      if (_mediaController != null) {
        CastLogger.info('AirPlay: using AirPlayMediaController for /play');
        await _mediaController!.play(
          playUrl,
          startPositionSeconds: startSeconds,
        );
      } else {
        CastLogger.info('AirPlay: using plain HTTP for /play');
        // AirPlay 1 has no absolute-seek parameter on /play; seek after load.
        await _client!.play(playUrl, startPosition: 0.0);
        if (startSeconds > 0) {
          await _client!.scrub(startSeconds);
        }
      }

      // Start polling for playback state
      _startPolling();
    } catch (e) {
      CastLogger.error('AirPlay: loadMedia failed: $e');
      if (stateMachine.canTransitionTo(SessionState.idle)) {
        stateMachine.transitionTo(SessionState.idle);
      }
      rethrow;
    }
  }

  /// Builds a wrapper m3u8 that adds subtitle tracks to the original HLS stream.
  String _buildSubtitleWrapper(
    String originalProxyUrl,
    List<CastSubtitle> subtitles,
    Map<String, String> headers,
  ) {
    final subtitleEntries = <({String name, String language, String url})>[];

    for (final sub in subtitles) {
      // Register each subtitle as an HLS subtitle playlist
      final subPlaylistUrl = _proxy.registerSubtitlePlaylist(
        sub.url,
        headers: headers,
      );
      subtitleEntries.add((
        name: sub.label,
        language: sub.language,
        url: subPlaylistUrl,
      ));
    }

    return _proxy.registerSubtitleWrapper(
      originalM3u8ProxyUrl: originalProxyUrl,
      subtitleEntries: subtitleEntries,
    );
  }

  /// Resumes playback (sends rate=1 to device).
  @override
  Future<void> play() async {
    _ensureClient();
    CastLogger.info('AirPlay: Play (resume)');
    if (_mediaController != null) {
      await _mediaController!.resume();
    } else {
      await _client!.rate(1);
    }
    if (stateMachine.canTransitionTo(SessionState.playing)) {
      stateMachine.transitionTo(SessionState.playing);
    }
  }

  /// Pauses playback (sends rate=0 to device).
  @override
  Future<void> pause() async {
    _ensureClient();
    CastLogger.info('AirPlay: Pause');
    if (_mediaController != null) {
      await _mediaController!.pause();
    } else {
      await _client!.rate(0);
    }
    if (stateMachine.canTransitionTo(SessionState.paused)) {
      stateMachine.transitionTo(SessionState.paused);
    }
  }

  /// Stops playback, cancels polling, and transitions to idle.
  @override
  Future<void> stop() async {
    _ensureClient();
    CastLogger.info('AirPlay: Stop');
    _stopPolling();
    if (_mediaController != null) {
      await _mediaController!.stop();
    } else {
      await _client!.stop();
    }
    _proxy.cleanupPreviousMedia();
    if (stateMachine.canTransitionTo(SessionState.idle)) {
      stateMachine.transitionTo(SessionState.idle);
    }
  }

  /// Seeks to the given [position] (sends scrub with seconds).
  @override
  Future<void> seek(Duration position) async {
    _ensureClient();
    final seconds = position.inMilliseconds / 1000.0;
    CastLogger.info('AirPlay: Seek to ${seconds.toStringAsFixed(1)}s');
    if (_mediaController != null) {
      await _mediaController!.seek(seconds);
    } else {
      await _client!.scrub(seconds);
    }
  }

  /// Sets volume. AirPlay 1 has no volume endpoint, so this stores locally.
  @override
  Future<void> setVolume(double volume) async {
    updateVolume(volume);
  }

  /// Sets the active subtitle track.
  ///
  /// For AirPlay 1, subtitles are delivered by rewriting the HLS playlist.
  /// This re-loads the media with a modified playlist containing the selected
  /// subtitle track, or without subtitles if [subtitle] is null.
  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    if (_currentMedia == null || _client == null) return;

    final media = _currentMedia!;

    // Build new media with only the selected subtitle (or none)
    final newMedia = CastMedia(
      url: media.url,
      type: media.type,
      httpHeaders: media.httpHeaders,
      title: media.title,
      imageUrl: media.imageUrl,
      startPosition: media.startPosition,
      subtitles: subtitle != null ? [subtitle] : const [],
    );

    // Clean up old proxy routes and re-register
    _proxy.cleanupPreviousMedia();

    final newTransformed = await _mediaTransformer.transform(newMedia, _proxy);
    final proxyUrl = newTransformed.proxyUrl;

    String playUrl;
    if (newMedia.subtitles.isNotEmpty && newMedia.type == CastMediaType.hls) {
      playUrl = _buildSubtitleWrapper(
        proxyUrl,
        newMedia.subtitles,
        newMedia.httpHeaders,
      );
    } else {
      playUrl = proxyUrl;
    }

    if (_mediaController != null) {
      await _mediaController!.play(playUrl);
    } else {
      await _client!.play(playUrl, startPosition: 0.0);
    }
  }

  /// Disconnects from the device, stopping playback and cleaning up.
  @override
  Future<void> disconnect() async {
    CastLogger.info('AirPlay: disconnecting from ${device.name}');
    _stopPolling();

    try {
      if (_mediaController != null) {
        await _mediaController!.stop();
      } else if (_client != null) {
        await _client!.stop();
      }
    } catch (e) {
      CastLogger.warning('AirPlay: error sending Stop during disconnect: $e');
    }

    await _mediaController?.dispose();
    _mediaController = null;
    await _hapSession?.close();
    _hapSession = null;
    _client?.close();
    _client = null;
    await _proxy.stop();
    stateMachine.transitionTo(SessionState.disconnected);
    CastLogger.info('AirPlay: disconnected from ${device.name}');
  }

  /// Disposes all resources.
  @override
  void dispose() {
    _stopPolling();
    _mediaController?.dispose();
    _mediaController = null;
    _hapSession?.close();
    _hapSession = null;
    _client?.close();
    _client = null;
    // Don't await — fire and forget during dispose
    _proxy.stop();
    super.dispose();
  }

  /// Starts periodic polling of playback info.
  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollPlaybackInfo(),
    );
  }

  /// Stops the polling timer.
  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Polls the device for playback info and updates session state.
  ///
  /// Consecutive failures are reported at warning level: swallowing them at
  /// debug level is how a session that never left `loading` could look
  /// healthy while every poll was in fact failing to parse.
  Future<void> _pollPlaybackInfo() async {
    if (_client == null || _isPolling) return;
    _isPolling = true;

    try {
      final PlaybackInfo info;
      if (_mediaController != null) {
        info = await _mediaController!.getPlaybackInfo();
      } else {
        info = await _client!.getPlaybackInfo();
      }
      _pollFailures = 0;
      _updateFromPlaybackInfo(info);
    } catch (e) {
      _pollFailures++;
      if (_pollFailures == 1 || _pollFailures % 10 == 0) {
        CastLogger.warning(
          'AirPlay: playback-info polling failed '
          '($_pollFailures consecutive): $e',
        );
      } else {
        CastLogger.debug('AirPlay: playback-info polling failed: $e');
      }
    } finally {
      _isPolling = false;
    }
  }

  /// Updates session state based on parsed playback info.
  void _updateFromPlaybackInfo(PlaybackInfo info) {
    // The receiver telling us it failed is authoritative — stop polling and
    // surface it rather than sitting in `loading` forever.
    final error = info.error;
    if (error != null) {
      CastLogger.error(
        'AirPlay: receiver reported playback error ${error.code ?? 'unknown'} '
        '(${error.domain ?? 'unknown domain'}) — stopping playback',
      );
      _stopPolling();
      if (stateMachine.canTransitionTo(SessionState.idle)) {
        stateMachine.transitionTo(SessionState.idle);
      }
      return;
    }

    // Update position and duration
    updatePosition(Duration(milliseconds: (info.position * 1000).round()));
    updateDuration(Duration(milliseconds: (info.duration * 1000).round()));

    // Update playback state based on rate and readiness
    if (!info.readyToPlay) {
      if (stateMachine.canTransitionTo(SessionState.buffering)) {
        stateMachine.transitionTo(SessionState.buffering);
      }
    } else if (info.rate == 0.0) {
      if (stateMachine.canTransitionTo(SessionState.paused)) {
        stateMachine.transitionTo(SessionState.paused);
      }
    } else if (info.rate > 0.0) {
      if (stateMachine.canTransitionTo(SessionState.playing)) {
        stateMachine.transitionTo(SessionState.playing);
      }
    }
  }

  void _ensureClient() {
    if (_client == null) {
      throw StateError(
        'AirPlaySession is not connected. Call connect() first.',
      );
    }
  }

  /// Parses AirPlay feature flags from device metadata.
  AirPlayFeatures _parseFeatures() {
    final featuresStr =
        device.metadata['features'] ?? device.metadata['ft'] ?? '';
    return AirPlayFeatures.parse(featuresStr);
  }

  /// Generates a UUID v4-like string.
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
