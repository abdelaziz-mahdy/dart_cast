import 'dart:io';

import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

class _TestSession extends CastSession {
  _TestSession(super.device);

  @override
  Future<void> loadMedia(CastMedia media) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {}

  @override
  Future<void> disconnect() async {}
}

void main() {
  group('CastSession (abstract)', () {
    late CastDevice device;
    late _TestSession session;

    setUp(() {
      device = CastDevice(
        id: 'test-device',
        name: 'Test TV',
        protocol: CastProtocol.chromecast,
        address: InternetAddress('192.168.1.1'),
        port: 8009,
      );
      session = _TestSession(device);
    });

    tearDown(() {
      session.dispose();
    });

    test('exposes the device', () {
      expect(session.device, same(device));
      expect(session.device.name, 'Test TV');
    });

    test('initial state is disconnected', () {
      expect(session.state, SessionState.disconnected);
    });

    test('state management via stateMachine', () {
      session.stateMachine.transitionTo(SessionState.connecting);
      expect(session.state, SessionState.connecting);

      session.stateMachine.transitionTo(SessionState.connected);
      expect(session.state, SessionState.connected);
    });

    test('stateStream emits changes', () async {
      final states = <SessionState>[];
      final sub = session.stateStream.listen(states.add);

      session.stateMachine.transitionTo(SessionState.connecting);
      session.stateMachine.transitionTo(SessionState.connected);

      await Future<void>.delayed(Duration.zero);

      expect(states, [SessionState.connecting, SessionState.connected]);

      await sub.cancel();
    });

    test('position defaults to zero', () {
      expect(session.position, Duration.zero);
    });

    test('duration defaults to zero', () {
      expect(session.duration, Duration.zero);
    });

    test('updatePosition updates value and emits on stream', () async {
      final positions = <Duration>[];
      final sub = session.positionStream.listen(positions.add);

      session.updatePosition(Duration(seconds: 42));
      expect(session.position, Duration(seconds: 42));

      await Future<void>.delayed(Duration.zero);
      expect(positions, [Duration(seconds: 42)]);

      await sub.cancel();
    });

    test('updateDuration updates value and emits on stream', () async {
      final durations = <Duration>[];
      final sub = session.durationStream.listen(durations.add);

      session.updateDuration(Duration(minutes: 5));
      expect(session.duration, Duration(minutes: 5));

      await Future<void>.delayed(Duration.zero);
      expect(durations, [Duration(minutes: 5)]);

      await sub.cancel();
    });

    test('updateVolume emits on stream', () async {
      final volumes = <double>[];
      final sub = session.volumeStream.listen(volumes.add);

      session.updateVolume(0.75);

      await Future<void>.delayed(Duration.zero);
      expect(volumes, [0.75]);

      await sub.cancel();
    });

    test('volume defaults to null until the device reports it', () {
      expect(session.volume, isNull);
    });

    test('updateVolume caches the value for late readers', () {
      session.updateVolume(0.18);
      expect(session.volume, 0.18);

      session.updateVolume(0.5);
      expect(session.volume, 0.5);
    });

    test('positionStream, durationStream, volumeStream exist', () {
      expect(session.positionStream, isA<Stream<Duration>>());
      expect(session.durationStream, isA<Stream<Duration>>());
      expect(session.volumeStream, isA<Stream<double>>());
    });
  });
}
