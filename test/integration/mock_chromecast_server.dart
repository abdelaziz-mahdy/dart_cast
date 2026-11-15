import 'dart:async';
import 'dart:convert';

/// A mock Chromecast device that simulates the CASTV2 protocol at the
/// channel/message level.
///
/// Instead of running a real TLS server, this mock works with
/// `ChromecastSession.withMocks()` to simulate the full Chromecast protocol:
/// CONNECT, PING/PONG, LAUNCH -> RECEIVER_STATUS, LOAD -> MEDIA_STATUS,
/// PLAY/PAUSE/SEEK/STOP -> MEDIA_STATUS updates.
///
/// This allows integration tests to verify the complete session lifecycle
/// without requiring TLS infrastructure.
class MockChromecastServer {
  final _incomingController = StreamController<MockCastMessage>.broadcast();

  /// Messages sent by the session (recorded for verification).
  final List<MockSentMessage> sentMessages = [];

  /// The stream of messages "from the device" to the session.
  Stream<MockCastMessage> get messageStream => _incomingController.stream;

  /// Whether the connection has been established.
  bool isConnected = false;

  /// Whether the connection has been closed.
  bool isClosed = false;

  // -- Simulated device state --

  /// The transport ID assigned to the launched app.
  final String transportId;

  /// The session ID assigned to the launched app.
  final String sessionId;

  /// Current player state.
  String playerState = 'IDLE';

  /// Current playback position in seconds.
  double currentTime = 0.0;

  /// Media duration in seconds.
  double duration = 0.0;

  /// Current volume level (0.0 to 1.0).
  double volumeLevel = 1.0;

  /// The media session ID.
  int mediaSessionId = 1;

  /// Whether auto-response mode is enabled.
  ///
  /// When true, the mock automatically responds to sent messages
  /// (e.g., LAUNCH -> RECEIVER_STATUS, LOAD -> MEDIA_STATUS).
  bool autoRespond;

  /// Creates a mock Chromecast server.
  MockChromecastServer({
    this.transportId = 'web-integration',
    this.sessionId = 'session-integration',
    this.autoRespond = true,
  });

  // -- Channel interface (called by ChromecastSession via withMocks) --

  /// Simulates connecting to the Chromecast.
  Future<void> connect(String host, {int port = 8009}) async {
    isConnected = true;
  }

