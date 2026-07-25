import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'hap_credentials.dart';

/// SRP-6a parameters for HAP (3072-bit prime, SHA-512).
///
/// These are the standard SRP-3072 group parameters used by HomeKit.
class _SrpParams {
  /// 3072-bit safe prime (RFC 5054, Appendix A).
  static final BigInt N = BigInt.parse(
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1'
    '29024E088A67CC74020BBEA63B139B22514A08798E3404DD'
    'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245'
    'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
    'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D'
    'C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F'
    '83655D23DCA3AD961C62F356208552BB9ED529077096966D'
    '670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B'
    'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9'
    'DE2BCBF6955817183995497CEA956AE515D2261898FA0510'
    '15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64'
    'ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7'
    'ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B'
    'F12FFA06D98A0864D87602733EC86A64521F2B18177B200C'
    'BBE117577A615D6C770988C0BAD946E208E24FA074E5AB31'
    '43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF',
    radix: 16,
  );

  /// Generator.
  static final BigInt g = BigInt.from(5);

  /// Hash function: SHA-512.
  static final sha512 = Sha512();
}

/// Implements SRP-6a with HAP-specific parameters for AirPlay pair-setup.
///
/// Also handles the Ed25519 credential exchange and ChaCha20-Poly1305
/// encryption used in the pair-setup M5/M6 steps.
class HapSrp {
  // SRP state
  BigInt? _privateKey; // client private key 'a'
  BigInt? _publicKey; // client public key 'A'
  BigInt? _sessionKey; // shared session key 'S'
  Uint8List? _sharedSecret; // H(S) — the SRP shared secret 'K'

  // Ed25519 key pair generated for this pairing
  SimpleKeyPair? _signingKeyPair;

  /// The SRP shared secret `K = H(S)`, available once [step2] has run.
  ///
  /// Transient pairing stops at M4 and derives the HAP channel keys straight
  /// from this value, so it needs to be readable without going through the
  /// M5/M6 credential exchange.
  Uint8List? get sharedKey => _sharedSecret;

  /// Initializes the SRP client state.
  ///
  /// Returns the client's SRP public key 'A'.
  ///
  /// If [privateKeyOverride] is provided, it is used as the client private key
  /// instead of generating a random one. This is only for testing.
  Future<Uint8List> step1({Uint8List? privateKeyOverride}) async {
    if (privateKeyOverride != null) {
      _privateKey = _bytesToBigInt(privateKeyOverride);
    } else {
      // Generate random private key 'a' (at least 256 bits)
      final random = Random.secure();
      final aBytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        aBytes[i] = random.nextInt(256);
      }
      _privateKey = _bytesToBigInt(aBytes);
    }

    // A = g^a mod N
    _publicKey = _SrpParams.g.modPow(_privateKey!, _SrpParams.N);

    // Ensure A mod N != 0
    if (_publicKey! % _SrpParams.N == BigInt.zero) {
      throw StateError('SRP: invalid client public key (A mod N == 0)');
    }

