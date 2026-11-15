import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/airplay_auth.dart';
import 'package:dart_cast/src/protocols/airplay/auth/airplay_transient_auth.dart';
import 'package:dart_cast/src/protocols/airplay/auth/tlv8.dart';
import 'package:test/test.dart';

import 'srp_accessory.dart';

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
/// By default it plays the accessory side of SRP for real ([SrpAccessory]):
/// M2 carries a genuine salt and B for PIN `3939`, M3's proof is checked
/// (a wrong one gets `kTLVError_Authentication`), and M4 carries the real
/// accessory proof M2. [m4Proof] lets a test tamper with that proof.
class _MockHapServer {
  final ServerSocket _server;
  final List<_CapturedRequest> requests = [];

  /// Canned body for each successive `/pair-setup` POST, or `null` to run
  /// real SRP through [_accessory].
  final List<Uint8List>? pairSetupResponses;

  /// Status code to return for each successive `/pair-setup` POST.
  final List<int> pairSetupStatuses;

  /// Maps the real accessory proof to the one sent in M4 (`null` omits it).
  final Uint8List? Function(Uint8List realProof) m4Proof;

  final SrpAccessory _accessory;

  int _pairSetupCount = 0;
  Future<void> _replies = Future<void>.value();

  _MockHapServer._(
    this._server,
    this._accessory, {
    required this.pairSetupResponses,
    required this.pairSetupStatuses,
    required this.m4Proof,
  });

  int get port => _server.port;

  int get pairSetupCount => _pairSetupCount;

  static Future<_MockHapServer> start({
    List<Uint8List>? pairSetupResponses,
    List<int>? pairSetupStatuses,
    Uint8List? Function(Uint8List realProof)? m4Proof,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = _MockHapServer._(
      socket,
      await SrpAccessory.create(pin: AirPlayTransientPairing.transientPin),
      pairSetupResponses: pairSetupResponses,
      pairSetupStatuses: pairSetupStatuses ?? [200, 200],
      m4Proof: m4Proof ?? (proof) => proof,
    );
    socket.listen(server._handleConnection);
    return server;
  }

  Future<Uint8List> _srpResponse(int index, Uint8List requestBody) async {
    if (index == 0) {
      return Tlv8.encode([
        (Tlv8.tagSeqNo, [0x02]),
        (Tlv8.tagSalt, _accessory.salt),
        (Tlv8.tagPublicKey, _accessory.publicKey),
      ]);
    }
    final m3 = Tlv8.decode(requestBody);
    final realProof = await _accessory.verifyM1(
      m3[Tlv8.tagPublicKey] ?? const [],
      m3[Tlv8.tagProof] ?? const [],
    );
    if (realProof == null) {
      return Tlv8.encode([
        (Tlv8.tagSeqNo, [0x04]),
        (Tlv8.tagError, [0x02]), // kTLVError_Authentication
      ]);
    }
    final proof = m4Proof(realProof);
    return Tlv8.encode([
      (Tlv8.tagSeqNo, [0x04]),
      if (proof != null) (Tlv8.tagProof, proof),
    ]);
  }

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

      final path = requestLine[1];
      _replies = _replies.then((_) => _respond(socket, path, body));
    }
  }

  Future<void> _respond(Socket socket, String path, Uint8List request) async {
    if (path == '/pair-pin-start') {
      socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'));
      return;
    }

    final index = _pairSetupCount++;
    final status =
        index < pairSetupStatuses.length ? pairSetupStatuses[index] : 200;
    final canned = pairSetupResponses;
    final body =
        canned == null
            ? (index < 2 ? await _srpResponse(index, request) : Uint8List(0))
            : index < canned.length
            ? canned[index]
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
  Uint8List? Function(Uint8List realProof)? m4Proof,
}) async {
  final server = await _MockHapServer.start(
    pairSetupResponses: pairSetupResponses,
    pairSetupStatuses: pairSetupStatuses,
    m4Proof: m4Proof,
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

    test('accepts M4 carrying the real accessory proof', () async {
      final ctx = await _connect();
      addTearDown(() async {
        ctx.socket.destroy();
        await ctx.server.close();
      });

      final sharedKey = await ctx.pairing.execute();
      expect(sharedKey, hasLength(64));
    });

    test('throws when the M4 accessory proof is wrong', () async {
      final ctx = await _connect(m4Proof: (_) => Uint8List(64));
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
            contains('proof'),
          ),
        ),
      );
    });

    test('throws when M4 carries no accessory proof', () async {
      final ctx = await _connect(m4Proof: (_) => null);
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
            contains('proof'),
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
