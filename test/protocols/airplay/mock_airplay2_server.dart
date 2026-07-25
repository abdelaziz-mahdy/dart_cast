import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/binary_plist.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';

/// One request the mock received, already decrypted and parsed.
class RecordedRequest {
  /// HTTP/RTSP method, e.g. `POST` or `SETUP`.
  final String method;

  /// Request target including any query string, e.g. `/rate?value=1.000000`.
  final String target;

  /// Protocol from the request line: `HTTP/1.1` or `RTSP/1.0`.
  final String protocol;

  /// Request headers with lower-cased keys.
  final Map<String, String> headers;

  /// Raw request body.
  final Uint8List body;

  RecordedRequest({
    required this.method,
    required this.target,
    required this.protocol,
    required this.headers,
    required this.body,
  });

  /// The target without its query string.
  String get path => target.split('?').first;

  /// The query string, or an empty string when there is none.
  String get query {
    final index = target.indexOf('?');
    return index == -1 ? '' : target.substring(index + 1);
  }

  /// Whether this request was sent over RTSP rather than HTTP.
  bool get isRtsp => protocol.startsWith('RTSP');

  /// The body decoded as a binary plist, or `{}` when it is not one.
  Map<String, dynamic> get plistBody {
    if (body.isEmpty) return {};
    try {
      return BinaryPlistDecoder.decode(body);
    } on FormatException {
      return {};
    }
  }

  @override
  String toString() => '$method $target ($protocol)';
}

/// An adversarial AirPlay 2 receiver for tests.
///
/// The old [MockAirPlayServer] accepted every request the package sent, which
/// is exactly why hundreds of passing tests coexisted with a protocol that had
/// never once worked against hardware. This one refuses the things a real
/// AirPlay 2 receiver refuses:
///
/// - `SETUP` without a non-zero `timingPort` and `timingProtocol: "NTP"` is
///   rejected with 400.
/// - `/playback-info` is answered with a **binary** plist, not XML.
/// - playback rate stays at `0.0` until `POST /rate` arrives — an AirPlay 2
///   `/play` starts the item paused, so forgetting `/rate` produces a session
///   that is stuck at `paused` instead of one that silently looks fine.
/// - `duration` is only reported once `/play` has been accepted, matching a
///   receiver that has nothing loaded.
///
/// It speaks the HAP encrypted framing with a fixed key. Pairing itself is
/// covered by `airplay_transient_auth_test.dart`; reproducing an SRP verifier
/// here would test the mock rather than the package.
class MockAirPlay2Server {
  /// The fixed symmetric key both sides use, so tests can skip pair-verify.
  static final Uint8List sessionKey = Uint8List.fromList(
    List<int>.generate(32, (i) => i),
  );

  ServerSocket? _server;
  final List<HapSession> _sessions = [];
  final List<Socket> _sockets = [];

  /// Every request received, in arrival order.
  final List<RecordedRequest> requests = [];

  /// Whether SETUP must carry a usable timing port. Turn off to test that the
  /// package would otherwise be refused.
  bool requireTimingPort = true;

  /// `eventPort` reported in the SETUP response. 0 disables the event channel.
  int eventPort = 0;

  /// Status code returned for `SETUP`.
  int setupStatus = 200;

  /// Status code returned for `RECORD`.
  int recordStatus = 200;

  /// Status code returned for `POST /play`.
  int playStatus = 200;

  /// Optional per-request override for `/play`, so a test can answer the
  /// AirPlay 2 form differently from the AirPlay 1 one.
  int Function(RecordedRequest request)? onPlay;

  /// Status code returned for `POST /rate`.
  int rateStatus = 200;

  /// Media duration reported once playback has started.
  double duration = 120.0;

  /// Current position reported by `/playback-info`.
  double position = 3.0;

  /// An `error` dict to include in `/playback-info`, when set.
  Map<String, dynamic>? playbackError;

  /// The `timingPort` seen in the SETUP body, or null if SETUP never arrived.
  int? observedTimingPort;

  /// The `timingProtocol` seen in the SETUP body.
  String? observedTimingProtocol;

  /// The RTSP URI the client used for SETUP.
  String? observedRtspUri;

  bool _playing = false;
  double _rate = 0.0;

  /// The rate the receiver is currently at: 0.0 until `/rate` is sent.
  double get rate => _rate;

  /// Whether a `/play` has been accepted.
  bool get isPlaying => _playing;

  /// Targets of every request, in order — convenient for sequence assertions.
  List<String> get requestTargets =>
      requests.map((r) => '${r.method} ${r.target}').toList();

  /// The port the mock is listening on.
  int get port => _server!.port;

