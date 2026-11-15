/// Chromecast receiver channel message builders and parsers.
///
/// Handles the `urn:x-cast:com.google.cast.receiver` namespace for
/// launching/stopping apps, querying status, and setting device volume,
/// as well as connection and heartbeat namespaces.
library;

import 'dart:convert';

/// Parsed receiver status from a RECEIVER_STATUS message.
class ReceiverStatusInfo {
  /// The transport ID used as destination for media commands.
  final String transportId;

  /// The session ID used for stopping the app.
  final String sessionId;

  /// The application ID.
  final String appId;

  /// Device volume level (0.0 to 1.0).
  final double volumeLevel;

  /// Whether the device is muted.
  final bool isMuted;

  /// Creates a [ReceiverStatusInfo].
  const ReceiverStatusInfo({
    required this.transportId,
    required this.sessionId,
    required this.appId,
    required this.volumeLevel,
    required this.isMuted,
  });
}

/// Builds and parses messages for Chromecast receiver control.
class CastReceiverChannel {
  /// Connection namespace for virtual connections.
  static const connectionNamespace = 'urn:x-cast:com.google.cast.tp.connection';

  /// Heartbeat namespace for keep-alive.
  static const heartbeatNamespace = 'urn:x-cast:com.google.cast.tp.heartbeat';

  /// Receiver namespace for app/device control.
  static const receiverNamespace = 'urn:x-cast:com.google.cast.receiver';

  /// Cast Command-and-Control namespace, used by CaC Tool. The Default
  /// Media Receiver advertises this and broadcasts debug / log events on
  /// it once a sender subscribes. We use it to surface receiver-side
  /// LOAD_FAILED detail that doesn't appear in the standard MEDIA_STATUS.
  static const cacNamespace = 'urn:x-cast:com.google.cast.cac';

  /// Receiver-side debug overlay namespace. Sending `SHOW` here makes the
  /// TV draw a debug overlay with playback errors, useful when remote
  /// debugging isn't available.
  static const debugOverlayNamespace =
      'urn:x-cast:com.google.cast.debugoverlay';

  /// Default Media Receiver app ID.
  static const defaultMediaReceiverAppId = 'CC1AD845';

  /// Auto-incrementing request ID counter.
  int _requestId = 0;

  /// Returns the next request ID.
  int nextRequestId() => ++_requestId;

  // ---------------------------------------------------------------------------
  // Static builders (no requestId needed)
  // ---------------------------------------------------------------------------

  /// Builds a CONNECT message.
  static String buildConnect() {
    return jsonEncode({'type': 'CONNECT', 'origin': {}});
  }

  /// Builds a CLOSE message.
  static String buildClose() {
    return jsonEncode({'type': 'CLOSE'});
  }

  /// Builds a PING message.
  static String buildPing() {
    return jsonEncode({'type': 'PING'});
  }

  /// Builds a PONG message, the answer to a PING from the device.
  static String buildPong() {
    return jsonEncode({'type': 'PONG'});
  }

  // ---------------------------------------------------------------------------
  // Static builders with auto-generated requestId (use a shared counter)
  // ---------------------------------------------------------------------------

  static int _staticRequestId = 0;

  static int _nextStaticRequestId() => ++_staticRequestId;

  /// Builds a LAUNCH message with a static request ID.
  static String buildLaunch([String appId = defaultMediaReceiverAppId]) {
    return jsonEncode({
      'type': 'LAUNCH',
      'appId': appId,
      'requestId': _nextStaticRequestId(),
    });
  }

  /// Builds a GET_STATUS message with a static request ID.
  static String buildGetStatus() {
    return jsonEncode({
      'type': 'GET_STATUS',
      'requestId': _nextStaticRequestId(),
    });
  }

  /// Builds a STOP message with a static request ID.
  static String buildStop(String sessionId) {
    return jsonEncode({
      'type': 'STOP',
      'sessionId': sessionId,
      'requestId': _nextStaticRequestId(),
    });
  }

