import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:dart_cast/src/core/ts_dvb_stripper.dart';
import 'package:test/test.dart';

/// Upstream behaviour the proxy has to cope with, one path per case.
class _Upstream {
  late HttpServer server;
  final requests = <String, HttpHeaders>{};

  String get origin => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requests[path] = request.headers;
      final response = request.response;
      switch (path) {
        case '/a/index.m3u8':
          response.redirect(Uri.parse('$origin/b/index.m3u8'));
          return;
        case '/b/index.m3u8':
        case '/plain/index.m3u8':
          // Answers a Range request with a 206 slice, like a CDN would.
          final body = utf8.encode(
            '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXTINF:6.0,\nseg.ts\n#EXT-X-ENDLIST\n',
          );
          final range = request.headers.value('Range');
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          if (range != null) {
            response.statusCode = HttpStatus.partialContent;
            response.headers.set('Content-Range', 'bytes 0-9/${body.length}');
            response.add(body.sublist(0, 10));
          } else {
            response.add(body);
          }
        case '/segment.vtt':
          response.headers.contentType = ContentType('text', 'vtt');
          response.write(
            'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n'
            '00:00:01.000 --> 00:00:02.000\nHi\n',
          );
        case '/gzipped.mp4':
          // gzip-encoded pass-through media: HttpClient decompresses it.
          final raw = List<int>.generate(10240, (i) => i % 251);
          final gz = gzip.encode(raw);
          response.headers.contentType = ContentType('video', 'mp4');
          response.headers.set('Content-Encoding', 'gzip');
          response.headers.set('Content-Length', gz.length.toString());
          response.add(gz);
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

Future<({int status, HttpHeaders headers, List<int> body})> _get(
  String url, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.fold<List<int>>(
      <int>[],
      (a, c) => a..addAll(c),
    );
    return (status: response.statusCode, headers: response.headers, body: body);
  } finally {
    client.close(force: true);
  }
}

/// A 188-byte TS packet on [pid] with payload_unit_start set, carrying
/// [section] after a zero pointer_field.
Uint8List _psiPacket(int pid, List<int> section) {
  final packet = Uint8List(188)..fillRange(4, 188, 0xFF);
  packet[0] = 0x47;
  packet[1] = 0x40 | ((pid >> 8) & 0x1F);
  packet[2] = pid & 0xFF;
  packet[3] = 0x10; // payload only
  packet[4] = 0x00; // pointer_field
  packet.setRange(5, 5 + section.length, section);
  return packet;
}

Uint8List _payloadPacket(int pid) {
  final packet = Uint8List(188);
  packet[0] = 0x47;
  packet[1] = (pid >> 8) & 0x1F;
  packet[2] = pid & 0xFF;
  packet[3] = 0x10;
  return packet;
}

void main() {
  group('MediaProxy HTTP and HLS compliance', () {
    late _Upstream upstream;
    late MediaProxy proxy;

    setUp(() async {
      upstream = _Upstream();
      await upstream.start();
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await upstream.stop();
    });

    test(
      'relative playlist URIs resolve against the post-redirect URL',
      () async {
        final url = proxy.registerMedia('${upstream.origin}/a/index.m3u8');
        final response = await _get(url);
        final body = utf8.decode(response.body);
        expect(
          body,
          contains(Uri.encodeComponent('${upstream.origin}/b/seg.ts')),
        );
        expect(
          body,
          isNot(contains(Uri.encodeComponent('${upstream.origin}/a/seg.ts'))),
        );
      },
    );

    test('a Range request on a playlist still gets the whole playlist, '
        'rewritten', () async {
      final url = proxy.registerMedia('${upstream.origin}/plain/index.m3u8');
      final response = await _get(url, headers: {'Range': 'bytes=0-9'});
      expect(upstream.requests['/plain/index.m3u8']!.value('Range'), isNull);
      expect(response.status, HttpStatus.ok);
      expect(utf8.decode(response.body), contains('/stream/'));
    });

    test(
      'X-TIMESTAMP-MAP stays on WebVTT segments fetched via a playlist',
      () async {
        final url = proxy.registerMedia('${upstream.origin}/plain/index.m3u8');
        final segmentUrl =
            '$url${url.contains('?') ? '&' : '?'}url='
            '${Uri.encodeComponent('${upstream.origin}/segment.vtt')}';
        final response = await _get(segmentUrl);
        expect(utf8.decode(response.body), contains('X-TIMESTAMP-MAP'));
      },
    );

    test('a sidecar WebVTT still has X-TIMESTAMP-MAP stripped', () async {
      final url = proxy.registerSubtitle('${upstream.origin}/segment.vtt');
      final response = await _get(url);
      expect(utf8.decode(response.body), isNot(contains('X-TIMESTAMP-MAP')));
    });

    test('a gzip upstream body is not cut short by its compressed '
        'Content-Length', () async {
      final url = proxy.registerMedia('${upstream.origin}/gzipped.mp4');
      final response = await _get(url);
      expect(response.status, HttpStatus.ok);
      expect(response.body.length, 10240);
    });

    test('synthetic playlists carry CORS, Date and a UTF-8 charset', () async {
      final url = proxy.registerSubtitlePlaylist(
        '${upstream.origin}/segment.vtt',
      );
      final response = await _get(url);
      expect(response.headers.value('Access-Control-Allow-Origin'), '*');
      expect(response.headers.value('Date'), isNotNull);
      expect(response.headers.contentType?.charset, 'utf-8');
      expect(utf8.decode(response.body), contains('#EXT-X-VERSION:3'));
    });

    test(
      'subtitle wrapper keeps quotes and newlines out of quoted strings',
      () async {
        final url = proxy.registerSubtitleWrapper(
          originalM3u8ProxyUrl: 'http://x/master.m3u8',
          subtitleEntries: [
            (name: 'Director "cut"\nnotes', language: 'en', url: 'http://x/s'),
          ],
        );
        final body = utf8.decode((await _get(url)).body);
        final media = body
            .split('\n')
            .firstWhere((l) => l.startsWith('#EXT-X-MEDIA:'));
        expect(media, contains('NAME="Director \'cut\' notes"'));
        expect(media, contains('URI="http://x/s"'));
      },
    );
  });

  group('subtitle wrapper over a master playlist', () {
    late HttpServer origin;
    late MediaProxy proxy;

    setUp(() async {
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXT-X-VERSION:4\n'
          '#EXT-X-STREAM-INF:SUBTITLES="old",BANDWIDTH=900000\nhi.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=300000,CODECS="avc1.42e01e"\nlo.m3u8\n',
        );
        await request.response.close();
      });
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await origin.close(force: true);
    });