  /// Starts the mock on an ephemeral loopback port.
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleConnection);
  }

  /// Connects a client [HapSession] keyed with [sessionKey].
  Future<HapSession> connectClient({String sessionId = 'mock-session'}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    _sockets.add(socket);
    return HapSession(
      socket: socket,
      outputKey: Uint8List.fromList(sessionKey),
      inputKey: Uint8List.fromList(sessionKey),
      host: '127.0.0.1',
      port: port,
      sessionId: sessionId,
    );
  }

  void _handleConnection(Socket socket) {
    _sockets.add(socket);
    final session = HapSession(
      socket: socket,
      outputKey: Uint8List.fromList(sessionKey),
      inputKey: Uint8List.fromList(sessionKey),
      host: '127.0.0.1',
      port: port,
    );
    _sessions.add(session);
    unawaited(_serve(session, socket));
  }

  Future<void> _serve(HapSession session, Socket socket) async {
    final buffer = BytesBuilder(copy: false);
    while (true) {
      final Uint8List chunk;
      try {
        chunk = await session.readDecryptedData(
          timeout: const Duration(seconds: 10),
        );
      } catch (_) {
        return;
      }
      if (chunk.isEmpty) return;
      buffer.add(chunk);

      while (true) {
        final bytes = Uint8List.fromList(buffer.toBytes());
        final request = _tryParse(bytes);
        if (request == null) break;
        buffer.clear();
        buffer.add(bytes.sublist(request.consumed));
        requests.add(request.request);
        try {
          await _respond(session, socket, request.request);
        } catch (_) {
          return;
        }
      }
    }
  }

  ({RecordedRequest request, int consumed})? _tryParse(Uint8List data) {
    final headerEnd = _findHeaderEnd(data);
    if (headerEnd == -1) return null;

    final headerText = utf8.decode(data.sublist(0, headerEnd));
    final lines = headerText.split('\r\n');
    final parts = lines.first.split(' ');
    if (parts.length < 3) return null;

    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] =
            line.substring(colon + 1).trim();
      }
    }

    final bodyStart = headerEnd + 4;
    final contentLength = int.tryParse(headers['content-length'] ?? '0') ?? 0;
    if (data.length < bodyStart + contentLength) return null;

    return (
      request: RecordedRequest(
        method: parts[0],
        target: parts[1],
        protocol: parts[2],
        headers: headers,
        body: Uint8List.fromList(
          data.sublist(bodyStart, bodyStart + contentLength),
        ),
      ),
      consumed: bodyStart + contentLength,
    );
  }

  Future<void> _respond(
    HapSession session,
    Socket socket,
    RecordedRequest request,
  ) async {
    switch (request.method) {
      case 'SETUP':
        observedRtspUri = request.target;
        final body = request.plistBody;
        observedTimingPort = (body['timingPort'] as num?)?.toInt();
        observedTimingProtocol = body['timingProtocol'] as String?;
        if (requireTimingPort &&
            ((observedTimingPort ?? 0) <= 0 ||
                observedTimingProtocol != 'NTP')) {
          await _send(
            session,
            socket,
            request,
            400,
            'Bad Request',
            reasonHeader:
                'SETUP needs a non-zero timingPort with timingProtocol NTP',
          );
          return;
        }
        await _send(
          session,
          socket,
          request,
          setupStatus,
          setupStatus == 200 ? 'OK' : 'Error',
          body: BinaryPlistEncoder.encode({'eventPort': eventPort}),
          contentType: 'application/x-apple-binary-plist',
        );
        return;

      case 'RECORD':
        await _send(
          session,
          socket,
          request,
          recordStatus,
          recordStatus == 200 ? 'OK' : 'Error',
        );
        return;
    }

    switch (request.path) {
      case '/play':
        final status = onPlay?.call(request) ?? playStatus;
        if (status == 200) _playing = true;
        await _send(
          session,
          socket,
          request,
          status,
          status == 200 ? 'OK' : 'Error',
        );
        return;

      case '/rate':
        if (rateStatus == 200) {
          final value = Uri.splitQueryString(request.query)['value'];
          _rate = double.tryParse(value ?? '') ?? _rate;
        }
        await _send(
          session,
          socket,
          request,
          rateStatus,
          rateStatus == 200 ? 'OK' : 'Error',
        );
        return;

      case '/playback-info':
        await _send(
          session,
          socket,
          request,
          200,
          'OK',
          body: BinaryPlistEncoder.encode({
            if (_playing) 'duration': duration,
            'position': position,
            'rate': _rate,
            'readyToPlay': _playing,
            'playbackBufferEmpty': false,
            'playbackLikelyToKeepUp': true,
            if (playbackError != null) 'error': playbackError!,
          }),
          contentType: 'application/x-apple-binary-plist',
        );
        return;

      case '/stop':
        _playing = false;
        _rate = 0.0;
        await _send(session, socket, request, 200, 'OK');
        return;

      default:
        // /feedback, /setProperty, /scrub and anything else: accept it.
        await _send(session, socket, request, 200, 'OK');
    }
  }

  Future<void> _send(
    HapSession session,
    Socket socket,
    RecordedRequest request,
    int statusCode,
    String reason, {
    List<int> body = const [],
    String? contentType,
    String? reasonHeader,
  }) async {
    final protocol = request.isRtsp ? 'RTSP/1.0' : 'HTTP/1.1';
    final buffer = StringBuffer()..write('$protocol $statusCode $reason\r\n');
    final cseq = request.headers['cseq'];
    if (cseq != null) buffer.write('CSeq: $cseq\r\n');
    // Echoed so tests can prove a response was matched to its own request.
    buffer.write('X-Mock-Target: ${request.method} ${request.target}\r\n');
    if (contentType != null) buffer.write('Content-Type: $contentType\r\n');
    if (reasonHeader != null) buffer.write('X-Mock-Reason: $reasonHeader\r\n');
    buffer
      ..write('Content-Length: ${body.length}\r\n')
      ..write('\r\n');

    final bytes = Uint8List.fromList([
      ...utf8.encode(buffer.toString()),
      ...body,
    ]);
    socket.add(await session.encrypt(bytes));
    await socket.flush();
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

  /// Stops the mock and drops every connection it holds.
  Future<void> stop() async {
    for (final session in _sessions) {
      await session.close();
    }
    _sessions.clear();
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    await _server?.close();
    _server = null;
  }
}
