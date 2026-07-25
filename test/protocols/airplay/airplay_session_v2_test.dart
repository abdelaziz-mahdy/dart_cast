import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_session.dart';
import 'package:dart_cast/src/protocols/airplay/auth/binary_plist.dart';
import 'package:dart_cast/src/protocols/airplay/auth/tlv8.dart';
import 'package:test/test.dart';

import 'mock_airplay_server.dart';

/// The TCL "Living room TV" bitmask from test/integration/logs.txt: AirPlay 2
/// (bits 38/48), video V2 (bit 49), video V1 clear, transient pairing.
const _tclFeatures = '0x007f8ad0,0x000bcf46';

/// A receiver advertising only AirPlay 1 video.
const _v1Features = '0x1';

/// Records how a device was approached during connect().
class _ProbeServer {
  final HttpServer _server;

  /// Paths requested, in order.
  final List<String> paths = [];

  /// `X-Apple-HKP` header values seen on pairing requests.
  final List<String?> hkpHeaders = [];

  /// Whether `GET /info` should answer with a populated binary plist.
  bool serveInfo;

  _ProbeServer._(this._server, {required this.serveInfo});

  int get port => _server.port;

  static Future<_ProbeServer> start({bool serveInfo = true}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _ProbeServer._(http, serveInfo: serveInfo);
    http.listen(server._handle);
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    paths.add(request.uri.path);
    final response = request.response;

    switch (request.uri.path) {
      case '/info':
        if (!serveInfo) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        final body = BinaryPlistEncoder.encode({
          'deviceid': 'AA:BB:CC:DD:EE:FF',
          'model': 'TCL Google TV',
          'name': 'Living room TV',
        });
        response.headers.contentType = ContentType(
          'application',
          'x-apple-binary-plist',
        );
        response.add(body);
        await response.close();
        return;

      case '/pair-pin-start':
        hkpHeaders.add(request.headers.value('X-Apple-HKP'));
        response.statusCode = HttpStatus.ok;
        await response.close();
        return;

      case '/pair-setup':
        hkpHeaders.add(request.headers.value('X-Apple-HKP'));
        // Refuse the exchange so connect() fails deterministically without a
        // full SRP accessory implementation. What matters here is *that* the
        // session took the pairing path at all.
        final tlv = Tlv8.encode([
          (Tlv8.tagSeqNo, [0x02]),
          (Tlv8.tagError, [0x02]),
        ]);
        response.headers.contentType = ContentType(
          'application',
          'octet-stream',
        );
        response.add(Uint8List.fromList(tlv));
        await response.close();
        return;

      default:
        response.statusCode = HttpStatus.notFound;
        await response.close();
    }
  }

  Future<void> stop() => _server.close(force: true);
}

CastDevice _device(int port, {String? features}) => CastDevice(
  id: 'test-device',
  name: 'Living room TV',
  protocol: CastProtocol.airplay,
  address: InternetAddress.loopbackIPv4,
  port: port,
  metadata: features == null ? const {} : {'features': features},
);

void main() {
  group('AirPlaySession connect() transport selection', () {
    test('an AirPlay 2 receiver that answers 200 still pairs', () async {
      // Regression: the encrypted path was reachable only through a 403 from
      // /server-info. AirPlay 2 receivers using transient encryption answer
      // 200, so every one of them silently fell through to an
      // unauthenticated AirPlay 1 client that could only send a V1 /play.
      final server = await _ProbeServer.start();
      addTearDown(server.stop);

      final session = AirPlaySession(
        _device(server.port, features: _tclFeatures),
      );
      addTearDown(session.dispose);

      await expectLater(
        session.connect(),
        throwsA(isA<NeedsPairingException>()),
      );

      expect(
        server.paths,
        contains('/pair-setup'),
        reason: 'a bit-48 receiver must be offered pairing, not plain HTTP',
      );
      expect(session.state, equals(SessionState.disconnected));
    });

    test('pairing uses the transient header, not the PIN one', () async {
      final server = await _ProbeServer.start();
      addTearDown(server.stop);

      final session = AirPlaySession(
        _device(server.port, features: _tclFeatures),
      );
      addTearDown(session.dispose);

      await expectLater(session.connect(), throwsA(isA<Exception>()));

      expect(server.hkpHeaders, isNotEmpty);
      expect(
        server.hkpHeaders,
        everyElement(equals('4')),
        reason: 'X-Apple-HKP: 3 is the PIN flow this TV will never display',
      );
    });

    test('probes GET /info before GET /server-info', () async {
      final server = await _ProbeServer.start();
      addTearDown(server.stop);

      final session = AirPlaySession(
        _device(server.port, features: _tclFeatures),
      );
      addTearDown(session.dispose);

      await expectLater(session.connect(), throwsA(isA<Exception>()));

      expect(server.paths.first, equals('/info'));
    });

    test('a receiver without /info is not a fatal connect error', () async {
      // pyatv tolerates a missing /info; a receiver that implements only one
      // of the two endpoints must not fail before playback is attempted.
      final server = await _ProbeServer.start(serveInfo: false);
      addTearDown(server.stop);

      final session = AirPlaySession(
        _device(server.port, features: _v1Features),
      );
      addTearDown(session.dispose);

      await session.connect();

      expect(session.state, equals(SessionState.connected));
      expect(server.paths, containsAllInOrder(['/info', '/server-info']));
    });

    test('an AirPlay 1 receiver keeps the plain HTTP path', () async {
      final mock = MockAirPlayServer();
      await mock.start();
      addTearDown(mock.stop);

      final session = AirPlaySession(_device(mock.port, features: _v1Features));
      addTearDown(session.dispose);

      await session.connect();

      expect(session.state, equals(SessionState.connected));
      expect(mock.lastPath, equals('/server-info'));
    });
  });

  group('AirPlaySession start position', () {
    test(
      'honours media.startPosition instead of always starting at 0',
      () async {
        // airplay_session.dart hardcoded 0.0 and dropped media.startPosition
        // entirely, so "resume where you left off" silently restarted playback.
        final mock = MockAirPlayServer();
        await mock.start();
        addTearDown(mock.stop);

        final session = AirPlaySession(
          _device(mock.port, features: _v1Features),
        );
        addTearDown(session.dispose);

        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'http://127.0.0.1:1/video.mp4',
            type: CastMediaType.mp4,
            startPosition: const Duration(seconds: 90),
          ),
        );

        // AirPlay 1 cannot express an absolute offset on /play, so the session
        // seeks right after loading.
        expect(mock.lastPath, equals('/scrub'));
        expect(mock.lastQueryParameters['position'], equals('90.0'));
      },
    );

    test('does not seek when no start position was requested', () async {
      final mock = MockAirPlayServer();
      await mock.start();
      addTearDown(mock.stop);

      final session = AirPlaySession(_device(mock.port, features: _v1Features));
      addTearDown(session.dispose);

      await session.connect();
      await session.loadMedia(
        CastMedia(url: 'http://127.0.0.1:1/video.mp4', type: CastMediaType.mp4),
      );

      expect(mock.lastPath, equals('/play'));
    });
  });
}