    test('copies the variants instead of nesting the master', () async {
      final master = proxy.registerMedia(
        'http://127.0.0.1:${origin.port}/master.m3u8',
      );
      final url = proxy.registerSubtitleWrapper(
        originalM3u8ProxyUrl: master,
        subtitleEntries: [(name: 'English', language: 'en', url: 'http://s')],
      );
      final body = utf8.decode((await _get(url)).body);
      final lines = body.split('\n');
      final variants =
          lines.where((l) => l.startsWith('#EXT-X-STREAM-INF:')).toList();
      expect(variants, hasLength(2));
      expect(variants, everyElement(endsWith('SUBTITLES="dart_cast_subs"')));
      expect(
        variants.first,
        '#EXT-X-STREAM-INF:BANDWIDTH=900000,'
        'SUBTITLES="dart_cast_subs"',
      );
      expect(body, contains('#EXT-X-MEDIA:TYPE=SUBTITLES'));
      // The URI after each STREAM-INF is a media playlist, never the master.
      expect(lines, isNot(contains(master)));
    });
  });

  group('DLNA subtitle variants', () {
    late MediaProxy proxy;
    late Directory dir;

    setUp(() async {
      proxy = MediaProxy();
      await proxy.start();
      dir = await Directory.systemTemp.createTemp('dart_cast_sub_');
    });

    tearDown(() async {
      await proxy.stop();
      await dir.delete(recursive: true);
    });

    test(
      'the SRT variant of a local SRT is served as SRT, not WebVTT',
      () async {
        final file = File('${dir.path}/movie.srt');
        await file.writeAsString('1\n00:00:01,000 --> 00:00:02,000\nHello\n');

        final variants = proxy.registerSubtitleVariants('file://${file.path}');
        final srt = variants.firstWhere((v) => v.format == 'srt');
        final vtt = variants.firstWhere((v) => v.format == 'vtt');

        final srtResponse = await _get(srt.url);
        expect(srtResponse.headers.contentType?.mimeType, 'text/srt');
        final srtBody = utf8.decode(srtResponse.body);
        expect(srtBody, isNot(startsWith('WEBVTT')));
        expect(srtBody, contains('00:00:01,000 --> 00:00:02,000'));

        final vttBody = utf8.decode((await _get(vtt.url)).body);
        expect(vttBody, startsWith('WEBVTT'));
      },
    );

    test('a Latin-1 SRT file is converted instead of failing', () async {
      final file = File('${dir.path}/latin1.srt');
      await file.writeAsBytes(
        latin1.encode('1\n00:00:01,000 --> 00:00:02,000\nCafé\n'),
      );
      final variants = proxy.registerSubtitleVariants('file://${file.path}');
      final vtt = variants.firstWhere((v) => v.format == 'vtt');
      expect(utf8.decode((await _get(vtt.url)).body), contains('Café'));
    });

    test('remote subtitles are labelled as the WebVTT the proxy serves', () {
      final variants = proxy.registerSubtitleVariants(
        'http://example.com/subs.srt',
      );
      expect(variants.single.format, 'vtt');
    });
  });

  group('TsDvbStripper', () {
    test('keeps a PMT and elementary stream that the PAT/PMT put on DVB '
        'PIDs', () {
      // PAT: program 1 → PMT on PID 0x0011 (the SDT PID in DVB).
      final pat = _psiPacket(0x0000, [
        0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, //
        0x00, 0x01, 0xE0, 0x11, //
        0x00, 0x00, 0x00, 0x00, // CRC (not checked)
      ]);
      // PMT: PCR on 0x0012, one H.264 stream on 0x0012.
      final pmt = _psiPacket(0x0011, [
        0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, //
        0xE0, 0x12, 0xF0, 0x00, //
        0x1B, 0xE0, 0x12, 0xF0, 0x00, //
        0x00, 0x00, 0x00, 0x00, // CRC (not checked)
      ]);
      final stripper = TsDvbStripper();
      final out = stripper.process([
        ...pat,
        ...pmt,
        ..._payloadPacket(0x0012),
        ..._payloadPacket(0x0014), // a real TDT: still dropped
      ]);
      expect(out.length, 188 * 3);
      expect(stripper.packetsDropped, 1);
    });

    test('still drops DVB tables when the PAT does not claim their PIDs', () {
      final stripper = TsDvbStripper();
      final out = stripper.process([
        ..._payloadPacket(0x0011),
        ..._payloadPacket(0x0100),
      ]);
      expect(out.length, 188);
    });
  });
}
