import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../../utils/logger.dart';
import 'binary_plist.dart';

/// Derives the HAP session encryption keys from an X25519 shared secret.
///
/// Returns `(outputKey, inputKey)` — the output key encrypts data sent to the
/// device, and the input key decrypts data received from it.
Future<({Uint8List outputKey, Uint8List inputKey})> deriveHapSessionKeys(
  Uint8List sharedSecret,
) async {
  final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);

  final outputKeyObj = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: utf8.encode('Control-Salt'),
    info: utf8.encode('Control-Write-Encryption-Key'),
  );

  final inputKeyObj = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: utf8.encode('Control-Salt'),
    info: utf8.encode('Control-Read-Encryption-Key'),
  );

  return (
    outputKey: Uint8List.fromList(await outputKeyObj.extractBytes()),
    inputKey: Uint8List.fromList(await inputKeyObj.extractBytes()),
  );
}

/// Derives event channel encryption keys from an X25519 shared secret.
///
/// Uses different HKDF salts/info than the control channel keys.
/// The event channel uses `Events-Salt` as the HKDF nonce and
/// `Events-Write-Encryption-Key` / `Events-Read-Encryption-Key` as the info.
Future<({Uint8List outputKey, Uint8List inputKey})> deriveEventKeys(
  Uint8List sharedSecret,
) async {
  final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);

  final outputKeyObj = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: utf8.encode('Events-Salt'),
    info: utf8.encode('Events-Write-Encryption-Key'),
  );

  final inputKeyObj = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: utf8.encode('Events-Salt'),
    info: utf8.encode('Events-Read-Encryption-Key'),
  );

  return (
    outputKey: Uint8List.fromList(await outputKeyObj.extractBytes()),
    inputKey: Uint8List.fromList(await inputKeyObj.extractBytes()),
  );
}

/// A parsed HTTP response from the HAP encrypted channel.
class HapHttpResponse {
  /// HTTP status code.
  final int statusCode;

  /// HTTP reason phrase (e.g. "OK").
  final String reasonPhrase;

  /// Response headers (lowercased keys).
  final Map<String, String> headers;

  /// Response body bytes.
  final Uint8List body;

  HapHttpResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
  });

  /// Returns the body decoded as UTF-8 text.
  ///
  /// AirPlay 2 answers many endpoints with a *binary* plist, which is not
  /// valid UTF-8 — use [body] together with [contentType] for those, and only
  /// reach for this on responses known to be textual. Malformed sequences are
  /// replaced rather than thrown so diagnostics logging cannot crash a
  /// session.
  String get bodyText => utf8.decode(body, allowMalformed: true);

  /// The response `Content-Type`, or an empty string when absent.
  String get contentType => headers['content-type'] ?? '';

  @override
  String toString() =>
      'HapHttpResponse($statusCode $reasonPhrase, '
      '${body.length} bytes)';
}

/// HAP encrypted session layer for AirPlay.
///
/// After pair-verify succeeds, all subsequent HTTP traffic must be encrypted
/// using HAP's framing protocol (HomeKit Accessory Protocol, section 5.2.2).
///
/// Data is split into max 1024-byte frames. Each frame is:
/// ```
/// [2-byte LE length][ChaCha20-Poly1305(payload) + 16-byte auth tag]
/// ```
/// The 2-byte length serves as AAD (Additional Authenticated Data).
/// Nonces are 12 bytes: 4 zero bytes followed by an 8-byte LE counter.
class HapSession {
  /// Maximum frame payload size as specified by HAP section 5.2.2.
  static const int frameLength = 1024;

  /// ChaCha20-Poly1305 authentication tag length.
  static const int authTagLength = 16;

  final Socket _socket;
  final Uint8List _outputKey;
  final Uint8List _inputKey;
  int _outputCounter = 0;
  int _inputCounter = 0;

  /// RTSP CSeq counter for RTSP exchanges.
  int _cseq = 0;

  /// DACP-ID header value — random hex string, persistent across session.
  /// Used by pyatv in all RTSP exchanges.
  late final String _dacpId =
      Random.secure()
          .nextInt(0x7FFFFFFF)
          .toRadixString(16)
          .padLeft(16, '0')
          .toUpperCase();

  /// Active-Remote header value — random integer, persistent across session.
  late final int _activeRemote = Random.secure().nextInt(0x7FFFFFFF);

