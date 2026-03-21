/// ChromecastSession — full lifecycle management for Chromecast casting.
///
/// Extends [CastSession] to manage TLS connection, receiver/media channels,
/// heartbeat keep-alive, media proxy, and playback state synchronisation.
library;

import 'dart:async';
import 'dart:convert';

import '../../core/cast_device.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import '../../core/media_transformer.dart';
import '../../core/ts_hls_media_transformer.dart';
import '../../utils/logger.dart';
import 'cast_media_channel.dart';
import 'cast_receiver_channel.dart';
import 'castv2_channel.dart';
import 'proto/cast_channel.dart';

/// A casting session with a Chromecast device.
///
/// Manages the full lifecycle: TLS connect, receiver LAUNCH, heartbeat,
/// media LOAD/PLAY/PAUSE/STOP/SEEK, and graceful disconnect.
class ChromecastSession extends CastSession {
  /// The sender ID used in all messages.
  static const _senderId = 'sender-0';

  /// The platform receiver destination ID.
  static const _receiverId = 'receiver-0';

  // ---------------------------------------------------------------------------
  // Dependencies (injectable for testing)
  // ---------------------------------------------------------------------------

  final _ChannelAdapter _channel;
  final MediaProxy _proxy;
  final MediaTransformer _mediaTransformer;

  // ---------------------------------------------------------------------------
  // Session state
  // ---------------------------------------------------------------------------

  final CastReceiverChannel _receiverChannel = CastReceiverChannel();
  final CastMediaChannel _mediaChannel = CastMediaChannel();

  String? _transportId;
  String? _sessionId; // Used for STOP app via receiver namespace.
  int? _mediaSessionId;
  StreamSubscription<dynamic>? _mediaStatusSubscription;

  /// Periodic timer that polls GET_STATUS on the media channel to keep
  /// the playback position up-to-date. Chromecast only pushes MEDIA_STATUS
  /// on state changes (play, pause, load) — it does NOT send periodic
  /// position updates on its own.
  Timer? _positionPollTimer;

  /// Guard to prevent overlapping GET_STATUS requests.
  bool _isPolling = false;

  /// The current receiver session ID, if connected.
  String? get sessionId => _sessionId;
  Timer? _heartbeatTimer;
  StreamSubscription<dynamic>? _messageSubscription;

  /// Whether the heartbeat timer is currently active.
  bool get isHeartbeatActive => _heartbeatTimer?.isActive ?? false;

  /// Whether the position polling timer is currently active.
  bool get isPositionPollingActive => _positionPollTimer?.isActive ?? false;

  // ---------------------------------------------------------------------------
  // Constructors
  // ---------------------------------------------------------------------------

  /// Creates a [ChromecastSession] for the given [device].
  ///
  /// An optional [mediaTransformer] can be provided to customize how media
  /// is prepared before casting (e.g., custom segmentation, transcoding).
  /// Defaults to [TsHlsMediaTransformer] which wraps TS in HLS.
  ChromecastSession({
    required CastDevice device,
    MediaTransformer? mediaTransformer,
  })  : _channel = _RealChannelAdapter(),
        _proxy = MediaProxy(),
        _mediaTransformer = mediaTransformer ??
            const TsHlsMediaTransformer(wrapRemoteTs: true),
        super(device);

  /// Creates a [ChromecastSession] with mock dependencies for testing.
  ///
  /// [channel] is a mock for the TLS channel (required for unit/integration
  /// tests that avoid real TLS connections).
  /// [proxy] is an optional [MediaProxy] instance; a real [MediaProxy] is
  /// created if not provided.
  /// [mediaTransformer] is an optional transformer; defaults to
  /// [TsHlsMediaTransformer].
  ChromecastSession.withMocks({
    required CastDevice device,
    required dynamic channel,
    MediaProxy? proxy,
    MediaTransformer? mediaTransformer,
  })  : _channel = _MockChannelAdapter(channel),
        _proxy = proxy ?? MediaProxy(),
        _mediaTransformer = mediaTransformer ??
            const TsHlsMediaTransformer(wrapRemoteTs: true),
        super(device);

