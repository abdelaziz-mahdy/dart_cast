import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/http10_file_server.dart';
import 'package:dart_cast/src/core/media_source.dart';
import 'package:test/test.dart';

/// A raw HTTP/1.0 response as read off the wire.
class _RawResponse {
  final String statusLine;
  final Map<String, String> headers;
  final List<int> body;

  _RawResponse(this.statusLine, this.headers, this.body);

  int get status => int.parse(statusLine.split(' ')[1]);
}

/// Serves [source] through [Http10FileServer.serveSource] on a detached
/// socket, exactly as MediaProxy does.
class _Harness {
  final HttpServer _server;
  _Harness._(this._server);

  int get port => _server.port;

  static Future<_Harness> start(
    MediaSource source, {
    String? contentFeatures,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      try {
        await Http10FileServer.serveSource(
          socket,
          source,
          request,
          contentFeatures: contentFeatures,
        );
      } catch (_) {
        // A crash here is what the tests look for: no status line arrives.
      } finally {
        await socket.close();
      }
    });
    return _Harness._(server);
  }

  /// Sends a raw request with [headers] and reads until the server closes.
  Future<_RawResponse> request({
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final buffer = StringBuffer('$method /file HTTP/1.1\r\nHost: x\r\n');
    headers.forEach((k, v) => buffer.write('$k: $v\r\n'));
    buffer.write('\r\n');
    socket.add(latin1.encode(buffer.toString()));
    await socket.flush();
    final bytes = <int>[];
    await socket.listen(bytes.addAll).asFuture<void>();
    socket.destroy();

    // Split head and body on the first CRLFCRLF.
    var split = -1;
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        split = i;
        break;
      }
    }
    if (split < 0) {
      return _RawResponse('', const {}, bytes);
    }
    final head = latin1.decode(bytes.sublist(0, split)).split('\r\n');
    final parsed = <String, String>{};
    for (final line in head.skip(1)) {
      final colon = line.indexOf(':');
      parsed[line.substring(0, colon).trim().toLowerCase()] =
          line.substring(colon + 1).trim();
    }
    return _RawResponse(head.first, parsed, bytes.sublist(split + 4));
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  final tenBytes = List<int>.generate(10, (i) => i);

  group('Http10FileServer range handling (RFC 9110 §14)', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start(
        MediaSource.bytes(tenBytes, contentType: 'video/mp4'),
      );
    });
    tearDown(() => harness.stop());

    test('a single satisfiable range still gets 206', () async {
      final r = await harness.request(headers: {'Range': 'bytes=2-4'});
      expect(r.status, 206);
      expect(r.headers['content-range'], 'bytes 2-4/10');
      expect(r.body, [2, 3, 4]);
    });

    test('a multi-range request is ignored and served whole', () async {
      final r = await harness.request(headers: {'Range': 'bytes=0-1,4-5'});
      expect(r.statusLine, startsWith('HTTP/1.0 200'));
      expect(r.headers.containsKey('content-range'), isFalse);
      expect(r.body, tenBytes);
    });

    test('a junk range is ignored and served whole', () async {
      final r = await harness.request(headers: {'Range': 'bytes=abc-def'});
      expect(r.statusLine, startsWith('HTTP/1.0 200'));
      expect(r.body, tenBytes);
    });

    test('a range with last < first is invalid and ignored', () async {
      final r = await harness.request(headers: {'Range': 'bytes=5-2'});
      expect(r.statusLine, startsWith('HTTP/1.0 200'));
      expect(r.body, tenBytes);
    });

    test('bytes=-0 is unsatisfiable', () async {
      final r = await harness.request(headers: {'Range': 'bytes=-0'});
      expect(r.status, 416);
      expect(r.headers['content-range'], 'bytes */10');
      expect(r.body, isEmpty);
    });

    test('a range starting past the end is unsatisfiable', () async {
      final r = await harness.request(headers: {'Range': 'bytes=10-'});
      expect(r.status, 416);
      expect(r.headers['content-range'], 'bytes */10');
    });

    test('every response carries a Date header (RFC 9110 §6.6.1)', () async {
      final ok = await harness.request();
      expect(ok.headers['date'], isNotNull);
      expect(() => HttpDate.parse(ok.headers['date']!), returnsNormally);

      final unsatisfiable = await harness.request(
        headers: {'Range': 'bytes=-0'},
      );
      expect(unsatisfiable.headers['date'], isNotNull);
    });
  });

  group('Http10FileServer zero-length source', () {
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start(
        MediaSource.bytes(const [], contentType: 'text/plain'),
      );
    });
    tearDown(() => harness.stop());

    test('a plain GET is 200 with an empty body, not 416', () async {
      final r = await harness.request();
      expect(r.status, 200);
      expect(r.headers['content-length'], '0');
      expect(r.body, isEmpty);
    });

    test('a suffix range does not crash the connection', () async {
      final r = await harness.request(headers: {'Range': 'bytes=-5'});
      expect(r.statusLine, startsWith('HTTP/1.0 '));
      expect(r.body, isEmpty);
    });

    test('bytes=0- on an empty source is unsatisfiable', () async {
      final r = await harness.request(headers: {'Range': 'bytes=0-'});
      expect(r.status, 416);
      expect(r.headers['content-range'], 'bytes */0');
    });
  });

  group('Http10FileServer DLNA transfer headers (DLNA 7.4.1.3)', () {
    const features =
        'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
        'DLNA.ORG_FLAGS=01700000000000000000000000000000';
    late _Harness harness;

    setUp(() async {
      harness = await _Harness.start(
        MediaSource.bytes(tenBytes, contentType: 'video/mp4'),
        contentFeatures: features,
      );
    });
    tearDown(() => harness.stop());

    test('answers getcontentFeatures and echoes transferMode', () async {
      final r = await harness.request(
        headers: {
          'getcontentFeatures.dlna.org': '1',
          'transferMode.dlna.org': 'Streaming',
        },
      );
      expect(r.status, 200);
      expect(r.headers['contentfeatures.dlna.org'], features);
      expect(r.headers['transfermode.dlna.org'], 'Streaming');
    });

    test('echoes the requested transfer mode, not a fixed one', () async {
      final r = await harness.request(
        method: 'HEAD',
        headers: {'transferMode.dlna.org': 'Interactive'},
      );
      expect(r.headers['transfermode.dlna.org'], 'Interactive');
    });

    test('adds neither header when the client did not ask', () async {
      final r = await harness.request();
      expect(r.headers.containsKey('contentfeatures.dlna.org'), isFalse);
      expect(r.headers.containsKey('transfermode.dlna.org'), isFalse);
    });

    test('does not echo an unknown transfer mode', () async {
      final r = await harness.request(
        headers: {'transferMode.dlna.org': 'Bogus\r\nX-Injected: 1'},
      );
      expect(r.headers.containsKey('transfermode.dlna.org'), isFalse);
      expect(r.headers.containsKey('x-injected'), isFalse);
    });
  });

  group('DlnaContentFeatures', () {
    test('names no DLNA.ORG_PN profile for media it never inspected', () {
      for (final value in [
        DlnaContentFeatures.pipedTransportStream,
        DlnaContentFeatures.forByteSeekableMime('video/mp4')!,
        DlnaContentFeatures.forByteSeekableMime('video/mp2t')!,
        DlnaContentFeatures.forByteSeekableMime('video/x-matroska')!,
      ]) {
        expect(value, isNot(contains('DLNA.ORG_PN')));
      }
    });

    test('builds the 4th protocolInfo field', () {
      expect(
        DlnaContentFeatures.build(
          profile: 'MPEG_TS_HD_NA_ISO',
          timeSeek: true,
          byteSeek: false,
        ),
        'DLNA.ORG_PN=MPEG_TS_HD_NA_ISO;DLNA.ORG_OP=10;DLNA.ORG_CI=0;'
        'DLNA.ORG_FLAGS=01700000000000000000000000000000',
      );
      expect(
        DlnaContentFeatures.build(timeSeek: false, byteSeek: true),
        'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
        'DLNA.ORG_FLAGS=01700000000000000000000000000000',
      );
    });

    test('defaults by MIME type for byte-seekable file routes', () async {
      final harness = await _Harness.start(
        MediaSource.bytes(tenBytes, contentType: 'video/mp2t'),
      );
      addTearDown(harness.stop);
      final r = await harness.request(
        headers: {'getcontentFeatures.dlna.org': '1'},
      );
      expect(
        r.headers['contentfeatures.dlna.org'],
        DlnaContentFeatures.forByteSeekableMime('video/mp2t'),
      );
      expect(
        r.headers['contentfeatures.dlna.org'],
        startsWith('DLNA.ORG_OP=01;'),
      );
    });
  });
}
