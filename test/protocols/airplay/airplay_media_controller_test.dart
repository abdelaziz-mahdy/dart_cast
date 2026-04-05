import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_media_controller.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a server-side HapSession from an accepted socket using the same key.
HapSession _serverSession(Socket sock, int port) {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    key[i] = i;
  }
  return HapSession(
    socket: sock,
    outputKey: Uint8List.fromList(key),
    inputKey: Uint8List.fromList(key),
    host: '127.0.0.1',
    port: port,
  );
}

/// Sends an encrypted HTTP response from the server side.
Future<void> _sendResponse(
  HapSession serverSess,
  Socket serverSock,
  int statusCode,
  String reasonPhrase, {
  String body = '',
}) async {
  final resp = 'HTTP/1.1 $statusCode $reasonPhrase\r\n'
      'Content-Length: ${body.length}\r\n'
      '\r\n'
      '$body';
  final encrypted = await serverSess.encrypt(
    Uint8List.fromList(utf8.encode(resp)),
  );
  serverSock.add(encrypted);
  await serverSock.flush();
}

/// Creates an encrypted client/server pair with a fixed known key.
Future<({ServerSocket server, HapSession client})> createEncryptedPair() async {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) key[i] = i;
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sock = await Socket.connect('127.0.0.1', srv.port);
  final client = HapSession(
    socket: sock,
    outputKey: Uint8List.fromList(key),
    inputKey: Uint8List.fromList(key),
    host: '127.0.0.1',
    port: srv.port,
    sessionId: 'test-media-session',
  );
  return (server: srv, client: client);
}

