import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A raw HTTP/1.1 response read off a [Socket].
class SocketHttpResponse {
  /// HTTP status code.
  final int statusCode;

  /// Response headers, with lower-cased keys.
  final Map<String, String> headers;

  /// Response body bytes.
  final Uint8List body;

  const SocketHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  @override
  String toString() => 'SocketHttpResponse($statusCode, ${body.length} bytes)';
}

/// Thrown when a raw-socket HTTP exchange fails.
class SocketHttpException implements Exception {
  /// Description of the failure.
  final String message;

  /// The status code that caused the failure, when there was one.
  final int? statusCode;

  SocketHttpException(this.message, {this.statusCode});

  @override
  String toString() => 'SocketHttpException: $message';
}

/// Speaks plain HTTP/1.1 over an already-connected [Socket].
///
/// AirPlay binds authentication state to the TCP connection, so pairing has to
/// happen on the same socket that is later promoted to an encrypted session.
/// A normal `http.Client` opens its own connection and cannot be used for
/// that; this class fills the gap.
///
/// The socket is never closed here — ownership stays with the caller, which
/// hands it to the HAP session once pairing completes. Call [release] before
/// that handover so this channel stops buffering bytes meant for the
/// encrypted reader.
class SocketHttpChannel {
  final Socket _socket;
  final String host;
  final int port;

  StreamSubscription<Uint8List>? _subscription;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<void>? _dataArrived;
  bool _done = false;

  /// Wraps [socket]. When the socket's stream is already being shared, pass a
  /// broadcast [dataStream] instead of letting this class listen directly.
  SocketHttpChannel(
    Socket socket, {
    required this.host,
    required this.port,
    Stream<Uint8List>? dataStream,
  }) : _socket = socket {
    final source = dataStream ?? socket;
    _subscription = source.listen(
      (data) {
        _buffer.add(data);
        _dataArrived?.complete();
        _dataArrived = null;
      },
      onError: (Object error) {
        _dataArrived?.completeError(error);
        _dataArrived = null;
      },
      onDone: () {
        _done = true;
        _dataArrived?.completeError(
          SocketHttpException('Socket closed while awaiting a response'),
        );
        _dataArrived = null;
      },
    );
  }

  /// Sends `POST [path]` and waits for the complete response.
  Future<SocketHttpResponse> post(
    String path, {
    Map<String, String> headers = const {},
    List<int> body = const [],
    Duration timeout = const Duration(seconds: 30),
  }) => send('POST', path, headers: headers, body: body, timeout: timeout);

  /// Sends a request and waits for the complete response.
  Future<SocketHttpResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int> body = const [],
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request =
        StringBuffer()
          ..write('$method $path HTTP/1.1\r\n')
          ..write('Host: $host:$port\r\n');
    for (final entry in headers.entries) {
      request.write('${entry.key}: ${entry.value}\r\n');
    }
    request
      ..write('Content-Length: ${body.length}\r\n')
      ..write('\r\n');

    _socket.add(utf8.encode(request.toString()));
    if (body.isNotEmpty) _socket.add(body);
    await _socket.flush();

    return _readResponse(timeout);
  }

  Future<SocketHttpResponse> _readResponse(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);

    while (true) {
      if (_buffer.length > 0) {
        final accumulated = Uint8List.fromList(_buffer.toBytes());
        final parsed = _tryParse(accumulated);
        if (parsed != null) {
          _buffer.clear();
          if (parsed.consumed < accumulated.length) {
            _buffer.add(accumulated.sublist(parsed.consumed));
          }
          return parsed.response;
        }
        // Incomplete — put the bytes back and wait for more.
        _buffer.clear();
        _buffer.add(accumulated);
      }

      if (_done) {
        throw SocketHttpException('Socket closed while awaiting a response');
      }

      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative || remaining == Duration.zero) {
        throw SocketHttpException('Timed out awaiting a response');
      }

      _dataArrived = Completer<void>();
      await _dataArrived!.future.timeout(
        remaining,
        onTimeout:
            () => throw SocketHttpException('Timed out awaiting a response'),
      );
    }
  }

  ({SocketHttpResponse response, int consumed})? _tryParse(Uint8List data) {
    final headerEnd = _findHeaderEnd(data);
    if (headerEnd == -1) return null;

    final headerText = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4;

    final lines = headerText.split('\r\n');
    final statusMatch = RegExp(
      r'(?:HTTP|RTSP)/\d\.\d\s+(\d+)',
    ).firstMatch(lines.first);
    if (statusMatch == null) {
      throw SocketHttpException('Malformed status line: ${lines.first}');
    }
    final statusCode = int.parse(statusMatch.group(1)!);

    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] =
            line.substring(colon + 1).trim();
      }
    }

    final contentLength = int.tryParse(headers['content-length'] ?? '');
    if (contentLength == null) {
      // No Content-Length: treat the headers as the whole response.
      return (
        response: SocketHttpResponse(
          statusCode: statusCode,
          headers: headers,
          body: Uint8List(0),
        ),
        consumed: bodyStart,
      );
    }

    if (data.length < bodyStart + contentLength) return null;

    return (
      response: SocketHttpResponse(
        statusCode: statusCode,
        headers: headers,
        body: Uint8List.fromList(
          data.sublist(bodyStart, bodyStart + contentLength),
        ),
      ),
      consumed: bodyStart + contentLength,
    );
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

  /// Stops listening so the socket can be handed to the encrypted session.
  ///
  /// Without this the channel keeps every subsequent (encrypted) byte in its
  /// buffer for the life of the connection.
  Future<void> release() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
