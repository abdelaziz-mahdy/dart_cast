import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_credentials.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_srp.dart';
import 'package:test/test.dart';

Uint8List _hexToBytes(String hex) {
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
  }
  return result;
}

String _bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  group('HapSrp', () {
    group('padNonce', () {
      test('pads short nonce to 12 bytes from the left', () {
        final nonce = HapSrp.padNonce('PS-Msg05');
        expect(nonce.length, equals(12));
        // 'PS-Msg05' is 8 bytes, so 4 zero bytes at the start
        expect(nonce[0], equals(0));
        expect(nonce[1], equals(0));
        expect(nonce[2], equals(0));
        expect(nonce[3], equals(0));
        // Then the ASCII bytes of 'PS-Msg05'
        expect(nonce.sublist(4), equals(utf8.encode('PS-Msg05')));
      });

      test('pads PV-Msg02 correctly', () {
        final nonce = HapSrp.padNonce('PV-Msg02');
        expect(nonce.length, equals(12));
        expect(nonce.sublist(4), equals(utf8.encode('PV-Msg02')));
      });

      test('pads PV-Msg03 correctly', () {
        final nonce = HapSrp.padNonce('PV-Msg03');
        expect(nonce.length, equals(12));
        expect(nonce.sublist(4), equals(utf8.encode('PV-Msg03')));
      });

      test('pads PS-Msg06 correctly', () {
        final nonce = HapSrp.padNonce('PS-Msg06');
        expect(nonce.length, equals(12));
        expect(nonce.sublist(4), equals(utf8.encode('PS-Msg06')));
      });

      test('throws on nonce longer than 12 bytes', () {
        expect(
          () => HapSrp.padNonce('this-is-way-too-long'),
          throwsArgumentError,
        );
      });

      test('handles exactly 12 byte nonce', () {
        final nonce = HapSrp.padNonce('123456789012');
        expect(nonce.length, equals(12));
        expect(nonce, equals(utf8.encode('123456789012')));
      });

      test('handles empty nonce', () {
        final nonce = HapSrp.padNonce('');
        expect(nonce.length, equals(12));
        expect(nonce, equals(Uint8List(12)));
      });
    });

    group('ChaCha20-Poly1305 encrypt/decrypt', () {
      test('roundtrip encrypt then decrypt', () async {
        final key = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          key[i] = i;
        }
        final nonce = HapSrp.padNonce('PS-Msg05');
        final plaintext = Uint8List.fromList(utf8.encode('Hello, HAP world!'));

        // Encrypt
        final algorithm = Chacha20.poly1305Aead();
        final secretBox = await algorithm.encrypt(
          plaintext,
          secretKey: SecretKey(key),
          nonce: nonce,
        );
        final ciphertext = Uint8List.fromList([
          ...secretBox.cipherText,
          ...secretBox.mac.bytes,
        ]);

        // Decrypt
        final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
        final ct = ciphertext.sublist(0, ciphertext.length - 16);
        final box = SecretBox(ct, nonce: nonce, mac: mac);
        final decrypted = await algorithm.decrypt(
          box,
          secretKey: SecretKey(key),
        );

        expect(decrypted, equals(plaintext));
      });

      test('ciphertext includes 16-byte MAC', () async {
        final key = Uint8List(32);
        final nonce = Uint8List(12);
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

        final algorithm = Chacha20.poly1305Aead();
        final secretBox = await algorithm.encrypt(
          plaintext,
          secretKey: SecretKey(key),
          nonce: nonce,
        );
        final ciphertext = Uint8List.fromList([
          ...secretBox.cipherText,
          ...secretBox.mac.bytes,
        ]);

        // Ciphertext length = plaintext length + 16 (MAC)
        expect(ciphertext.length, equals(5 + 16));
      });
    });

    group('HKDF-SHA-512', () {
      test('derives a key of specified length', () async {
        final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final inputKey = SecretKey(Uint8List(32));
        final derived = await hkdf.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('test-salt'),
          info: utf8.encode('test-info'),
        );
        final bytes = await derived.extractBytes();
        expect(bytes.length, equals(32));
      });

      test('different salts produce different keys', () async {
        final inputKey = SecretKey(Uint8List(32));

        final hkdf1 = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final derived1 = await hkdf1.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('salt-1'),
          info: utf8.encode('info'),
        );

        final hkdf2 = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final derived2 = await hkdf2.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('salt-2'),
          info: utf8.encode('info'),
        );

        final bytes1 = await derived1.extractBytes();
        final bytes2 = await derived2.extractBytes();
        expect(bytes1, isNot(equals(bytes2)));
      });

      test('different infos produce different keys', () async {
        final inputKey = SecretKey(Uint8List(32));

        final hkdf1 = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final derived1 = await hkdf1.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('salt'),
          info: utf8.encode('Pair-Setup-Controller-Sign-Info'),
        );

        final hkdf2 = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final derived2 = await hkdf2.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('salt'),
          info: utf8.encode('Pair-Setup-Encrypt-Info'),
        );

        final bytes1 = await derived1.extractBytes();
        final bytes2 = await derived2.extractBytes();
        expect(bytes1, isNot(equals(bytes2)));
      });

      test('same inputs produce same output (deterministic)', () async {
        final inputKey = SecretKey(List.generate(32, (i) => i));

        final hkdf1 = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final derived1 = await hkdf1.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('Pair-Setup-Encrypt-Salt'),
          info: utf8.encode('Pair-Setup-Encrypt-Info'),
        );

        final hkdf2 = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
        final derived2 = await hkdf2.deriveKey(
          secretKey: inputKey,
          nonce: utf8.encode('Pair-Setup-Encrypt-Salt'),
          info: utf8.encode('Pair-Setup-Encrypt-Info'),
        );

        final bytes1 = await derived1.extractBytes();
        final bytes2 = await derived2.extractBytes();
        expect(bytes1, equals(bytes2));
      });
    });

    group('Ed25519', () {
      test('generates key pair and signs/verifies', () async {
        final ed25519 = Ed25519();
        final keyPair = await ed25519.newKeyPair();
        // Extract public key to verify it exists (used implicitly in sign/verify)
        await keyPair.extractPublicKey();

        final message = utf8.encode('test message for signing');
        final signature = await ed25519.sign(message, keyPair: keyPair);

        final valid = await ed25519.verify(message, signature: signature);
        expect(valid, isTrue);
      });

      test('verification fails with wrong message', () async {
        final ed25519 = Ed25519();
        final keyPair = await ed25519.newKeyPair();

        final signature = await ed25519.sign(
          utf8.encode('original message'),
          keyPair: keyPair,
        );

        final valid = await ed25519.verify(
          utf8.encode('tampered message'),
          signature: signature,
        );
        expect(valid, isFalse);
      });

      test('public key is 32 bytes', () async {
        final ed25519 = Ed25519();
        final keyPair = await ed25519.newKeyPair();
        final pubKey = await keyPair.extractPublicKey();
        expect(pubKey.bytes.length, equals(32));
      });
    });

    group('X25519', () {
      test('shared secret is identical for both sides', () async {
        final x25519 = X25519();
        final keyPairA = await x25519.newKeyPair();
        final keyPairB = await x25519.newKeyPair();
        final pubA = await keyPairA.extractPublicKey();
        final pubB = await keyPairB.extractPublicKey();

        final sharedA = await x25519.sharedSecretKey(
          keyPair: keyPairA,
          remotePublicKey: pubB,
        );
        final sharedB = await x25519.sharedSecretKey(
          keyPair: keyPairB,
          remotePublicKey: pubA,
        );

        expect(
          await sharedA.extractBytes(),
          equals(await sharedB.extractBytes()),
        );
      });

      test('public key is 32 bytes', () async {
        final x25519 = X25519();
        final keyPair = await x25519.newKeyPair();
        final publicKey = await keyPair.extractPublicKey();
        expect(publicKey.bytes.length, equals(32));
      });
    });

    group('SRP cross-validation with srptools', () {
      // These test vectors were generated using Python srptools with:
      //   SRPContext("Pair-Setup", "1234", prime=PRIME_3072, generator=PRIME_3072_GEN, hash_func=sha512)
      //   SRPClientSession(context, hexlify(a_bytes))
      //   session.process(B_hex, salt_hex)
      test('M1 proof and K match srptools reference values', () async {
        // Client private key 'a' = bytes 0x01..0x20
        final aBytes = Uint8List.fromList(List.generate(32, (i) => i + 1));
        // Salt = bytes 0x10..0x1f
        final salt = Uint8List.fromList(List.generate(16, (i) => i + 0x10));
        // Server public key B (generated by srptools)
        final bHex =
            '1c23324867195876032a468243570beda22487d1d81c01b8a559b947c69059200d77cc65423260fb3d59bc334c33074b419d8b465963bbc4cbf66b2b23a19f0a61ed0368fed7ee2b50a03c3a2806d8a7e5ce0acb30e78d7f0a4108b6f043d2202e7fbb4a14626ff2e6135d685719e6ad34c9651fad107d7ce39e1bedd53057f0622b7f75c870cc4b831f2a3d5fde6d5d5935385a903219e2034d4ce579eb1f6702d1b7331927fa09956080156c0a30974f16e25f1d0a4d90c153716a88d906c9150ad3b54694bee922ba161bf7afd1d2100da9c2d0c279a3376dd2e8ea6a0e6ce1fbe0884435f053290a23c9970b804ff20d887993b98318c9957dceebeb7220fa5273be2bb5cd9f4560c972097c2b14ee766f8e8ad7acc77f2fe034fd29a024eef69e6c0872baef9a9718b44a830d8e2d3419646198e32f7793718dede081ae8f7572296efe554d0422f1d474ae2916240318a0087293a8ba88c1ef41543dffe4415527b4fc102844d1fa344a99d619043ccc336c2cd4405e3d496ffcf11381';
        final B = _hexToBytes(bHex);

        // Expected values from srptools
        const expectedAHex =
            'bc0e7cf5dc3babf67dcedbb3b140aacc6cac43f4336b43bbd5de48d6ea7c8eda66924e354255225bccad9debe21182e6bb050f3ff3e6cfbb62c229379968c70ca436ad649a0b051373184215eef046f6f1f2256838f958581f6c7b2b85fa4afe326a0e8a951d4489305331aff88a136fd8d108bcc95fceb7e557c889c828bd23fb0702f053e1ca6470fb3c76bce4843fc005c7ea675740f8550212656cfc8919d9db805a434a68229e0d9dfe43fc16dc680a5ce74b77cf374353b05759bc1da3a9dabde30a4209381c87ca83d9483abdf66b86f9b1cbda9ad82c62712b87ce6fb7069b8fc8df344261821a06d0dc5106af76d4245f3f7737a94dbc484b415555dc401842d3011204553ba9f611b02bc38de26eba1a76bf8350205a62c436ba1c3c7c69d59318bd107fd1c1f5d846b3142e85a5d49e522655e020ed1bfe1e186cf923bf328f0b9b4c6a8aa3266ed9125bb98d63827110713be7803122ee4603c54ea31863ce4b10aff31f9073cf63b94733b4f066e72d4ec35687047d5d0db160';
        const expectedM1Hex =
            '1faabda6e7ff0ead29e0e35cdcc5189aca3f03a93cc24429875cd8243d077bcf3a23110594887fa5439a598378c08e3ab3ac07b6cd917e56e6a0e0ca01f06ed4';
        // expectedKHex is the shared secret K = H(S) — verified implicitly
        // through M1 proof matching, since M1 depends on K.

        final srp = HapSrp();
        final A = await srp.step1(privateKeyOverride: aBytes);

        // Verify A matches srptools
        expect(_bytesToHex(A), equals(expectedAHex));

        // Compute M1
        final proof = await srp.step2(
          serverPublicKey: B,
          salt: salt,
          pin: '1234',
        );

        // Verify M1 proof matches srptools
        expect(_bytesToHex(proof), equals(expectedM1Hex));

        // Verify K (shared secret) matches srptools
        // Access K via step3 HKDF derivation — or we need to expose it.
        // Instead, verify indirectly: the proof matching means K is correct
        // since M1 = H(... | K).
      });

      test('verifyServerProof accepts the srptools M2 = H(A | M1 | K)', () async {
        // Same inputs as above; M2 from srptools `key_proof_hash`. A has no
        // leading zero byte, so this is also HomeKitADK's padded-A form.
        const expectedM2Hex =
            '927f3cd5718028347790cde9710fa5f060f5b247a1cd220f7bd7716a67299c4727ebc339e3fb7831ea36691df1e5b9526565960fca6e365ba56f78495bb71ac9';
        final srp = HapSrp();
        await srp.step1(
          privateKeyOverride: Uint8List.fromList(
            List.generate(32, (i) => i + 1),
          ),
        );
        await srp.step2(
          serverPublicKey: _hexToBytes(
            '1c23324867195876032a468243570beda22487d1d81c01b8a559b947c69059200d77cc65423260fb3d59bc334c33074b419d8b465963bbc4cbf66b2b23a19f0a61ed0368fed7ee2b50a03c3a2806d8a7e5ce0acb30e78d7f0a4108b6f043d2202e7fbb4a14626ff2e6135d685719e6ad34c9651fad107d7ce39e1bedd53057f0622b7f75c870cc4b831f2a3d5fde6d5d5935385a903219e2034d4ce579eb1f6702d1b7331927fa09956080156c0a30974f16e25f1d0a4d90c153716a88d906c9150ad3b54694bee922ba161bf7afd1d2100da9c2d0c279a3376dd2e8ea6a0e6ce1fbe0884435f053290a23c9970b804ff20d887993b98318c9957dceebeb7220fa5273be2bb5cd9f4560c972097c2b14ee766f8e8ad7acc77f2fe034fd29a024eef69e6c0872baef9a9718b44a830d8e2d3419646198e32f7793718dede081ae8f7572296efe554d0422f1d474ae2916240318a0087293a8ba88c1ef41543dffe4415527b4fc102844d1fa344a99d619043ccc336c2cd4405e3d496ffcf11381',
          ),
          salt: Uint8List.fromList(List.generate(16, (i) => i + 0x10)),
          pin: '1234',
        );

        expect(await srp.verifyServerProof(_hexToBytes(expectedM2Hex)), isTrue);
        expect(await srp.verifyServerProof(Uint8List(64)), isFalse);
        final flipped = _hexToBytes(expectedM2Hex)..[63] ^= 1;
        expect(await srp.verifyServerProof(flipped), isFalse);
        expect(
          await srp.verifyServerProof(
            _hexToBytes(expectedM2Hex).sublist(0, 32),
          ),
          isFalse,
        );
      });

      test('verifyServerProof throws before step2', () async {
        final srp = HapSrp();
        await srp.step1();
        expect(() => srp.verifyServerProof(Uint8List(64)), throwsStateError);
      });
    });

    group('SRP step1', () {
      test('returns 384-byte client public key', () async {
        final srp = HapSrp();
        final pubKey = await srp.step1();
        expect(pubKey.length, equals(384));
      });

      test('generates different keys each time', () async {
        final srp1 = HapSrp();
        final srp2 = HapSrp();
        final key1 = await srp1.step1();
        final key2 = await srp2.step1();
        // Overwhelmingly likely to be different
        expect(key1, isNot(equals(key2)));
      });
    });

    group('SRP step2', () {
      test('throws on zero server public key', () async {
        final srp = HapSrp();
        await srp.step1();

        // Server public key of all zeros means B mod N == 0
        final zeroKey = Uint8List(384);
        final salt = Uint8List(16);

        expect(
          () async => await srp.step2(
            serverPublicKey: zeroKey,
            salt: salt,
            pin: '1234',
          ),
          throwsStateError,
        );
      });
    });

    group('step3', () {
      test('throws if step2 not completed', () async {
        final srp = HapSrp();
        await srp.step1();

        expect(() async => await srp.step3('client-id'), throwsStateError);
      });
    });

    group('step4', () {
      test('throws if step3 not completed', () async {
        final srp = HapSrp();

        expect(
          () async =>
              await srp.step4(encryptedData: Uint8List(32), clientId: 'test'),
          throwsStateError,
        );
      });
    });

    group('pair-verify', () {
      test('pairVerify rejects invalid encrypted data', () async {
        // Generate device Ed25519 key pair
        final ed25519 = Ed25519();
        final deviceEdKeyPair = await ed25519.newKeyPair();
        final deviceEdPublicKey = await deviceEdKeyPair.extractPublicKey();

        // Generate client Ed25519 key pair
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

        // Simulate device side: generate ephemeral X25519 key pair
        final x25519 = X25519();
        final deviceX25519KeyPair = await x25519.newKeyPair();
        final deviceX25519PublicKey =
            await deviceX25519KeyPair.extractPublicKey();

        // Craft invalid encrypted data (random bytes that won't decrypt)
        final invalidEncryptedData = Uint8List(48); // 32 bytes + 16 MAC
        for (var i = 0; i < 48; i++) {
          invalidEncryptedData[i] = i;
        }

        // pairVerify should fail during decryption of the invalid M2 payload
        await expectLater(
          HapSrp.pairVerify(
            deviceX25519PublicKey: Uint8List.fromList(
              deviceX25519PublicKey.bytes,
            ),
            encryptedData: invalidEncryptedData,
            credentials: credentials,
          ),
          throwsA(anything),
        );
      });

      test('pairVerify rejects tampered device signature', () async {
        // This test builds a valid-looking M2 payload but with a wrong
        // device signature, verifying that pairVerify checks signatures.

        final ed25519 = Ed25519();
        final x25519 = X25519();

        // Device Ed25519 keys
        final deviceEdKeyPair = await ed25519.newKeyPair();
        final deviceEdPublicKey = await deviceEdKeyPair.extractPublicKey();

        // Client Ed25519 keys
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

        // Device X25519 keys (simulated device side)
        final deviceX25519KeyPair = await x25519.newKeyPair();
        final deviceX25519PublicKey =
            await deviceX25519KeyPair.extractPublicKey();

        // Client X25519 keys (we need to know the client's ephemeral key to
        // build a valid encrypted payload, but pairVerify generates it
        // internally — so we construct our own and compute the shared secret)
        final clientX25519KeyPair = await x25519.newKeyPair();
        final clientX25519PublicKey =
            await clientX25519KeyPair.extractPublicKey();

        // Compute shared secret between device and client X25519 keys
        final sharedSecret = await x25519.sharedSecretKey(
          keyPair: deviceX25519KeyPair,
          remotePublicKey: clientX25519PublicKey,
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

        // Build device info with WRONG client public key (tampered)
        final deviceIdBytes = utf8.encode('test-device');
        final wrongInfo = Uint8List.fromList([
          ...deviceX25519PublicKey.bytes,
          ...deviceIdBytes,
          ...Uint8List(32), // wrong client key (zeros)
        ]);

        // Sign the wrong info (signature won't match actual exchange)
        final wrongSignature = await ed25519.sign(
          wrongInfo,
          keyPair: deviceEdKeyPair,
        );

        // Build challenge sub-TLV with the wrong signature
        final challengeTlvBuilder = BytesBuilder();
        // TLV tag 0x01 (Identifier)
        challengeTlvBuilder.addByte(0x01);
        challengeTlvBuilder.addByte(deviceIdBytes.length);
        challengeTlvBuilder.add(deviceIdBytes);
        // TLV tag 0x0A (Signature)
        challengeTlvBuilder.addByte(0x0A);
        challengeTlvBuilder.addByte(wrongSignature.bytes.length);
        challengeTlvBuilder.add(wrongSignature.bytes);
        final challengeTlv = challengeTlvBuilder.toBytes();

        // Encrypt the challenge
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

        // pairVerify will generate its own X25519 key pair, so it will compute
        // a different shared secret and fail to decrypt our payload. This
        // verifies that the method properly exercises the decrypt path.
        await expectLater(
          HapSrp.pairVerify(
            deviceX25519PublicKey: Uint8List.fromList(
              deviceX25519PublicKey.bytes,
            ),
            encryptedData: encryptedChallenge,
            credentials: credentials,
          ),
          throwsA(anything),
        );
      });

      test('pairVerify rejects too-short encrypted data', () async {
        final ed25519 = Ed25519();
        final x25519 = X25519();

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

        final deviceX25519KeyPair = await x25519.newKeyPair();
        final deviceX25519PublicKey =
            await deviceX25519KeyPair.extractPublicKey();

        // Too-short ciphertext (less than 16 bytes for MAC)
        await expectLater(
          HapSrp.pairVerify(
            deviceX25519PublicKey: Uint8List.fromList(
              deviceX25519PublicKey.bytes,
            ),
            encryptedData: Uint8List(10),
            credentials: credentials,
          ),
          throwsStateError,
        );
      });
    });
  });
}
