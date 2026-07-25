import 'dart:async' show Timer, unawaited;
import 'dart:io';

import '../../core/cast_device.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import '../../core/media_transformer.dart';
import '../../utils/logger.dart';
import '../../utils/network_utils.dart';
import 'dlna_controller.dart';
import 'dlna_device.dart';

/// A DLNA casting session that controls playback on a DLNA renderer.
///
/// Uses SOAP/UPnP to send AVTransport and RenderingControl actions.
class DlnaSession extends CastSession {
  /// The parsed device description with control URLs.
  final DlnaDeviceDescription description;

  final DlnaHttpClient _httpClient;
  final MediaProxy _proxy;
  final MediaTransformer _mediaTransformer;

  /// Duration we determined ourselves (explicit or probed from the source).
  /// Preferred over whatever the renderer reports for piped streams.
  Duration? _knownDuration;

  /// Whether the current route is a generated TS pipe rather than a real file.
  bool _isPipedStream = false;

  /// Title of the current item, reused when a piped stream is restarted.
  String? _currentTitle;

  /// Offset the current piped stream was restarted at.
  ///
  /// A restarted pipe begins at zero as far as the renderer is concerned, so
  /// this is added back to reported positions to keep the scrub bar absolute.
  Duration _pipedStartOffset = Duration.zero;

  Timer? _pollTimer;
  bool _isPolling = false;
  bool _isLoadingMedia = false;
  CastMedia? _currentMedia;
  CastSubtitle? _currentSubtitle;
  String? _currentProxyUrl;
  String? _currentProtocolInfo;
  Duration? _pendingSeekPosition;

  /// Creates a [DlnaSession] for the given [device] and [description].
  ///
  /// An optional [httpClient] can be provided for testing.
  ///
  /// Prefer using [DlnaSession.fromDevice] which automatically extracts
  /// the device description from the metadata set by [DlnaDiscoveryProvider].
  /// An optional [mediaTransformer] can customize how media is prepared
  /// before casting (e.g., custom segmentation, transcoding).
  DlnaSession({
    required CastDevice device,
    required this.description,
    DlnaHttpClient? httpClient,
    MediaProxy? proxy,
    MediaTransformer? mediaTransformer,
  }) : _httpClient = httpClient ?? DlnaHttpClient(),
       _proxy = proxy ?? MediaProxy(),
       _mediaTransformer = mediaTransformer ?? const DefaultMediaTransformer(),
       super(device);

  /// Creates a [DlnaSession] from a [CastDevice] discovered by
  /// [DlnaDiscoveryProvider].
  ///
  /// Automatically extracts the device description (control URLs, etc.)
  /// from the device's metadata. This is the recommended constructor
  /// when using devices from discovery.
  ///
  /// Throws [ArgumentError] if the device metadata is missing required
  /// DLNA control URLs (e.g., if the device was not discovered by
  /// [DlnaDiscoveryProvider]).
  factory DlnaSession.fromDevice(
    CastDevice device, {
    DlnaHttpClient? httpClient,
  }) {
    final avTransportUrl = device.metadata['avTransportControlUrl'];
    final renderingControlUrl = device.metadata['renderingControlUrl'];

    if (avTransportUrl == null || avTransportUrl.isEmpty) {
      throw ArgumentError(
        'CastDevice "${device.name}" is missing the DLNA AVTransport control URL '
        'in its metadata. This usually means the device was not discovered by '
        'DlnaDiscoveryProvider, or the device description XML did not contain '
        'an AVTransport service. '
        'Expected metadata key: "avTransportControlUrl". '
        'Available metadata keys: ${device.metadata.keys.toList()}',
      );
    }

    final connectionManagerControlUrl =
        device.metadata['connectionManagerControlUrl'];

    final description = DlnaDeviceDescription(
      friendlyName: device.name,
      udn: device.id,
      manufacturer: device.metadata['manufacturer'],
      modelName: device.metadata['modelName'],
      avTransportControlUrl: avTransportUrl,
      renderingControlUrl: renderingControlUrl,
      connectionManagerControlUrl: connectionManagerControlUrl,
      locationUrl: 'http://${device.address.address}:${device.port}',
    );

    return DlnaSession(
      device: device,
      description: description,
      httpClient: httpClient,
    );
  }