  /// Builds a SET_VOLUME message with a static request ID.
  static String buildSetVolume({double? level, bool? muted}) {
    final volume = <String, dynamic>{};
    if (level != null) volume['level'] = clampVolumeLevel(level);
    if (muted != null) volume['muted'] = muted;
    return jsonEncode({
      'type': 'SET_VOLUME',
      'volume': volume,
      'requestId': _nextStaticRequestId(),
    });
  }

  // ---------------------------------------------------------------------------
  // Instance builders (use instance requestId counter)
  // ---------------------------------------------------------------------------

  /// Builds a LAUNCH message with an instance-scoped request ID.
  String buildLaunchWithId([String appId = defaultMediaReceiverAppId]) {
    return jsonEncode({
      'type': 'LAUNCH',
      'appId': appId,
      'requestId': nextRequestId(),
    });
  }

  /// Builds a GET_STATUS message with an instance-scoped request ID.
  String buildGetStatusWithId() {
    return jsonEncode({'type': 'GET_STATUS', 'requestId': nextRequestId()});
  }

  /// Builds a STOP message with an instance-scoped request ID.
  String buildStopWithId(String sessionId) {
    return jsonEncode({
      'type': 'STOP',
      'sessionId': sessionId,
      'requestId': nextRequestId(),
    });
  }

  /// Builds a SET_VOLUME message with an instance-scoped request ID.
  String buildSetVolumeWithId({double? level, bool? muted}) {
    final volume = <String, dynamic>{};
    if (level != null) volume['level'] = clampVolumeLevel(level);
    if (muted != null) volume['muted'] = muted;
    return jsonEncode({
      'type': 'SET_VOLUME',
      'volume': volume,
      'requestId': nextRequestId(),
    });
  }

  // ---------------------------------------------------------------------------
  // Parsers
  // ---------------------------------------------------------------------------

  /// Parses a RECEIVER_STATUS payload and extracts the entry for [appId]
  /// (the Default Media Receiver unless told otherwise) plus the volume.
  ///
  /// Returns null if [appId] is not among the running applications, or if
  /// its entry lacks a transportId or sessionId. RECEIVER_STATUS is also
  /// broadcast unprompted (requestId 0), for example on a volume change or
  /// when another sender launches a different app, so the first entry is
  /// not necessarily the app this sender launched.
  static ReceiverStatusInfo? parseReceiverStatus(
    Map<String, dynamic> json, {
    String appId = defaultMediaReceiverAppId,
  }) {
    final status = json['status'];
    if (status is! Map) return null;

    final apps = status['applications'];
    if (apps is! List) return null;

    for (final app in apps) {
      if (app is! Map || app['appId'] != appId) continue;
      final transportId = app['transportId'];
      final sessionId = app['sessionId'];
      if (transportId is! String || sessionId is! String) continue;
      final volume = status['volume'];
      return ReceiverStatusInfo(
        transportId: transportId,
        sessionId: sessionId,
        appId: appId,
        volumeLevel:
            (volume is Map ? volume['level'] as num? : null)?.toDouble() ?? 1.0,
        isMuted: (volume is Map ? volume['muted'] as bool? : null) ?? false,
      );
    }
    return null;
  }

  /// Returns the device volume level from a RECEIVER_STATUS payload, or
  /// null when the payload carries no volume.
  static double? parseVolumeLevel(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! Map) return null;
    final volume = status['volume'];
    if (volume is! Map) return null;
    return (volume['level'] as num?)?.toDouble();
  }

  /// Returns the session IDs of every application listed in a
  /// RECEIVER_STATUS payload, or null when the payload carries no status.
  ///
  /// A status without an `applications` list means nothing is running.
  static Set<String>? runningSessionIds(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! Map) return null;
    final apps = status['applications'];
    if (apps is! List) return <String>{};
    return {
      for (final app in apps)
        if (app is Map && app['sessionId'] is String)
          app['sessionId'] as String,
    };
  }

  /// Clamps a volume level to the 0.0–1.0 range the receiver accepts.
  /// NaN becomes 0.0.
  static double clampVolumeLevel(double level) =>
      level.isNaN ? 0.0 : level.clamp(0.0, 1.0).toDouble();

  /// Returns true if the message is a PONG heartbeat response.
  static bool isPong(Map<String, dynamic> json) {
    return json['type'] == 'PONG';
  }
}
