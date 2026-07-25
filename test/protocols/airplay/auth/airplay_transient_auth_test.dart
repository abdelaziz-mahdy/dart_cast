import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/airplay_auth.dart';
import 'package:dart_cast/src/protocols/airplay/auth/airplay_transient_auth.dart';
import 'package:dart_cast/src/protocols/airplay/auth/tlv8.dart';
import 'package:test/test.dart';

/// One request captured by [_MockHapServer].
class _CapturedRequest {
  final String method;
  final String path;
  final Map<String, String> headers;
  final Uint8List body;

  _CapturedRequest(this.method, this.path, this.headers, this.body);

  Map<int, List<int>> get tlv => Tlv8.decode(body);
}

/// A raw TCP server that speaks just enough HAP to drive transient pairing.
///
/// It answers `/pair-setup` M1 with a plausible salt and SRP public key. The
/// client's SRP maths is exercised for real; only the accessory's side of the
/// proof check is skipped, which is what makes an offline test possible at
/// all. The wire shape — headers, TLV tags, message count — is the point.
class _MockHapServer {
  final ServerSocket _server;
  final List<_CapturedRequest> requests = [];

  /// Response body to return for each successive `/pair-setup` POST.
  final List<Uint8List> pairSetupResponses;

  /// Status code to return for each successive `/pair-setup` POST.
  final List<int> pairSetupStatuses;

  int _pairSetupCount = 0;

  _MockHapServer._(
    this._server, {
    required this.pairSetupResponses,
    required this.pairSetupStatuses,
  });

  int get port => _server.port;

  int get pairSetupCount => _pairSetupCount;

  static Future<_MockHapServer> start({
    List<Uint8List>? pairSetupResponses,
    List<int>? pairSetupStatuses,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _MockHapServer._(
      socket,
      pairSetupResponses: pairSetupResponses ?? [_defaultM2(), _defaultM4()],
      pairSetupStatuses: pairSetupStatuses ?? [200, 200],
    );
    socket.listen(server._handleConnection);
    return server;
  }

  static Uint8List _defaultM2() {
    final random = Random(1234);
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    // SRP-3072 public key B is 384 bytes; any non-zero value works here.
    final publicKey = List<int>.generate(384, (i) => (i * 7 + 3) & 0xFF);
    return Tlv8.encode([
      (Tlv8.tagSeqNo, [0x02]),
      (Tlv8.tagSalt, salt),
      (Tlv8.tagPublicKey, publicKey),
    ]);
  }

  static Uint8List _defaultM4() => Tlv8.encode([
    (Tlv8.tagSeqNo, [0x04]),
  ]);

  void _handleConnection(Socket socket) {
    final buffer = BytesBuilder(copy: false);
    socket.listen(
      (data) {
        buffer.add(data);
        _drain(socket, buffer);
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  void _drain(Socket socket, BytesBuilder buffer) {
    while (true) {
      final bytes = Uint8List.fromList(buffer.toBytes());
      final headerEnd = _findHeaderEnd(bytes);
      if (headerEnd == -1) return;

      final headerText = utf8.decode(bytes.sublist(0, headerEnd));
      final lines = headerText.split('\r\n');
      final requestLine = lines.first.split(' ');
      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).trim().toLowerCase()] =
              line.substring(colon + 1).trim();
        }
      }

      final contentLength = int.tryParse(headers['content-length'] ?? '0') ?? 0;
      final bodyStart = headerEnd + 4;
      if (bytes.length < bodyStart + contentLength) return;

      final body = Uint8List.fromList(
        bytes.sublist(bodyStart, bodyStart + contentLength),
      );
      requests.add(
        _CapturedRequest(requestLine[0], requestLine[1], headers, body),
      );

      buffer.clear();
      buffer.add(bytes.sublist(bodyStart + contentLength));

      _respond(socket, requestLine[1]);
    }
  }

  void _respond(Socket socket, String path) {
    if (path == '/pair-pin-start') {
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'));
      return;
    }

    final index = _pairSetupCount++;
    final status =
        index < pairSetupStatuses.length ? pairSetupStatuses[index] : 200;
    final body =
        index < pairSetupResponses.length
            ? pairSetupResponses[index]
            : Uint8List(0);

    socket.add(
      utf8.encode(
        'HTTP/1.1 $status ${status == 200 ? 'OK' : 'Error'}\r\n'
        'Content-Length: ${body.length}\r\n\r\n',
      ),
    );
    socket.add(body);
  }