  // ---------------------------------------------------------------------------
  // Connect lifecycle
  // ---------------------------------------------------------------------------

  /// Connects to the Chromecast device and launches the Default Media Receiver.
  ///
  /// Sequence: TLS connect -> CONNECT to receiver-0 -> start heartbeat ->
  /// LAUNCH CC1AD845 -> wait for RECEIVER_STATUS -> extract transportId ->
  /// CONNECT to transportId.
  @override
  Future<void> connect() async {
    CastLogger.info(
        'Chromecast: connecting to ${device.name} at ${device.address.address}:${device.port}');
    stateMachine.transitionTo(SessionState.connecting);

    // 1. TLS connect
    await _channel.connect(device.address.address, port: device.port);

    // 2. Start listening for messages
    final completer = Completer<void>();
    _messageSubscription = _channel.messageStream.listen((msg) {
      _handleMessage(msg, completer);
    });

    // 3. CONNECT to receiver-0
    _channel.sendMessage(
      namespace: CastReceiverChannel.connectionNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: CastReceiverChannel.buildConnect(),
    );

    // 4. Start heartbeat
    _startHeartbeat();

    // 5. LAUNCH Default Media Receiver
    _channel.sendMessage(
      namespace: CastReceiverChannel.receiverNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: _receiverChannel.buildLaunchWithId(),
    );

    // 6. Wait for RECEIVER_STATUS with transportId
    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        CastLogger.error('Chromecast: connect timed out after 15s');
        stateMachine.transitionTo(SessionState.disconnected);
        throw TimeoutException('Chromecast connect timed out after 15 seconds');
      },
    );

    // 7. CONNECT to app transportId
    _channel.sendMessage(
      namespace: CastReceiverChannel.connectionNamespace,
      sourceId: _senderId,
      destinationId: _transportId!,
      payload: CastReceiverChannel.buildConnect(),
    );

    CastLogger.info(
        'Chromecast: connected to ${device.name}, transportId=$_transportId');
    stateMachine.transitionTo(SessionState.connected);
  }

  // ---------------------------------------------------------------------------
  // Media loading
  // ---------------------------------------------------------------------------

  @override
  Future<void> loadMedia(CastMedia media) async {
    if (_transportId == null) {
      throw StateError('Not connected. Call connect() first.');
    }

    stateMachine.transitionTo(SessionState.loading);

    // Start proxy and transform media for Chromecast
    await _proxy.start();
    final transformed = await _mediaTransformer.transform(media, _proxy);
    var proxyUrl = transformed.proxyUrl;

    // Extract token from the proxy URL to exclude it from cleanup
    final newToken = Uri.parse(proxyUrl).pathSegments.last;
    _proxy.cleanupPreviousMedia(excludeToken: newToken);

    // Determine content type from the (possibly transformed) media type
    final contentType = _contentTypeForMedia(transformed.effectiveType);

    // Build subtitle tracks — proxy each subtitle URL so the Chromecast can
    // fetch them with CORS headers (Access-Control-Allow-Origin) and any
    // custom headers the caller attached to the media.
    CastLogger.info(
        'Chromecast: loading ${media.subtitles.length} subtitle track(s)');
    final subtitles = <CastMediaTrack>[];
    for (var i = 0; i < media.subtitles.length; i++) {
      final sub = media.subtitles[i];
      // Proxy subtitle URL so Chromecast can fetch it with CORS headers.
      // Uses registerSubtitle to handle both file:// and http:// URLs,
      // with automatic SRT-to-VTT conversion.
      final proxySubUrl =
          _proxy.registerSubtitle(sub.url, headers: media.httpHeaders);
      subtitles.add(CastMediaTrack(
        trackId: i + 1,
        url: proxySubUrl,
        name: sub.label,
        language: sub.language,
      ));
    }

    // Send LOAD
    final loadPayload = _mediaChannel.buildLoad(
      contentId: proxyUrl,
      contentType: contentType,
      title: media.title,
      imageUrl: media.imageUrl,
      startPosition: media.startPosition != null
          ? media.startPosition!.inMilliseconds / 1000.0
          : null,
      subtitles: subtitles.isNotEmpty ? subtitles : null,
    );

    CastLogger.info(
        'Chromecast: LOAD contentId=$proxyUrl contentType=$contentType');

    final completer = Completer<void>();
    _waitForMediaStatus(completer);

    _channel.sendMessage(
      namespace: CastMediaChannel.mediaNamespace,
      sourceId: _senderId,
      destinationId: _transportId!,
      payload: loadPayload,
    );

    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        CastLogger.error('Chromecast: loadMedia timed out after 15s');
        _mediaStatusSubscription?.cancel();
        _mediaStatusSubscription = null;
        stateMachine.transitionTo(SessionState.idle);
        throw TimeoutException(
            'Chromecast loadMedia timed out after 15 seconds');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Playback controls
  // ---------------------------------------------------------------------------

  @override
  Future<void> play() async {
    _requireMediaSession();
    CastLogger.info('Chromecast: PLAY');
    _sendMediaCommand(_mediaChannel.buildPlay(_mediaSessionId!));
  }

  @override
  Future<void> pause() async {
    _requireMediaSession();
    CastLogger.info('Chromecast: PAUSE');
    _sendMediaCommand(_mediaChannel.buildPause(_mediaSessionId!));
  }

  @override
  Future<void> stop() async {
    _requireMediaSession();
    CastLogger.info('Chromecast: STOP');
    _stopPositionPolling();
    _sendMediaCommand(_mediaChannel.buildStop(_mediaSessionId!));
  }

  @override
  Future<void> seek(Duration position) async {
    _requireMediaSession();
    final seconds = position.inMilliseconds / 1000.0;
    CastLogger.info('Chromecast: SEEK to ${seconds.toStringAsFixed(1)}s '
        '(${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')})');
    _sendMediaCommand(_mediaChannel.buildSeek(_mediaSessionId!, seconds));
  }

  @override
  Future<void> setVolume(double volume) async {
    _requireMediaSession();
    CastLogger.info('Chromecast: SET_VOLUME ${volume.toStringAsFixed(2)}');
    // Device-level volume uses receiver namespace to receiver-0.
    // The device responds with RECEIVER_STATUS containing the actual volume,
    // which is handled in _handleMessage() to update the volume stream.
    _channel.sendMessage(
      namespace: CastReceiverChannel.receiverNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: _receiverChannel.buildSetVolumeWithId(level: volume),
    );
  }

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    _requireMediaSession();
    if (subtitle == null) {
      _sendMediaCommand(
          _mediaChannel.buildEditTracksInfo(_mediaSessionId!, []));
    } else {
      // Activate track ID 1 (conventionally the first subtitle track)
      _sendMediaCommand(
          _mediaChannel.buildEditTracksInfo(_mediaSessionId!, [1]));
    }
  }

  // ---------------------------------------------------------------------------
  // Disconnect
  // ---------------------------------------------------------------------------

  @override
  Future<void> disconnect() async {
    CastLogger.info('Chromecast: disconnecting from ${device.name}');
    _stopHeartbeat();
    _stopPositionPolling();
    _mediaStatusSubscription?.cancel();
    _mediaStatusSubscription = null;

    // Send CLOSE messages (fire-and-forget — don't wait for response)
    try {
      if (_transportId != null) {
        _channel.sendMessage(
          namespace: CastReceiverChannel.connectionNamespace,
          sourceId: _senderId,
          destinationId: _transportId!,
          payload: CastReceiverChannel.buildClose(),
        );
      }
      _channel.sendMessage(
        namespace: CastReceiverChannel.connectionNamespace,
        sourceId: _senderId,
        destinationId: _receiverId,
        payload: CastReceiverChannel.buildClose(),
      );
    } catch (e) {
      CastLogger.warning('Chromecast: error sending CLOSE messages: $e');
    }

    // Transition state immediately so the UI responds
    _transportId = null;
    _sessionId = null;
    _mediaSessionId = null;
    stateMachine.transitionTo(SessionState.disconnected);

    // Clean up socket and proxy with a timeout so we don't hang
    try {
      await Future.wait([
        _messageSubscription?.cancel() ?? Future.value(),
        _channel.close(),
        _proxy.stop(),
      ]).timeout(const Duration(seconds: 3), onTimeout: () => []);
    } catch (e) {
      CastLogger.warning('Chromecast: cleanup error during disconnect: $e');
    }
    _messageSubscription = null;
    CastLogger.info('Chromecast: disconnected from ${device.name}');
  }

  @override
  void dispose() {
    _stopHeartbeat();
    _stopPositionPolling();
    _mediaStatusSubscription?.cancel();
    unawaited(_proxy.stop());
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _requireMediaSession() {
    if (_mediaSessionId == null) {
      throw StateError('No active media session. Call loadMedia() first.');
    }
  }

  void _sendMediaCommand(String payload) {
    _channel.sendMessage(
      namespace: CastMediaChannel.mediaNamespace,
      sourceId: _senderId,
      destinationId: _transportId!,
      payload: payload,
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        _channel.sendMessage(
          namespace: CastReceiverChannel.heartbeatNamespace,
          sourceId: _senderId,
          destinationId: _receiverId,
          payload: CastReceiverChannel.buildPing(),
        );
      },
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Starts a 1-second periodic timer that sends GET_STATUS on the media
  /// channel. The response triggers [_handleMediaStatus] which updates
  /// position, duration, and state.
  void _startPositionPolling() {
    _stopPositionPolling();
    _positionPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (_isPolling || _mediaSessionId == null || _transportId == null) {
          return;
        }
        _isPolling = true;
        _sendMediaCommand(_mediaChannel.buildGetStatus());
        _isPolling = false;
      },
    );
  }

  /// Stops the position polling timer.
  void _stopPositionPolling() {
    _positionPollTimer?.cancel();
    _positionPollTimer = null;
    _isPolling = false;
  }

  void _handleMessage(dynamic msg, Completer<void> connectCompleter) {
    final namespace = _getNamespace(msg);
    final payload = _getPayload(msg);
    if (payload == null) return;

    // Handle RECEIVER_STATUS — extract volume and session info
    if (namespace == CastReceiverChannel.receiverNamespace &&
        payload['type'] == 'RECEIVER_STATUS') {
      final status = CastReceiverChannel.parseReceiverStatus(payload);
      if (status != null) {
        // Always update volume from device state
        updateVolume(status.volumeLevel);

        // Complete connection if still connecting
        if (!connectCompleter.isCompleted) {
          _transportId = status.transportId;
          _sessionId = status.sessionId;
          connectCompleter.complete();
        }
      }
    }

    // Handle MEDIA_STATUS
    if (namespace == CastMediaChannel.mediaNamespace &&
        payload['type'] == 'MEDIA_STATUS') {
      _handleMediaStatus(payload);
    }
  }

  void _handleMediaStatus(Map<String, dynamic> payload) {
    final status = CastMediaChannel.parseMediaStatus(payload);
    if (status == null) return;

    _mediaSessionId = status.mediaSessionId;

    // Update position
    updatePosition(Duration(
      milliseconds: (status.currentTime * 1000).round(),
    ));

    // Update duration
    if (status.duration != null) {
      updateDuration(Duration(
        milliseconds: (status.duration! * 1000).round(),
      ));
    }

    // Note: MEDIA_STATUS volume is the stream-level volume (usually 1.0),
    // NOT the device volume. Device volume comes from RECEIVER_STATUS
    // and is handled in _handleMessage(). Don't overwrite it here.

    // Update state machine based on playerState
    _updateState(status.playerState, status.idleReason);
  }

  void _updateState(String playerState, String? idleReason) {
    final targetState = switch (playerState) {
      'PLAYING' => SessionState.playing,
      'PAUSED' => SessionState.paused,
      'BUFFERING' => SessionState.buffering,
      'IDLE' => SessionState.idle,
      'LOADING' => SessionState.loading,
      _ => null,
    };

    if (targetState != null && stateMachine.canTransitionTo(targetState)) {
      stateMachine.transitionTo(targetState);
    }

    // Start/stop position polling based on playback state.
    // Poll during PLAYING and BUFFERING to keep the seek slider current.
    // Stop polling on IDLE to avoid sending commands after media ends.
    if (playerState == 'PLAYING' || playerState == 'BUFFERING') {
      if (_positionPollTimer == null || !_positionPollTimer!.isActive) {
        _startPositionPolling();
      }
    } else if (playerState == 'IDLE') {
      _stopPositionPolling();
    }
    // PAUSED: keep polling so seek-while-paused still updates position.
  }

  void _waitForMediaStatus(Completer<void> completer) {
    // Cancel any previous media status subscription to prevent leaks
    _mediaStatusSubscription?.cancel();

    // Listen for the next MEDIA_STATUS that sets _mediaSessionId
    _mediaStatusSubscription = _channel.messageStream.listen((msg) {
      final namespace = _getNamespace(msg);
      final payload = _getPayload(msg);
      if (namespace == CastMediaChannel.mediaNamespace &&
          payload != null &&
          payload['type'] == 'MEDIA_STATUS') {
        _handleMediaStatus(payload);
        if (!completer.isCompleted) {
          completer.complete();
        }
        _mediaStatusSubscription?.cancel();
        _mediaStatusSubscription = null;
      }
    });
  }

  String? _getNamespace(dynamic msg) {
    if (msg is CastMessage) return msg.namespace_;
    // Mock message
    if (msg is Map) return msg['namespace'] as String?;
    // Dynamic mock object
    try {
      return (msg as dynamic).namespace as String?;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _getPayload(dynamic msg) {
    if (msg is CastMessage) {
      try {
        return jsonDecode(msg.payloadUtf8) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    // Mock message
    if (msg is Map) return msg['payload'] as Map<String, dynamic>?;
    // Dynamic mock object
    try {
      return (msg as dynamic).payload as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static String _contentTypeForMedia(CastMediaType type) {
    return switch (type) {
      CastMediaType.hls => 'application/x-mpegURL',
      CastMediaType.mp4 => 'video/mp4',
      CastMediaType.mkv => 'video/x-matroska',
      CastMediaType.mpegTs => 'video/mp2t',
    };
  }
}

// ---------------------------------------------------------------------------
// Adapter interfaces for testability
// ---------------------------------------------------------------------------

/// Adapter over CastV2Channel or a mock.
abstract class _ChannelAdapter {
  Future<void> connect(String host, {int port});
  Stream<dynamic> get messageStream;
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  });
  Future<void> close();
}

// ---------------------------------------------------------------------------
// Real adapters (wrap actual implementations)
// ---------------------------------------------------------------------------

class _RealChannelAdapter implements _ChannelAdapter {
  final CastV2Channel _channel = CastV2Channel();

  @override
  Future<void> connect(String host, {int port = 8009}) =>
      _channel.connect(host, port: port);

  @override
  Stream<CastMessage> get messageStream => _channel.messageStream;

  @override
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    _channel.sendMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: payload,
    );
  }

  @override
  Future<void> close() => _channel.close();
}

// ---------------------------------------------------------------------------
// Mock adapters (wrap test doubles)
// ---------------------------------------------------------------------------

class _MockChannelAdapter implements _ChannelAdapter {
  final dynamic _mock;

  _MockChannelAdapter(this._mock);

  @override
  Future<void> connect(String host, {int port = 8009}) =>
      (_mock as dynamic).connect(host, port: port) as Future<void>;

  @override
  Stream<dynamic> get messageStream =>
      (_mock as dynamic).messageStream as Stream<dynamic>;

  @override
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    (_mock as dynamic).sendMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: payload,
    );
  }

  @override
  Future<void> close() => (_mock as dynamic).close() as Future<void>;
}