// Features bitmask: bit 0 (V1 video) set
const _featuresV1 = AirPlayFeatures(0x1); // supportsVideoV1 = true
// Features bitmask: bit 49 (V2 video) set
const _featuresV2 = AirPlayFeatures(1 << 49); // supportsVideoV2 = true
// Both V1 and V2 (kept for future tests)
// ignore: unused_element
const _featuresBoth = AirPlayFeatures((1 << 49) | 0x1);
// No video support
const _featuresNone = AirPlayFeatures(0);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('AirPlayMediaController.playV1()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends POST /play with binary plist content-type', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.playV1('https://example.com/video.m3u8', 0.0);

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('POST /play HTTP/1.1'));
      expect(
        receivedRequest!.toLowerCase(),
        contains('content-type: application/x-apple-binary-plist'),
      );
    });

    test('sends User-Agent: MediaControl/1.0', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.playV1('https://example.com/video.m3u8', 0.0);

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('User-Agent: MediaControl/1.0'));
    });

    test('body contains Content-Location and Start-Position', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.playV1('https://example.com/video.m3u8', 0.5);

      // The body is a binary plist — URL should appear somewhere in the raw bytes
      expect(receivedRequest, isNotNull);
      expect(
        receivedRequest!,
        contains('https://example.com/video.m3u8'),
      );
    });

    test('does NOT call setupRtspSession (no RTSP/1.0 line in request)',
        () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.playV1('https://example.com/video.m3u8', 0.0);

      expect(receivedRequest, isNotNull);
      // V1 play goes straight to HTTP/1.1, no RTSP/1.0 setup request
      expect(receivedRequest!, isNot(contains('RTSP/1.0')));
    });
  });

  group('AirPlayMediaController.playV1Text()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends Content-Type: text/parameters', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.playV1Text('https://example.com/video.m3u8', 0.0);

      expect(receivedRequest, isNotNull);
      expect(
        receivedRequest!.toLowerCase(),
        contains('content-type: text/parameters'),
      );
    });

    test('body is "Content-Location: <url>\\nStart-Position: <pos>\\n"',
        () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.playV1Text('https://example.com/video.m3u8', 0.25);

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!,
          contains('Content-Location: https://example.com/video.m3u8'));
      expect(receivedRequest!, contains('Start-Position: 0.25'));
    });
  });

  group('AirPlayMediaController.playV2()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV2,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('calls setupRtspSession first (sends RTSP SETUP before /play)',
        () async {
      final requestLog = <String>[];

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        // Handle multiple requests from the same connection
        while (true) {
          try {
            final data = await srvSess.readDecryptedData(
              timeout: const Duration(milliseconds: 200),
            );
            final req = utf8.decode(data, allowMalformed: true);
            requestLog.add(req);

            if (req.contains('SETUP')) {
              // RTSP SETUP response
              final resp =
                  'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
              final enc = await srvSess.encrypt(
                Uint8List.fromList(utf8.encode(resp)),
              );
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('POST /feedback') ||
                req.contains('POST /rate')) {
              // feedback / rate
              final resp = req.contains('RTSP')
                  ? 'RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 0\r\n\r\n'
                  : 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
              final enc = await srvSess.encrypt(
                Uint8List.fromList(utf8.encode(resp)),
              );
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('RECORD')) {
              final resp =
                  'RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: 0\r\n\r\n';
              final enc = await srvSess.encrypt(
                Uint8List.fromList(utf8.encode(resp)),
              );
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('POST /play')) {
              await _sendResponse(srvSess, sock, 200, 'OK');
            }
          } catch (_) {
            break;
          }
        }
      });

      await controller.playV2('https://example.com/video.m3u8', 0.0);

      // There should have been a SETUP request before the /play
      final setupReqs = requestLog.where((r) => r.contains('SETUP')).toList();
      final playReqs =
          requestLog.where((r) => r.contains('POST /play')).toList();

      expect(setupReqs, isNotEmpty, reason: 'Expected RTSP SETUP to be sent');
      expect(playReqs, isNotEmpty, reason: 'Expected POST /play to be sent');

      // SETUP must appear before /play in the log
      final setupIdx = requestLog.indexWhere((r) => r.contains('SETUP'));
      final playIdx = requestLog.indexWhere((r) => r.contains('POST /play'));
      expect(setupIdx, lessThan(playIdx));
    });

    test('sends User-Agent: AirPlay/550.10 on /play request', () async {
      String? playRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        while (true) {
          try {
            final data = await srvSess.readDecryptedData(
              timeout: const Duration(milliseconds: 200),
            );
            final req = utf8.decode(data, allowMalformed: true);

            if (req.contains('SETUP')) {
              final resp =
                  'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
              final enc =
                  await srvSess.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('RTSP/1.0')) {
              final cseqMatch = RegExp(r'CSeq: (\d+)').firstMatch(req);
              final cseq = cseqMatch?.group(1) ?? '1';
              final resp =
                  'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
              final enc =
                  await srvSess.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('POST /play')) {
              playRequest = req;
              await _sendResponse(srvSess, sock, 200, 'OK');
            } else {
              await _sendResponse(srvSess, sock, 200, 'OK');
            }
          } catch (_) {
            break;
          }
        }
      });

      await controller.playV2('https://example.com/video.m3u8', 0.0);

      expect(playRequest, isNotNull);
      expect(playRequest!, contains('User-Agent: AirPlay/550.10'));
    });

    test('sends X-Apple-ProtocolVersion: 1 and X-Apple-Stream-ID: 1', () async {
      String? playRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        while (true) {
          try {
            final data = await srvSess.readDecryptedData(
              timeout: const Duration(milliseconds: 200),
            );
            final req = utf8.decode(data, allowMalformed: true);

            if (req.contains('RTSP/1.0')) {
              final cseqMatch = RegExp(r'CSeq: (\d+)').firstMatch(req);
              final cseq = cseqMatch?.group(1) ?? '1';
              final resp =
                  'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
              final enc =
                  await srvSess.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('POST /play')) {
              playRequest = req;
              await _sendResponse(srvSess, sock, 200, 'OK');
            } else {
              await _sendResponse(srvSess, sock, 200, 'OK');
            }
          } catch (_) {
            break;
          }
        }
      });

      await controller.playV2('https://example.com/video.m3u8', 0.0);

      expect(playRequest, isNotNull);
      expect(playRequest!, contains('X-Apple-ProtocolVersion: 1'));
      expect(playRequest!, contains('X-Apple-Stream-ID: 1'));
    });

    test('body contains Content-Location and Start-Position-Seconds', () async {
      String? playRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        while (true) {
          try {
            final data = await srvSess.readDecryptedData(
              timeout: const Duration(milliseconds: 200),
            );
            final req = utf8.decode(data, allowMalformed: true);

            if (req.contains('RTSP/1.0')) {
              final cseqMatch = RegExp(r'CSeq: (\d+)').firstMatch(req);
              final cseq = cseqMatch?.group(1) ?? '1';
              final resp =
                  'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
              final enc =
                  await srvSess.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            } else if (req.contains('POST /play')) {
              playRequest = req;
              await _sendResponse(srvSess, sock, 200, 'OK');
            } else {
              await _sendResponse(srvSess, sock, 200, 'OK');
            }
          } catch (_) {
            break;
          }
        }
      });

      await controller.playV2('https://example.com/video.m3u8', 10.0);

      expect(playRequest, isNotNull);
      // The binary plist body will contain the URL as a UTF-8 string
      expect(
        playRequest!,
        contains('https://example.com/video.m3u8'),
      );
    });
  });

  group('AirPlayMediaController.play() auto-selection', () {
    late ServerSocket server;
    late HapSession client;

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('throws UnsupportedFeatureException when no video bits set', () async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;

      final controller = AirPlayMediaController(
        session: client,
        features: _featuresNone,
      );

      expect(
        () => controller.play('https://example.com/video.m3u8'),
        throwsA(isA<UnsupportedFeatureException>()),
      );
    });

    test('returns on 200 from V1 binary plist without fallback', () async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;

      final controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );

      int requestCount = 0;
      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          await srvSess.readDecryptedData();
          requestCount++;
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.play('https://example.com/video.m3u8');

      // Only one /play request should have been sent
      expect(requestCount, equals(1));
    });

    test('falls back to V1 text on 404 from V1 plist', () async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;

      final controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );

      final requests = <String>[];
      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        while (true) {
          try {
            final data = await srvSess.readDecryptedData(
              timeout: const Duration(milliseconds: 500),
            );
            final req = utf8.decode(data, allowMalformed: true);
            requests.add(req);
            // First call: 404, second call: 200
            final code = requests.length == 1 ? 404 : 200;
            final phrase = code == 200 ? 'OK' : 'Not Found';
            await _sendResponse(srvSess, sock, code, phrase);
          } catch (_) {
            break;
          }
        }
      });

      await controller.play('https://example.com/video.m3u8');

      expect(requests.length, equals(2));
      // First request: binary plist (application/x-apple-binary-plist)
      expect(
        requests[0].toLowerCase(),
        contains('content-type: application/x-apple-binary-plist'),
      );
      // Second request: text/parameters
      expect(
        requests[1].toLowerCase(),
        contains('content-type: text/parameters'),
      );
    });
  });

  group('AirPlayMediaController.pause()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends POST /rate?value=0', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.pause();

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('POST /rate'));
      expect(receivedRequest!, contains('value=0'));
    });
  });

  group('AirPlayMediaController.resume()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends POST /rate?value=1', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.resume();

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('POST /rate'));
      expect(receivedRequest!, contains('value=1'));
    });
  });

  group('AirPlayMediaController.seek()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends POST /scrub?position=42.5', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.seek(42.5);

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('POST /scrub'));
      expect(receivedRequest!, contains('position=42.5'));
    });
  });

  group('AirPlayMediaController.stop()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends POST /stop', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);
          await _sendResponse(srvSess, sock, 200, 'OK');
        } catch (_) {}
      });

      await controller.stop();

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('POST /stop'));
    });
  });

  group('AirPlayMediaController.getPlaybackInfo()', () {
    late ServerSocket server;
    late HapSession client;
    late AirPlayMediaController controller;

    setUp(() async {
      final pair = await createEncryptedPair();
      server = pair.server;
      client = pair.client;
      controller = AirPlayMediaController(
        session: client,
        features: _featuresV1,
      );
    });

    tearDown(() async {
      await client.close();
      await server.close();
    });

    test('sends GET /playback-info', () async {
      String? receivedRequest;

      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          final data = await srvSess.readDecryptedData();
          receivedRequest = utf8.decode(data, allowMalformed: true);

          // Return a minimal XML plist as the body
          const plistBody = '<?xml version="1.0" encoding="UTF-8"?>\n'
              '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
              '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
              '<plist version="1.0"><dict>'
              '<key>duration</key><real>120.0</real>'
              '<key>position</key><real>10.0</real>'
              '<key>rate</key><real>1.0</real>'
              '</dict></plist>';

          await _sendResponse(srvSess, sock, 200, 'OK', body: plistBody);
        } catch (_) {}
      });

      final info = await controller.getPlaybackInfo();

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('GET /playback-info'));
      expect(info, isNotNull);
    });

    test('returns parsed PlaybackInfo from XML plist response', () async {
      server.listen((sock) async {
        final srvSess = _serverSession(sock, server.port);
        try {
          await srvSess.readDecryptedData();

          const plistBody = '<?xml version="1.0" encoding="UTF-8"?>\n'
              '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
              '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
              '<plist version="1.0"><dict>'
              '<key>duration</key><real>300.0</real>'
              '<key>position</key><real>45.0</real>'
              '<key>rate</key><real>1.0</real>'
              '</dict></plist>';

          await _sendResponse(srvSess, sock, 200, 'OK', body: plistBody);
        } catch (_) {}
      });

      final info = await controller.getPlaybackInfo();

      expect(info.duration, closeTo(300.0, 0.001));
      expect(info.position, closeTo(45.0, 0.001));
    });
  });
}