  /// Records a sent message and optionally auto-responds.
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    final parsed = jsonDecode(payload) as Map<String, dynamic>;
    final sent = MockSentMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: parsed,
    );
    sentMessages.add(sent);

    if (autoRespond) {
      _autoRespond(sent);
    }
  }

  /// Closes the mock connection.
  Future<void> close() async {
    isClosed = true;
    await _incomingController.close();
  }

  // -- Manual message injection --

  /// Injects a message as if it came from the Chromecast device.
  void injectMessage({
    required String namespace,
    required Map<String, dynamic> payload,
    String sourceId = 'receiver-0',
    String destinationId = 'sender-0',
  }) {
    _incomingController.add(
      MockCastMessage(
        namespace: namespace,
        sourceId: sourceId,
        destinationId: destinationId,
        payload: payload,
      ),
    );
  }

  /// Clears recorded sent messages.
  void clearMessages() => sentMessages.clear();

  // -- Auto-response logic --

  void _autoRespond(MockSentMessage msg) {
    final type = msg.payload['type'] as String?;

    final requestId = (msg.payload['requestId'] as num?)?.toInt() ?? 0;
    switch (type) {
      case 'LAUNCH':
        // Respond with RECEIVER_STATUS containing the transportId
        _respondLater(() {
          injectMessage(
            namespace: 'urn:x-cast:com.google.cast.receiver',
            payload: _buildReceiverStatus(),
          );
        });
      case 'LOAD':
        // Respond with MEDIA_STATUS showing PLAYING
        playerState = 'PLAYING';
        _respondLater(() {
          injectMessage(
            namespace: 'urn:x-cast:com.google.cast.media',
            sourceId: transportId,
            payload: _buildMediaStatus(requestId: requestId),
          );
        });
      case 'PLAY':
        playerState = 'PLAYING';
        _respondLater(() {
          injectMessage(
            namespace: 'urn:x-cast:com.google.cast.media',
            sourceId: transportId,
            payload: _buildMediaStatus(requestId: requestId),
          );
        });
      case 'PAUSE':
        playerState = 'PAUSED';
        _respondLater(() {
          injectMessage(
            namespace: 'urn:x-cast:com.google.cast.media',
            sourceId: transportId,
            payload: _buildMediaStatus(requestId: requestId),
          );
        });
      case 'STOP':
        if (msg.namespace == 'urn:x-cast:com.google.cast.media') {
          playerState = 'IDLE';
          currentTime = 0.0;
          _respondLater(() {
            injectMessage(
              namespace: 'urn:x-cast:com.google.cast.media',
              sourceId: transportId,
              payload: _buildMediaStatus(
                idleReason: 'CANCELLED',
                requestId: requestId,
              ),
            );
          });
        }
      case 'SEEK':
        final seekTime = msg.payload['currentTime'] as num?;
        if (seekTime != null) {
          currentTime = seekTime.toDouble();
        }
        _respondLater(() {
          injectMessage(
            namespace: 'urn:x-cast:com.google.cast.media',
            sourceId: transportId,
            payload: _buildMediaStatus(requestId: requestId),
          );
        });
      case 'SET_VOLUME':
        final volume = msg.payload['volume'] as Map<String, dynamic>?;
        if (volume != null && volume['level'] != null) {
          volumeLevel = (volume['level'] as num).toDouble();
        }
      case 'PING':
        _respondLater(() {
          injectMessage(
            namespace: 'urn:x-cast:com.google.cast.tp.heartbeat',
            payload: {'type': 'PONG'},
          );
        });
    }
  }

  void _respondLater(void Function() action) {
    // Use a microtask to simulate async response
    Future.microtask(action);
  }

  Map<String, dynamic> _buildReceiverStatus() => {
    'type': 'RECEIVER_STATUS',
    'requestId': 1,
    'status': {
      'applications': [
        {
          'appId': 'CC1AD845',
          'displayName': 'Default Media Receiver',
          'sessionId': sessionId,
          'transportId': transportId,
          'namespaces': [
            {'name': 'urn:x-cast:com.google.cast.media'},
          ],
        },
      ],
      'volume': {'level': volumeLevel, 'muted': false},
    },
  };

  /// A spec receiver answers a media command with a MEDIA_STATUS carrying
  /// that command's requestId; 0 is reserved for unsolicited broadcasts.
  Map<String, dynamic> _buildMediaStatus({
    String? idleReason,
    int requestId = 0,
  }) {
    final statusEntry = <String, dynamic>{
      'mediaSessionId': mediaSessionId,
      'playerState': playerState,
      'currentTime': currentTime,
      'volume': {'level': volumeLevel, 'muted': false},
    };

    if (duration > 0) {
      statusEntry['media'] = {'duration': duration};
    }

    if (idleReason != null) {
      statusEntry['idleReason'] = idleReason;
    }

    return {
      'type': 'MEDIA_STATUS',
      'requestId': requestId,
      'status': [statusEntry],
    };
  }
}

/// A message sent by the session to the mock server.
class MockSentMessage {
  final String namespace;
  final String sourceId;
  final String destinationId;
  final Map<String, dynamic> payload;

  MockSentMessage({
    required this.namespace,
    required this.sourceId,
    required this.destinationId,
    required this.payload,
  });

  String get type => payload['type'] as String? ?? '';

  @override
  String toString() =>
      'MockSentMessage(ns=$namespace, dst=$destinationId, type=$type)';
}

/// A message received from the mock Chromecast device.
class MockCastMessage {
  final String namespace;
  final String sourceId;
  final String destinationId;
  final Map<String, dynamic> payload;

  MockCastMessage({
    required this.namespace,
    required this.sourceId,
    required this.destinationId,
    required this.payload,
  });
}
