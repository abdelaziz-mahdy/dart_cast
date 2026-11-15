import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../../../utils/logger.dart';
import 'hap_credentials.dart';
import 'hap_srp.dart';
import 'tlv8.dart';

/// Orchestrates the AirPlay HAP pair-setup flow (4 HTTP requests).
///
/// This is the one-time PIN-based pairing that produces persistent
/// [HapCredentials] for future pair-verify sessions.
class AirPlayPairSetup {
  final String host;
  final int port;
  final http.Client _httpClient;

  AirPlayPairSetup({
    required this.host,
    required this.port,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Triggers the device to display a PIN on screen.
  ///
  /// This is fire-and-forget — the HTTP request triggers the PIN display
  /// but the device may not respond (connection stays open). We don't wait
  /// for the response to avoid blocking the PIN dialog.
  void startPinDisplay() {
    CastLogger.info('AirPlay auth: requesting PIN display (fire-and-forget)');
    _httpClient
        .post(_uri('/pair-pin-start'), headers: _defaultHeaders, body: '')
        .then((response) {
          CastLogger.info(
            'AirPlay auth: pair-pin-start response: ${response.statusCode}',
          );
        })
        .catchError((Object e) {
          CastLogger.debug('AirPlay auth: pair-pin-start error (expected): $e');
        });
  }

  /// Runs the full pair-setup flow with the given [pin].
  ///
  /// [clientId] is the pairing identifier for this client (e.g., a UUID).
  /// Returns [HapCredentials] on success.
  Future<HapCredentials> pairSetup({
    required String pin,
    required String clientId,
  }) async {
    final srp = HapSrp();

    // -- M1: Send PairSetup method + SeqNo 1 --
    CastLogger.info('AirPlay auth: pair-setup M1');
    final m1 = Tlv8.encode([
      (Tlv8.tagMethod, [0x00]), // PairSetup
      (Tlv8.tagSeqNo, [0x01]),
    ]);

    final m2Response = await _postPairSetup(m1);
    final m2 = Tlv8.decode(m2Response);
    _checkError(m2, 'M2');

    final salt = Uint8List.fromList(m2[Tlv8.tagSalt]!);
    final serverPublicKey = Uint8List.fromList(m2[Tlv8.tagPublicKey]!);
    CastLogger.info(
      'AirPlay auth: M2 received salt(${salt.length}B) pubkey(${serverPublicKey.length}B)',
    );

    // -- M3: SRP client public key + proof --
    CastLogger.info('AirPlay auth: pair-setup M3 (SRP exchange)');
    final clientPublicKey = await srp.step1();
    final proof = await srp.step2(
      serverPublicKey: serverPublicKey,
      salt: salt,
      pin: pin,
    );

    final m3 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x03]),
      (Tlv8.tagPublicKey, clientPublicKey),
      (Tlv8.tagProof, proof),
    ]);

    final m4Response = await _postPairSetup(m3);
    final m4 = Tlv8.decode(m4Response);
    _checkError(m4, 'M4');
    await verifyAccessoryProof(srp, m4[Tlv8.tagProof], 'pair-setup');
    CastLogger.info('AirPlay auth: M4 received (accessory proof verified)');

    // -- M5: Encrypted credentials --
    CastLogger.info('AirPlay auth: pair-setup M5 (credential exchange)');
    final encryptedCredentials = await srp.step3(clientId);

    final m5 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x05]),
      (Tlv8.tagEncryptedData, encryptedCredentials),
    ]);

    final m6Response = await _postPairSetup(m5);
    final m6 = Tlv8.decode(m6Response);
    _checkError(m6, 'M6');

    // -- Process M6: Decrypt device credentials --
    final deviceEncryptedData = Uint8List.fromList(m6[Tlv8.tagEncryptedData]!);
    CastLogger.info(
      'AirPlay auth: M6 received (${deviceEncryptedData.length}B encrypted)',
    );

    final credentials = await srp.step4(
      encryptedData: deviceEncryptedData,
      clientId: clientId,
    );

    CastLogger.info(
      'AirPlay auth: pair-setup complete for device ${credentials.deviceId}',
    );
    return credentials;
  }

  Future<Uint8List> _postPairSetup(Uint8List body) async {
    final response = await _httpClient.post(
      _uri('/pair-setup'),
      headers: {..._defaultHeaders, 'Content-Type': 'application/octet-stream'},
      body: body,
    );
    if (response.statusCode != 200) {
      throw AirPlayAuthException(
        'pair-setup failed with HTTP ${response.statusCode}',
      );
    }
    return Uint8List.fromList(response.bodyBytes);
  }

  void _checkError(Map<int, List<int>> tlv, String step) {
    if (tlv.containsKey(Tlv8.tagError)) {
      final errorCode = tlv[Tlv8.tagError]!.first;
      throw AirPlayAuthException(
        'pair-setup $step error: ${_errorCodeToString(errorCode)} ($errorCode)',
      );
    }
  }

  Uri _uri(String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  Map<String, String> get _defaultHeaders => {
    'User-Agent': 'AirPlay/320.20',
    'Connection': 'keep-alive',
    'X-Apple-HKP': '3',
  };

  /// Closes the underlying HTTP client.
  void close() => _httpClient.close();

  static String _errorCodeToString(int code) {
    switch (code) {
      case 1:
        return 'kTLVError_Unknown';
      case 2:
        return 'kTLVError_Authentication';
      case 3:
        return 'kTLVError_Backoff';
      case 4:
        return 'kTLVError_MaxPeers';
      case 5:
        return 'kTLVError_MaxTries';
      case 6:
        return 'kTLVError_Unavailable';
      case 7:
        return 'kTLVError_Busy';
      default:
        return 'Unknown';
    }
  }
}