  /// Whether the RTSP session has been set up (SETUP + RECORD completed).
  bool _rtspSessionSetUp = false;

  /// The RTSP URI used for all RTSP commands (rtsp://host/session_id).
  String? _rtspUri;

  /// Whether the periodic feedback loop is active.
  bool _feedbackActive = false;

  /// Tail of the request queue.
  ///
  /// Every exchange on this socket runs to completion before the next one
  /// starts. Without this the 2-second `/feedback` loop shares one reader and
  /// one completer with foreground commands, so `/play` can be handed the
  /// feedback response — and two concurrent writers desynchronise the
  /// ChaCha20 nonce counters, after which every frame fails MAC verification.
  Future<void>? _requestQueue;

  /// Buffer for incomplete encrypted data received from the device.
  final BytesBuilder _receiveBuffer = BytesBuilder(copy: false);

  /// The host used in HTTP Host headers.
  final String host;

  /// The port used in HTTP Host headers.
  final int port;

  /// Session ID for X-Apple-Session-ID header.
  String _sessionId;

  /// Persistent socket listener — set up once to avoid "Stream has already
  /// been listened to" errors on the single-subscription socket stream.
  late final StreamSubscription<Uint8List> _socketSubscription;

  /// Raw encrypted bytes received from the socket, waiting to be consumed.
  final BytesBuilder _rawReceiveBuffer = BytesBuilder(copy: false);

  /// Completer that is completed whenever new data arrives on the socket.
  Completer<void>? _dataArrived;

  /// Whether the socket has been closed by the remote end.
  bool _socketDone = false;

  /// The X25519 shared secret used for deriving event channel keys.
  /// Set via constructor parameter.
  final Uint8List? _sharedSecret;

  /// The event channel HAP session, opened after RTSP SETUP.
  HapSession? _eventChannel;

  /// Creates a [HapSession] wrapping a raw TCP [socket].
  ///
  /// [outputKey] encrypts data sent to the device.
  /// [inputKey] decrypts data received from the device.
  /// [sharedSecret] is the X25519 shared secret, needed to derive event
  /// channel encryption keys after RTSP SETUP.
  /// [dataStream] optionally provides an alternative stream to listen on
  /// instead of the socket directly (e.g., a broadcast stream wrapper).
  HapSession({
    required Socket socket,
    required Uint8List outputKey,
    required Uint8List inputKey,
    required this.host,
    required this.port,
    String? sessionId,
    Uint8List? sharedSecret,
    Stream<Uint8List>? dataStream,
  }) : _socket = socket,
       _outputKey = outputKey,
       _inputKey = inputKey,
       _sharedSecret = sharedSecret,
       _sessionId = sessionId ?? _generateUuid() {
    _setupSocketListener(dataStream);
  }