  static int _findHeaderEnd(Uint8List data) {
    for (int i = 0; i + 3 < data.length; i++) {
      if (data[i] == 0x0D &&
          data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D &&
          data[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
  }

  Future<void> close() => _server.close();
}

Future<
  ({AirPlayTransientPairing pairing, Socket socket, _MockHapServer server})
>
_connect({
  List<Uint8List>? pairSetupResponses,
  List<int>? pairSetupStatuses,
}) async {
  final server = await _MockHapServer.start(
    pairSetupResponses: pairSetupResponses,
    pairSetupStatuses: pairSetupStatuses,
  );
  final socket = await Socket.connect('127.0.0.1', server.port);
  final pairing = AirPlayTransientPairing.withSocket(
    socket,
    host: '127.0.0.1',
    port: server.port,
  );
  return (pairing: pairing, socket: socket, server: server);
}

void main() {
  group('AirPlayTransientPairing', () {
    test('sends X-Apple-HKP: 4 on every pairing request', () async {
      final ctx = await _connect();
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await ctx.pairing.execute();

      expect(ctx.server.requests, isNotEmpty);
      for (final request in ctx.server.requests) {
        expect(
          request.headers['x-apple-hkp'],
          equals('4'),
          reason: '${request.path} used the PIN-based header instead',
        );
      }
    });

    test(
      'M1 carries Method 0x00, SeqNo 0x01 and the TransientPairing flag',
      () async {
        final ctx = await _connect();
        addTearDown(() async {
          ctx.socket.destroy();
          await ctx.server.close();
        });

        await ctx.pairing.execute();

        final m1 =
            ctx.server.requests.firstWhere((r) => r.path == '/pair-setup').tlv;
        expect(m1[Tlv8.tagMethod], equals([0x00]));
        expect(m1[Tlv8.tagSeqNo], equals([0x01]));
        expect(
          m1[Tlv8.tagFlags],
          equals([AirPlayTransientPairing.transientPairingFlag]),
          reason: 'TLV tag 0x13 must carry Flags.TransientPairing (0x10)',
        );
      },
    );

    test('M3 carries SeqNo 0x03 with the SRP public key and proof', () async {
      final ctx = await _connect();
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await ctx.pairing.execute();

      final pairSetups =
          ctx.server.requests.where((r) => r.path == '/pair-setup').toList();
      expect(pairSetups, hasLength(2));

      final m3 = pairSetups[1].tlv;
      expect(m3[Tlv8.tagSeqNo], equals([0x03]));
      expect(m3[Tlv8.tagPublicKey], isNotNull);
      expect(m3[Tlv8.tagPublicKey], hasLength(384));
      expect(m3[Tlv8.tagProof], isNotNull);
      expect(m3[Tlv8.tagProof], hasLength(64), reason: 'SHA-512 proof');
    });

    test('stops at M4 — no M5/M6 credential exchange', () async {
      final ctx = await _connect();
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await ctx.pairing.execute();

      expect(
        ctx.server.pairSetupCount,
        equals(2),
        reason:
            'transient pairing is M1-M4 only; a third POST means M5 was '
            'sent and credentials would be persisted',
      );
    });

    test('pokes /pair-pin-start first, as pyatv does', () async {
      final ctx = await _connect();
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await ctx.pairing.execute();

      expect(ctx.server.requests.first.path, equals('/pair-pin-start'));
    });

    test('returns a 64-byte SRP shared key for HAP key derivation', () async {
      final ctx = await _connect();
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      final sharedKey = await ctx.pairing.execute();

      expect(sharedKey, hasLength(64), reason: 'SHA-512 of the SRP secret');
      expect(sharedKey.any((b) => b != 0), isTrue);
    });

    test('throws when the receiver reports a TLV error', () async {
      final ctx = await _connect(
        pairSetupResponses: [
          Tlv8.encode([
            (Tlv8.tagSeqNo, [0x02]),
            (Tlv8.tagError, [0x02]), // kTLVError_Authentication
          ]),
        ],
      );
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await expectLater(
        ctx.pairing.execute(),
        throwsA(
          isA<AirPlayAuthException>().having(
            (e) => e.message,
            'message',
            contains('M2 error'),
          ),
        ),
      );
    });

    test('throws when M2 omits the salt or public key', () async {
      final ctx = await _connect(
        pairSetupResponses: [
          Tlv8.encode([
            (Tlv8.tagSeqNo, [0x02]),
          ]),
        ],
      );
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await expectLater(
        ctx.pairing.execute(),
        throwsA(
          isA<AirPlayAuthException>().having(
            (e) => e.message,
            'message',
            contains('missing salt or public key'),
          ),
        ),
      );
    });

    test('throws when /pair-setup answers with a non-200', () async {
      final ctx = await _connect(
        pairSetupResponses: [Uint8List(0)],
        pairSetupStatuses: [470],
      );
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      await expectLater(
        ctx.pairing.execute(),
        throwsA(
          isA<AirPlayAuthException>().having(
            (e) => e.message,
            'message',
            contains('470'),
          ),
        ),
      );
    });

    test(
      'releaseSocket detaches the pairing reader from the shared stream',
      () async {
        final server = await _MockHapServer.start();
        final socket = await Socket.connect('127.0.0.1', server.port);
        addTearDown(() async {
          socket.destroy();
          await server.close();
        });

        // Mirrors how AirPlaySession shares one socket between pairing and the
        // encrypted session.
        final broadcast = StreamController<Uint8List>.broadcast();
        socket.listen(
          (data) => broadcast.add(Uint8List.fromList(data)),
          onError: (Object _) {},
          onDone: broadcast.close,
        );

        final pairing = AirPlayTransientPairing.withSocket(
          socket,
          host: '127.0.0.1',
          port: server.port,
          dataStream: broadcast.stream,
        );

        await pairing.execute();
        expect(broadcast.hasListener, isTrue);

        await pairing.releaseSocket();

        // Without this the pairing reader keeps a copy of every encrypted byte
        // for the life of the session.
        expect(broadcast.hasListener, isFalse);
      },
    );
  });
}