/// Orchestrates the AirPlay HAP pair-verify flow (2 HTTP requests).
///
/// Uses stored [HapCredentials] to establish an authenticated session
/// without requiring a PIN.
///
/// Supports two modes:
/// - **HTTP client mode** (default): Uses an [http.Client] for pair-verify.
///   Simple but creates a separate TCP connection from the HAP session.
/// - **Raw socket mode** ([withSocket]): Uses a raw [Socket] for pair-verify.
///   This allows the SAME socket to be reused for the subsequent HAP encrypted
///   session, which is required by AirPlay devices that bind authentication
///   to a specific TCP connection.
class AirPlayPairVerify {
  final String host;
  final int port;
  final http.Client? _httpClient;
  final Socket? _socket;

  AirPlayPairVerify({
    required this.host,
    required this.port,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _socket = null;

  /// Persistent socket listener state (for raw-socket mode).
  StreamSubscription<Uint8List>? _socketSubscription;
  final BytesBuilder _socketBuffer = BytesBuilder(copy: false);
  Completer<void>? _dataArrived;
  bool _socketDone = false;

  /// Creates a pair-verify handler that operates over a raw [Socket].
  ///
  /// The socket is NOT closed by this class — ownership remains with the
  /// caller so it can be handed off to [HapSession] after pair-verify.
  AirPlayPairVerify.withSocket(
    Socket socket, {
    required this.host,
    required this.port,
    Stream<Uint8List>? dataStream,
  }) : _socket = socket,
       _httpClient = null {
    // Listen on the provided dataStream (broadcast wrapper) or socket directly.
    final source = dataStream ?? socket;
    _socketSubscription = source.listen(
      (data) {
        _socketBuffer.add(data);
        _dataArrived?.complete();
        _dataArrived = null;
      },
      onError: (Object error) {
        _dataArrived?.completeError(error);
        _dataArrived = null;
      },
      onDone: () {
        _socketDone = true;
        _dataArrived?.completeError(
          AirPlayAuthException('Socket closed during pair-verify'),
        );
        _dataArrived = null;
      },
    );
  }

  /// Runs the complete pair-verify flow using stored [credentials].
  ///
  /// Returns the X25519 shared secret for session encryption.
  Future<Uint8List> execute(HapCredentials credentials) async {
    // Generate ephemeral X25519 key pair
    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    final ephemeralPubBytes = Uint8List.fromList(ephemeralPublicKey.bytes);

    // -- M1: Send ephemeral X25519 public key --
    CastLogger.info('AirPlay auth: pair-verify M1');
    final m1 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x01]),
      (Tlv8.tagPublicKey, ephemeralPubBytes),
    ]);

    final m2Response = await _postPairVerify(m1);
    final m2 = Tlv8.decode(m2Response);
    _checkError(m2, 'M2');

    final deviceX25519PublicKey = Uint8List.fromList(m2[Tlv8.tagPublicKey]!);
    final encryptedData = Uint8List.fromList(m2[Tlv8.tagEncryptedData]!);
    CastLogger.info(
      'AirPlay auth: pair-verify M2 received '
      '(pubkey ${deviceX25519PublicKey.length}B, '
      'encrypted ${encryptedData.length}B)',
    );

    // -- Compute shared secret --
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

    // Derive session key via HKDF
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final sessionKeyObj = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecretBytes),
      nonce: utf8.encode('Pair-Verify-Encrypt-Salt'),
      info: utf8.encode('Pair-Verify-Encrypt-Info'),
    );
    final sessionKey = Uint8List.fromList(await sessionKeyObj.extractBytes());

    // Decrypt M2 challenge
    final decryptNonce = HapSrp.padNonce('PV-Msg02');
    final decrypted = await _chachaDecrypt(
      key: sessionKey,
      nonce: decryptNonce,
      ciphertext: encryptedData,
    );

    // Parse the sub-TLV from the decrypted challenge
    final subTlv = Tlv8.decode(decrypted);
    final deviceId = utf8.decode(subTlv[Tlv8.tagIdentifier]!);
    final deviceSignature = subTlv[Tlv8.tagSignature]!;

    // Verify device signature
    // deviceInfo = deviceX25519PublicKey | deviceId | ephemeralPublicKey
    final deviceIdBytes = utf8.encode(deviceId);
    final deviceInfo = Uint8List.fromList([
      ...deviceX25519PublicKey,
      ...deviceIdBytes,
      ...ephemeralPubBytes,
    ]);

    final ed25519 = Ed25519();
    final devicePubKey = SimplePublicKey(
      credentials.devicePublicKey,
      type: KeyPairType.ed25519,
    );
    final sig = Signature(deviceSignature, publicKey: devicePubKey);
    final valid = await ed25519.verify(deviceInfo, signature: sig);
    if (!valid) {
      throw AirPlayAuthException(
        'pair-verify: device signature verification failed',
      );
    }
    CastLogger.info('AirPlay auth: pair-verify device signature verified');

    // -- Build M3: Sign our response --
    final clientIdBytes = utf8.encode(credentials.clientId);
    final clientInfo = Uint8List.fromList([
      ...ephemeralPubBytes,
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
    final responseTlv = Tlv8.encode([
      (Tlv8.tagIdentifier, clientIdBytes),
      (Tlv8.tagSignature, clientSignature.bytes),
    ]);

    // Encrypt response
    final encryptNonce = HapSrp.padNonce('PV-Msg03');
    final encryptedResponse = await _chachaEncrypt(
      key: sessionKey,
      nonce: encryptNonce,
      plaintext: responseTlv,
    );

    // -- Send M3 --
    CastLogger.info('AirPlay auth: pair-verify M3');
    final m3 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x03]),
      (Tlv8.tagEncryptedData, encryptedResponse),
    ]);

    final m4Response = await _postPairVerify(m3);
    final m4 = Tlv8.decode(m4Response);
    _checkError(m4, 'M4');

    CastLogger.info('AirPlay auth: pair-verify complete');
    return sharedSecretBytes;
  }

  Future<Uint8List> _postPairVerify(Uint8List body) async {
    if (_socket != null) {
      return _rawHttpPost(_socket, '/pair-verify', body);
    }
    final response = await _httpClient!.post(
      _uri('/pair-verify'),
      headers: {..._defaultHeaders, 'Content-Type': 'application/octet-stream'},
      body: body,
    );
    if (response.statusCode != 200) {
      throw AirPlayAuthException(
        'pair-verify failed with HTTP ${response.statusCode}',
      );
    }
    return Uint8List.fromList(response.bodyBytes);
  }

  /// Sends a raw HTTP POST over a [Socket] and reads the response.
  ///
  /// Uses the persistent socket listener set up in [withSocket] to avoid
  /// "Stream has already been listened to" errors on subsequent calls.
  Future<Uint8List> _rawHttpPost(
    Socket socket,
    String path,
    Uint8List body,
  ) async {
    // Build raw HTTP request
    final request = StringBuffer();
    request.write('POST $path HTTP/1.1\r\n');
    request.write('Host: $host:$port\r\n');
    request.write('Content-Type: application/octet-stream\r\n');
    request.write('Content-Length: ${body.length}\r\n');
    request.write('User-Agent: AirPlay/320.20\r\n');
    request.write('X-Apple-HKP: 3\r\n');
    request.write('Connection: keep-alive\r\n');
    request.write('\r\n');

    socket.add(utf8.encode(request.toString()));
    socket.add(body);
    await socket.flush();

    // Wait for a complete HTTP response using the persistent listener.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      // Check if we already have enough buffered data
      if (_socketBuffer.length > 0) {
        final accumulated = Uint8List.fromList(_socketBuffer.toBytes());
        final result = _tryParseRawHttpResponse(accumulated);
        if (result != null) {
          // Consume the bytes that were part of this response.
          // _tryParseRawHttpResponse returns the body; we need to know
          // how many bytes were consumed. Re-parse to find offset.
          final consumed = _findResponseEnd(accumulated);
          _socketBuffer.clear();
          if (consumed < accumulated.length) {
            _socketBuffer.add(accumulated.sublist(consumed));
          }
          return result;
        }
      }

      if (_socketDone) {
        throw AirPlayAuthException('Socket closed during pair-verify');
      }

      // Wait for more data
      _dataArrived = Completer<void>();
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) break;
      try {
        await _dataArrived!.future.timeout(
          remaining,
          onTimeout: () => throw AirPlayAuthException('pair-verify timed out'),
        );
      } on AirPlayAuthException {
        rethrow;
      }
    }

    throw AirPlayAuthException('pair-verify timed out');
  }

  /// Returns the total number of bytes consumed by the HTTP response
  /// (headers + body), so we can remove them from the buffer.
  int _findResponseEnd(Uint8List data) {
    int headerEnd = -1;
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0x0D &&
          data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D &&
          data[i + 3] == 0x0A) {
        headerEnd = i;
        break;
      }
    }
    if (headerEnd == -1) return 0;
    final headerStr = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4;
    final clMatch = RegExp(
      r'content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(headerStr);
    if (clMatch != null) {
      final contentLength = int.parse(clMatch.group(1)!);
      return bodyStart + contentLength;
    }
    return data.length;
  }

  /// Tries to parse a raw HTTP response from accumulated bytes.
  ///
  /// Returns the response body bytes if a complete response has been received,
  /// or null if more data is needed.
  Uint8List? _tryParseRawHttpResponse(Uint8List data) {
    // Find \r\n\r\n (end of headers)
    int headerEnd = -1;
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0x0D &&
          data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D &&
          data[i + 3] == 0x0A) {
        headerEnd = i;
        break;
      }
    }
    if (headerEnd == -1) return null;

    final headerStr = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4;

    // Parse status code
    final statusMatch = RegExp(r'HTTP/\d+\.\d+\s+(\d+)').firstMatch(headerStr);
    if (statusMatch == null) return null;
    final statusCode = int.parse(statusMatch.group(1)!);

    // Parse Content-Length
    final clMatch = RegExp(
      r'content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(headerStr);
    if (clMatch != null) {
      final contentLength = int.parse(clMatch.group(1)!);
      if (data.length < bodyStart + contentLength) {
        return null; // Need more data
      }
      final bodyBytes = data.sublist(bodyStart, bodyStart + contentLength);
      if (statusCode != 200) {
        throw AirPlayAuthException('pair-verify failed with HTTP $statusCode');
      }
      return Uint8List.fromList(bodyBytes);
    }

    // No Content-Length — assume body is everything after headers
    // (only valid once socket stops sending, but we return what we have)
    if (data.length > bodyStart) {
      if (statusCode != 200) {
        throw AirPlayAuthException('pair-verify failed with HTTP $statusCode');
      }
      return Uint8List.fromList(data.sublist(bodyStart));
    }

    // Headers only, no body yet — for pair-verify there should always be a body
    // Return empty body if status is not 200
    if (statusCode != 200) {
      throw AirPlayAuthException('pair-verify failed with HTTP $statusCode');
    }
    return Uint8List(0);
  }

  void _checkError(Map<int, List<int>> tlv, String step) {
    if (tlv.containsKey(Tlv8.tagError)) {
      final errorCode = tlv[Tlv8.tagError]!.first;
      throw AirPlayAuthException('pair-verify $step error: code $errorCode');
    }
  }

  Future<Uint8List> _chachaEncrypt({
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
    if (ciphertext.length < 16) {
      throw AirPlayAuthException('Ciphertext too short for ChaCha20-Poly1305');
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

  Uri _uri(String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  /// Releases the socket listener so the socket can be handed off to
  /// [HapSession]. Must be called after [execute] completes and before
  /// constructing a [HapSession] with the same socket.
  ///
  /// Only relevant in raw-socket mode; no-op otherwise.
  Future<void> releaseSocket() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;
  }

  /// Closes the underlying HTTP client (if one was used).
  ///
  /// Does NOT close the socket in raw-socket mode — the caller retains
  /// ownership so it can hand the socket off to [HapSession].
  void close() {
    _httpClient?.close();
    // Cancel subscription but don't close the socket
    _socketSubscription?.cancel();
    _socketSubscription = null;
  }

  Map<String, String> get _defaultHeaders => {
    'User-Agent': 'AirPlay/320.20',
    'Connection': 'keep-alive',
    'X-Apple-HKP': '3',
  };
}

/// Exception thrown during AirPlay HAP authentication.
class AirPlayAuthException implements Exception {
  final String message;
  AirPlayAuthException(this.message);

  @override
  String toString() => 'AirPlayAuthException: $message';
}

/// Verifies the accessory's SRP proof carried in pair-setup M4.
///
/// Throws [AirPlayAuthException] when [proof] is missing or does not match,
/// i.e. the peer does not know the PIN-derived verifier.
Future<void> verifyAccessoryProof(
  HapSrp srp,
  List<int>? proof,
  String flow,
) async {
  if (proof == null || proof.isEmpty) {
    throw AirPlayAuthException('$flow M4 carries no accessory SRP proof');
  }
  if (!await srp.verifyServerProof(Uint8List.fromList(proof))) {
    throw AirPlayAuthException('$flow M4 accessory SRP proof is invalid');
  }
}