  /// Sets up the ONE persistent listener on the data stream.
  void _setupSocketListener([Stream<Uint8List>? dataStream]) {
    final source = dataStream ?? _socket;
    _socketSubscription = source.listen(
      (data) {
        _rawReceiveBuffer.add(data);
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
          HapSessionException('Socket closed unexpectedly'),
        );
        _dataArrived = null;
      },
    );
  }

  /// The current session ID.
  String get sessionId => _sessionId;

  /// The sender's local IP address on this connection.
  ///
  /// AirPlay 2 expects the RTSP URI to name the *sender*, not the receiver
  /// (`pyatv/support/rtsp.py`, `RtspSession.uri`).
  String get localIp {
    try {
      return _socket.address.address;
    } catch (_) {
      return host;
    }
  }

  /// The RTSP URI in use for this session, once [setupRtspSession] has run.
  String? get rtspUri => _rtspUri;

  /// Whether SETUP + RECORD have completed successfully.
  bool get isRtspSessionSetUp => _rtspSessionSetUp;

  /// Runs [action] once every previously queued exchange has finished.
  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _requestQueue;
    final completer = Completer<void>();
    _requestQueue = completer.future;
    if (previous != null) {
      // A failed predecessor must not poison the queue.
      await previous.catchError((Object _) {});
    }
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  /// Visible for testing: the current output (encrypt) nonce counter.
  int get outputCounter => _outputCounter;

  /// Visible for testing: the current input (decrypt) nonce counter.
  int get inputCounter => _inputCounter;

  /// Encrypts [data] into HAP framed format.
  ///
  /// Data is split into max [frameLength]-byte chunks. Each chunk is encrypted
  /// with ChaCha20-Poly1305, producing:
  /// `[2-byte LE length][ciphertext + 16-byte tag]`
  Future<Uint8List> encrypt(Uint8List data) async {
    final result = BytesBuilder(copy: false);
    int offset = 0;

    while (offset < data.length) {
      final end =
          (offset + frameLength < data.length)
              ? offset + frameLength
              : data.length;
      final chunk = data.sublist(offset, end);

      // 2-byte little-endian length as AAD
      final lengthBytes = Uint8List(2);
      lengthBytes[0] = chunk.length & 0xFF;
      lengthBytes[1] = (chunk.length >> 8) & 0xFF;

      // Build 12-byte nonce: 4 zero bytes + 8-byte LE counter
      final nonce = _buildNonce(_outputCounter);
      _outputCounter++;

      // Encrypt with ChaCha20-Poly1305
      final algorithm = Chacha20.poly1305Aead();
      final secretBox = await algorithm.encrypt(
        chunk,
        secretKey: SecretKey(_outputKey),
        nonce: nonce,
        aad: lengthBytes,
      );

      // Frame = lengthBytes + ciphertext + mac
      result.add(lengthBytes);
      result.add(secretBox.cipherText);
      result.add(secretBox.mac.bytes);

      offset = end;
    }

    return result.toBytes();
  }

  /// Decrypts HAP framed [data] received from the device.
  ///
  /// Each frame is: `[2-byte LE length][ciphertext(length bytes) + 16-byte tag]`
  /// Returns the decrypted plaintext.
  ///
  /// May return fewer bytes than expected if the data is incomplete (partial
  /// frame). Unconsumed bytes are buffered internally.
  Future<Uint8List> decrypt(Uint8List data) async {
    _receiveBuffer.add(data);
    final buffered = _receiveBuffer.toBytes();
    _receiveBuffer.clear();

    final result = BytesBuilder(copy: false);
    int offset = 0;

    while (offset < buffered.length) {
      // Need at least 2 bytes for length
      if (offset + 2 > buffered.length) {
        break;
      }

      final blockLength = buffered[offset] | (buffered[offset + 1] << 8);
      final totalFrameLength = 2 + blockLength + authTagLength;

      // Not enough data for this frame yet
      if (offset + totalFrameLength > buffered.length) {
        break;
      }

      final lengthBytes = buffered.sublist(offset, offset + 2);
      final encrypted = buffered.sublist(
        offset + 2,
        offset + 2 + blockLength + authTagLength,
      );

      // Split into ciphertext and mac
      final ciphertext = encrypted.sublist(0, blockLength);
      final mac = Mac(
        encrypted.sublist(blockLength, blockLength + authTagLength),
      );

      // Build nonce
      final nonce = _buildNonce(_inputCounter);
      _inputCounter++;

      // Decrypt
      final algorithm = Chacha20.poly1305Aead();
      final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
      final plaintext = await algorithm.decrypt(
        secretBox,
        secretKey: SecretKey(_inputKey),
        aad: lengthBytes,
      );
      result.add(plaintext);

      offset += totalFrameLength;
    }

    // Buffer any remaining incomplete data
    if (offset < buffered.length) {
      _receiveBuffer.add(buffered.sublist(offset));
    }

    return Uint8List.fromList(result.toBytes());
  }

  /// Sends an HTTP request through the encrypted channel and returns the response.
  ///
  /// Exchanges are serialized: a request issued while another is in flight
  /// waits its turn rather than racing it on the shared socket.
  Future<HapHttpResponse> sendRequest(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
    Map<String, String>? queryParameters,
  }) => _serialized(
    () => _sendRequestLocked(
      method,
      path,
      headers: headers,
      body: body,
      queryParameters: queryParameters,
    ),
  );

  Future<HapHttpResponse> _sendRequestLocked(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
    Map<String, String>? queryParameters,
  }) async {
    CastLogger.debug('HAP session: sendRequest $method $path');
    // Build the URI path with query parameters
    String fullPath = path;
    if (queryParameters != null && queryParameters.isNotEmpty) {
      final queryString = queryParameters.entries
          .map(
            (e) =>
                '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
          )
          .join('&');
      fullPath = '$path?$queryString';
    }

    // Build raw HTTP request — use AirPlay User-Agent to match pyatv
    final requestHeaders = <String, String>{
      'User-Agent': 'AirPlay/550.10',
      'X-Apple-Session-ID': _sessionId,
      ...?headers,
    };

    if (body != null && body.isNotEmpty) {
      requestHeaders['Content-Length'] = '${body.length}';
    }

    final buffer = StringBuffer();
    buffer.write('$method $fullPath HTTP/1.1\r\n');
    for (final entry in requestHeaders.entries) {
      buffer.write('${entry.key}: ${entry.value}\r\n');
    }
    buffer.write('\r\n');

    final headerBytes = utf8.encode(buffer.toString());
    final requestBytes =
        body != null && body.isNotEmpty
            ? Uint8List.fromList([...headerBytes, ...body])
            : Uint8List.fromList(headerBytes);

    // Encrypt and send
    CastLogger.debug('HAP session: encrypting ${requestBytes.length} bytes');
    final encrypted = await encrypt(requestBytes);
    CastLogger.debug(
      'HAP session: sending ${encrypted.length} encrypted bytes',
    );
    _socket.add(encrypted);
    await _socket.flush();
    CastLogger.debug('HAP session: waiting for encrypted response...');

    // Read response
    final responseBytes = await _readEncryptedResponse();
    CastLogger.debug(
      'HAP session: received ${responseBytes.length} decrypted response bytes',
    );
    return _parseHttpResponse(responseBytes);
  }

  /// Sends an RTSP request over the encrypted channel and returns the response.
  ///
  /// RTSP requests use `RTSP/1.0` as the protocol line instead of `HTTP/1.1`,
  /// and include an auto-incrementing `CSeq` header. The [uri] is typically
  /// `*` for SETUP/RECORD or a path like `/play` for media commands.
  Future<HapHttpResponse> sendRtspRequest(
    String method,
    String uri, {
    Map<String, String>? headers,
    List<int>? body,
  }) => _serialized(
    () => _sendRtspRequestLocked(method, uri, headers: headers, body: body),
  );

  Future<HapHttpResponse> _sendRtspRequestLocked(
    String method,
    String uri, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    _cseq++;
    final cseq = _cseq;
    CastLogger.debug('HAP session: sendRtspRequest $method $uri (CSeq=$cseq)');

    final requestHeaders = <String, String>{
      'CSeq': '$cseq',
      'DACP-ID': _dacpId,
      'Active-Remote': '$_activeRemote',
      'Client-Instance': _dacpId,
      'User-Agent': 'AirPlay/550.10',
      'X-Apple-Session-ID': _sessionId,
      ...?headers,
    };

    if (body != null && body.isNotEmpty) {
      requestHeaders['Content-Length'] = '${body.length}';
    }

    final buffer = StringBuffer();
    buffer.write('$method $uri RTSP/1.0\r\n');
    for (final entry in requestHeaders.entries) {
      buffer.write('${entry.key}: ${entry.value}\r\n');
    }
    buffer.write('\r\n');

    final headerBytes = utf8.encode(buffer.toString());
    final requestBytes =
        body != null && body.isNotEmpty
            ? Uint8List.fromList([...headerBytes, ...body])
            : Uint8List.fromList(headerBytes);

    // Encrypt and send
    CastLogger.debug(
      'HAP session: encrypting ${requestBytes.length} RTSP bytes',
    );
    final encrypted = await encrypt(requestBytes);
    CastLogger.debug(
      'HAP session: sending ${encrypted.length} encrypted RTSP bytes',
    );
    _socket.add(encrypted);
    await _socket.flush();
    CastLogger.debug('HAP session: waiting for encrypted RTSP response...');

    // Read response
    final responseBytes = await _readEncryptedResponse();
    CastLogger.debug(
      'HAP session: received ${responseBytes.length} decrypted RTSP response bytes',
    );
    final response = _parseHttpResponse(responseBytes);

    // Receivers echo the CSeq. A mismatch means the reply belongs to another
    // in-flight exchange, which serialization is supposed to make impossible —
    // log it loudly rather than silently treating it as our answer.
    final responseCseq = int.tryParse(response.headers['cseq'] ?? '');
    if (responseCseq != null && responseCseq != cseq) {
      CastLogger.warning(
        'HAP session: RTSP response CSeq $responseCseq does not match '
        'request CSeq $cseq ($method $uri)',
      );
    }

    return response;
  }

  /// Performs AirPlay 2 RTSP session setup required before `/play`.
  ///
  /// This sends SETUP (with device info) and RECORD over the HAP encrypted
  /// channel, which is required by AirPlay 2 devices before they will accept
  /// media commands like `/play`.
  ///
  /// [timingPort] is the UDP port of a running [AirPlayTimingServer]. It must
  /// be non-zero: a receiver told `timingProtocol: "NTP"` will send timing
  /// requests there, and one told `"None"` may refuse to play at all. Passing
  /// 0 declares no timing server, which is what the AirPlay 1 path wants.
  ///
  /// Throws [HapSessionException] if SETUP or RECORD is rejected. Continuing
  /// past a rejected SETUP was how this code previously reported success on
  /// sessions the receiver had already refused.
  Future<void> setupRtspSession({int timingPort = 0}) async {
    if (_rtspSessionSetUp) return;

    // Generate a session ID used as the RTSP URI path.
    // pyatv uses rtsp://<sender ip>/<session id> for all RTSP commands — the
    // URI names the sender, not the receiver.
    final rtspSessionId = Random.secure().nextInt(0x7FFFFFFF);
    _rtspUri = 'rtsp://$localIp/$rtspSessionId';

    CastLogger.info(
      'HAP session: RTSP SETUP (uri=$_rtspUri, timingPort=$timingPort)',
    );

    final setupBodyBytes = BinaryPlistEncoder.encode({
      'deviceID': 'AA:BB:CC:DD:EE:FF',
      'sessionUUID': _generateUuid().toUpperCase(),
      if (timingPort > 0) 'timingPort': timingPort,
      'timingProtocol': timingPort > 0 ? 'NTP' : 'None',
      'isMultiSelectAirPlay': true,
      'groupContainsGroupLeader': false,
      'macAddress': 'AA:BB:CC:DD:EE:FF',
      'model': 'iPhone14,3',
      'name': 'dart_cast',
      'osBuildVersion': '20F66',
      'osName': 'iPhone OS',
      'osVersion': '16.5',
      'senderSupportsRelay': false,
      'sourceVersion': '690.7.1',
      'statsCollectionEnabled': false,
    });

    final setupResp = await sendRtspRequest(
      'SETUP',
      _rtspUri!,
      headers: {'Content-Type': 'application/x-apple-binary-plist'},
      body: setupBodyBytes,
    );
    CastLogger.info(
      'HAP session: RTSP SETUP response: ${setupResp.statusCode} body(${setupResp.body.length}B)',
    );

    if (setupResp.statusCode != 200) {
      throw HapSessionException(
        'RTSP SETUP rejected with ${setupResp.statusCode} '
        '${setupResp.reasonPhrase}',
      );
    }

    // Parse eventPort from the binary plist response body
    int? eventPort;
    if (setupResp.body.isNotEmpty) {
      try {
        final setupData = BinaryPlistDecoder.decode(setupResp.body);
        CastLogger.debug('HAP session: SETUP response plist: $setupData');
        eventPort = setupData['eventPort'] as int?;
        if (eventPort != null && eventPort > 0) {
          CastLogger.info('HAP session: eventPort=$eventPort');
        }
      } catch (e) {
        CastLogger.debug(
          'HAP session: SETUP response body: ${setupResp.body.length} bytes '
          '(could not decode as bplist: $e)',
        );
      }
    }

    // Set up the event channel if we have an event port and shared secret
    if (eventPort != null && eventPort > 0 && _sharedSecret != null) {
      try {
        await _setupEventChannel(eventPort);
      } catch (e) {
        CastLogger.warning(
          'HAP session: event channel setup failed: $e — proceeding anyway',
        );
      }
    }

    // Start periodic feedback loop BEFORE RECORD (pyatv sends POST /feedback
    // every 2 seconds starting before RECORD and continuing throughout playback)
    _startFeedbackLoop();

    // Send one immediate feedback before RECORD
    CastLogger.info('HAP session: POST /feedback');
    final feedbackResp = await sendRtspRequest('POST', '/feedback');
    CastLogger.info(
      'HAP session: /feedback response: ${feedbackResp.statusCode}',
    );

    // RECORD
    CastLogger.info('HAP session: RTSP RECORD');
    final recordResp = await sendRtspRequest('RECORD', _rtspUri!);
    CastLogger.info(
      'HAP session: RTSP RECORD response: ${recordResp.statusCode} body: ${recordResp.bodyText}',
    );

    if (recordResp.statusCode != 200) {
      _stopFeedbackLoop();
      throw HapSessionException(
        'RTSP RECORD rejected with ${recordResp.statusCode} '
        '${recordResp.reasonPhrase}',
      );
    }

    _rtspSessionSetUp = true;
  }

  /// Sets up the AirPlay 2 event channel on the given [eventPort].
  ///
  /// The event channel is a separate TCP connection to the device that uses
  /// HAP encryption with event-specific keys derived from the same shared
  /// secret. The device sends events (like `POST /event`) over this channel
  /// and expects `HTTP/1.1 200 OK` responses.
  ///
  /// pyatv notes that the device may not be ready immediately after SETUP,
  /// so we retry up to 5 times with a 1-second delay between attempts.
  Future<void> _setupEventChannel(int eventPort) async {
    CastLogger.info(
      'HAP session: setting up event channel on $host:$eventPort',
    );

    // Derive event-specific encryption keys
    final eventKeys = await deriveEventKeys(_sharedSecret!);
    CastLogger.debug('HAP session: event encryption keys derived');

    // Try to connect with retries — the device may not be ready immediately
    Socket? eventSocket;
    for (int attempt = 1; attempt <= 5; attempt++) {
      try {
        CastLogger.debug(
          'HAP session: event channel connection attempt $attempt/5',
        );
        eventSocket = await Socket.connect(
          host,
          eventPort,
          timeout: const Duration(seconds: 5),
        );
        CastLogger.info(
          'HAP session: event channel connected on attempt $attempt',
        );
        break;
      } on SocketException catch (e) {
        CastLogger.debug(
          'HAP session: event channel attempt $attempt failed: $e',
        );
        if (attempt == 5) {
          throw HapSessionException(
            'Failed to connect event channel after 5 attempts: $e',
          );
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }

    // Create a HAP session on the event socket with event keys
    _eventChannel = HapSession(
      socket: eventSocket!,
      outputKey: eventKeys.outputKey,
      inputKey: eventKeys.inputKey,
      host: host,
      port: eventPort,
    );

    // Start a background listener that reads events and responds with 200 OK
    _listenForEvents();

    CastLogger.info('HAP session: event channel established');
  }

  /// Listens for incoming events on the event channel in the background.
  ///
  /// When an event is received (typically `POST /event` with a binary plist
  /// body), responds with `HTTP/1.1 200 OK` to acknowledge it.
  void _listenForEvents() {
    if (_eventChannel == null) return;

    // Run the event listener asynchronously — don't block the RTSP flow
    Future<void>.microtask(() async {
      while (_eventChannel != null && !_eventChannel!._socketDone) {
        try {
          final data = await _eventChannel!.readDecryptedData(
            timeout: const Duration(seconds: 120),
          );
          if (data.isEmpty) continue;

          final text = utf8.decode(data, allowMalformed: true);
          CastLogger.debug(
            'HAP session: event channel received ${data.length} bytes: '
            '${text.length > 200 ? text.substring(0, 200) : text}',
          );

          // Respond with 200 OK
          const response =
              'HTTP/1.1 200 OK\r\n'
              'Content-Length: 0\r\n'
              '\r\n';
          final responseBytes = Uint8List.fromList(utf8.encode(response));
          final encrypted = await _eventChannel!.encrypt(responseBytes);
          _eventChannel!._socket.add(encrypted);
          await _eventChannel!._socket.flush();

          CastLogger.debug('HAP session: sent 200 OK on event channel');
        } on HapSessionException catch (e) {
          CastLogger.debug('HAP session: event channel read ended: $e');
          break;
        } catch (e) {
          CastLogger.debug('HAP session: event channel error: $e');
          break;
        }
      }
      CastLogger.debug('HAP session: event listener loop exited');
    });
  }

  /// Starts a periodic POST /feedback loop every 2 seconds.
  ///
  /// pyatv sends feedback continuously during playback to keep the session
  /// alive. The loop runs in the background and is best-effort — errors are
  /// logged but do not interrupt playback.
  void _startFeedbackLoop() {
    if (_feedbackActive) return;
    _feedbackActive = true;

    Future<void>.microtask(() async {
      while (_feedbackActive && !_socketDone) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!_feedbackActive || _socketDone) break;
        try {
          await sendRtspRequest('POST', '/feedback');
          CastLogger.debug('HAP session: periodic feedback sent');
        } catch (e) {
          CastLogger.debug('HAP session: feedback failed: $e');
        }
      }
      CastLogger.debug('HAP session: feedback loop exited');
    });
  }

  /// Stops the periodic feedback loop.
  void _stopFeedbackLoop() {
    _feedbackActive = false;
  }

  /// Reads encrypted frames from the socket until a complete HTTP response
  /// is received.
  ///
  /// Uses the persistent socket listener — never calls `_socket.listen()`
  /// directly, which would fail on second invocation since Dart sockets are
  /// single-subscription streams.
  Future<Uint8List> _readEncryptedResponse() async {
    final decryptedBuffer = BytesBuilder(copy: false);
    final deadline = DateTime.now().add(const Duration(seconds: 30));

    while (DateTime.now().isBefore(deadline)) {
      // Process any raw data that has accumulated in the buffer.
      if (_rawReceiveBuffer.length > 0) {
        final raw = _rawReceiveBuffer.toBytes();
        _rawReceiveBuffer.clear();
        final decrypted = await decrypt(Uint8List.fromList(raw));
        if (decrypted.isNotEmpty) {
          decryptedBuffer.add(decrypted);
        }

        // Check if we have a complete HTTP response.
        final accumulated = decryptedBuffer.toBytes();
        if (_isCompleteHttpResponse(accumulated)) {
          return Uint8List.fromList(accumulated);
        }
      }

      // If the socket is done and there is no more data, return what we have
      // (mirrors the original onDone behaviour).
      if (_socketDone) {
        return Uint8List.fromList(decryptedBuffer.toBytes());
      }

      // Wait for the next chunk of data from the persistent listener.
      _dataArrived = Completer<void>();
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) break;
      try {
        await _dataArrived!.future.timeout(
          remaining,
          onTimeout:
              () => throw HapSessionException('Timed out waiting for response'),
        );
      } on HapSessionException {
        rethrow;
      }
    }

    throw HapSessionException('Timed out waiting for response');
  }

  /// Waits for any decrypted data to arrive from the socket and returns it.
  ///
  /// Unlike [_readEncryptedResponse], this does not wait for a complete HTTP
  /// response — it returns as soon as at least one decrypted byte is available.
  /// Used by tests that need to read raw decrypted data from the socket without
  /// HTTP framing expectations.
  // Visible for testing only.
  Future<Uint8List> readDecryptedData({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (_rawReceiveBuffer.length > 0) {
        final raw = _rawReceiveBuffer.toBytes();
        _rawReceiveBuffer.clear();
        final decrypted = await decrypt(Uint8List.fromList(raw));
        if (decrypted.isNotEmpty) {
          return decrypted;
        }
      }

      if (_socketDone) {
        return Uint8List(0);
      }

      _dataArrived = Completer<void>();
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) break;
      await _dataArrived!.future.timeout(
        remaining,
        onTimeout:
            () => throw HapSessionException('Timed out waiting for data'),
      );
    }

    throw HapSessionException('Timed out waiting for data');
  }

  /// Checks if the accumulated bytes form a complete HTTP response.
  bool _isCompleteHttpResponse(Uint8List data) {
    // Find the end of headers (\r\n\r\n)
    final headerEnd = _findHeaderEnd(data);
    if (headerEnd == -1) return false;

    final headerStr = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4; // Skip \r\n\r\n

    // Check for Content-Length
    final contentLengthMatch = RegExp(
      r'content-length:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(headerStr);
    if (contentLengthMatch != null) {
      final contentLength = int.parse(contentLengthMatch.group(1)!);
      return data.length >= bodyStart + contentLength;
    }

    // Check for Transfer-Encoding: chunked
    if (headerStr.toLowerCase().contains('transfer-encoding: chunked')) {
      // Look for the terminal chunk (0\r\n\r\n)
      final bodyBytes = data.sublist(bodyStart);
      final bodyStr = utf8.decode(bodyBytes, allowMalformed: true);
      return bodyStr.contains('0\r\n\r\n');
    }

    // No Content-Length and not chunked — assume complete if we have headers
    // This handles responses like "HTTP/1.1 200 OK\r\n\r\n"
    return true;
  }

  /// Finds the index of the first \r\n\r\n sequence in [data].
  /// Returns -1 if not found.
  int _findHeaderEnd(Uint8List data) {
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0x0D &&
          data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D &&
          data[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
  }

  /// Parses raw HTTP response bytes into a [HapHttpResponse].
  HapHttpResponse _parseHttpResponse(Uint8List data) {
    final headerEnd = _findHeaderEnd(data);
    if (headerEnd == -1) {
      throw HapSessionException('Invalid HTTP response: no header terminator');
    }

    final headerStr = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4;

    // Parse status line
    final lines = headerStr.split('\r\n');
    if (lines.isEmpty) {
      throw HapSessionException('Invalid HTTP response: empty headers');
    }

    final statusLine = lines.first;
    // Accept both HTTP/1.1 and RTSP/1.0 status lines
    final statusMatch = RegExp(
      r'(?:HTTP|RTSP)/\d+\.\d+\s+(\d+)\s*(.*)',
    ).firstMatch(statusLine);
    if (statusMatch == null) {
      throw HapSessionException(
        'Invalid HTTP/RTSP response status line: $statusLine',
      );
    }

    final statusCode = int.parse(statusMatch.group(1)!);
    final reasonPhrase = statusMatch.group(2) ?? '';

    // Parse headers
    final headers = <String, String>{};
    for (int i = 1; i < lines.length; i++) {
      final colonIndex = lines[i].indexOf(':');
      if (colonIndex > 0) {
        final key = lines[i].substring(0, colonIndex).trim().toLowerCase();
        final value = lines[i].substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }

    // Extract body
    final body =
        bodyStart < data.length
            ? Uint8List.fromList(data.sublist(bodyStart))
            : Uint8List(0);

    return HapHttpResponse(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      headers: headers,
      body: body,
    );
  }

  /// Resets the RTSP session state so a new SETUP + RECORD can be performed.
  /// Does NOT send any network request — only resets local state.
  ///
  /// `CSeq` deliberately keeps counting up. Restarting it at 0 on a live
  /// connection produces two different exchanges carrying the same sequence
  /// number, which makes correlating responses impossible.
  void resetRtspSession() {
    _stopFeedbackLoop();
    _sessionId = _generateUuid();
    _rtspSessionSetUp = false;
  }

  /// Closes the underlying socket, event channel, and cancels the persistent
  /// listener.
  Future<void> close() async {
    _stopFeedbackLoop();
    // Close the event channel first
    if (_eventChannel != null) {
      try {
        await _eventChannel!.close();
      } catch (_) {
        // Ignore errors during event channel close
      }
      _eventChannel = null;
    }

    try {
      await _socketSubscription.cancel();
    } catch (_) {
      // Ignore errors during subscription cancel
    }
    try {
      _socket.destroy();
    } catch (_) {
      // Ignore errors during close
    }
  }

  /// Builds a 12-byte nonce: 4 zero bytes + 8-byte little-endian counter.
  static Uint8List _buildNonce(int counter) {
    final nonce = Uint8List(12);
    // First 4 bytes are zero (already initialized)
    // Bytes 4-11 are the 8-byte LE counter
    nonce[4] = counter & 0xFF;
    nonce[5] = (counter >> 8) & 0xFF;
    nonce[6] = (counter >> 16) & 0xFF;
    nonce[7] = (counter >> 24) & 0xFF;
    nonce[8] = (counter >> 32) & 0xFF;
    nonce[9] = (counter >> 40) & 0xFF;
    nonce[10] = (counter >> 48) & 0xFF;
    nonce[11] = (counter >> 56) & 0xFF;
    return nonce;
  }

  /// Generates a UUID v4-like string.
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Creates a [HapSession] by connecting a raw TCP socket to the AirPlay
  /// device and deriving encryption keys from the shared secret.
  static Future<HapSession> connect({
    required String host,
    required int port,
    required Uint8List sharedSecret,
    String? sessionId,
  }) async {
    CastLogger.info('HAP session: deriving encryption keys');
    final keys = await deriveHapSessionKeys(sharedSecret);

    CastLogger.info('HAP session: connecting raw socket to $host:$port');
    final socket = await Socket.connect(host, port);

    CastLogger.info('HAP session: encrypted session established');
    return HapSession(
      socket: socket,
      outputKey: keys.outputKey,
      inputKey: keys.inputKey,
      host: host,
      port: port,
      sessionId: sessionId,
      sharedSecret: sharedSecret,
    );
  }
}

/// Exception thrown when the HAP encrypted session encounters an error.
class HapSessionException implements Exception {
  /// Description of the error.
  final String message;

  HapSessionException(this.message);

  @override
  String toString() => 'HapSessionException: $message';
}
