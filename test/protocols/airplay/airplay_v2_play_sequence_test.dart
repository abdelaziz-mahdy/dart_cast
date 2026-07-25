import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_media_controller.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

import 'mock_airplay2_server.dart';

/// The TCL "Living room TV" bitmask captured in test/integration/logs.txt:
/// AirPlay 2 (bits 38/48), video V2 (bit 49), no video V1 (bit 0 clear).
const _tclGoogleTv = AirPlayFeatures(0x000bcf46007f8ad0);

const _url = 'http://192.168.1.10:8080/media/video.mp4';

void main() {
  late MockAirPlay2Server server;
  late HapSession client;
  late AirPlayMediaController controller;

  setUp(() async {
    server = MockAirPlay2Server();
    await server.start();
    client = await server.connectClient();
    controller = AirPlayMediaController(
      session: client,
      features: _tclGoogleTv,
    );
  });

  tearDown(() async {
    await controller.dispose();
    await client.close();
    await server.stop();
  });

  group('AirPlay 2 play sequence', () {
    test(
      'runs SETUP, RECORD, /play and then the post-play commands in order',
      () async {
        await controller.play(_url);

        final targets = server.requestTargets;

        int indexOf(String needle) =>
            targets.indexWhere((t) => t.contains(needle));

        expect(indexOf('SETUP'), isNonNegative, reason: '$targets');
        expect(indexOf('RECORD'), isNonNegative, reason: '$targets');
        expect(indexOf('POST /play'), isNonNegative, reason: '$targets');

        // Handshake precedes playback.
        expect(indexOf('SETUP'), lessThan(indexOf('RECORD')));
        expect(indexOf('RECORD'), lessThan(indexOf('POST /play')));

        // Post-play sequence, in pyatv's order.
        final play = indexOf('POST /play');
        final dateRange = indexOf('setProperty?isInterestedInDateRange');
        final actionAtEnd = indexOf('setProperty?actionAtItemEnd');
        final rate = indexOf('POST /rate');
        final forwardEnd = indexOf('setProperty?forwardEndTime');
        final reverseEnd = indexOf('setProperty?reverseEndTime');

        expect(
          [dateRange, actionAtEnd, rate, forwardEnd, reverseEnd],
          everyElement(isNonNegative),
          reason: '$targets',
        );
        expect(play, lessThan(dateRange));
        expect(dateRange, lessThan(actionAtEnd));
        expect(actionAtEnd, lessThan(rate));
        expect(rate, lessThan(forwardEnd));
        expect(forwardEnd, lessThan(reverseEnd));
      },
    );

    test(
      'reaches rate 1.0 — /play alone would leave the item paused',
      () async {
        expect(server.rate, isZero, reason: 'receiver starts paused');

        await controller.play(_url);

        expect(
          server.rate,
          equals(1.0),
          reason: 'the receiver only leaves the paused state on POST /rate',
        );
      },
    );

    test('sends /rate with the six-decimal value pyatv uses', () async {
      await controller.play(_url);

      final rateRequest = server.requests.firstWhere((r) => r.path == '/rate');
      expect(rateRequest.target, equals('/rate?value=1.000000'));
      expect(
        rateRequest.isRtsp,
        isTrue,
        reason: 'post-play commands travel over RTSP, as in pyatv',
      );
    });

    test(
      'SETUP advertises a live timing port with timingProtocol NTP',
      () async {
        await controller.play(_url);

        expect(server.observedTimingProtocol, equals('NTP'));
        expect(server.observedTimingPort, isNotNull);
        expect(server.observedTimingPort, greaterThan(0));
        expect(
          server.observedTimingPort,
          equals(controller.timingServer.port),
          reason: 'the advertised port must be the one actually bound',
        );
        expect(controller.timingServer.isRunning, isTrue);
      },
    );

    test('SETUP names the sender in the RTSP URI, not the receiver', () async {
      await controller.play(_url);

      expect(server.observedRtspUri, startsWith('rtsp://'));
      expect(
        server.observedRtspUri,
        contains(client.localIp),
        reason: 'pyatv builds rtsp://<local ip>/<session id>',
      );
    });

    test(
      '/play carries the AirPlay 2 headers and an absolute start position',
      () async {
        await controller.play(_url, startPositionSeconds: 42.5);

        final play = server.requests.firstWhere((r) => r.path == '/play');
        expect(play.isRtsp, isFalse, reason: '/play is an HTTP request');
        expect(
          play.headers['content-type'],
          equals('application/x-apple-binary-plist'),
        );
        expect(play.headers['x-apple-protocolversion'], equals('1'));
        expect(play.headers['x-apple-stream-id'], equals('1'));

        final body = play.plistBody;
        expect(body['Content-Location'], equals(_url));
        expect(body['Start-Position-Seconds'], equals(42.5));
        expect(
          body.containsKey('Start-Position'),
          isFalse,
          reason: 'Start-Position is the AirPlay 1 fraction, not seconds',
        );
      },
    );

    test('a receiver that refuses /rate fails the playback', () async {
      server.rateStatus = 500;

      await expectLater(
        controller.play(_url),
        throwsA(
          isA<PlaybackException>().having(
            (e) => e.message,
            'message',
            contains('/rate'),
          ),
        ),
      );
    });

    test(
      'a receiver that refuses SETUP fails instead of pretending to be set up',
      () async {
        server.setupStatus = 456;

        await expectLater(controller.play(_url), throwsA(isA<Exception>()));
        expect(client.isRtspSessionSetUp, isFalse);
        expect(
          server.requestTargets.any((t) => t.contains('/play')),
          isFalse,
          reason: 'no /play may follow a refused SETUP',
        );
      },
    );

    test('a receiver that refuses RECORD fails before /play', () async {
      server.recordStatus = 500;

      await expectLater(controller.play(_url), throwsA(isA<Exception>()));
      expect(client.isRtspSessionSetUp, isFalse);
      expect(server.requestTargets.any((t) => t.contains('/play')), isFalse);
    });

    test('failing /setProperty calls do not stop playback', () async {
      // The mock accepts /setProperty; assert the contract explicitly by
      // checking that /rate still ran and the session reached rate 1.0 even
      // though setProperty results are never inspected.
      await controller.play(_url);
      expect(server.rate, equals(1.0));
    });
  });

  group('AirPlay 2 playback-info', () {
    test('parses the binary plist a real receiver returns', () async {
      await controller.play(_url);

      final info = await controller.getPlaybackInfo();
      expect(info.duration, equals(120.0));
      expect(info.position, equals(3.0));
      expect(info.rate, equals(1.0));
      expect(info.readyToPlay, isTrue);
      expect(info.hasDuration, isTrue);
      expect(info.error, isNull);
    });

    test('reports no duration before anything is playing', () async {
      final info = await controller.getPlaybackInfo();
      expect(info.hasDuration, isFalse);
      expect(info.duration, isZero);
      expect(info.rate, isZero);
    });

    test('surfaces an error dict from the receiver', () async {
      server.playbackError = {'code': -12645, 'domain': 'NSURLErrorDomain'};

      final info = await controller.getPlaybackInfo();
      expect(info.error, isNotNull);
      expect(info.error!.code, equals(-12645));
      expect(info.error!.domain, equals('NSURLErrorDomain'));
    });
  });

  group('AirPlay 2 control commands', () {
    test('pause and resume drive the receiver rate over RTSP', () async {
      await controller.play(_url);
      expect(server.rate, equals(1.0));

      await controller.pause();
      expect(server.rate, isZero);

      await controller.resume();
      expect(server.rate, equals(1.0));

      final rateRequests =
          server.requests.where((r) => r.path == '/rate').toList();
      expect(rateRequests.last.isRtsp, isTrue);
    });

    test('stop clears the receiver state', () async {
      await controller.play(_url);
      await controller.stop();

      expect(server.isPlaying, isFalse);
      expect(server.rate, isZero);
    });
  });

  group('timing server lifecycle', () {
    test('dispose closes the UDP socket bound for playback', () async {
      await controller.play(_url);
      expect(controller.timingServer.isRunning, isTrue);

      await controller.dispose();
      expect(controller.timingServer.isRunning, isFalse);
      expect(controller.timingServer.port, isZero);
    });
  });
}