  /// Connects to the DLNA device by verifying it is reachable.
  @override
  Future<void> connect() async {
    CastLogger.info(
      'DLNA: connecting to ${device.name} at ${device.address.address}:${device.port}',
    );
    stateMachine.transitionTo(SessionState.connecting);
    // For DLNA, "connect" simply means we verified the device is reachable.
    // There is no persistent connection — each action is an HTTP POST.
    stateMachine.transitionTo(SessionState.connected);
    CastLogger.info('DLNA: connected to ${device.name}');
  }

  @override
  Future<void> loadMedia(CastMedia media) async {
    if (_isLoadingMedia) {
      CastLogger.warning(
        'DLNA: loadMedia called while already loading — ignoring',
      );
      return;
    }
    _isLoadingMedia = true;
    try {
      await _loadMediaInternal(media);
    } catch (_) {
      // Don't get stuck in `loading` if anything below throws.
      if (stateMachine.canTransitionTo(SessionState.idle)) {
        stateMachine.transitionTo(SessionState.idle);
      }
      rethrow;
    } finally {
      _isLoadingMedia = false;
    }
  }

  Future<void> _loadMediaInternal(CastMedia media) async {
    CastLogger.info('DLNA: loadMedia called, state=${stateMachine.state}');
    stateMachine.transitionTo(SessionState.loading);
    _currentMedia = media;

    // Start proxy and transform media
    await _proxy.start(targetDeviceIp: device.address.address);

    // Use transformer for media preparation (register, wrap TS in HLS, etc.)
    final transformed = await _mediaTransformer.transform(media, _proxy);
    String proxyUrl = transformed.proxyUrl;
    final String protocolInfo;

    // DLNA flags must match between DIDL-Lite protocolInfo and HTTP headers.
    // Use 01700000 (STREAMING + BACKGROUND + CONNECTION_STALL + V1.5) —
    // same as VLC and MiniDLNA. Include DLNA.ORG_PN profile name so the
    // renderer knows the codec without probing the stream.
    const dlnaFlags = '01700000000000000000000000000000';

    // Piped-TS routes are generated on the fly: there is no Content-Length and
    // byte ranges cannot be served. DLNA.ORG_OP is "<time-seek><byte-seek>",
    // so those routes must advertise 10 (time seek only) rather than 01.
    // Claiming byte-range seek on a stream that answers `Accept-Ranges: none`
    // is what made this TV stop playback the moment a seek was issued.
    const opByteSeek = 'DLNA.ORG_OP=01';
    const opTimeSeek = 'DLNA.ORG_OP=10';
    var isPipedStream = false;
    Duration? probedDuration;

    if (media.type == CastMediaType.hls) {
      // Remote HLS → pipe as continuous MPEG-TS stream for DLNA. The
      // handler internally detects alternate-audio HLS and muxes
      // video+audio per segment via [TsAltAudioRemuxer] so the TV
      // gets one continuous TS regardless of source layout.
      isPipedStream = true;
      // Probe the source playlist before piping it: a renderer given a
      // length-less TS otherwise reports a 1-second duration and draws no
      // scrub bar.
      probedDuration = await _proxy.probeHlsDuration(
        media.url,
        headers: media.httpHeaders,
      );
      proxyUrl = _proxy.registerHlsAsStream(
        media.url,
        headers: media.httpHeaders,
      );
      protocolInfo =
          'http-get:*:video/mp2t:DLNA.ORG_PN=MPEG_TS_HD_NA_ISO;$opTimeSeek;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags';
    } else if (transformed.effectiveType == CastMediaType.hls) {
      // Transformer wrapped media in HLS → pipe as TS stream for DLNA
      isPipedStream = true;
      probedDuration = await _proxy.probeHlsDuration(proxyUrl);
      proxyUrl = _proxy.registerHlsAsStream(proxyUrl);
      protocolInfo =
          'http-get:*:video/mp2t:DLNA.ORG_PN=MPEG_TS_HD_NA_ISO;$opTimeSeek;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags';
    } else if (transformed.effectiveType == CastMediaType.mpegTs) {
      protocolInfo =
          'http-get:*:video/mp2t:DLNA.ORG_PN=MPEG_TS_HD_NA_ISO;$opByteSeek;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags';
    } else if (transformed.effectiveType == CastMediaType.mkv) {
      protocolInfo =
          'http-get:*:video/x-matroska:$opByteSeek;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags';
    } else {
      protocolInfo =
          'http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;$opByteSeek;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=$dlnaFlags';
    }

    _currentProxyUrl = proxyUrl;
    _currentProtocolInfo = protocolInfo;

    CastLogger.info(
      'DLNA: loading media, effectiveType=${transformed.effectiveType.name}',
    );
    CastLogger.debug('DLNA: proxy URL = $proxyUrl');
    CastLogger.debug('DLNA: protocolInfo=$protocolInfo');

    // Register subtitle in both SRT and VTT formats so the TV can pick
    // whichever it supports. Many DLNA TVs only support SRT, others VTT.
    List<({String url, String format})>? subtitleVariants;
    final subtitleSource =
        media.subtitles.isNotEmpty ? media.subtitles.first : _currentSubtitle;
    if (subtitleSource != null) {
      subtitleVariants = _proxy.registerSubtitleVariants(
        subtitleSource.url,
        headers: media.httpHeaders,
      );
    }

    // Build duration string for DIDL-Lite <res> element (HH:MM:SS).
    // An explicit media.duration wins; otherwise use whatever the HLS probe
    // found, so piped streams still get a scrub bar.
    final effectiveDuration = media.duration ?? probedDuration;
    final durationStr =
        effectiveDuration != null
            ? NetworkUtils.formatDuration(effectiveDuration)
            : null;
    if (isPipedStream) {
      CastLogger.info(
        'DLNA: piped TS route, seek mode=time, '
        'duration=${durationStr ?? 'unknown'}',
      );
    }

    // File size for local files — helps DLNA renderer know the content length
    final fileSize = media.isLocalFile ? File(media.url).lengthSync() : null;

    // Send SetAVTransportURI with proxy URL (not original URL)
    await _sendAvTransport(
      'SetAVTransportURI',
      DlnaSoapBuilder.buildSetAVTransportURI(
        proxyUrl,
        title: media.title,
        subtitleVariants: subtitleVariants,
        protocolInfo: protocolInfo,
        duration: durationStr,
        size: fileSize,
      ),
    );

    // Set known duration immediately if available (the TV may report 0
    // for piped streams since it doesn't know the total size upfront)
    _knownDuration = effectiveDuration;
    _isPipedStream = isPipedStream;
    _currentTitle = media.title;
    _pipedStartOffset = Duration.zero;
    if (effectiveDuration != null) {
      updateDuration(effectiveDuration);
    }

    // Send Play
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());

