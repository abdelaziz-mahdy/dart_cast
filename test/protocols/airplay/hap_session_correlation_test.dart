import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

import 'mock_airplay2_server.dart';

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

  group('HapSession request correlation', () {
    test('concurrent requests each receive their own response', () async {
      // One socket, one reader, one nonce counter per direction. Before
      // exchanges were serialized, the first decrypted frame was handed to
      // whoever happened to be waiting — so /play could be given the 200 that
      // belonged to /feedback, and two writers desynchronised the ChaCha20
      // nonce counters until every frame failed MAC verification.
      final targets = [
        '/playback-info',
        '/scrub',
        '/stop',
        '/playback-info',
        '/scrub',
      ];

      final responses = await Future.wait([
        for (final target in targets) client.sendRequest('GET', target),
      ]);

      for (var i = 0; i < targets.length; i++) {
        expect(
          responses[i].headers['x-mock-target'],
          equals('GET ${targets[i]}'),
          reason: 'response $i was matched to the wrong request',
        );
      }
    });

    test(
      'an RTSP exchange racing HTTP traffic keeps its own response',
      () async {
        final rtsp = client.sendRtspRequest('POST', '/feedback');
        final http = client.sendRequest('GET', '/playback-info');
        final rtsp2 = client.sendRtspRequest('POST', '/rate?value=1.000000');

        final rtspResp = await rtsp;
        final httpResp = await http;
        final rtsp2Resp = await rtsp2;

        expect(rtspResp.headers['x-mock-target'], equals('POST /feedback'));
        expect(httpResp.headers['x-mock-target'], equals('GET /playback-info'));
        expect(
          rtsp2Resp.headers['x-mock-target'],
          equals('POST /rate?value=1.000000'),
        );
      },
    );

    test('RTSP responses carry the CSeq of their own request', () async {
      final first = await client.sendRtspRequest('POST', '/feedback');
      final second = await client.sendRtspRequest('POST', '/feedback');

      final firstCseq = int.parse(first.headers['cseq']!);
      final secondCseq = int.parse(second.headers['cseq']!);
      expect(secondCseq, equals(firstCseq + 1));
    });

    test(
      'a live feedback loop cannot steal the /play response',
      () async {
        // setupRtspSession starts the 2-second feedback loop before RECORD.
        await client.setupRtspSession(timingPort: 51234);
        expect(client.isRtspSessionSetUp, isTrue);

        // Overlap the loop with a burst of foreground commands.
        for (var i = 0; i < 6; i++) {
          final resp = await client.sendRequest('POST', '/play');
          expect(resp.headers['x-mock-target'], equals('POST /play'));
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('resetRtspSession keeps CSeq monotonic', () async {
      final before = await client.sendRtspRequest('POST', '/feedback');
      client.resetRtspSession();
      final after = await client.sendRtspRequest('POST', '/feedback');

      // Restarting CSeq at 0 on a live connection produces two exchanges with
      // the same sequence number, making correlation impossible.
      expect(
        int.parse(after.headers['cseq']!),
        greaterThan(int.parse(before.headers['cseq']!)),
      );
    });
  });

  group('HapSession RTSP SETUP', () {
    test('advertises timingProtocol NTP with the port it was given', () async {
      await client.setupRtspSession(timingPort: 49876);

      expect(server.observedTimingPort, equals(49876));
      expect(server.observedTimingProtocol, equals('NTP'));
    });

    test('declares no timing protocol when no port is supplied', () async {
      server.requireTimingPort = false;
      await client.setupRtspSession();

      expect(server.observedTimingProtocol, equals('None'));
      expect(server.observedTimingPort, isNull);
    });

    test(
      'a receiver demanding a timing port rejects a timing-less SETUP',
      () async {
        // This is the failure the package used to paper over: SETUP was
        // answered with an error, a warning was logged, and the session was
        // marked set up anyway.
        await expectLater(
          client.setupRtspSession(),
          throwsA(
            isA<HapSessionException>().having(
              (e) => e.message,
              'message',
              contains('SETUP rejected with 400'),
            ),
          ),
        );
        expect(client.isRtspSessionSetUp, isFalse);
      },
    );

    test('a rejected RECORD leaves the session not set up', () async {
      server.recordStatus = 500;

      await expectLater(
        client.setupRtspSession(timingPort: 5000),
        throwsA(
          isA<HapSessionException>().having(
            (e) => e.message,
            'message',
            contains('RECORD rejected with 500'),
          ),
        ),
      );
      expect(client.isRtspSessionSetUp, isFalse);
    });

    test('builds the RTSP URI from the sender IP', () async {
      await client.setupRtspSession(timingPort: 5000);

      expect(client.rtspUri, equals(server.observedRtspUri));
      expect(client.rtspUri, startsWith('rtsp://${client.localIp}/'));
    });

    test('is idempotent once the handshake has succeeded', () async {
      await client.setupRtspSession(timingPort: 5000);
      final setupCount =
          server.requests.where((r) => r.method == 'SETUP').length;

      await client.setupRtspSession(timingPort: 5000);
      expect(
        server.requests.where((r) => r.method == 'SETUP').length,
        equals(setupCount),
      );
    });
  });
}
