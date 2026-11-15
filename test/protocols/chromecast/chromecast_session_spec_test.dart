import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_media_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_receiver_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/chromecast_session.dart';
import 'package:test/test.dart';

import 'chromecast_session_test.dart' show MockCastV2Channel;

const _receiver = CastReceiverChannel.receiverNamespace;
const _connection = CastReceiverChannel.connectionNamespace;
const _heartbeat = CastReceiverChannel.heartbeatNamespace;

Map<String, dynamic> _status(
  List<Map<String, dynamic>> apps, {
  int requestId = 0,
  double level = 0.5,
}) => {
  'type': 'RECEIVER_STATUS',
  'requestId': requestId,
  'status': {
    'applications': apps,
    'volume': {'level': level, 'muted': false},
  },
};

Map<String, dynamic> _app(String appId, String transportId, String sessionId) =>
    {'appId': appId, 'transportId': transportId, 'sessionId': sessionId};

void main() {
  late MockCastV2Channel channel;
  late MediaProxy proxy;
  late ChromecastSession session;

  ChromecastSession build({
    Duration heartbeatInterval = const Duration(seconds: 5),
    Duration heartbeatTimeout = const Duration(seconds: 15),
    Duration connectTimeout = const Duration(seconds: 15),
  }) => ChromecastSession.withMocks(
    device: CastDevice(
      id: 'cc',
      name: 'Test Chromecast',
      protocol: CastProtocol.chromecast,
      address: InternetAddress('192.168.1.100'),
      port: 8009,
    ),
    channel: channel,
    proxy: proxy,
    heartbeatInterval: heartbeatInterval,
    heartbeatTimeout: heartbeatTimeout,
    connectTimeout: connectTimeout,
  );

  void inject(String namespace, Map<String, dynamic> payload, {String? from}) {
    channel.injectMessage(
      namespace: namespace,
      sourceId: from ?? 'receiver-0',
      destinationId: 'sender-0',
      payload: payload,
    );
  }

  Future<void> connect() async {
    final future = session.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    inject(_receiver, _status([_app('CC1AD845', 'web-4', 'sess-1')]));
    await future;
  }

  setUp(() async {
    channel = MockCastV2Channel();
    proxy = MediaProxy();
    await proxy.start();
    session = build();
  });

  tearDown(() async {
    session.dispose();
    await proxy.stop();
  });

  test('connect ignores a broadcast naming another app and joins the '
      'Default Media Receiver', () async {
    final future = session.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    inject(_receiver, _status([_app('233637DE', 'yt-transport', 'yt')]));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    inject(
      _receiver,
      _status([
        _app('233637DE', 'yt-transport', 'yt'),
        _app('CC1AD845', 'web-4', 'sess-1'),
      ]),
    );
    await future;

    final appConnects = channel.sentMessages.where(
      (m) =>
          m.namespace == _connection &&
          m.payload['type'] == 'CONNECT' &&
          m.destinationId != 'receiver-0',
    );
    expect(appConnects.map((m) => m.destinationId), ['web-4']);
    expect(session.sessionId, 'sess-1');
  });

  test('an application entry without transportId does not throw', () async {
    final future = session.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    inject(_receiver, {
      'type': 'RECEIVER_STATUS',
      'status': {
        'applications': [
          {'appId': 'CC1AD845'},
        ],
      },
    });
    inject(_receiver, _status([_app('CC1AD845', 'web-4', 'sess-1')]));
    await future;
    expect(session.state, SessionState.connected);
  });

  test('LAUNCH_ERROR fails connect at once with the reason', () async {
    final future = session.connect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    inject(_receiver, {
      'type': 'LAUNCH_ERROR',
      'requestId': 1,
      'reason': 'NOT_FOUND',
    });
    await expectLater(
      future.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<DeviceUnreachableException>().having(
          (e) => e.toString(),
          'message',
          contains('NOT_FOUND'),
        ),
      ),
    );
    expect(session.state, SessionState.disconnected);
    expect(session.isHeartbeatActive, isFalse);
    expect(channel.isClosed, isTrue);
  });

  test('a connect timeout stops the heartbeat and closes the socket', () async {
    session.dispose();
    session = build(connectTimeout: const Duration(milliseconds: 100));
    await expectLater(session.connect(), throwsA(isA<TimeoutException>()));
    expect(session.isHeartbeatActive, isFalse);
    expect(channel.isClosed, isTrue);
    expect(session.state, SessionState.disconnected);
  });

  test('a PING from the device is answered with a PONG', () async {
    await connect();
    channel.clearMessages();
    inject(_heartbeat, {'type': 'PING'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final pongs = channel.sentMessages.where(
      (m) => m.namespace == _heartbeat && m.payload['type'] == 'PONG',
    );
    expect(pongs.map((m) => m.destinationId), ['receiver-0']);
  });

  test('CLOSE from the app transport ends the session', () async {
    await connect();
    inject(_connection, {'type': 'CLOSE'}, from: 'web-4');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.state, SessionState.disconnected);
    expect(session.isPositionPollingActive, isFalse);
    // The app's transport is gone, so no CLOSE is addressed to it.
    expect(
      channel.sentMessages.where(
        (m) => m.payload['type'] == 'CLOSE' && m.destinationId == 'web-4',
      ),
      isEmpty,
    );
  });

  test('a RECEIVER_STATUS without our app ends the session', () async {
    await connect();
    inject(_receiver, _status([_app('233637DE', 'yt-transport', 'yt')]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.state, SessionState.disconnected);
  });

  test('a volume-only RECEIVER_STATUS that still lists our app keeps the '
      'session and updates the volume', () async {
    await connect();
    final volumes = <double>[];
    session.volumeStream.listen(volumes.add);
    inject(
      _receiver,
      _status([_app('CC1AD845', 'web-4', 'sess-1')], level: 0.25),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.state, SessionState.connected);
    expect(volumes.last, 0.25);
  });

  test(
    'a silent device is treated as gone after the heartbeat timeout',
    () async {
      session.dispose();
      session = build(
        heartbeatInterval: const Duration(milliseconds: 40),
        heartbeatTimeout: const Duration(milliseconds: 150),
      );
      await connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(session.state, SessionState.disconnected);
      expect(session.isHeartbeatActive, isFalse);
    },
  );

  test('a device that keeps answering stays connected', () async {
    session.dispose();
    session = build(
      heartbeatInterval: const Duration(milliseconds: 40),
      heartbeatTimeout: const Duration(milliseconds: 150),
    );
    await connect();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      inject(_heartbeat, {'type': 'PONG'});
    }
    expect(session.state, SessionState.connected);
  });

  group('volume', () {
    test('SET_VOLUME level is clamped to 0.0–1.0 and sent without muted', () {
      final receiver = CastReceiverChannel();
      final high =
          jsonDecode(receiver.buildSetVolumeWithId(level: 1.5))
              as Map<String, dynamic>;
      final low =
          jsonDecode(receiver.buildSetVolumeWithId(level: -0.2))
              as Map<String, dynamic>;
      final nan =
          jsonDecode(receiver.buildSetVolumeWithId(level: double.nan))
              as Map<String, dynamic>;
      expect(high['volume'], {'level': 1.0});
      expect(low['volume'], {'level': 0.0});
      expect(nan['volume'], {'level': 0.0});
    });
  });

  group('LOAD', () {
    test('omits currentTime when no start position is given', () {
      final load =
          jsonDecode(
                CastMediaChannel().buildLoad(
                  contentId: 'http://x/a.m3u8',
                  contentType: 'application/x-mpegURL',
                ),
              )
              as Map<String, dynamic>;
      expect(load.containsKey('currentTime'), isFalse);
    });
  });
}
