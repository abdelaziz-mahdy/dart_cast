import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dart_cast/src/protocols/airplay/auth/airplay_auth.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_credentials.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_srp.dart';
import 'package:dart_cast/src/protocols/airplay/auth/tlv8.dart';
import 'package:test/test.dart';

import 'srp_accessory.dart';

/// Serves `/pair-setup` with real accessory-side SRP for PIN `1234`.
///
/// M4 carries `m4Proof(realProof)`; M5 is answered with HTTP 500 so a test
/// can tell "got past the M4 proof check" from "stopped at M4".
Future<({HttpServer server, List<int> seqNos})> _startSrpPairSetupServer({
  required Uint8List? Function(Uint8List realProof) m4Proof,
}) async {
  final accessory = await SrpAccessory.create(pin: '1234');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seqNos = <int>[];
  server.listen((request) async {
    final body = await request.fold<List<int>>(
      [],
      (prev, chunk) => [...prev, ...chunk],
    );
    final tlv = Tlv8.decode(body);
    final seqNo = tlv[Tlv8.tagSeqNo]?.first ?? 0;
    seqNos.add(seqNo);
    Uint8List reply;
    if (seqNo == 1) {
      reply = Tlv8.encode([
        (Tlv8.tagSeqNo, [0x02]),
        (Tlv8.tagSalt, accessory.salt),
        (Tlv8.tagPublicKey, accessory.publicKey),
      ]);
    } else if (seqNo == 3) {
      final realProof = await accessory.verifyM1(
        tlv[Tlv8.tagPublicKey] ?? const [],
        tlv[Tlv8.tagProof] ?? const [],
      );
      final proof = realProof == null ? null : m4Proof(realProof);
      reply = Tlv8.encode([
        (Tlv8.tagSeqNo, [0x04]),
        if (realProof == null) (Tlv8.tagError, [0x02]),
        if (proof != null) (Tlv8.tagProof, proof),
      ]);
    } else {
      request.response.statusCode = 500;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = 200
      ..add(reply);
    await request.response.close();
  });
  return (server: server, seqNos: seqNos);
}

void main() {
  group('AirPlayPairSetup', () {
    test('startPinDisplay sends POST to /pair-pin-start', () async {
      // Create a mock server
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? receivedPath;
      String? receivedMethod;

      server.listen((request) {
        receivedPath = request.uri.path;
        receivedMethod = request.method;
        request.response
          ..statusCode = 200
          ..close();
      });

      try {
        final pairSetup = AirPlayPairSetup(
          host: '127.0.0.1',
          port: server.port,
        );

        pairSetup.startPinDisplay();
        // Give the fire-and-forget request time to arrive
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(receivedPath, equals('/pair-pin-start'));
        expect(receivedMethod, equals('POST'));
      } finally {
        await server.close();
      }
    });

    test('pairSetup M1 sends correct TLV', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      List<int>? receivedBody;

      server.listen((request) async {
        if (request.uri.path == '/pair-setup') {
          receivedBody = await request.fold<List<int>>(
            [],
            (prev, chunk) => [...prev, ...chunk],
          );

          // Return an error response to stop the flow after M1
          final errorTlv = Tlv8.encode([
            (Tlv8.tagSeqNo, [0x02]),
            (Tlv8.tagError, [0x06]), // Unavailable
          ]);
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType('application', 'octet-stream')
            ..add(errorTlv)
            ..close();
        } else {
          request.response
            ..statusCode = 200
            ..close();
        }
      });

      try {
        final pairSetup = AirPlayPairSetup(
          host: '127.0.0.1',
          port: server.port,
        );

        await expectLater(
          pairSetup.pairSetup(pin: '1234', clientId: 'test-client'),
          throwsA(isA<AirPlayAuthException>()),
        );

        // The request has completed by now
        expect(receivedBody, isNotNull);
        final decoded = Tlv8.decode(receivedBody!);
        expect(decoded[Tlv8.tagMethod], equals([0x00])); // PairSetup
        expect(decoded[Tlv8.tagSeqNo], equals([0x01])); // Step 1
      } finally {
        await server.close();
      }
    });

    test('pairSetup rejects a wrong M4 accessory proof', () async {
      final ctx = await _startSrpPairSetupServer(m4Proof: (_) => Uint8List(64));
      addTearDown(() => ctx.server.close(force: true));

      await expectLater(
        AirPlayPairSetup(
          host: '127.0.0.1',
          port: ctx.server.port,
        ).pairSetup(pin: '1234', clientId: 'test-client'),
        throwsA(
          isA<AirPlayAuthException>().having(
            (e) => e.message,
            'message',
            contains('proof'),
          ),
        ),
      );
      expect(ctx.seqNos, equals([1, 3]), reason: 'M5 must not be sent');
    });

    test('pairSetup rejects an M4 without an accessory proof', () async {
      final ctx = await _startSrpPairSetupServer(m4Proof: (_) => null);
      addTearDown(() => ctx.server.close(force: true));

      await expectLater(
        AirPlayPairSetup(
          host: '127.0.0.1',
          port: ctx.server.port,
        ).pairSetup(pin: '1234', clientId: 'test-client'),
        throwsA(
          isA<AirPlayAuthException>().having(
            (e) => e.message,
            'message',
            contains('proof'),
          ),
        ),
      );
      expect(ctx.seqNos, equals([1, 3]), reason: 'M5 must not be sent');
    });

    test(
      'pairSetup accepts the real M4 accessory proof and sends M5',
      () async {
        final ctx = await _startSrpPairSetupServer(m4Proof: (proof) => proof);
        addTearDown(() => ctx.server.close(force: true));

        await expectLater(
          AirPlayPairSetup(
            host: '127.0.0.1',
            port: ctx.server.port,
          ).pairSetup(pin: '1234', clientId: 'test-client'),
          throwsA(
            isA<AirPlayAuthException>().having(
              (e) => e.message,
              'message',
              contains('HTTP 500'),
            ),
          ),
        );
        expect(ctx.seqNos, equals([1, 3, 5]));
      },
    );

    test('pairSetup throws on HTTP 500 error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) {
        request.response
          ..statusCode = 500
          ..close();
      });

      try {
        final pairSetup = AirPlayPairSetup(
          host: '127.0.0.1',
          port: server.port,
        );

        await expectLater(
          pairSetup.pairSetup(pin: '1234', clientId: 'test-client'),
          throwsA(isA<AirPlayAuthException>()),
        );
      } finally {
        await server.close();
      }
    });
  });

  group('AirPlayPairVerify', () {
    test('execute sends M1 with X25519 public key', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      List<int>? receivedBody;

      server.listen((request) async {
        if (request.uri.path == '/pair-verify') {
          receivedBody = await request.fold<List<int>>(
            [],
            (prev, chunk) => [...prev, ...chunk],
          );

          // Return error to stop the flow
          final errorTlv = Tlv8.encode([
            (Tlv8.tagSeqNo, [0x02]),
            (Tlv8.tagError, [0x02]), // Authentication error
          ]);
          request.response
            ..statusCode = 200
            ..add(errorTlv)
            ..close();
        } else {
          request.response
            ..statusCode = 200
            ..close();
        }
      });

      try {
        final pairVerify = AirPlayPairVerify(
          host: '127.0.0.1',
          port: server.port,
        );

        // Create dummy credentials
        final ed25519 = Ed25519();
        final keyPair = await ed25519.newKeyPair();
        final pubKey = await keyPair.extractPublicKey();
        final privKeyBytes = await keyPair.extractPrivateKeyBytes();

        final credentials = HapCredentials(
          clientPrivateKey: Uint8List.fromList(privKeyBytes),
          clientPublicKey: Uint8List.fromList(pubKey.bytes),
          clientId: 'test-client',
          devicePublicKey: Uint8List.fromList(pubKey.bytes),
          deviceId: 'test-device',
        );

        await expectLater(
          pairVerify.execute(credentials),
          throwsA(isA<AirPlayAuthException>()),
        );

        if (receivedBody != null) {
          final decoded = Tlv8.decode(receivedBody!);
          expect(decoded[Tlv8.tagSeqNo], equals([0x01]));
          // X25519 public key should be 32 bytes
          expect(decoded[Tlv8.tagPublicKey]?.length, equals(32));
        }
      } finally {
        await server.close();
      }
    });

    test('execute throws on HTTP 403 error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) {
        request.response
          ..statusCode = 403
          ..close();
      });

      try {
        final pairVerify = AirPlayPairVerify(
          host: '127.0.0.1',
          port: server.port,
        );

        final ed25519 = Ed25519();
        final keyPair = await ed25519.newKeyPair();
        final pubKey = await keyPair.extractPublicKey();
        final privKeyBytes = await keyPair.extractPrivateKeyBytes();

        final credentials = HapCredentials(
          clientPrivateKey: Uint8List.fromList(privKeyBytes),
          clientPublicKey: Uint8List.fromList(pubKey.bytes),
          clientId: 'test-client',
          devicePublicKey: Uint8List.fromList(pubKey.bytes),
          deviceId: 'test-device',
        );

        await expectLater(
          pairVerify.execute(credentials),
          throwsA(isA<AirPlayAuthException>()),
        );
      } finally {
        await server.close();
      }
    });
  });

  group('AirPlayAuthException', () {
    test('toString includes message', () {
      final exception = AirPlayAuthException('test error');
      expect(exception.toString(), contains('test error'));
    });
  });

  group('Full pair-verify simulation', () {
    test('complete pair-verify with simulated device', () async {
      // Generate Ed25519 key pairs for both sides
      final ed25519 = Ed25519();
      final deviceEdKeyPair = await ed25519.newKeyPair();
      final deviceEdPublicKey = await deviceEdKeyPair.extractPublicKey();

      final clientEdKeyPair = await ed25519.newKeyPair();
      final clientEdPublicKey = await clientEdKeyPair.extractPublicKey();
      final clientPrivateKeyBytes =
          await clientEdKeyPair.extractPrivateKeyBytes();

      final credentials = HapCredentials(
        clientPrivateKey: Uint8List.fromList(clientPrivateKeyBytes),
        clientPublicKey: Uint8List.fromList(clientEdPublicKey.bytes),
        clientId: 'test-client',
        devicePublicKey: Uint8List.fromList(deviceEdPublicKey.bytes),
        deviceId: 'test-device',
      );

      // Simulate the device side
      final x25519 = X25519();
      final deviceX25519KeyPair = await x25519.newKeyPair();
      final deviceX25519PublicKey =
          await deviceX25519KeyPair.extractPublicKey();

      int requestCount = 0;
      Uint8List? clientX25519PublicKey;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) async {
        if (request.uri.path == '/pair-verify') {
          final body = await request.fold<List<int>>(
            [],
            (prev, chunk) => [...prev, ...chunk],
          );
          final tlv = Tlv8.decode(body);
          requestCount++;

          if (requestCount == 1) {
            // M1: Client sends ephemeral X25519 public key
            clientX25519PublicKey = Uint8List.fromList(tlv[Tlv8.tagPublicKey]!);

            // Device computes shared secret
            final sharedSecret = await x25519.sharedSecretKey(
              keyPair: deviceX25519KeyPair,
              remotePublicKey: SimplePublicKey(
                clientX25519PublicKey!,
                type: KeyPairType.x25519,
              ),
            );
            final sharedSecretBytes = Uint8List.fromList(
              await sharedSecret.extractBytes(),
            );

            // Derive session key
            final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
            final sessionKeyObj = await hkdf.deriveKey(
              secretKey: SecretKey(sharedSecretBytes),
              nonce: utf8.encode('Pair-Verify-Encrypt-Salt'),
              info: utf8.encode('Pair-Verify-Encrypt-Info'),
            );
            final sessionKey = Uint8List.fromList(
              await sessionKeyObj.extractBytes(),
            );

            // Build device info: deviceX25519PublicKey | deviceId | clientX25519PublicKey
            final deviceIdBytes = utf8.encode('test-device');
            final deviceInfo = Uint8List.fromList([
              ...deviceX25519PublicKey.bytes,
              ...deviceIdBytes,
              ...clientX25519PublicKey!,
            ]);

            // Sign with device Ed25519 key
            final signature = await ed25519.sign(
              deviceInfo,
              keyPair: deviceEdKeyPair,
            );

            // Build challenge sub-TLV
            final challengeTlv = Tlv8.encode([
              (Tlv8.tagIdentifier, deviceIdBytes),
              (Tlv8.tagSignature, signature.bytes),
            ]);

            // Encrypt challenge
            final nonce = HapSrp.padNonce('PV-Msg02');
            final algorithm = Chacha20.poly1305Aead();
            final secretBox = await algorithm.encrypt(
              challengeTlv,
              secretKey: SecretKey(sessionKey),
              nonce: nonce,
            );
            final encryptedChallenge = Uint8List.fromList([
              ...secretBox.cipherText,
              ...secretBox.mac.bytes,
            ]);

            // Send M2 response
            final m2 = Tlv8.encode([
              (Tlv8.tagSeqNo, [0x02]),
              (Tlv8.tagPublicKey, deviceX25519PublicKey.bytes),
              (Tlv8.tagEncryptedData, encryptedChallenge),
            ]);

            request.response
              ..statusCode = 200
              ..add(m2)
              ..close();
          } else if (requestCount == 2) {
            // M3: Client sends encrypted response
            // Verify it has SeqNo=3 and EncryptedData
            expect(tlv[Tlv8.tagSeqNo], equals([0x03]));
            expect(tlv.containsKey(Tlv8.tagEncryptedData), isTrue);

            // Send M4 (success — just SeqNo 4, no error)
            final m4 = Tlv8.encode([
              (Tlv8.tagSeqNo, [0x04]),
            ]);
            request.response
              ..statusCode = 200
              ..add(m4)
              ..close();
          }
        } else {
          request.response
            ..statusCode = 200
            ..close();
        }
      });

      try {
        final pairVerify = AirPlayPairVerify(
          host: '127.0.0.1',
          port: server.port,
        );

        final sharedSecret = await pairVerify.execute(credentials);

        expect(sharedSecret.length, equals(32));
        expect(requestCount, equals(2));
      } finally {
        await server.close();
      }
    });
  });
}