    stateMachine.transitionTo(SessionState.playing);

    // Save start position — will seek after TV confirms PLAYING via poll.
    // Seeking immediately after Play fails because the TV hasn't loaded yet.
    if (media.startPosition != null && media.startPosition! > Duration.zero) {
      _pendingSeekPosition = media.startPosition;
      CastLogger.info(
        'DLNA: deferred seek to ${media.startPosition!.inSeconds}s (waiting for TV to load)',
      );
    }

    // Start position polling
    _startPolling();
  }

  @override
  Future<void> play() async {
    CastLogger.info('DLNA: Play');
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());
    if (stateMachine.canTransitionTo(SessionState.playing)) {
      stateMachine.transitionTo(SessionState.playing);
    }
  }

  @override
  Future<void> pause() async {
    CastLogger.info('DLNA: Pause');
    await _sendAvTransport('Pause', DlnaSoapBuilder.buildPause());
    if (stateMachine.canTransitionTo(SessionState.paused)) {
      stateMachine.transitionTo(SessionState.paused);
    }
  }

  @override
  Future<void> stop() async {
    CastLogger.info('DLNA: Stop');
    _stopPolling();
    await _sendAvTransport('Stop', DlnaSoapBuilder.buildStop());
    if (stateMachine.canTransitionTo(SessionState.idle)) {
      stateMachine.transitionTo(SessionState.idle);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    CastLogger.info('DLNA: Seek to ${position.inSeconds}s');

    if (_isPipedStream) {
      // A piped TS has no length and no byte offsets, so a renderer cannot
      // seek inside it — the TCL Google TV answers a REL_TIME Seek by simply
      // going to STOPPED. Re-point it at the same route with the offset
      // encoded instead: the proxy restarts the stream at that segment, which
      // is a seek from the viewer's point of view.
      await _reloadPipedStreamAt(position);
      _pipedStartOffset = position;
      updatePosition(position);
      return;
    }

    await _sendAvTransport('Seek', DlnaSoapBuilder.buildSeek(position));
    // Update position immediately so the UI reflects the seek without
    // waiting for the next polling cycle.
    updatePosition(position);
  }

  /// Restarts a piped-TS route at [position] by re-issuing SetAVTransportURI.
  Future<void> _reloadPipedStreamAt(Duration position) async {
    final baseUrl = _currentProxyUrl;
    final protocolInfo = _currentProtocolInfo;
    if (baseUrl == null || protocolInfo == null) return;

    final seconds = position.inMilliseconds / 1000.0;
    final separator = baseUrl.contains('?') ? '&' : '?';
    final seekUrl = '$baseUrl${separator}t=${seconds.toStringAsFixed(3)}';

    CastLogger.info('DLNA: restarting piped stream at ${position.inSeconds}s');

    await _sendAvTransport('Stop', DlnaSoapBuilder.buildStop());
    await _sendAvTransport(
      'SetAVTransportURI',
      DlnaSoapBuilder.buildSetAVTransportURI(
        seekUrl,
        title: _currentTitle,
        protocolInfo: protocolInfo,
        duration:
            _knownDuration != null
                ? NetworkUtils.formatDuration(_knownDuration!)
                : null,
      ),
    );
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());
  }

  @override
  Future<void> setVolume(double volume) async {
    CastLogger.info('DLNA: SetVolume ${volume.toStringAsFixed(2)}');
    final intVolume = (volume.clamp(0.0, 1.0) * 100).round();
    final controlUrl = description.renderingControlUrl;
    if (controlUrl == null) return;

    await _httpClient.sendAction(
      controlUrl,
      DlnaServiceType.renderingControl,
      'SetVolume',
      DlnaSoapBuilder.buildSetVolume(intVolume),
    );
    updateVolume(volume);
  }

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    _currentSubtitle = subtitle;
    final media = _currentMedia;
    if (media == null || _currentProxyUrl == null) return;

    String? subtitleProxyUrl;
    if (subtitle != null) {
      subtitleProxyUrl = _proxy.registerSubtitle(
        subtitle.url,
        headers: media.httpHeaders,
      );
    }

    // Re-send SetAVTransportURI with proxy URL and proxied subtitle
    await _sendAvTransport(
      'SetAVTransportURI',
      DlnaSoapBuilder.buildSetAVTransportURI(
        _currentProxyUrl!,
        title: media.title,
        subtitleUrl: subtitleProxyUrl,
        protocolInfo: _currentProtocolInfo ?? 'http-get:*:video/mp4:*',
      ),
    );

    // Resume playback
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());
  }

  @override
  Future<void> disconnect() async {
    CastLogger.info('DLNA: disconnecting from ${device.name}');
    _stopPolling();

    // Try to stop playback
    try {
      await _sendAvTransport('Stop', DlnaSoapBuilder.buildStop());
    } catch (e) {
      CastLogger.warning('DLNA: error sending Stop during disconnect: $e');
    }

    await _proxy.stop();
    stateMachine.transitionTo(SessionState.disconnected);
    CastLogger.info('DLNA: disconnected from ${device.name}');
  }

  /// Disposes of resources used by this session.
  ///
  /// Prefer calling [disconnect] before [dispose] for a clean shutdown
  /// that awaits the proxy server stop.
  @override
  void dispose() {
    _stopPolling();
    _httpClient.close();
    // Fire-and-forget — callers should await disconnect() before dispose() for clean shutdown
    unawaited(_proxy.stop());
    super.dispose();
  }

  /// Checks whether the device supports the given [mimeType].
  ///
  /// Queries the ConnectionManager's GetProtocolInfo action and checks
  /// whether the Sink list contains the specified MIME type.
  /// Returns `false` if no ConnectionManager URL is available.
  Future<bool> supportsMediaType(String mimeType) async {
    final controlUrl = description.connectionManagerControlUrl;
    if (controlUrl == null) return false;

    try {
      final response = await _httpClient.sendAction(
        controlUrl,
        DlnaServiceType.connectionManager,
        'GetProtocolInfo',
        DlnaSoapBuilder.buildGetProtocolInfo(),
      );
      final protocols = DlnaSoapParser.parseProtocolInfo(response);
      return protocols.any((p) => p.contains(mimeType));
    } catch (e) {
      CastLogger.warning('DLNA: failed to query GetProtocolInfo: $e');
      return false;
    }
  }

  // -- Private helpers --

  Future<String> _sendAvTransport(String action, String body) async {
    final controlUrl = description.avTransportControlUrl;
    if (controlUrl == null) {
      throw StateError(
        'No AVTransport control URL available for "${device.name}". '
        'Use DlnaSession.fromDevice() to auto-extract URLs from discovery metadata, '
        'or ensure DlnaDeviceDescription has avTransportControlUrl set.',
      );
    }

    // Non-polling actions get logged at info level
    final isPolling =
        action == 'GetPositionInfo' ||
        action == 'GetTransportInfo' ||
        action == 'GetVolume';
    if (!isPolling) {
      CastLogger.debug('DLNA: $action → $controlUrl');
    }

    final response = await _httpClient.sendAction(
      controlUrl,
      DlnaServiceType.avTransport,
      action,
      body,
    );

    if (!isPolling) {
      CastLogger.info('DLNA: $action response (${response.length} chars)');
      CastLogger.debug('DLNA: $action response body: $response');
    }
    return response;
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      // Get position info
      final positionResponse = await _sendAvTransport(
        'GetPositionInfo',
        DlnaSoapBuilder.buildGetPositionInfo(),
      );
      final posInfo = DlnaSoapParser.parsePositionInfo(positionResponse);
      CastLogger.debug(
        'DLNA: poll position=${posInfo.position.inSeconds}s, duration=${posInfo.duration.inSeconds}s',
      );
      updatePosition(posInfo.position + _pipedStartOffset);
      // Only trust the device's duration when we have nothing better.
      // A renderer fed a length-less piped TS reports a placeholder — this TV
      // says 0:00:01 — which would otherwise clobber the real duration probed
      // from the HLS playlist and collapse the scrub bar.
      final deviceDuration = posInfo.duration;
      final known = _knownDuration;
      final devicePlaceholder = deviceDuration <= const Duration(seconds: 2);
      if (deviceDuration > Duration.zero &&
          !(known != null && devicePlaceholder)) {
        updateDuration(deviceDuration);
      }

      // Get transport info for state detection
      final transportResponse = await _sendAvTransport(
        'GetTransportInfo',
        DlnaSoapBuilder.buildGetTransportInfo(),
      );
      CastLogger.debug('DLNA: GetTransportInfo response: $transportResponse');
      final transportState = DlnaSoapParser.parseTransportInfo(
        transportResponse,
      );

      _handleTransportState(transportState);

      // Poll volume from RenderingControl
      final controlUrl = description.renderingControlUrl;
      if (controlUrl != null) {
        try {
          final volumeResponse = await _httpClient.sendAction(
            controlUrl,
            DlnaServiceType.renderingControl,
            'GetVolume',
            DlnaSoapBuilder.buildGetVolume(),
          );
          final intVolume = DlnaSoapParser.parseVolume(volumeResponse);
          updateVolume(intVolume / 100.0);
        } catch (e) {
          CastLogger.debug('DLNA: volume polling failed: $e');
        }
      }
    } catch (e) {
      CastLogger.debug('DLNA: polling failed: $e');
    } finally {
      _isPolling = false;
    }
  }

  void _handleTransportState(String transportState) {
    CastLogger.debug(
      'DLNA: transport state: $transportState (current: $state)',
    );
    switch (transportState) {
      case 'PLAYING':
        if (state != SessionState.playing &&
            stateMachine.canTransitionTo(SessionState.playing)) {
          stateMachine.transitionTo(SessionState.playing);
        }
        // Execute deferred seek now that the TV has loaded and is playing.
        if (_pendingSeekPosition != null) {
          final pos = _pendingSeekPosition!;
          _pendingSeekPosition = null;
          CastLogger.info('DLNA: executing deferred seek to ${pos.inSeconds}s');
          seek(pos);
        }
        break;
      case 'PAUSED_PLAYBACK':
        if (state != SessionState.paused &&
            stateMachine.canTransitionTo(SessionState.paused)) {
          stateMachine.transitionTo(SessionState.paused);
        }
        break;
      case 'STOPPED':
        CastLogger.info('DLNA: device reported STOPPED, transitioning to idle');
        if (state != SessionState.idle &&
            stateMachine.canTransitionTo(SessionState.idle)) {
          stateMachine.transitionTo(SessionState.idle);
          _stopPolling();
        }
        break;
    }
  }
}
