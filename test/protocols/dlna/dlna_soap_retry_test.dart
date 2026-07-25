import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_controller.dart';
import 'package:test/test.dart';

/// A renderer that drops the connection before answering, for the first
/// [failures] requests.
///
/// This reproduces the failure reported in issue #9 against an LG smartshare
/// renderer: the socket is accepted and then closed without a complete
/// response, which `package:http` surfaces as
/// `ClientException: Connection closed before full header was received`.
class _FlakyRenderer {
  final ServerSocket _server;
  int _seen = 0;

  /// How many initial requests to kill before answering normally.
  int failures;

  _FlakyRenderer._(this._server, this.failures);

  int get port => _server.port;
  String get controlUrl => 'http://127.0.0.1:$port/AVTransport/control';
  int get requestCount => _seen;

  static Future<_FlakyRenderer> start({int failures = 1}) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final renderer = _FlakyRenderer._(socket, failures);
    socket.listen(renderer._handle);
    return renderer;
  }

  void _handle(Socket socket) {
    _seen++;
    final mine = _seen;
    socket.listen(
      (_) {
        if (mine <= failures) {
          // Close mid-exchange, exactly as the reported renderer does.
          socket.destroy();
          return;
        }
        const soap =
            '<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body><u:SeekResponse /></s:Body></s:Envelope>';
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/xml; charset="utf-8"\r\n'
          'Content-Length: ${soap.length}\r\n'
          '\r\n$soap',
        );
        socket.flush().then((_) => socket.destroy());
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  Future<void> stop() => _server.close();
}

void main() {
  group('DlnaHttpClient.sendAction connection handling', () {
    late _FlakyRenderer renderer;
    late DlnaHttpClient client;

    tearDown(() async {
      client.close();
      await renderer.stop();
    });

    test('recovers when the renderer drops the first connection', () async {
      // Issue #9: a Seek threw ClientException straight out to the caller
      // because a dropped keep-alive connection was never retried.
      renderer = await _FlakyRenderer.start(failures: 1);
      client = DlnaHttpClient();

      final body = await client.sendAction(
        renderer.controlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Seek',
        '<soap/>',
      );

      expect(body, contains('SeekResponse'));
      expect(
        renderer.requestCount,
        equals(2),
        reason: 'the first attempt should have been retried once',
      );
    });

    test('gives up after one retry rather than looping', () async {
      // A renderer that is genuinely unreachable must surface an error, not
      // spin. One retry covers a stale connection; two failures is a fault.
      renderer = await _FlakyRenderer.start(failures: 99);
      client = DlnaHttpClient();

      await expectLater(
        client.sendAction(
          renderer.controlUrl,
          'urn:schemas-upnp-org:service:AVTransport:1',
          'Seek',
          '<soap/>',
        ),
        throwsA(anything),
      );

      expect(renderer.requestCount, equals(2));
    });

    test('succeeds without retrying when the renderer behaves', () async {
      renderer = await _FlakyRenderer.start(failures: 0);
      client = DlnaHttpClient();

      final body = await client.sendAction(
        renderer.controlUrl,
        'urn:schemas-upnp-org:service:AVTransport:1',
        'Play',
        '<soap/>',
      );

      expect(body, contains('SeekResponse'));
      expect(renderer.requestCount, equals(1));
    });
  });

  group('DlnaHttpClient.sendAction timeout', () {
    test(
      'a stalled renderer fails instead of hanging forever',
      () async {
        // Accepts the connection and then never answers.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final held = <Socket>[];
        server.listen((socket) {
          held.add(socket);
          socket.listen((_) {}, onError: (Object _) {});
        });
        addTearDown(() {
          for (final s in held) {
            s.destroy();
          }
        });

        final client = DlnaHttpClient();
        addTearDown(client.close);

        await expectLater(
          client.sendAction(
            'http://127.0.0.1:${server.port}/control',
            'urn:schemas-upnp-org:service:AVTransport:1',
            'GetPositionInfo',
            '<soap/>',
          ),
          throwsA(isA<ProtocolException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