    return _bigIntToBytes(_publicKey!, 384);
  }

  /// Processes the server's SRP response (salt + server public key B).
  ///
  /// Computes the SRP shared secret using the given [pin].
  /// Returns the client's SRP proof M1.
  Future<Uint8List> step2({
    required Uint8List serverPublicKey,
    required Uint8List salt,
    required String pin,
  }) async {
    final B = _bytesToBigInt(serverPublicKey);

    // B mod N must not be 0
    if (B % _SrpParams.N == BigInt.zero) {
      throw StateError('SRP: invalid server public key (B mod N == 0)');
    }

    final A = _publicKey!;
    final a = _privateKey!;
    final N = _SrpParams.N;
    final g = _SrpParams.g;

    // u = H(A | B) — "scrambling parameter"
    final u = _bytesToBigInt(
      await _hash([..._bigIntToBytes(A, 384), ..._bigIntToBytes(B, 384)]),
    );

    if (u == BigInt.zero) {
      throw StateError('SRP: scrambling parameter u is zero');
    }

    // Compute x = H(salt | H("Pair-Setup" | ":" | pin))
    final identityHash = await _hash(utf8.encode('Pair-Setup:$pin'));
    final x = _bytesToBigInt(await _hash([...salt, ...identityHash]));

    // Compute k = H(N | pad(g))
    final k = _bytesToBigInt(
      await _hash([..._bigIntToBytes(N, 384), ..._bigIntToBytes(g, 384)]),
    );

    // S = (B - k * g^x mod N)^(a + u * x) mod N
    final gx = g.modPow(x, N);
    var kgx = (k * gx) % N;
    var diff = (B - kgx) % N;
    if (diff < BigInt.zero) diff += N;

    final exp = (a + u * x) % (N - BigInt.one);
    _sessionKey = diff.modPow(exp, N);

    // K = H(S) — the shared secret
    // srptools uses the minimal (unpadded) byte representation of S.
    _sharedSecret = await _hash(_bigIntToBytesUnpadded(_sessionKey!));

    // M1 = H(H(N) XOR H(g) | H(identity) | salt | A | B | K)
    // srptools hashes N and g using their minimal byte representations:
    //   - N is 384 bytes naturally (3072-bit prime)
    //   - g=5 is just 1 byte (0x05), NOT padded to 384 bytes
    // A and B are also passed as unpadded integers in srptools.
    final hN = await _hash(_bigIntToBytesUnpadded(N));
    final hg = await _hash(_bigIntToBytesUnpadded(g));
    // XOR the two hash values as integers, then convert to unpadded bytes
    // (matches srptools' h(N) ^ h(g) which is integer XOR)
    final hNint = _bytesToBigInt(hN);
    final hgInt = _bytesToBigInt(hg);
    final hNxorHg = _bigIntToBytesUnpadded(hNint ^ hgInt);
    final hIdentity = _bigIntToBytesUnpadded(
      _bytesToBigInt(await _hash(utf8.encode('Pair-Setup'))),
    );

    final proof = await _hash([
      ...hNxorHg,
      ...hIdentity,
      ...salt,
      ..._bigIntToBytesUnpadded(A),
      ..._bigIntToBytesUnpadded(B),
      ..._sharedSecret!,
    ]);

    return proof;
  }

  /// Derives the encryption key and builds the encrypted credential payload
  /// for pair-setup M5.
  ///
  /// Returns the encrypted data to send in M5.
  Future<Uint8List> step3(String clientId) async {
    if (_sharedSecret == null) {
      throw StateError('SRP: step2 must be completed before step3');
    }

    // Generate an Ed25519 key pair for this pairing
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    _signingKeyPair = keyPair;
    final publicKey = await _signingKeyPair!.extractPublicKey();

    // Derive the signing key via HKDF
    // iOSDeviceX = HKDF-SHA-512(K, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info")
    final signingKey = await _hkdfDerive(
      inputKey: _sharedSecret!,
      salt: 'Pair-Setup-Controller-Sign-Salt',
      info: 'Pair-Setup-Controller-Sign-Info',
      length: 32,
    );

    // Build iOSDeviceInfo = signingKey | clientId | clientPublicKey
    final clientIdBytes = utf8.encode(clientId);
    final deviceInfo = Uint8List.fromList([
      ...signingKey,
      ...clientIdBytes,
      ...publicKey.bytes,
    ]);

    // Sign the info
    final signature = await algorithm.sign(
      deviceInfo,
      keyPair: _signingKeyPair!,
    );

    // Build the sub-TLV: Identifier + PublicKey + Signature
    // Using raw TLV encoding inline to avoid circular dependency
    final subTlv = _encodeTlv([
      (0x01, clientIdBytes), // Identifier
      (0x03, publicKey.bytes), // PublicKey
      (0x0A, signature.bytes), // Signature
    ]);

    // Derive the encryption key
    // SessionKey = HKDF-SHA-512(K, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
    final encryptionKey = await _hkdfDerive(
      inputKey: _sharedSecret!,
      salt: 'Pair-Setup-Encrypt-Salt',
      info: 'Pair-Setup-Encrypt-Info',
      length: 32,
    );

    // Encrypt the sub-TLV with ChaCha20-Poly1305
    final nonce = padNonce('PS-Msg05');
    final encrypted = await _chachaEncrypt(
      key: encryptionKey,
      nonce: nonce,
      plaintext: subTlv,
    );

    return encrypted;
  }

  /// Processes the server's M6 encrypted response.
  ///
  /// Decrypts the server's credentials and returns [HapCredentials].
  Future<HapCredentials> step4({
    required Uint8List encryptedData,
    required String clientId,
  }) async {
    if (_sharedSecret == null || _signingKeyPair == null) {
      throw StateError('SRP: step3 must be completed before step4');
    }

    // Derive the decryption key
    final decryptionKey = await _hkdfDerive(
      inputKey: _sharedSecret!,
      salt: 'Pair-Setup-Encrypt-Salt',
      info: 'Pair-Setup-Encrypt-Info',
      length: 32,
    );

    // Decrypt the server's response
    final nonce = padNonce('PS-Msg06');
    final decrypted = await _chachaDecrypt(
      key: decryptionKey,
      nonce: nonce,
      ciphertext: encryptedData,
    );

    // Parse the sub-TLV
    final subTlv = _decodeTlv(decrypted);
    final deviceId = utf8.decode(subTlv[0x01]!);
    final devicePublicKey = Uint8List.fromList(subTlv[0x03]!);
    final deviceSignature = subTlv[0x0A]!;

    // Derive the device signing key
    final deviceSigningKey = await _hkdfDerive(
      inputKey: _sharedSecret!,
      salt: 'Pair-Setup-Accessory-Sign-Salt',
      info: 'Pair-Setup-Accessory-Sign-Info',
      length: 32,
    );

    // Build deviceInfo = deviceSigningKey | deviceId | devicePublicKey
    final deviceIdBytes = utf8.encode(deviceId);
    final deviceInfo = Uint8List.fromList([
      ...deviceSigningKey,
      ...deviceIdBytes,
      ...devicePublicKey,
    ]);

    // Verify the device signature
    final ed25519 = Ed25519();
    final devicePubKey = SimplePublicKey(
      devicePublicKey,
      type: KeyPairType.ed25519,
    );
    final sig = Signature(deviceSignature, publicKey: devicePubKey);
    final valid = await ed25519.verify(deviceInfo, signature: sig);
    if (!valid) {
      throw StateError('HAP: device signature verification failed');
    }

    // Extract our private key bytes
    final privateKeyData = await _signingKeyPair!.extractPrivateKeyBytes();
    final ourPublicKey = await _signingKeyPair!.extractPublicKey();

    return HapCredentials(
      clientPrivateKey: Uint8List.fromList(privateKeyData),
      clientPublicKey: Uint8List.fromList(ourPublicKey.bytes),
      clientId: clientId,
      devicePublicKey: devicePublicKey,
      deviceId: deviceId,
    );
  }

  // -- Pair-Verify methods --

  /// Processes pair-verify M2 from the device.
  ///
  /// Takes the device's X25519 public key and encrypted challenge data.
  /// Returns the encrypted response for M3 and the session encryption keys.
  static Future<PairVerifyResult> pairVerify({
    required Uint8List deviceX25519PublicKey,
    required Uint8List encryptedData,
    required HapCredentials credentials,
  }) async {
    // Generate ephemeral X25519 key pair
    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    // Compute shared secret via X25519 DH
    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: SimplePublicKey(
        deviceX25519PublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final sharedSecretBytes = Uint8List.fromList(
      await sharedSecret.extractBytes(),
    );

    // Derive the session encryption key for decrypting M2
    final sessionKey = await _hkdfDeriveStatic(
      inputKey: sharedSecretBytes,
      salt: 'Pair-Verify-Encrypt-Salt',
      info: 'Pair-Verify-Encrypt-Info',
      length: 32,
    );

    // Decrypt M2 challenge
    final nonce = padNonce('PV-Msg02');
    final decrypted = await _chachaDecryptStatic(
      key: sessionKey,
      nonce: nonce,
      ciphertext: encryptedData,
    );

    // Parse the sub-TLV from the decrypted challenge
    final subTlv = _decodeTlv(decrypted);
    final deviceId = utf8.decode(subTlv[0x01]!);
    final deviceSignature = subTlv[0x0A]!;

    // Verify device signature
    // deviceInfo = deviceX25519PublicKey | deviceId | ephemeralPublicKey
    final deviceIdBytes = utf8.encode(deviceId);
    final deviceInfo = Uint8List.fromList([
      ...deviceX25519PublicKey,
      ...deviceIdBytes,
      ...ephemeralPublicKey.bytes,
    ]);

    final ed25519 = Ed25519();
    final devicePubKey = SimplePublicKey(
      credentials.devicePublicKey,
      type: KeyPairType.ed25519,
    );
    final sig = Signature(deviceSignature, publicKey: devicePubKey);
    final valid = await ed25519.verify(deviceInfo, signature: sig);
    if (!valid) {
      throw StateError('HAP pair-verify: device signature verification failed');
    }

    // Build our response
    // clientInfo = ephemeralPublicKey | clientId | deviceX25519PublicKey
    final clientIdBytes = utf8.encode(credentials.clientId);
    final clientInfo = Uint8List.fromList([
      ...ephemeralPublicKey.bytes,
      ...clientIdBytes,
      ...deviceX25519PublicKey,
    ]);

    // Sign with our stored Ed25519 private key
    final signingKeyPair = SimpleKeyPairData(
      credentials.clientPrivateKey,
      publicKey: SimplePublicKey(
        credentials.clientPublicKey,
        type: KeyPairType.ed25519,
      ),
      type: KeyPairType.ed25519,
    );
    final clientSignature = await ed25519.sign(
      clientInfo,
      keyPair: signingKeyPair,
    );

    // Build response sub-TLV
    final responseTlv = _encodeTlv([
      (0x01, clientIdBytes), // Identifier
      (0x0A, clientSignature.bytes), // Signature
    ]);

    // Encrypt response with ChaCha20-Poly1305
    final responseNonce = padNonce('PV-Msg03');
    final encryptedResponse = await _chachaEncryptStatic(
      key: sessionKey,
      nonce: responseNonce,
      plaintext: responseTlv,
    );

    return PairVerifyResult(
      encryptedResponse: encryptedResponse,
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublicKey.bytes),
      sharedSecret: sharedSecretBytes,
    );
  }

  // -- Utility methods --

  Future<Uint8List> _hash(List<int> data) async {
    final hash = await _SrpParams.sha512.hash(data);
    return Uint8List.fromList(hash.bytes);
  }

  Future<Uint8List> _hkdfDerive({
    required Uint8List inputKey,
    required String salt,
    required String info,
    required int length,
  }) async {
    return _hkdfDeriveStatic(
      inputKey: inputKey,
      salt: salt,
      info: info,
      length: length,
    );
  }

  static Future<Uint8List> _hkdfDeriveStatic({
    required Uint8List inputKey,
    required String salt,
    required String info,
    required int length,
  }) async {
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: length);
    final secretKey = SecretKey(inputKey);
    final derivedKey = await hkdf.deriveKey(
      secretKey: secretKey,
      nonce: utf8.encode(salt),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await derivedKey.extractBytes());
  }

  Future<Uint8List> _chachaEncrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
  }) async {
    return _chachaEncryptStatic(key: key, nonce: nonce, plaintext: plaintext);
  }

  static Future<Uint8List> _chachaEncryptStatic({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
  }) async {
    final algorithm = Chacha20.poly1305Aead();
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    // Return ciphertext + MAC (16 bytes) concatenated
    return Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  Future<Uint8List> _chachaDecrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    return _chachaDecryptStatic(key: key, nonce: nonce, ciphertext: ciphertext);
  }

  static Future<Uint8List> _chachaDecryptStatic({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    if (ciphertext.length < 16) {
      throw StateError('Ciphertext too short for ChaCha20-Poly1305');
    }
    final algorithm = Chacha20.poly1305Aead();
    final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final secretBox = SecretBox(ct, nonce: nonce, mac: mac);
    final plaintext = await algorithm.decrypt(
      secretBox,
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plaintext);
  }

  /// Zero-pads a nonce string to 12 bytes from the left.
  static Uint8List padNonce(String nonceStr) {
    final nonceBytes = utf8.encode(nonceStr);
    if (nonceBytes.length > 12) {
      throw ArgumentError('Nonce string too long: ${nonceBytes.length} > 12');
    }
    final padded = Uint8List(12);
    final offset = 12 - nonceBytes.length;
    for (var i = 0; i < nonceBytes.length; i++) {
      padded[offset + i] = nonceBytes[i];
    }
    return padded;
  }

  /// Converts bytes to BigInt (big-endian unsigned).
  static BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  /// Converts BigInt to bytes (big-endian unsigned, padded to [length]).
  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final bytes = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
    return bytes;
  }

  /// Converts BigInt to bytes (big-endian unsigned, minimal length — no padding).
  ///
  /// This matches srptools' `int_to_bytes()` which uses the minimal byte
  /// representation (no leading zero padding).
  static Uint8List _bigIntToBytesUnpadded(BigInt value) {
    if (value == BigInt.zero) return Uint8List.fromList([0]);
    // Calculate the number of bytes needed
    var temp = value;
    var byteCount = 0;
    while (temp > BigInt.zero) {
      temp >>= 8;
      byteCount++;
    }
    final bytes = Uint8List(byteCount);
    var v = value;
    for (var i = byteCount - 1; i >= 0; i--) {
      bytes[i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
    return bytes;
  }

  // Inline TLV encode/decode to avoid circular imports

  static Uint8List _encodeTlv(List<(int, List<int>)> items) {
    final builder = BytesBuilder(copy: false);
    for (final (tag, value) in items) {
      if (value.isEmpty) {
        builder.addByte(tag);
        builder.addByte(0);
        continue;
      }
      int offset = 0;
      while (offset < value.length) {
        final chunkSize =
            (value.length - offset) > 255 ? 255 : (value.length - offset);
        builder.addByte(tag);
        builder.addByte(chunkSize);
        builder.add(value.sublist(offset, offset + chunkSize));
        offset += chunkSize;
      }
    }
    return builder.toBytes();
  }

  static Map<int, List<int>> _decodeTlv(List<int> data) {
    final result = <int, List<int>>{};
    int offset = 0;
    int? lastTag;
    while (offset < data.length) {
      if (offset + 1 >= data.length) break;
      final tag = data[offset];
      final length = data[offset + 1];
      offset += 2;
      if (offset + length > data.length) break;
      final value = data.sublist(offset, offset + length);
      offset += length;
      if (tag == lastTag && result.containsKey(tag)) {
        result[tag] = [...result[tag]!, ...value];
      } else {
        result[tag] = value;
      }
      lastTag = tag;
    }
    return result;
  }
}

/// Result of a pair-verify exchange.
class PairVerifyResult {
  /// The encrypted response to send as M3.
  final Uint8List encryptedResponse;

  /// The ephemeral X25519 public key used in M1.
  final Uint8List ephemeralPublicKey;

  /// The X25519 shared secret (for deriving further session keys if needed).
  final Uint8List sharedSecret;

  PairVerifyResult({
    required this.encryptedResponse,
    required this.ephemeralPublicKey,
    required this.sharedSecret,
  });
}
