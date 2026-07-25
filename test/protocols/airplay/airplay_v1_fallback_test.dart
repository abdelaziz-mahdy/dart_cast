import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_media_controller.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

import 'mock_airplay2_server.dart';

/// The macOS AirPlay receiver captured in test/integration/logs.txt: AirPlay 2
/// (bits 38/48) *and* AirPlay 1 video (bit 0). Apple TVs look like this too.
const _dualCapable = AirPlayFeatures(0x38174fde4a7fcfd5);

/// The TCL Google TV: AirPlay 2 with video V2, but bit 0 clear.
const _v2Only = AirPlayFeatures(0x000bcf46007f8ad0);

const _url = 'http://192.168.1.10:8080/media/video.mp4';

/// True for the AirPlay 2 form of `/play`, which carries the protocol-version
/// header. The V1 form does not.
bool _isV2Play(RecordedRequest r) =>
    r.path == '/play' && r.headers.containsKey('x-apple-protocolversion');

void main() {
  late MockAirPlay2Server server;
  late HapSession client;

  setUp(() async {
    server = MockAirPlay2Server();
    await server.start();
    client = await server.connectClient();
  });

  tearDown(() async {
    await client.close();
    await server.stop();
  });

  group('dual-capable receivers (bit 0 and bit 49)', () {
    test('fall back to AirPlay 1 when the V2 /play returns 404', () async {
      // Before this, a receiver advertising both versions was sent down the V2
      // path and never offered V1, so a device that only implements the V1
      // endpoints could not play at all.
      server.playStatus = 404;

      final controller = AirPlayMediaController(
        session: client,
        features: _dualCapable,
      );
      addTearDown(controller.dispose);

      // The mock 404s the V2 /play; accept the V1 one that follows.
      var seenV2Play = false;
      server.onPlay = (request) {
        if (_isV2Play(request)) {
          seenV2Play = true;
          return 404;
        }
        return 200;
      };

      await controller.play(_url);

      final plays = server.requests.where((r) => r.path == '/play').toList();
      expect(seenV2Play, isTrue, reason: 'V2 must still be tried first');
      expect(plays, hasLength(2));
      expect(_isV2Play(plays[0]), isTrue);
      expect(_isV2Play(plays[1]), isFalse, reason: 'second is the V1 form');
    });

    test('do not attempt V1 when the V2 /play succeeds', () async {
      final controller = AirPlayMediaController(
        session: client,
        features: _dualCapable,
      );
      addTearDown(controller.dispose);

      await controller.play(_url);

      final plays = server.requests.where((r) => r.path == '/play').toList();
      expect(plays, hasLength(1));
      expect(_isV2Play(plays.single), isTrue);
      // The post-play sequence belongs to the V2 path only.
      expect(server.rate, equals(1.0));
    });

    test('control commands use the HTTP forms after falling back', () async {
      // A receiver answering the V1 /play expects the V1 control endpoints,
      // not the RTSP ones the V2 path uses.
      server.onPlay = (request) => _isV2Play(request) ? 404 : 200;

      final controller = AirPlayMediaController(
        session: client,
        features: _dualCapable,
      );
      addTearDown(controller.dispose);

      await controller.play(_url);
      await controller.pause();

      final rate = server.requests.lastWhere((r) => r.path == '/rate');
      expect(
        rate.isRtsp,
        isFalse,
        reason: 'after a V1 fallback, /rate must go over HTTP',
      );
    });

    test(
      'surface a PlaybackException when both versions are refused',
      () async {
        server.onPlay = (_) => 500;

        final controller = AirPlayMediaController(
          session: client,
          features: _dualCapable,
        );
        addTearDown(controller.dispose);

        // A 500 is not a "wrong protocol version" signal, so no fallback: the
        // V2 attempt fails outright.
        await expectLater(
          controller.play(_url),
          throwsA(isA<PlaybackException>()),
        );
      },
    );
  });

  group('receivers that advertise only AirPlay 2 video', () {
    test('never send a V1 /play, even after a 404', () async {
      // This is the regression that mattered: probing V1 on devices whose bits
      // said they do not speak it is what produced the misleading 404 and hid
      // the real defect for months.
      server.onPlay = (_) => 404;

      final controller = AirPlayMediaController(
        session: client,
        features: _v2Only,
      );
      addTearDown(controller.dispose);

      await expectLater(
        controller.play(_url),
        throwsA(
          isA<UnsupportedFeatureException>().having(
            (e) => e.message,
            'message',
            contains('advertises no AirPlay 1 video'),
          ),
        ),
      );

      final plays = server.requests.where((r) => r.path == '/play').toList();
      expect(plays, hasLength(1));
      expect(_isV2Play(plays.single), isTrue);
    });
  });
}
